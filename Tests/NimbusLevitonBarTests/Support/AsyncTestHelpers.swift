// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest

/// Spin until `cond` holds (checking every 10 ms), failing the test at `timeout`. The store's
/// work happens in main-actor Tasks, so an async test just has to yield; this is the yield.
@MainActor
func waitUntil(_ what: String, timeout: TimeInterval = 5,
               file: StaticString = #filePath, line: UInt = #line,
               _ cond: @MainActor () -> Bool) async {
    let start = Date()
    while !cond() {
        if Date().timeIntervalSince(start) > timeout {
            XCTFail("timed out after \(timeout) s waiting for \(what)", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
