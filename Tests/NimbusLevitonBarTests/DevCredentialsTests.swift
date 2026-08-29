// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusLevitonBar

/// The CLI-only `.leviton` file: its parser, the environment-over-file precedence, the
/// permissions warning, and the session cache that stops the CLI logging in once per command.
///
/// Every test drives `load()` through `MYLEVITON_ENV_FILE` pointed into a fresh temp
/// directory — never the working directory, which in a real checkout may hold the owner's own
/// `.leviton`. Nothing here reads the Keychain or the network.
final class DevCredentialsTests: XCTestCase {

    private var dir: URL!
    /// What the ambient environment held before we started, so tearDown can put it back.
    private var savedEnv: [String: String?] = [:]
    private static let envKeys = ["MYLEVITON_ENV_FILE", "MYLEVITON_EMAIL", "MYLEVITON_PASSWORD"]

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevCredentialsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        for k in Self.envKeys {
            savedEnv[k] = env[k]
            unsetenv(k)
        }
    }

    override func tearDownWithError() throws {
        for k in Self.envKeys {
            if let v = savedEnv[k] ?? nil { setenv(k, v, 1) } else { unsetenv(k) }
        }
        savedEnv = [:]
        try? FileManager.default.removeItem(at: dir)
        dir = nil
    }

    // MARK: Helpers

    @discardableResult
    private func writeFile(_ name: String, _ text: String, mode: Int = 0o600) throws -> URL {
        let url = dir.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8),
                                                     attributes: [.posixPermissions: mode]))
        return url
    }

    private func mode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
    }

    /// `load()` with the warnings captured instead of printed.
    private func load() -> (store: DevCredentials.Store?, warnings: [String]) {
        var warnings: [String] = []
        let store = DevCredentials.load { warnings.append($0) }
        return (store, warnings)
    }

    // MARK: The probe this whole file rests on

    /// `DevCredentials.load()` reads `ProcessInfo.processInfo.environment`, and these tests
    /// steer it with `setenv`. Foundation is free to snapshot the environment at first use, in
    /// which case none of the `load()` tests below would mean anything — so check it outright.
    func testSetenvIsVisibleThroughProcessInfo() {
        _ = ProcessInfo.processInfo.environment            // force any snapshot to be taken first
        setenv("MYLEVITON_ENV_FILE", "/probe/value", 1)
        XCTAssertEqual(ProcessInfo.processInfo.environment["MYLEVITON_ENV_FILE"], "/probe/value",
                       "setenv is not visible through ProcessInfo — the load() tests are meaningless")
        unsetenv("MYLEVITON_ENV_FILE")
        XCTAssertNil(ProcessInfo.processInfo.environment["MYLEVITON_ENV_FILE"])
    }

    // MARK: parse

    func testParseTheOrdinaryFile() {
        let v = DevCredentials.parse("""
            MYLEVITON_EMAIL=you@example.com
            MYLEVITON_PASSWORD=hunter2
            """)
        XCTAssertEqual(v, ["MYLEVITON_EMAIL": "you@example.com", "MYLEVITON_PASSWORD": "hunter2"])
    }

    func testParseSkipsCommentsBlanksAndJunk() {
        let v = DevCredentials.parse("""
            # a comment
              # an indented comment

            not a setting
            A=1
            """)
        XCTAssertEqual(v, ["A": "1"])
    }

    /// The file is meant to be `source`-able, so `export` and quotes both come off.
    func testParseHandlesExportAndQuotes() {
        let v = DevCredentials.parse("""
            export A=1
            B="two"
            C='three'
            """)
        XCTAssertEqual(v, ["A": "1", "B": "two", "C": "three"])
    }

    func testParseStripsQuotesOnlyWhenBothEndsMatch() {
        let v = DevCredentials.parse("""
            A="unclosed
            B=unopened"
            C='mixed"
            D=""
            E="
            """)
        XCTAssertEqual(v["A"], "\"unclosed")
        XCTAssertEqual(v["B"], "unopened\"")
        XCTAssertEqual(v["C"], "'mixed\"")
        XCTAssertEqual(v["D"], "")            // "" is a matched pair around nothing
        XCTAssertEqual(v["E"], "\"")          // one character can't be a pair
    }

    /// Pinning what the code does rather than what one might wish: the two quote characters
    /// are stripped in sequence, so a doubly-quoted value loses both layers.
    func testParseStripsNestedQuotesInSequence() {
        XCTAssertEqual(DevCredentials.parse(#"A="'x'""#)["A"], "x")
        // …but only in that order: an inner double quote survives an outer single one.
        XCTAssertEqual(DevCredentials.parse("A='\"x\"'")["A"], "\"x\"")
    }

    func testParseKeepsEqualsSignsInTheValue() {
        XCTAssertEqual(DevCredentials.parse("MYLEVITON_PASSWORD=a=b=c")["MYLEVITON_PASSWORD"], "a=b=c")
    }

    func testParseTrimsWhitespaceAroundBothSides() {
        XCTAssertEqual(DevCredentials.parse("   A   =   b   ")["A"], "b")
    }

    func testParseDropsAnEmptyKey() {
        let v = DevCredentials.parse("=orphan\nA=1")
        XCTAssertEqual(v, ["A": "1"])
    }

    /// There is no trailing-comment syntax — a `#` after a value is part of the value. Worth
    /// knowing before someone annotates their `.leviton`.
    func testParseDoesNotStripTrailingComments() {
        XCTAssertEqual(DevCredentials.parse("A=1 # not a comment")["A"], "1 # not a comment")
    }

    // MARK: load

    func testLoadFromTheFile() throws {
        let file = try writeFile(".leviton", """
            MYLEVITON_EMAIL=you@example.com
            MYLEVITON_PASSWORD=hunter2
            """)
        setenv("MYLEVITON_ENV_FILE", file.path, 1)
        let (store, warnings) = load()
        let s = try XCTUnwrap(store)
        XCTAssertEqual(s.login, Keychain.Login(email: "you@example.com", password: "hunter2"))
        XCTAssertEqual(s.source, ".leviton")
        XCTAssertEqual(s.sessionFile, dir.appendingPathComponent(".leviton-session.json"))
        XCTAssertEqual(warnings, [])
    }

    /// The source is whatever the file is called — it is only ever printed at the user.
    func testLoadNamesTheFileItActuallyRead() throws {
        let file = try writeFile("creds.env", "MYLEVITON_EMAIL=a@b.c\nMYLEVITON_PASSWORD=pw")
        setenv("MYLEVITON_ENV_FILE", file.path, 1)
        let s = try XCTUnwrap(load().store)
        XCTAssertEqual(s.source, "creds.env")
        // The session cache keeps its fixed name, beside the file.
        XCTAssertEqual(s.sessionFile, dir.appendingPathComponent(".leviton-session.json"))
    }

    func testEnvironmentWinsOverTheFile() throws {
        let file = try writeFile(".leviton", "MYLEVITON_EMAIL=file@example.com\nMYLEVITON_PASSWORD=filepw")
        setenv("MYLEVITON_ENV_FILE", file.path, 1)
        setenv("MYLEVITON_EMAIL", "env@example.com", 1)
        setenv("MYLEVITON_PASSWORD", "envpw", 1)
        let s = try XCTUnwrap(load().store)
        XCTAssertEqual(s.login, Keychain.Login(email: "env@example.com", password: "envpw"))
        XCTAssertEqual(s.source, ".leviton")   // the file was still read, so it still names it
    }

    func testEnvironmentAloneSuffices() throws {
        let missing = dir.appendingPathComponent("nothing-here")
        setenv("MYLEVITON_ENV_FILE", missing.path, 1)
        setenv("MYLEVITON_EMAIL", "env@example.com", 1)
        setenv("MYLEVITON_PASSWORD", "envpw", 1)
        let (store, warnings) = load()
        let s = try XCTUnwrap(store)
        XCTAssertEqual(s.login, Keychain.Login(email: "env@example.com", password: "envpw"))
        XCTAssertEqual(s.source, "the environment")
        XCTAssertEqual(s.sessionFile, dir.appendingPathComponent(".leviton-session.json"))
        // The named file could not be read, and that is said out loud even though the
        // environment saved the day.
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("cannot be read"), warnings[0])
    }

    func testMissingFileAndNoEnvironmentWarnsAndFallsBack() {
        let missing = dir.appendingPathComponent("nothing-here")
        setenv("MYLEVITON_ENV_FILE", missing.path, 1)
        let (store, warnings) = load()
        XCTAssertNil(store)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("MYLEVITON_ENV_FILE"), warnings[0])
        XCTAssertTrue(warnings[0].contains("falling back to the Keychain"), warnings[0])
    }

    func testFilePresentButMissingTheKeysWarnsAndFallsBack() throws {
        let file = try writeFile(".leviton", "SOMETHING_ELSE=1")
        setenv("MYLEVITON_ENV_FILE", file.path, 1)
        let (store, warnings) = load()
        XCTAssertNil(store)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("no MYLEVITON_EMAIL/MYLEVITON_PASSWORD"), warnings[0])
    }

    /// An empty file parses to nothing at all, and the "no keys" warning is keyed off having
    /// parsed *something* — so this case is silent. Pinned as it stands.
    func testAnEmptyFileFallsBackSilently() throws {
        let file = try writeFile(".leviton", "\n# nothing\n")
        setenv("MYLEVITON_ENV_FILE", file.path, 1)
        let (store, warnings) = load()
        XCTAssertNil(store)
        XCTAssertEqual(warnings, [])
    }

    func testAnEmptyPasswordIsNotACredential() throws {
        let file = try writeFile(".leviton", "MYLEVITON_EMAIL=a@b.c\nMYLEVITON_PASSWORD=")
        setenv("MYLEVITON_ENV_FILE", file.path, 1)
        XCTAssertNil(load().store)
    }

    // MARK: Permissions

    func testAFileOthersCanReadIsCalledOut() throws {
        let file = try writeFile(".leviton", "MYLEVITON_EMAIL=a@b.c\nMYLEVITON_PASSWORD=pw", mode: 0o644)
        setenv("MYLEVITON_ENV_FILE", file.path, 1)
        let (store, warnings) = load()
        XCTAssertNotNil(store)                       // it still works; it just says so
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("readable by others"), warnings[0])
    }

    func testA0600FileIsNotCalledOut() throws {
        let file = try writeFile(".leviton", "MYLEVITON_EMAIL=a@b.c\nMYLEVITON_PASSWORD=pw", mode: 0o600)
        setenv("MYLEVITON_ENV_FILE", file.path, 1)
        XCTAssertEqual(load().warnings, [])
    }

    // MARK: The session cache

    private func store() -> DevCredentials.Store {
        DevCredentials.Store(login: Fixtures.login(), source: ".leviton",
                             sessionFile: dir.appendingPathComponent(DevCredentials.sessionFileName))
    }

    /// The cache is what keeps the CLI from logging in once per command — the thing that locks
    /// a My Leviton account — so it has to survive a round trip exactly.
    func testSessionRoundTripsAndIsWrittenPrivate() throws {
        let s = store()
        let session = Fixtures.session(token: "tok-cache-000", userId: "7",
                                       created: Date(timeIntervalSinceReferenceDate: 800_000_000),
                                       ttl: 5_184_000)
        s.saveSession(session)
        XCTAssertEqual(try mode(of: s.sessionFile), 0o600, "the cache is a bearer token")
        XCTAssertEqual(s.loadSession(), session)
    }

    func testSessionWithNoTtlRoundTrips() {
        let s = store()
        let session = Fixtures.session(token: "tok-no-ttl", created: Date(timeIntervalSinceReferenceDate: 1), ttl: nil)
        s.saveSession(session)
        XCTAssertEqual(s.loadSession(), session)
    }

    func testSaveSessionOverwritesTheOldOne() {
        let s = store()
        s.saveSession(Fixtures.session(token: "first"))
        s.saveSession(Fixtures.session(token: "second"))
        XCTAssertEqual(s.loadSession()?.token, "second")
    }

    func testLoadSessionIsNilWhenThereIsNothingOrItIsGarbage() throws {
        let s = store()
        XCTAssertNil(s.loadSession())                                  // no file at all
        try Data("not json".utf8).write(to: s.sessionFile)
        XCTAssertNil(s.loadSession())                                  // unreadable → sign in again
        try Data(#"{"token":"t"}"#.utf8).write(to: s.sessionFile)
        XCTAssertNil(s.loadSession())                                  // JSON, but not a Session
    }

    func testDeleteSessionRemovesTheFileAndForgivesItsAbsence() {
        let s = store()
        s.saveSession(Fixtures.session())
        s.deleteSession()
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.sessionFile.path))
        s.deleteSession()                                              // no throw, no crash
        XCTAssertNil(s.loadSession())
    }
}
