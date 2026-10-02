import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// A small input record for `LocalMemorySentenceReranker`.
///
/// `graphScore` should be the caller's existing project-scoped graph recall score.
/// The reranker treats a non-finite value as zero and never uses it to cross project
/// boundaries.
public struct LocalMemoryEmbeddingCandidate: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let projectID: String
    public let text: String
    public let graphScore: Double

    public init(id: UUID, projectID: String, text: String, graphScore: Double) {
        self.id = id
        self.projectID = projectID
        self.text = text
        self.graphScore = graphScore
    }
}

/// States whether an embedding contributed to a reranked candidate's final score.
public enum LocalMemoryEmbeddingScoreSource: String, Sendable, Hashable {
    /// A finite system sentence-vector cosine score was blended with deterministic evidence.
    case semanticAndDeterministic
    /// The system embedding was unavailable or invalid, so only deterministic evidence was used.
    case deterministicFallback
}

/// One bounded reranking result. Scores are always finite and in the inclusive range `0...1`.
public struct LocalMemoryEmbeddingRerankResult: Identifiable, Sendable, Hashable {
    public let candidate: LocalMemoryEmbeddingCandidate
    public let score: Double
    public let semanticScore: Double?
    public let deterministicScore: Double
    public let scoreSource: LocalMemoryEmbeddingScoreSource
    public let explanation: String

    public var id: UUID { candidate.id }

    public init(
        candidate: LocalMemoryEmbeddingCandidate,
        score: Double,
        semanticScore: Double?,
        deterministicScore: Double,
        scoreSource: LocalMemoryEmbeddingScoreSource,
        explanation: String
    ) {
        self.candidate = candidate
        self.score = score
        self.semanticScore = semanticScore
        self.deterministicScore = deterministicScore
        self.scoreSource = scoreSource
        self.explanation = explanation
    }
}

/// A synchronous, injectable source of sentence vectors.
///
/// Test code can provide a tiny fake implementation. Production uses
/// `AppleEnglishSentenceEmbeddingBackend`, which obtains only Apple's system-provided
/// English sentence embedding and has no download or network path.
public protocol LocalSentenceEmbeddingBackend {
    /// `false` when this device or OS cannot provide the requested system embedding.
    var isAvailable: Bool { get }

    /// Returns a vector for one already-bounded sentence, or `nil` when no vector is available.
    func vector(for sentence: String) -> [Double]?
}

/// Production backend for Apple's built-in English sentence embedding.
///
/// This backend calls `NLEmbedding.sentenceEmbedding(for: .english)` only. It does not
/// create a model URL, fetch model weights, or make a network request. `NLEmbedding` can
/// be absent on a supported OS/device, in which case `isAvailable` is `false` and callers
/// must use their deterministic fallback.
public final class AppleEnglishSentenceEmbeddingBackend: LocalSentenceEmbeddingBackend {
    public init() {}

    public var isAvailable: Bool {
        #if canImport(NaturalLanguage)
        if #available(iOS 14.0, *) {
            return NLEmbedding.sentenceEmbedding(for: .english) != nil
        }
        #endif
        return false
    }

    public func vector(for sentence: String) -> [Double]? {
        let boundedSentence = String(sentence.prefix(LocalMemorySentenceReranker.maximumTextCharacterCount))
        guard !boundedSentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        #if canImport(NaturalLanguage)
        if #available(iOS 14.0, *) {
            return NLEmbedding.sentenceEmbedding(for: .english)?.vector(for: boundedSentence)
        }
        #endif
        return nil
    }
}

/// A bounded local reranker that adds a small English semantic signal to existing graph recall.
///
/// The caller **must** pass candidates from the selected `projectID` (normally the output of
/// `LocalNeuralMemoryStore.recall(projectID:query:)`). The method also drops any candidate
/// whose `projectID` differs from that parameter as a defense in depth; it never searches
/// another project to fill the window. Candidate order defines the bounded window, so callers
/// should supply their existing graph-ranked candidates first.
///
/// The implementation permits at most 128 candidates, truncates the query and every candidate
/// text to 500 characters before tokenization or vectorization, and consumes at most the first
/// 256 finite vector dimensions. Scores are finite and clamped to `0...1`.
///
/// ## Deliberate scope and limitations
/// - This uses Apple's system-provided `NaturalLanguage.NLEmbedding` only for `.english` on
///   iOS devices where that sentence embedding is available (the app itself targets iOS 17).
///   It has no language detection and makes no claim for non-English input or unavailable OS/device variants.
/// - There is **no network inference, model download, model URL, external weight file, or corpus index**.
/// - This is not upstream MiniLM and is not NeuralMemory Pro or full NeuralMemory parity. It is
///   a small, project-scoped reranking adjunct to the existing deterministic local graph.
public struct LocalMemorySentenceReranker {
    /// Absolute upper bound on candidate vectors evaluated during one call.
    public static let maximumCandidateCount = 128
    /// Absolute upper bound on characters sent to tokenization or the embedding backend per string.
    public static let maximumTextCharacterCount = 500
    /// Absolute upper bound on vector components considered for cosine similarity.
    public static let maximumVectorDimension = 256

    private static let semanticWeight = 0.85
    private let backend: any LocalSentenceEmbeddingBackend
    private let maximumCandidates: Int

    /// Creates a local reranker. `maximumCandidates` is clamped to `1...128`.
    public init(
        backend: any LocalSentenceEmbeddingBackend = AppleEnglishSentenceEmbeddingBackend(),
        maximumCandidates: Int = 64
    ) {
        self.backend = backend
        self.maximumCandidates = min(max(maximumCandidates, 1), Self.maximumCandidateCount)
    }

