import UIKit
import XCTest
@testable import WaifuClaw

final class KlineSpriteAssetTests: XCTestCase {
    func testFourLayeredTexturesAreActuallyBundled() throws {
        for name in ["KlineBody", "KlineWingLeft", "KlineWingRight", "KlineBlinkEyes"] {
            let image = try XCTUnwrap(UIImage(named: name), "Missing bundled texture: \(name)")
            XCTAssertEqual(image.size.width, 960, accuracy: 0.5, "Incorrect \(name) width")
            XCTAssertEqual(image.size.height, 960, accuracy: 0.5, "Incorrect \(name) height")
        }
    }

    func testNeuralMemoryNoticeIsActuallyBundled() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md")
        )
        let notice = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(notice.contains("Copyright (c) 2024 NeuralMemory Contributors"))
    }

    func testPrivacyManifestIsActuallyBundled() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(NSDictionary(contentsOf: url))
        let requiredReasons = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        XCTAssertTrue(requiredReasons.contains {
            ($0["NSPrivacyAccessedAPIType"] as? String) == "NSPrivacyAccessedAPICategoryUserDefaults"
        })
    }
}
