import Foundation
import XCTest
@testable import WaifuClaw

final class NativeMemoryConsentTests: XCTestCase {
    func testSharingIsOptInAndProjectIsolated() throws {
        let suiteName = "memory-consent-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let consent = NativeMemoryConsent(defaults: suite)
        let first = String(repeating: "a", count: 64)
        let second = String(repeating: "b", count: 64)

        XCTAssertFalse(consent.isEnabled(for: first))
        XCTAssertFalse(consent.isEnabled(for: second))
        suite.set(true, forKey: "native.memory.useInAgent")
        XCTAssertFalse(consent.isEnabled(for: first), "Old global opt-in must not be silently inherited")
        consent.setEnabled(true, for: first)
        XCTAssertTrue(consent.isEnabled(for: first))
        XCTAssertFalse(consent.isEnabled(for: second))
        consent.setEnabled(false, for: first)
        XCTAssertFalse(consent.isEnabled(for: first))
    }

    func testInvalidOrMissingProjectCannotEnableSharing() throws {
        let suiteName = "memory-consent-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let consent = NativeMemoryConsent(defaults: suite)
        consent.setEnabled(true, for: nil)
        consent.setEnabled(true, for: "../../another-project")
        XCTAssertFalse(consent.isEnabled(for: nil))
        XCTAssertFalse(consent.isEnabled(for: "../../another-project"))
    }
}