    /// Reranks at most the first configured candidates for exactly one project.
    ///
    /// A valid system vector contributes a bounded cosine signal with 85% weight; the remaining
    /// 15% preserves deterministic graph/keyword evidence. If the backend, query vector, or a
    /// candidate vector is missing or non-finite, that item deterministically falls back to the
    /// graph/keyword score without retrying, networking, or inspecting more candidates.
    public func rerank(
        projectID rawProjectID: String,
        query rawQuery: String,
        candidates: [LocalMemoryEmbeddingCandidate]
    ) -> [LocalMemoryEmbeddingRerankResult] {
        guard let projectID = Self.boundedProjectID(rawProjectID),
              let query = Self.boundedText(rawQuery) else {
            return []
        }

        // Apply the cap before filtering or vectorization. This makes the caller-provided,
        // project-scoped graph ordering the only corpus window this component can inspect.
        let preparedCandidates = candidates.prefix(maximumCandidates).compactMap {
            candidate -> (candidate: LocalMemoryEmbeddingCandidate, text: String)? in
            guard candidate.projectID == projectID,
                  let text = Self.boundedText(candidate.text) else {
                return nil
            }
            return (candidate, text)
        }
        guard !preparedCandidates.isEmpty else { return [] }

        let queryTokens = Self.keywords(in: query)
        let queryVector: [Double]?
        if backend.isAvailable {
            queryVector = Self.validatedVector(backend.vector(for: query))
        } else {
            queryVector = nil
        }

        let results = preparedCandidates.map { prepared -> LocalMemoryEmbeddingRerankResult in
            let deterministicScore = Self.deterministicScore(
                graphScore: prepared.candidate.graphScore,
                queryTokens: queryTokens,
                candidateText: prepared.text
            )

            let semanticScore = queryVector.flatMap { queryVector in
                Self.validatedVector(backend.vector(for: prepared.text)).flatMap { candidateVector in
                    Self.cosineSimilarity(queryVector, candidateVector)
                }
            }

            if let semanticScore {
                let score = Self.clamp(
                    Self.semanticWeight * semanticScore +
                        (1 - Self.semanticWeight) * deterministicScore
                )
                return LocalMemoryEmbeddingRerankResult(
                    candidate: prepared.candidate,
                    score: score,
                    semanticScore: semanticScore,
                    deterministicScore: deterministicScore,
                    scoreSource: .semanticAndDeterministic,
                    explanation: "Bounded English system sentence similarity blended with local graph/keyword evidence."
                )
            }

            return LocalMemoryEmbeddingRerankResult(
                candidate: prepared.candidate,
                score: deterministicScore,
                semanticScore: nil,
                deterministicScore: deterministicScore,
                scoreSource: .deterministicFallback,
                explanation: "Deterministic local graph/keyword fallback; the English system sentence embedding was unavailable or invalid."
            )
        }

        return results.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.deterministicScore != rhs.deterministicScore {
                return lhs.deterministicScore > rhs.deterministicScore
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func boundedProjectID(_ rawValue: String) -> String? {
        let prefix = rawValue.prefix(129)
        guard prefix.count <= 128 else { return nil }
        let value = String(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func boundedText(_ rawValue: String) -> String? {
        let value = String(rawValue.prefix(maximumTextCharacterCount))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func deterministicScore(
        graphScore: Double,
        queryTokens: Set<String>,
        candidateText: String
    ) -> Double {
        let graph = clamp(graphScore)
        let candidateTokens = keywords(in: candidateText)
        guard !queryTokens.isEmpty, !candidateTokens.isEmpty else { return graph }
        let overlap = queryTokens.intersection(candidateTokens).count
        let keyword = Double(2 * overlap) / Double(queryTokens.count + candidateTokens.count)
        return max(graph, clamp(keyword))
    }

    private static func keywords(in text: String) -> Set<String> {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "for",
            "from", "has", "have", "he", "her", "him", "i", "in", "is", "it", "its",
            "me", "my", "of", "on", "or", "our", "she", "that", "the", "their", "them",
            "there", "these", "they", "this", "to", "us", "was", "we", "were", "with",
            "you", "your"
        ]
        return Set(folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap { token in
            let value = String(token)
            return value.count >= 2 && !stopWords.contains(value) ? value : nil
        })
    }

    private static func validatedVector(_ source: [Double]?) -> [Double]? {
        guard let source else { return nil }
        var vector: [Double] = []
        vector.reserveCapacity(min(source.count, maximumVectorDimension))
        for value in source.prefix(maximumVectorDimension) {
            guard value.isFinite else { return nil }
            vector.append(value)
        }
        return vector.isEmpty ? nil : vector
    }

    private static func cosineSimilarity(_ left: [Double], _ right: [Double]) -> Double? {
        let dimension = min(left.count, right.count)
        guard dimension > 0 else { return nil }

        var leftScale = 0.0
        var rightScale = 0.0
        for index in 0..<dimension {
            leftScale = max(leftScale, abs(left[index]))
            rightScale = max(rightScale, abs(right[index]))
        }
        guard leftScale.isFinite, rightScale.isFinite, leftScale > 0, rightScale > 0 else {
            return nil
        }

        var dot = 0.0
        var leftNormSquared = 0.0
        var rightNormSquared = 0.0
        for index in 0..<dimension {
            let leftValue = left[index] / leftScale
            let rightValue = right[index] / rightScale
            dot += leftValue * rightValue
            leftNormSquared += leftValue * leftValue
            rightNormSquared += rightValue * rightValue
        }

        let denominator = sqrt(leftNormSquared) * sqrt(rightNormSquared)
        guard dot.isFinite,
              denominator.isFinite,
              denominator > 0 else {
            return nil
        }
        let cosine = dot / denominator
        guard cosine.isFinite else { return nil }
        return clamp(max(0, cosine))
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
