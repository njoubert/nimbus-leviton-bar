// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusLevitonBar

/// Canary for the shared support: the executable target imports, and MockHTTP really does
/// intercept a `LevitonClient` round trip (headers, body stream, JSON out).
final class SupportSmokeTests: XCTestCase {
    func testMockHTTPRoundTrip() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Residences/100/residentialRooms",
                  .json(200, [Fixtures.room(id: 1, name: "Alcove", power: "ON")]))
        let rooms = try await client.rooms(Fixtures.session(), residenceId: "100")
        XCTAssertEqual(rooms, [Room(id: "1", name: "Alcove", power: true)])
        let req = http.requests("GET", "Residences/100/residentialRooms")
        XCTAssertEqual(req.count, 1)
        XCTAssertEqual(req[0].headers["Authorization"], "tok-test-000")   // bare, no "Bearer"
    }

    func testMockHTTPRecordsPUTBody() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("PUT", "IotSwitches/5",
                  .json(200, Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 70)))
        let echo = try await client.update(Fixtures.session(), deviceId: "5",
                                           fields: .init(power: true, brightness: 70))
        XCTAssertEqual(echo.power, true)
        XCTAssertEqual(echo.brightness, 70)
        let body = http.requests("PUT", "IotSwitches/5")[0].body
        XCTAssertEqual(body?["power"] as? String, "ON")
        XCTAssertEqual(body?["brightness"] as? Int, 70)
    }

    func testUnstubbedRouteFailsLoudly() async {
        let (client, _) = MockHTTP.makeClient()
        do {
            _ = try await client.rooms(Fixtures.session(), residenceId: "9")
            XCTFail("should have thrown")
        } catch let LevitonClient.Error.server(code, msg) {
            XCTAssertEqual(code, 599)
            XCTAssertTrue(msg.contains("no stub"), msg)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }
}
