import Foundation

/// Fixed bounds for an on-device Guardian review. These limits deliberately
/// match the approved workspace text-file read ceiling where applicable.
enum NativeGuardianScanLimits {
    static let maximumFiles = 1_000
    static let maximumDepth = 12
    static let maximumFileBytes = 128 * 1_024
    static let maximumTotalBytes = 8 * 1_024 * 1_024
    static let maximumVisitedEntries = 10_000
    static let maximumOmissions = 1_000
    static let maximumReviewHistory = 20
}

/// The exact metadata retained for one eligible source file. Guardian persists
/// hashes, paths, and sizes only; it never persists project file contents.
struct NativeGuardianFileFingerprint: Codable, Hashable, Sendable, Identifiable {
    let relativePath: String
    let sha256: String
    let byteCount: Int

    var id: String { relativePath }
}

/// A deliberately immutable approved inventory. Advancing a baseline creates a
/// new value instead of mutating this one.
struct NativeGuardianBaseline: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let approvedAt: Date
    let files: [NativeGuardianFileFingerprint]

    init(id: UUID = UUID(), approvedAt: Date = .now, files: [NativeGuardianFileFingerprint]) {
        self.id = id
        self.approvedAt = approvedAt
        self.files = files
    }
}

struct NativeGuardianFileChange: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable, Hashable {
        case added
        case changed
        case deleted
    }

    let kind: Kind
    let relativePath: String
    let previousSHA256: String?
    let currentSHA256: String?
    let previousByteCount: Int?
    let currentByteCount: Int?

    var id: String { "\(kind.rawValue):\(relativePath)" }
}

/// A regular file that was intentionally not admitted to the UTF-8 inventory.
/// Sensitive names and symlinks are not listed here: Guardian does not retain
/// their paths at all.
struct NativeGuardianOmission: Codable, Hashable, Sendable, Identifiable {
    enum Reason: String, Codable, Sendable, Hashable {
        case tooLarge
        case notUTF8
        case depthLimit
        case unsupportedName
    }

    let relativePath: String
    let reason: Reason

    var id: String { "\(reason.rawValue):\(relativePath)" }
}

/// A completed local comparison. `candidateFiles` is the exact inventory that
/// may become a new baseline only through the explicit approval flow.
struct NativeGuardianReviewRecord: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let projectID: String
    let baselineID: UUID?
    let scannedAt: Date
    let candidateFiles: [NativeGuardianFileFingerprint]
    let changes: [NativeGuardianFileChange]
    let omissions: [NativeGuardianOmission]
    let visitedEntries: Int

    init(
        id: UUID = UUID(),
        projectID: String,
        baselineID: UUID?,
        scannedAt: Date = .now,
        candidateFiles: [NativeGuardianFileFingerprint],
        changes: [NativeGuardianFileChange],
        omissions: [NativeGuardianOmission],
        visitedEntries: Int
    ) {
        self.id = id
        self.projectID = projectID
        self.baselineID = baselineID
        self.scannedAt = scannedAt
        self.candidateFiles = candidateFiles
        self.changes = changes
        self.omissions = omissions
        self.visitedEntries = visitedEntries
    }

    var addedCount: Int { changes.count(where: { $0.kind == .added }) }
    var changedCount: Int { changes.count(where: { $0.kind == .changed }) }
    var deletedCount: Int { changes.count(where: { $0.kind == .deleted }) }
    var hasChanges: Bool { !changes.isEmpty }
}

struct NativeGuardianProjectSnapshot: Codable, Hashable, Sendable {
    static let currentVersion = 1

    let version: Int
    let projectID: String
    let baseline: NativeGuardianBaseline?
    let reviews: [NativeGuardianReviewRecord]
    let lastApprovedReviewID: UUID?

