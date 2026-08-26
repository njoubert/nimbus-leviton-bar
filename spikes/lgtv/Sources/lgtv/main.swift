// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// A scratch instrument for Phase 0 of docs/lg-tv-plan.md, kept because the questions it
// answers keep coming back. It shares no code with the app and the app shares none with it.
// Unbuffered: `watch` is meant to be tailed and piped, and a buffered line that only appears
// when the process is killed is worse than no line at all.
setvbuf(stdout, nil, _IONBF, 0)

do {
    exit(try await Commands.run(Array(CommandLine.arguments.dropFirst())))
} catch {
    FileHandle.standardError.write(Data("✗ \(error.localizedDescription)\n".utf8))
    exit(1)
}
