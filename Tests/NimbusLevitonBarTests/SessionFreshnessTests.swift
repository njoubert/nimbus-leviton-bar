// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusLevitonBar

/// `Keychain.Session.isFresh` — the one guard between the app and a login per command, which
/// is what locks a My Leviton account. No clock is mocked: `created` is picked relative to
/// `Date()` and every offset is minutes wide, so the assertions cannot race the wall clock.
final class SessionFreshnessTests: XCTestCase {

    /// The ttl My Leviton actually issues (60 days, measured 2026-08-24).
    private let realTTL: TimeInterval = 5_184_000
    private let day: TimeInterval = 86_400
    private let minute: TimeInterval = 60

    // MARK: No ttl

    func testNoTTLIsAlwaysFresh() {
        // Without a ttl there is no expiry to be early of, and a session we cannot date is
        // better used than thrown away — a 401 will retire it soon enough.
        XCTAssertTrue(session(createdAgo: 0, ttl: nil).isFresh)
        XCTAssertTrue(session(createdAgo: 3650 * day, ttl: nil).isFresh)
        XCTAssertNil(session(createdAgo: 0, ttl: nil).expiry)
    }

    // MARK: The real 60-day ttl — margin is the one-day cap

    func testFreshlyIssuedRealSessionIsFresh() {
        XCTAssertTrue(session(createdAgo: 0, ttl: realTTL).isFresh)
        XCTAssertTrue(session(createdAgo: 30 * day, ttl: realTTL).isFresh)
    }

    func testRealSessionGoesStaleADayBeforeItExpires() {
        // min(86_400, ttl/2) is 86_400 here, so the last day of the session's life is treated
        // as already gone: the app re-logs in on its own schedule instead of discovering the
        // 401 under someone's click.
        XCTAssertTrue(session(createdAgo: 59 * day - 5 * minute, ttl: realTTL).isFresh,
                      "five minutes before the margin opens it is still fresh")
        XCTAssertFalse(session(createdAgo: 59 * day + 5 * minute, ttl: realTTL).isFresh,
                       "five minutes into the margin it is stale")
    }

    func testExpiredRealSessionIsStale() {
        XCTAssertFalse(session(createdAgo: 61 * day, ttl: realTTL).isFresh)
    }

    // MARK: A short ttl — margin is ttl/2, and this is the case the fraction exists for

    func testShortTTLIsFreshTheMomentItIsIssued() {
        // The whole point of the ttl/2 term. A flat one-day margin against a one-hour ttl
        // would make a session stale the instant the server handed it over — one login per
        // app launch and per CLI command, which is how an account gets locked.
        XCTAssertTrue(session(createdAgo: 0, ttl: 3600).isFresh)
        XCTAssertTrue(session(createdAgo: 25 * minute, ttl: 3600).isFresh)
    }

    func testShortTTLGoesStaleHalfwayThrough() {
        XCTAssertFalse(session(createdAgo: 31 * minute, ttl: 3600).isFresh)
        XCTAssertFalse(session(createdAgo: 2 * 3600, ttl: 3600).isFresh)
    }

    // MARK: Helper

    private func session(createdAgo: TimeInterval, ttl: TimeInterval?) -> Keychain.Session {
        Fixtures.session(created: Date().addingTimeInterval(-createdAgo), ttl: ttl)
    }
}
