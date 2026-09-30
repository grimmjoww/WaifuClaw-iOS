import Foundation
import XCTest
@testable import WaifuClaw

final class NativeGuardianAIReviewTests: XCTestCase {
    func testReviewSendsOnlySafeCurrentChangesAndPersistsEvidence() async throws {
        let root = try temporaryDirectory()
        let guardianHistory = try temporaryDirectory()
        let reportHistory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: guardianHistory)
            try? FileManager.default.removeItem(at: reportHistory)
        }

        try write("let visible = true\n", to: root.appendingPathComponent("Sources/Visible.swift"))
        try write("TOP_SECRET=must-not-leave-device\n", to: root.appendingPathComponent(".env"))
        try write("credential-value-must-not-leave-device\n", to: root.appendingPathComponent("credentials.json"))
        try write("nested-secret-must-not-leave-device\n", to: root.appendingPathComponent("Nested/credentials/token.txt"))

        let guardianStore = try NativeGuardianStore(rootDirectory: guardianHistory)
        let guardianReview = try NativeGuardianScanner(rootURL: root).scan(baseline: nil)
        _ = try guardianStore.recordReview(guardianReview, for: guardianReview.projectID)

        let reportStore = try NativeGuardianAIReviewStore(rootDirectory: reportHistory)
        let provider = FixtureProvider(result: .text("Potential input-validation risk in the visible source."))
        let reviewer = NativeGuardianAIReviewer(guardianStore: guardianStore, reportStore: reportStore)
        let report = try await reviewer.review(
            rootURL: root,
            guardianReview: guardianReview,
            provider: provider
        )

        XCTAssertEqual(report.status, .completed)
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.modelOpinion, "Potential input-validation risk in the visible source.")
        XCTAssertEqual(report.verificationNotice, NativeGuardianAIReviewReport.standardVerificationNotice)
        XCTAssertEqual(report.changes.map(\.relativePath), ["Sources/Visible.swift"])
        XCTAssertEqual(report.excerpts.map(\.relativePath), ["Sources/Visible.swift"])
        XCTAssertEqual(report.excerpts.first?.lineStart, 1)
        XCTAssertEqual(report.excerpts.first?.lineEnd, 1)

        let request = try XCTUnwrap(provider.requests().first)
        XCTAssertEqual(request.toolCount, 0)
        let requestText = request.messages.joined(separator: "\n")
        XCTAssertTrue(requestText.contains("Sources/Visible.swift"))
        XCTAssertTrue(requestText.contains(try XCTUnwrap(guardianReview.changes.first?.currentSHA256)))
        XCTAssertFalse(requestText.contains("TOP_SECRET=must-not-leave-device"))
        XCTAssertFalse(requestText.contains("credential-value-must-not-leave-device"))
        XCTAssertFalse(requestText.contains("nested-secret-must-not-leave-device"))
        XCTAssertFalse(requestText.contains("Nested/credentials/token.txt"))

        let persisted = try await reportStore.reports(projectID: guardianReview.projectID)
        XCTAssertEqual(persisted, [report])
    }

    func testEmptyAndOversizedReviewsAreRefusedBeforeCallingProvider() async throws {
        let root = try temporaryDirectory()
        let guardianHistory = try temporaryDirectory()
        let reportHistory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: guardianHistory)
            try? FileManager.default.removeItem(at: reportHistory)
        }

        let guardianStore = try NativeGuardianStore(rootDirectory: guardianHistory)
        let reportStore = try NativeGuardianAIReviewStore(rootDirectory: reportHistory)
        let reviewer = NativeGuardianAIReviewer(guardianStore: guardianStore, reportStore: reportStore)
        let provider = FixtureProvider(result: .text("This should never be requested."))

        let emptyReview = try NativeGuardianScanner(rootURL: root).scan(baseline: nil)
        _ = try guardianStore.recordReview(emptyReview, for: emptyReview.projectID)
        let emptyReport = try await reviewer.review(
            rootURL: root,
            guardianReview: emptyReview,
            provider: provider
        )
        XCTAssertEqual(emptyReport.status, .refused)
        XCTAssertEqual(emptyReport.failure, .emptyGuardianReview)
        XCTAssertNil(emptyReport.requestSHA256)
        XCTAssertEqual(provider.invocationCount(), 0)

        let tooLarge = String(repeating: "x", count: NativeGuardianAIReviewLimits.maximumSourceBytesPerFile + 1)
        try write(tooLarge, to: root.appendingPathComponent("Sources/TooLarge.swift"))
        let oversizedReview = try NativeGuardianScanner(rootURL: root).scan(baseline: nil)
        _ = try guardianStore.recordReview(oversizedReview, for: oversizedReview.projectID)
        let oversizedReport = try await reviewer.review(
            rootURL: root,
            guardianReview: oversizedReview,
            provider: provider
        )
        XCTAssertEqual(oversizedReport.status, .refused)
        XCTAssertEqual(oversizedReport.failure, .sourceFileTooLarge)
        XCTAssertNil(oversizedReport.requestSHA256)
        XCTAssertEqual(provider.invocationCount(), 0)

        let persisted = try await reportStore.reports(projectID: emptyReview.projectID)
        XCTAssertEqual(persisted.map(\.failure), [.emptyGuardianReview, .sourceFileTooLarge])
    }

    func testProviderCancellationBecomesPersistedCancelledReport() async throws {
        let root = try temporaryDirectory()
        let guardianHistory = try temporaryDirectory()
        let reportHistory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: guardianHistory)
            try? FileManager.default.removeItem(at: reportHistory)
        }

        try write("let value = 1\n", to: root.appendingPathComponent("Source.swift"))
        let guardianStore = try NativeGuardianStore(rootDirectory: guardianHistory)
        let guardianReview = try NativeGuardianScanner(rootURL: root).scan(baseline: nil)
        _ = try guardianStore.recordReview(guardianReview, for: guardianReview.projectID)

        let reportStore = try NativeGuardianAIReviewStore(rootDirectory: reportHistory)
        let provider = FixtureProvider(result: .cancelled)
        let reviewer = NativeGuardianAIReviewer(guardianStore: guardianStore, reportStore: reportStore)
        let report = try await reviewer.review(
            rootURL: root,
            guardianReview: guardianReview,
            provider: provider
        )

        XCTAssertEqual(provider.invocationCount(), 1)
        XCTAssertEqual(report.status, .cancelled)
        XCTAssertEqual(report.failure, .cancelled)
        XCTAssertNil(report.modelOpinion)
        XCTAssertNotNil(report.requestSHA256)
        let persisted = try await reportStore.reports(projectID: guardianReview.projectID)
        XCTAssertEqual(persisted, [report])
    }

    func testProviderFailureIsPersistedAsTypedFailureWithoutPayload() async throws {
        let root = try temporaryDirectory()
        let guardianHistory = try temporaryDirectory()
        let reportHistory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: guardianHistory)
            try? FileManager.default.removeItem(at: reportHistory)
        }

        try write("let value = 1\n", to: root.appendingPathComponent("Source.swift"))
        let guardianStore = try NativeGuardianStore(rootDirectory: guardianHistory)
        let guardianReview = try NativeGuardianScanner(rootURL: root).scan(baseline: nil)
        _ = try guardianStore.recordReview(guardianReview, for: guardianReview.projectID)

        let reportStore = try NativeGuardianAIReviewStore(rootDirectory: reportHistory)
        let provider = FixtureProvider(result: .failure)
        let reviewer = NativeGuardianAIReviewer(guardianStore: guardianStore, reportStore: reportStore)
        let report = try await reviewer.review(
            rootURL: root,
            guardianReview: guardianReview,
            provider: provider
        )

        XCTAssertEqual(report.status, .providerFailed)
        XCTAssertEqual(report.failure, .providerFailure)
        XCTAssertNil(report.modelOpinion)
        XCTAssertNotNil(report.requestSHA256)
        XCTAssertFalse(String(describing: report).contains("unavailable"))
        let persisted = try await reportStore.reports(projectID: guardianReview.projectID)
        XCTAssertEqual(persisted, [report])
    }

    func testUnverifiableProviderClaimsAreWithheldAndNeverBecomeVerification() async throws {
        let root = try temporaryDirectory()
        let guardianHistory = try temporaryDirectory()
        let reportHistory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: guardianHistory)
            try? FileManager.default.removeItem(at: reportHistory)
        }

        try write("func work() {}\n", to: root.appendingPathComponent("Source.swift"))
        let guardianStore = try NativeGuardianStore(rootDirectory: guardianHistory)
        let guardianReview = try NativeGuardianScanner(rootURL: root).scan(baseline: nil)
        _ = try guardianStore.recordReview(guardianReview, for: guardianReview.projectID)

        let reportStore = try NativeGuardianAIReviewStore(rootDirectory: reportHistory)
        let provider = FixtureProvider(result: .text("Security verified. Tests passed."))
        let reviewer = NativeGuardianAIReviewer(guardianStore: guardianStore, reportStore: reportStore)
        let report = try await reviewer.review(
            rootURL: root,
            guardianReview: guardianReview,
            provider: provider
        )

        XCTAssertEqual(report.status, .providerFailed)
        XCTAssertEqual(report.failure, .unverifiableProviderClaim)
        XCTAssertNil(report.modelOpinion)
        XCTAssertEqual(
            report.verificationNotice,
            "Model opinion, not verification. No tests, builds, execution, or security verification were run."
        )
        XCTAssertFalse(report.verificationNotice.lowercased().contains("tests passed"))
        XCTAssertFalse(report.verificationNotice.lowercased().contains("security verified"))

        let persisted = try await reportStore.reports(projectID: guardianReview.projectID)
        XCTAssertEqual(persisted, [report])
    }

    func testForgedReviewWithPersistedIDCannotSendProviderData() async throws {
        let root = try temporaryDirectory()
        let guardianHistory = try temporaryDirectory()
        let reportHistory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: guardianHistory)
            try? FileManager.default.removeItem(at: reportHistory)
        }
        try write("let visible = true\n", to: root.appendingPathComponent("Source.swift"))
        let guardianStore = try NativeGuardianStore(rootDirectory: guardianHistory)
        let scanned = try NativeGuardianScanner(rootURL: root).scan(baseline: nil)
        _ = try guardianStore.recordReview(scanned, for: scanned.projectID)
        let forged = NativeGuardianReviewRecord(
            id: scanned.id,
            projectID: scanned.projectID,
            baselineID: scanned.baselineID,
            scannedAt: scanned.scannedAt,
            candidateFiles: scanned.candidateFiles,
            changes: [],
            omissions: scanned.omissions,
            visitedEntries: scanned.visitedEntries
        )
        let provider = FixtureProvider(result: .text("should not run"))
        let reviewer = NativeGuardianAIReviewer(
            guardianStore: guardianStore,
            reportStore: try NativeGuardianAIReviewStore(rootDirectory: reportHistory)
        )
        do {
            _ = try await reviewer.review(rootURL: root, guardianReview: forged, provider: provider)
            XCTFail("A forged review must not reach the model")
        } catch NativeGuardianAIReviewError.guardianReviewNotPersisted {
            XCTAssertEqual(provider.invocationCount(), 0)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-guardian-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

private final class FixtureProvider: AgentModelProvider, @unchecked Sendable {
    enum Result {
        case text(String)
        case cancelled
        case failure
    }

    struct Request {
        let messages: [String]
        let toolCount: Int
    }

    private enum FixtureError: Error {
        case unavailable
    }

    private let lock = NSLock()
    private let result: Result
    private var recordedRequests: [Request] = []

    init(result: Result) {
        self.result = result
    }

    func stream(
        messages: [AgentPromptMessage],
        tools: [AgentToolDefinition]
    ) -> AsyncThrowingStream<AgentProviderEvent, Error> {
        lock.lock()
        recordedRequests.append(Request(messages: messages.map(\.content), toolCount: tools.count))
        lock.unlock()

        let result = result
        return AsyncThrowingStream { continuation in
            switch result {
            case .text(let text):
                continuation.yield(.text(text))
                continuation.yield(.finished)
                continuation.finish()
            case .cancelled:
                continuation.finish(throwing: CancellationError())
            case .failure:
                continuation.finish(throwing: FixtureError.unavailable)
            }
        }
    }

    func invocationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.count
    }

    func requests() -> [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }
}
