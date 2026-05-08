import XCTest
@testable import Jotty

final class KeybindingsStoreTests: XCTestCase {
    func testLoadsDefaults() throws {
        let json = """
        { "version": 1,
          "bindings": {
            "global.toggleCapture": { "keyCode": 45, "modifiers": ["cmd"] },
            "capture.submit":       { "keyCode": 36, "modifiers": ["cmd"] },
            "capture.cancel":       { "keyCode": 53, "modifiers": [] }
          }
        }
        """.data(using: .utf8)!

        let store = try KeybindingsStore(data: json)

        XCTAssertEqual(store.combo(for: .globalToggleCapture)?.keyCode, 45)
        XCTAssertTrue(store.combo(for: .globalToggleCapture)!.modifiers.contains(.cmd))
        XCTAssertEqual(store.combo(for: .captureSubmit)?.keyCode, 36)
        XCTAssertEqual(store.combo(for: .captureCancel)?.modifiers, [])
    }

    func testMissingActionReturnsNil() throws {
        let json = #"{ "version": 1, "bindings": {} }"#.data(using: .utf8)!
        let store = try KeybindingsStore(data: json)
        XCTAssertNil(store.combo(for: .captureSubmit))
    }
}
