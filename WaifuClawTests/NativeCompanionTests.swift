import UIKit
import XCTest
@testable import WaifuClaw

final class NativeCompanionTests: XCTestCase {
    func testInvalidOrMissingStoredSelectionDefaultsToKline() {
        XCTAssertEqual(CompanionID.selected(from: nil), .kline)
        XCTAssertEqual(CompanionID.selected(from: "not-a-companion"), .kline)
        XCTAssertEqual(CompanionID.defaultSelection, .kline)
    }

    func testSelectionSerializationRoundTripsEveryCompanion() {
        for companion in CompanionID.allCases {
            XCTAssertEqual(CompanionID.selected(from: companion.rawValue), companion)
            XCTAssertEqual(companion.definition.id, companion)
        }
    }

    func testCatalogHasUniqueIDsAndTextureMetadata() {
        let definitions = CompanionCatalog.all
        let ids = definitions.map { $0.id.rawValue }
        XCTAssertEqual(Set(ids).count, definitions.count, "Companion IDs must be unique")
        XCTAssertEqual(Set(ids), Set(CompanionID.allCases.map(\.rawValue)))

        let textureNames = definitions.flatMap { $0.textures.all }
        XCTAssertEqual(textureNames.count, definitions.count * 4)
        XCTAssertEqual(Set(textureNames).count, textureNames.count, "Layer texture names must be unique")
        XCTAssertFalse(textureNames.contains(where: { $0.isEmpty }))
    }

    func testMoodAccessibilityDescriptionsNameTheVisualCompanion() {
        let moods: [KlineSpriteMood] = [.idle, .thinking, .reading, .completed, .failed]
        for mood in moods {
            XCTAssertFalse(mood.accessibilityDescription.isEmpty)
            XCTAssertTrue(mood.accessibilityDescription(for: "Rei").contains("Rei"))
            XCTAssertFalse(mood.visualStateTitle.isEmpty)
        }
    }

    /// Inspect the actual installed app bundle; Swift source alone cannot prove
    /// that a selectable sprite has its four real aligned textures at runtime.
    func testConfiguredLayerTexturesAreBundled() throws {
        for textureName in CompanionCatalog.all.flatMap({ $0.textures.all }) {
            _ = try XCTUnwrap(UIImage(named: textureName), "Missing bundled texture: \(textureName)")
        }
    }

    func testStudioDisplayTypefacesAreRegisteredOnDevice() throws {
        _ = try XCTUnwrap(Bundle.main.url(forResource: "CinzelDecorative-Regular", withExtension: "ttf"))
        _ = try XCTUnwrap(Bundle.main.url(forResource: "CinzelDecorative-Bold", withExtension: "ttf"))
        StudioFontRegistration.registerIfNeeded()
        XCTAssertNotNil(UIFont(name: "CinzelDecorative-Regular", size: 22))
        XCTAssertNotNil(UIFont(name: "CinzelDecorative-Bold", size: 26))
    }

    func testEachCompanionSchedulesActualIndependentMotionAndReduceMotionStopsIt() throws {
        for companion in CompanionCatalog.all {
            let scene = CompanionSpriteScene(companion: companion)
            scene.configure(mood: .thinking, reduceMotion: false)
            let left = try XCTUnwrap(scene.childNode(withName: "appendage.left"))
            let right = try XCTUnwrap(scene.childNode(withName: "appendage.right"))
            let body = try XCTUnwrap(scene.childNode(withName: "body"))
            let eyes = try XCTUnwrap(scene.childNode(withName: "face.blink"))
            XCTAssertNotNil(left.action(forKey: "appendage.left.sway"), "\(companion.name) left appendage must move")
            XCTAssertNotNil(right.action(forKey: "appendage.right.sway"), "\(companion.name) right appendage must move")
            XCTAssertNotNil(body.action(forKey: "body.breathe"), "\(companion.name) must breathe")
            XCTAssertNotNil(eyes.action(forKey: "face.blink"), "\(companion.name) must blink")

            scene.configure(mood: .thinking, reduceMotion: true)
            XCTAssertNil(left.action(forKey: "appendage.left.sway"))
            XCTAssertNil(right.action(forKey: "appendage.right.sway"))
            XCTAssertNil(body.action(forKey: "body.breathe"))
            XCTAssertNil(eyes.action(forKey: "face.blink"))
        }
    }
}
