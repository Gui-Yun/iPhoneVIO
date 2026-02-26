//
//  iPhoneVIOTests.swift
//  iPhoneVIOTests
//
//  Created by David Gao on 5/5/24.
//

import XCTest
@testable import iPhoneVIO

final class iPhoneVIOTests: XCTestCase {
    func testDeviceNodeStatusDecodesSnakeCaseFields() throws {
        let json = """
        [
          {
            "name": "cam front",
            "bit_index": 2,
            "online": true,
            "process_running": false,
            "pid": 4321,
            "backend": "usb",
            "address": "192.168.0.22"
          }
        ]
        """

        let devices = try JSONDecoder().decode([DeviceNodeStatus].self, from: Data(json.utf8))
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].name, "cam front")
        XCTAssertEqual(devices[0].bitIndex, 2)
        XCTAssertEqual(devices[0].online, true)
        XCTAssertEqual(devices[0].processRunning, false)
        XCTAssertEqual(devices[0].pid, 4321)
        XCTAssertEqual(devices[0].backend, "usb")
        XCTAssertEqual(devices[0].address, "192.168.0.22")
    }

    func testDeviceNodeStatusOptionalFieldsCanBeMissing() throws {
        let json = """
        [
          {
            "name": "phone_a",
            "bit_index": 0,
            "online": false,
            "process_running": false,
            "backend": "ios"
          }
        ]
        """

        let devices = try JSONDecoder().decode([DeviceNodeStatus].self, from: Data(json.utf8))
        XCTAssertEqual(devices.count, 1)
        XCTAssertNil(devices[0].pid)
        XCTAssertNil(devices[0].address)
    }

    func testPerformanceExample() throws {
        self.measure {
        }
    }

}
