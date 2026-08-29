// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// The built binary, run for real — the only test here that exercises `main.swift`'s flag
/// table, the drawing code and the two preview renderers end to end.
///
/// **Safety is the whole design of this file.** The same binary, given no arguments or the
/// wrong ones, puts a live status item in the owner's menu bar or talks to my.leviton.com with
/// the owner's real account. So:
///
/// - `allowedFlags` below is the complete list of flags this file may run, and every run goes
///   through `run(_:)`, which refuses anything not on it. Nothing here signs in, reads the
///   Keychain, opens a socket or touches a device: every flag on the list either draws a PNG,
///   prints a string, or fails the argument parse.
/// - A bare run and an unknown-argument-only run are deliberately absent: both fall out of
///   `main.swift`'s parse loop and launch the app.
/// - Each process runs in a fresh temp directory, so a stray `.leviton` in anybody's working
///   directory cannot be picked up, and with an environment built from scratch — PATH and HOME
///   only, and never a `MYLEVITON_*`.
/// - Every process has a 30 s watchdog that terminates then kills it and fails the test. A
///   hung process must not hang the suite.
final class CLISmokeTests: XCTestCase {

    // MARK: The safety envelope

    /// Exactly what may be run, by first flag — a run that starts with anything else (or with
    /// nothing at all, which is how the app is launched) never becomes a process.
    private static let allowedFlags: Set<String> = [
        "--render-icon", "--dump-menu", "--dump-internals", "--login-item-status", "--put", "-h",
    ]

    private static func isAllowed(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        return allowedFlags.contains(first)
    }

