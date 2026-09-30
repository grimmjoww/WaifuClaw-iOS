import Foundation
import XCTest
@testable import WaifuClaw

final class NativeMemoryAutocaptureTests: XCTestCase {
    private let firstProject = String(repeating: "a", count: 64)
    private let secondProject = String(repeating: "b", count: 64)
    private let auditDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testCandidatePreferenceDefaultsOffAndIsProjectIsolated() throws {
        let suiteName = "memory-autocapture-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let preferences = NativeMemoryAutocapturePreferenceStore(defaults: suite)

        // Provider-sharing consent is a separate key and cannot enable local
        // automatic candidate extraction.
        suite.set(true, forKey: "native.memory.shareApproved.\(firstProject)")
        XCTAssertEqual(preferences.preference(for: firstProject), .unset)
        XCTAssertEqual(preferences.preference(for: secondProject), .unset)

        preferences.optIn(for: firstProject)
        XCTAssertEqual(preferences.preference(for: firstProject), .optedIn)
        XCTAssertEqual(preferences.preference(for: secondProject), .unset)

        let evaluation = NativeMemoryAutocaptureCandidateExtractor().evaluate(
            input(projectID: secondProject, phase: .finished, output: "We decided to use SQLite for local project memory."),
            preference: preferences.preference(for: secondProject),
            evaluatedAt: auditDate
        )
        XCTAssertEqual(evaluation.disposition, .skipped(reason: .automaticCaptureNotOptedIn))
        XCTAssertTrue(evaluation.candidates.isEmpty)

        preferences.optOut(for: firstProject)
        XCTAssertEqual(preferences.preference(for: firstProject), .optedOut)
        let optedOutEvaluation = NativeMemoryAutocaptureCandidateExtractor().evaluate(
            input(projectID: firstProject, phase: .finished, output: "We decided to use SQLite for local project memory."),
            preference: preferences.preference(for: firstProject),
            evaluatedAt: auditDate
        )
        XCTAssertEqual(optedOutEvaluation.disposition, .skipped(reason: .automaticCaptureOptedOut))
    }

    func testFailedOrCancelledRunCannotProduceCandidateEvenWhenProjectOptedIn() {
        for phase in [LocalRunPhase.failed, .cancelled] {
            let evaluation = NativeMemoryAutocaptureCandidateExtractor().evaluate(
                input(phase: phase, output: "We decided to use SQLite for local project memory."),
                preference: .optedIn,
                evaluatedAt: auditDate
            )

            XCTAssertEqual(evaluation.observedRunPhase, phase)
            XCTAssertEqual(evaluation.disposition, .skipped(reason: .runWasNotFinished))
            XCTAssertTrue(evaluation.candidates.isEmpty)
        }
    }

    func testSecretLookingOutputIsRejectedWithoutCandidateTextInAuditResult() {
        let output = "We decided to use SQLite for local project memory. API key: sk-this-is-a-very-secret-token"
        let evaluation = NativeMemoryAutocaptureCandidateExtractor().evaluate(
            input(phase: .finished, output: output),
            preference: .optedIn,
            evaluatedAt: auditDate
        )

        XCTAssertEqual(evaluation.disposition, .skipped(reason: .secretLookingContent))
        XCTAssertTrue(evaluation.candidates.isEmpty)
        XCTAssertTrue(evaluation.candidateRejections.isEmpty)
        XCTAssertFalse(String(describing: evaluation).contains("sk-this-is-a-very-secret-token"))
    }

    func testFinishedCandidateIsUnverifiedAndHasDurableRunProvenance() throws {
        let runID = UUID()
        let conversationID = UUID()
        let messageID = UUID()
        let source = input(
            projectID: firstProject,
            runID: runID,
            conversationID: conversationID,
            messageID: messageID,
            phase: .finished,
            output: "We decided to use SQLite for local project memory."
        )

        let evaluation = NativeMemoryAutocaptureCandidateExtractor().evaluate(
            source,
            preference: .optedIn,
            evaluatedAt: auditDate
        )
        XCTAssertEqual(evaluation.candidates.count, 1)
        let candidate = try XCTUnwrap(evaluation.candidates.first)

        XCTAssertEqual(evaluation.disposition, .proposed)
        XCTAssertEqual(candidate.statement, "We decided to use SQLite for local project memory")
        XCTAssertEqual(candidate.verification, .unverifiedModelStatement)
        XCTAssertTrue(candidate.requiresExplicitReview)
        XCTAssertEqual(candidate.provenance.source, .finishedNativeAgentRun)
        XCTAssertEqual(candidate.provenance.projectID, firstProject)
        XCTAssertEqual(candidate.provenance.runID, runID)
        XCTAssertEqual(candidate.provenance.conversationID, conversationID)
        XCTAssertEqual(candidate.provenance.assistantMessageID, messageID)
        XCTAssertEqual(candidate.provenance.terminalPhase, .finished)
        XCTAssertEqual(candidate.provenance.completedAt, auditDate)
    }

    func testDuplicateAndLowSignalFragmentsAreAuditedWithoutProposals() {
        let statement = "We decided to use SQLite for local project memory"
        let evaluation = NativeMemoryAutocaptureCandidateExtractor().evaluate(
            input(phase: .finished, output: "Done. \(statement). \(statement)."),
            preference: .optedIn,
            knownCandidateStatements: [statement],
            evaluatedAt: auditDate
        )

        XCTAssertEqual(evaluation.disposition, .skipped(reason: .noEligibleStatements))
        XCTAssertTrue(evaluation.candidates.isEmpty)
        XCTAssertEqual(evaluation.candidateRejections.filter { $0 == .lowSignal }.count, 1)
        XCTAssertEqual(evaluation.candidateRejections.filter { $0 == .duplicate }.count, 2)
    }

    private func input(
        projectID: String? = nil,
        runID: UUID = UUID(),
        conversationID: UUID = UUID(),
        messageID: UUID = UUID(),
        phase: LocalRunPhase,
        output: String
    ) -> NativeMemoryAutocaptureRunInput {
        let run = LocalRunRecord(
            id: runID,
            conversationID: conversationID,
            phase: phase,
            createdAt: auditDate.addingTimeInterval(-5),
            updatedAt: auditDate,
            errorMessage: phase == .failed ? "Failure" : nil
        )
        let message = LocalMessage(
            id: messageID,
            conversationID: conversationID,
            role: .assistant,
            content: output,
            createdAt: auditDate.addingTimeInterval(-1)
        )
        return NativeMemoryAutocaptureRunInput(
            projectID: projectID ?? firstProject,
            run: run,
            assistantMessage: message
        )
    }
}