    init(
        version: Int = NativeGuardianProjectSnapshot.currentVersion,
        projectID: String,
        baseline: NativeGuardianBaseline?,
        reviews: [NativeGuardianReviewRecord],
        lastApprovedReviewID: UUID?
    ) {
        self.version = version
        self.projectID = projectID
        self.baseline = baseline
        self.reviews = reviews
        self.lastApprovedReviewID = lastApprovedReviewID
    }
}

struct NativeGuardianScanProgress: Equatable, Sendable {
    enum Phase: String, Sendable, Equatable {
        case enumerating
        case complete
    }

    let phase: Phase
    let visitedEntries: Int
    let hashedFiles: Int
    let omittedFiles: Int
}

enum NativeGuardianError: LocalizedError {
    case noSelectedProject
    case invalidProject
    case invalidProjectIdentity
    case fileLimitExceeded(Int)
    case totalByteLimitExceeded(Int)
    case entryLimitExceeded(Int)
    case omissionLimitExceeded(Int)
    case enumerationFailed(String)
    case inspectionFailed(String)
    case trackedFileCannotBeRead(String, String)
    case corruptState
    case persistence(String)
    case reviewNotFound
    case staleReview

    var errorDescription: String? {
        switch self {
        case .noSelectedProject:
            return "Choose a Files project before starting Guardian."
        case .invalidProject:
            return "The selected Files folder is not a readable, non-symlink project folder."
        case .invalidProjectIdentity:
            return "Guardian could not safely identify this project."
        case .fileLimitExceeded(let limit):
            return "Guardian stopped without saving a review because more than \(limit) eligible UTF-8 text files were found. Narrow the selected project folder and try again."
        case .totalByteLimitExceeded(let limit):
            return "Guardian stopped without saving a review because eligible UTF-8 text exceeded its \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) local read limit."
        case .entryLimitExceeded(let limit):
            return "Guardian stopped without saving a review after inspecting \(limit) filesystem entries. Narrow the selected project folder and try again."
        case .omissionLimitExceeded(let limit):
            return "Guardian stopped without saving a review because more than \(limit) eligible files could not be included. Narrow the selected project folder and try again."
        case .enumerationFailed(let detail):
            return "Guardian could not safely list this project: \(detail)"
        case .inspectionFailed(let path):
            return "Guardian could not safely inspect \(path). No review was saved."
        case .trackedFileCannotBeRead(let path, let reason):
            return "Guardian could no longer inspect tracked file \(path) (\(reason)). No baseline was advanced."
        case .corruptState:
            return "Saved Guardian history is unreadable or invalid. It was not replaced. Delete Guardian history to start again."
        case .persistence(let detail):
            return "Guardian could not save local history: \(detail)"
        case .reviewNotFound:
            return "That review is no longer available. Scan again before accepting a baseline."
        case .staleReview:
            return "The approved baseline changed after this review. Scan again before accepting a new baseline."
        }
    }
}

/// Mirrors the existing ScopedWorkspace sensitive-component policy and adds the
/// bare `credentials` spelling. Scanner content reads still go through
/// `ScopedWorkspace.readFile`, which repeats its approved path validation.
enum NativeGuardianPathGuard {
    static func isSensitive(relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { isSensitiveComponent(String($0)) }
    }

    static func isSensitiveComponent(_ component: String) -> Bool {
        let lowered = component.lowercased()
        return lowered == ".git" ||
            lowered == ".env" ||
            lowered.hasPrefix(".env.") ||
            lowered == "id_rsa" ||
            lowered == "id_ed25519" ||
            lowered == "credentials" ||
            lowered == "credentials.json" ||
            lowered.hasPrefix("credentials.")
    }

    static func isValidRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\")
        else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return false }
        return !isSensitive(relativePath: path)
    }

    static func depth(of path: String) -> Int {
        path.split(separator: "/").count
    }

    static func isCanonicalSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    static func isCanonicalProjectID(_ value: String) -> Bool {
        isCanonicalSHA256(value)
    }
}