    /// A thread-safe drop box for a pipe's output — the drain runs on another queue.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func fill(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// The executable is built into the same directory as the test bundle.
    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("NimbusLevitonBar")
    }

    /// One finished run.
    private struct Run {
        var status: Int32
        var out: String
        var err: String
    }

    /// Run the binary once, in its own temp directory, on a scrubbed environment, under a
    /// watchdog. Returns nil (having failed the test) if it had to be killed.
    private func run(_ args: [String], file: StaticString = #filePath, line: UInt = #line) -> Run? {
        guard Self.isAllowed(args) else {
            XCTFail("refusing to run \(args): not on the allow-list — see this file's header", file: file, line: line)
            return nil
        }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("no binary at \(binary.path) — `swift test` should build it beside the test bundle",
                    file: file, line: line)
            return nil
        }

        let p = Process()
        p.executableURL = binary
        p.arguments = args
        p.currentDirectoryURL = tempDir()
        // Built from nothing, not filtered from ours: no MYLEVITON_EMAIL / MYLEVITON_PASSWORD /
        // MYLEVITON_ENV_FILE can reach the CLI's `.leviton` path this way.
        p.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                         "HOME": NSHomeDirectory()]

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice          // nothing can sit waiting on a prompt

        // Drain both pipes on their own threads: a process that fills the 64 KB pipe buffer
        // while we wait for it to exit would deadlock.
        let outSink = Sink(), errSink = Sink()
        let drained = DispatchGroup()
        for (pipe, sink) in [(outPipe, outSink), (errPipe, errSink)] {
            drained.enter()
            DispatchQueue.global().async {
                sink.fill(pipe.fileHandleForReading.readDataToEndOfFile())
                drained.leave()
            }
        }

        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch {
            XCTFail("could not run \(args): \(error)", file: file, line: line)
            return nil
        }

        if exited.wait(timeout: .now() + 30) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            XCTFail("\(args) did not exit within 30 s and was killed", file: file, line: line)
            return nil
        }
        _ = drained.wait(timeout: .now() + 5)
        return Run(status: p.terminationStatus,
                   out: String(decoding: outSink.value, as: UTF8.self),
                   err: String(decoding: errSink.value, as: UTF8.self))
    }

    /// A fresh directory per process, cleaned up when the test ends.
    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nlb-cli-smoke-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A PNG, not just a file: the renderers report success on stdout, so the magic bytes are
    /// what actually proves something was drawn.
    private func assertPNG(_ path: URL, file: StaticString = #filePath, line: UInt = #line) {
        guard let data = try? Data(contentsOf: path) else {
            XCTFail("no file at \(path.path)", file: file, line: line)
            return
        }
        XCTAssertGreaterThan(data.count, 1000, "a PNG this small is an empty canvas", file: file, line: line)
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "not a PNG", file: file, line: line)
    }

    /// The dumps draw offscreen, but they still want a window server. A test session without
    /// one skips rather than fails — and says so.
    private func skipIfNoWindowServer(_ r: Run, _ what: String) throws {
        if r.status != 0, r.out.contains("failed") || r.err.contains("connect to window server") {
            throw XCTSkip("\(what) could not render in this session (no window server): \(r.out)\(r.err)")
        }
    }

    // MARK: The runs

    func testBinaryIsWhereTheTestsExpectIt() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path), binary.path)
    }

    /// `build.sh icon` renders through this path, at every size in the iconset.
    func testRenderIcon() throws {
        let out = tempDir().appendingPathComponent("icon.png")
        let r = try XCTUnwrap(run(["--render-icon", out.path, "--size", "64"]))
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("64×64"), r.out)
        assertPNG(out)
    }

    /// `--dump-menu` is the layout check the whole of MenuRows is eyeballed through, so its
    /// exit status is worth a test of its own: it renders every row type with sample data.
    func testDumpMenu() throws {
        let out = tempDir().appendingPathComponent("menu.png")
        let r = try XCTUnwrap(run(["--dump-menu", out.path]))
        try skipIfNoWindowServer(r, "--dump-menu")
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("wrote"), r.out)
        assertPNG(out)
    }

    /// The Internals panel, built and drawn from a seeded session's worth of events — the one
    /// automated check that the panel's autolayout still resolves.
    func testDumpInternals() throws {
        let out = tempDir().appendingPathComponent("internals.png")
        let r = try XCTUnwrap(run(["--dump-internals", out.path]))
        try skipIfNoWindowServer(r, "--dump-internals")
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("wrote"), r.out)
        assertPNG(out)
    }

    /// Read-only: `SMAppService.mainApp.status` for a bare binary, which is one of the five
    /// strings `LoginItem.statusDescription` knows. It must not register anything.
    func testLoginItemStatus() throws {
        let r = try XCTUnwrap(run(["--login-item-status"]))
        XCTAssertEqual(r.status, 0, r.err)
        let printed = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(printed.isEmpty)
        XCTAssertTrue(["enabled", "not registered", "requires approval in System Settings › Login Items",
                       "not found", "unknown"].contains(printed), printed)
    }

    /// A flag whose value is missing must complain on stderr and exit 2 — not fall through the
    /// parse loop, which is what launches the app.
    func testMissingFlagValueIsUsage() throws {
        let r = try XCTUnwrap(run(["--put", "onlyonearg"]))
        XCTAssertEqual(r.status, 2)
        XCTAssertTrue(r.err.contains("--put needs a value"), r.err)
        XCTAssertTrue(r.out.contains("usage:"), r.out)
    }

    /// `-h` prints the usage — on stdout, so it can be piped — and exits 2.
    func testHelpExitsTwo() throws {
        let r = try XCTUnwrap(run(["-h"]))
        XCTAssertEqual(r.status, 2)
        XCTAssertTrue(r.out.hasPrefix("usage: NimbusLevitonBar"), r.out)
        XCTAssertTrue(r.err.isEmpty, r.err)
        // The usage line is the flag table's own summary; these are the ones the tests and
        // build.sh depend on being there.
        for flag in ["--render-icon", "--dump-menu", "--dump-internals", "--login-item-status"] {
            XCTAssertTrue(r.out.contains(flag), "usage no longer mentions \(flag)")
        }
    }

    /// The allow-list is the safety net, so it is itself tested — never by running one of the
    /// forbidden vectors, only by asking the gate about it.
    func testTheAllowListRefusesEverythingElse() {
        for args in [[], ["--print"], ["--set", "Desk", "100"], ["--login", "a@b.c"], ["--logout"],
                     ["--watch"], ["--get", "Residences"], ["--scenes"], ["--scene", "Evening"],
                     ["--room", "Alcove", "on"], ["--check-update"], ["--enable-login-item"],
                     ["--nonsense"], ["-psn_0_1234"]] {
            XCTAssertFalse(Self.isAllowed(args), "\(args) must never reach a Process")
        }
        XCTAssertTrue(Self.isAllowed(["--dump-menu", "/tmp/x.png"]))
        XCTAssertTrue(Self.isAllowed(["-h"]))
    }
}
