import Foundation
import XCTest
@testable import WaifuClaw

final class NativeMemoryEmbeddingTests: XCTestCase {
    func testSemanticCandidateOutranksLexicalOnlyCandidate() {
        let query = "Where is my delivery?"
        let lexicalOnly = candidate(
            projectID: "project-a",
            text: "Delivery status information unrelated to an order.",
            graphScore: 0
        )
        let semanticMatch = candidate(
            projectID: "project-a",
            text: "How do I track my order?",
            graphScore: 0
        )
        let backend = FakeSentenceEmbeddingBackend(isAvailable: true) { sentence in
            switch sentence {
            case query:
                return [1, 0]
            case lexicalOnly.text:
                return [0, 1]
            case semanticMatch.text:
                return [1, 0.02]
            default:
                return nil
            }
        }
        let reranker = LocalMemorySentenceReranker(backend: backend, maximumCandidates: 8)

        let results = reranker.rerank(
            projectID: "project-a",
            query: query,
            candidates: [lexicalOnly, semanticMatch]
        )

        XCTAssertEqual(results.map(\.id), [semanticMatch.id, lexicalOnly.id])
        XCTAssertEqual(results.first?.scoreSource, .semanticAndDeterministic)
        XCTAssertGreaterThan(results[0].score, results[1].score)
        XCTAssertGreaterThan(results[1].deterministicScore, results[0].deterministicScore)
    }

    func testRerankerDropsCandidatesOutsideCallerProjectParameter() {
        let included = candidate(
            projectID: "selected-project",
            text: "The selected project stores its own facts.",
            graphScore: 0.4
        )
        let excluded = candidate(
            projectID: "other-project",
            text: "This fact belongs to another project.",
            graphScore: 1
        )
        let backend = FakeSentenceEmbeddingBackend(isAvailable: true) { _ in [1, 0] }
        let reranker = LocalMemorySentenceReranker(backend: backend, maximumCandidates: 8)

        let results = reranker.rerank(
            projectID: "selected-project",
            query: "project facts",
            candidates: [excluded, included]
        )

        XCTAssertEqual(results.map(\.id), [included.id])
        XCTAssertTrue(results.allSatisfy { $0.candidate.projectID == "selected-project" })
        XCTAssertFalse(backend.requestedSentences.contains(excluded.text))
    }

    func testUnavailableAndInvalidBackendsUseFiniteDeterministicFallback() {
        let item = candidate(
            projectID: "project-a",
            text: "A graph score is retained while embeddings are unavailable.",
            graphScore: 0.7
        )
        let unavailable = FakeSentenceEmbeddingBackend(isAvailable: false) { _ in [1, 0] }
        let unavailableReranker = LocalMemorySentenceReranker(backend: unavailable)

        let unavailableResult = unavailableReranker.rerank(
            projectID: "project-a",
            query: "embeddings unavailable",
            candidates: [item]
        )

        XCTAssertEqual(unavailableResult.count, 1)
        XCTAssertEqual(unavailableResult[0].scoreSource, .deterministicFallback)
        XCTAssertNil(unavailableResult[0].semanticScore)
        XCTAssertTrue(unavailableResult[0].score.isFinite)
        XCTAssertEqual(unavailableResult[0].score, unavailableResult[0].deterministicScore)
        XCTAssertTrue(unavailable.requestedSentences.isEmpty)

        let invalid = FakeSentenceEmbeddingBackend(isAvailable: true) { _ in [Double.nan, 1] }
        let invalidReranker = LocalMemorySentenceReranker(backend: invalid)
        let invalidResult = invalidReranker.rerank(
            projectID: "project-a",
            query: "embeddings unavailable",
            candidates: [item]
        )

        XCTAssertEqual(invalidResult.first?.scoreSource, .deterministicFallback)
        XCTAssertTrue(invalidResult.allSatisfy { $0.score.isFinite && (0...1).contains($0.score) })
        XCTAssertEqual(invalid.requestedSentences.count, 1, "An invalid query vector must not trigger candidate calls.")
    }

    func testCandidateAndTextCapsAreHardEvenWhenCallerRequestsMore() {
        let query = String(repeating: "q", count: 700)
        let candidates = (0..<130).map { index in
            candidate(
                projectID: "project-a",
                text: String(repeating: "candidate", count: 90) + "-\(index)",
                graphScore: 0
            )
        }
        let backend = FakeSentenceEmbeddingBackend(isAvailable: true) { _ in [1, 0] }
        let reranker = LocalMemorySentenceReranker(backend: backend, maximumCandidates: 999)

        let results = reranker.rerank(
            projectID: "project-a",
            query: query,
            candidates: candidates
        )

        XCTAssertEqual(results.count, LocalMemorySentenceReranker.maximumCandidateCount)
        XCTAssertEqual(backend.requestedSentences.count, LocalMemorySentenceReranker.maximumCandidateCount + 1)
        XCTAssertTrue(backend.requestedSentences.allSatisfy {
            $0.count <= LocalMemorySentenceReranker.maximumTextCharacterCount
        })
    }

    func testAppleEnglishEmbeddingProducesFiniteVectorOrSkipsWhenUnavailable() throws {
        let backend = AppleEnglishSentenceEmbeddingBackend()
        guard backend.isAvailable else {
            throw XCTSkip("This OS/device does not expose Apple's English sentence embedding.")
        }

        let vector = try XCTUnwrap(backend.vector(for: "Where can I check the status of my order?"))
        let boundedVector = Array(vector.prefix(LocalMemorySentenceReranker.maximumVectorDimension))
        XCTAssertFalse(boundedVector.isEmpty)
        XCTAssertLessThanOrEqual(
            boundedVector.count,
            LocalMemorySentenceReranker.maximumVectorDimension
        )
        XCTAssertTrue(boundedVector.allSatisfy(\.isFinite))
    }

    private func candidate(
        projectID: String,
        text: String,
        graphScore: Double
    ) -> LocalMemoryEmbeddingCandidate {
        LocalMemoryEmbeddingCandidate(
            id: UUID(),
            projectID: projectID,
            text: text,
            graphScore: graphScore
        )
    }
}

private final class FakeSentenceEmbeddingBackend: LocalSentenceEmbeddingBackend {
    let isAvailable: Bool
    private let response: (String) -> [Double]?
    private(set) var requestedSentences: [String] = []

    init(isAvailable: Bool, response: @escaping (String) -> [Double]?) {
        self.isAvailable = isAvailable
        self.response = response
    }

    func vector(for sentence: String) -> [Double]? {
        requestedSentences.append(sentence)
        return response(sentence)
    }
}
