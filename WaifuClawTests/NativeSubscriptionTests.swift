import Foundation
import XCTest
@testable import WaifuClaw

final class NativeSubscriptionTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testProductIDAllowlistAcceptsOnlyProposals() {
        XCTAssertTrue(NativeSubscriptionProductID.isAllowed(NativeSubscriptionProductID.proMonthly.rawValue))
        XCTAssertTrue(NativeSubscriptionProductID.isAllowed(NativeSubscriptionProductID.proYearly.rawValue))
        XCTAssertFalse(NativeSubscriptionProductID.isAllowed("studio.phantomhorizons.waifuclaw.pro.lifetime"))
        XCTAssertFalse(NativeSubscriptionProductID.isAllowed("other.publisher.pro.monthly"))
    }

    func testVerifiedUnrevokedUnexpiredAllowlistedEntitlementIsEligible() {
        let snapshot = NativeSubscriptionEntitlementSnapshot(
            productID: NativeSubscriptionProductID.proMonthly.rawValue,
            verification: .verified,
            expirationDate: now.addingTimeInterval(60)
        )

        XCTAssertEqual(
            NativeSubscriptionEntitlementEvaluator.eligibility(for: snapshot, at: now),
            .eligible(.proMonthly)
        )
        XCTAssertEqual(
            NativeSubscriptionEntitlementEvaluator.entitlement(from: [snapshot], at: now),
            .verifiedPro(.proMonthly)
        )
    }

    func testRevokedEntitlementIsNeverEligible() {
        let snapshot = NativeSubscriptionEntitlementSnapshot(
            productID: NativeSubscriptionProductID.proYearly.rawValue,
            verification: .verified,
            revocationDate: now.addingTimeInterval(-1),
            expirationDate: now.addingTimeInterval(60)
        )

        XCTAssertEqual(
            NativeSubscriptionEntitlementEvaluator.eligibility(for: snapshot, at: now),
            .revoked
        )
        XCTAssertEqual(
            NativeSubscriptionEntitlementEvaluator.entitlement(from: [snapshot], at: now),
            .free
        )
    }

    func testExpiredEntitlementIsNeverEligible() {
        let snapshot = NativeSubscriptionEntitlementSnapshot(
            productID: NativeSubscriptionProductID.proMonthly.rawValue,
            verification: .verified,
            expirationDate: now
        )

        XCTAssertEqual(
            NativeSubscriptionEntitlementEvaluator.eligibility(for: snapshot, at: now),
            .expired
        )
        XCTAssertEqual(
            NativeSubscriptionEntitlementEvaluator.entitlement(from: [snapshot], at: now),
            .free
        )
    }

    func testUnverifiedEntitlementIsNeverEligible() {
        let snapshot = NativeSubscriptionEntitlementSnapshot(
            productID: NativeSubscriptionProductID.proMonthly.rawValue,
            verification: .unverified,
            expirationDate: now.addingTimeInterval(60)
        )

        XCTAssertEqual(
            NativeSubscriptionEntitlementEvaluator.eligibility(for: snapshot, at: now),
            .unverified
        )
    }

    func testLaunchOffDisablesPurchasesEvenWhenOtherRequirementsAreTrue() {
        let configuration = NativeSubscriptionLaunchConfiguration(
            isLaunchEnabled: false,
            productsApprovedForSale: true,
            guardianServiceReady: true
        )

        XCTAssertFalse(configuration.purchasesAreAvailable)
        XCTAssertFalse(NativeSubscriptionLaunchConfiguration.shipping.purchasesAreAvailable)
    }
}
