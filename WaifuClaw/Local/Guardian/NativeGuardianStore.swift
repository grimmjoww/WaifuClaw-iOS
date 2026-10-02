import Foundation

/// Per-project, local-only persistence for Guardian. The filename is a
/// SHA-256 project identity rather than a raw folder path or bookmark. A state
/// file is decoded and fully validated before it can be used or overwritten.
final class NativeGuardianStore {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) throws {
        if let rootDirectory {
            self.directoryURL = rootDirectory
        } else {
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw NativeGuardianError.persistence("Application Support is unavailable.")
            }
            self.directoryURL = applicationSupport
                .appendingPathComponent("WaifuClaw", isDirectory: true)
                .appendingPathComponent("Guardian", isDirectory: true)
        }
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    func load(projectID: String) throws -> NativeGuardianProjectSnapshot? {
        let url = try fileURL(forProjectID: projectID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let snapshot = try decoder.decode(NativeGuardianProjectSnapshot.self, from: data)
            try Self.validate(snapshot, expectedProjectID: projectID)
            return snapshot
        } catch let error as NativeGuardianError {
            throw error
        } catch {
            // A read/decode/validation problem must never be normalized into a
            // blank state, because that would erase the user's evidence.
            throw NativeGuardianError.corruptState
        }
    }

    /// Appends an actual completed scan before it can be approved. This makes it
    /// impossible to advance a baseline by manufacturing an unrecorded review.
    @discardableResult
    func recordReview(_ review: NativeGuardianReviewRecord, for projectID: String) throws -> NativeGuardianProjectSnapshot {
        guard review.projectID == projectID else { throw NativeGuardianError.staleReview }
        var current = try load(projectID: projectID) ?? NativeGuardianProjectSnapshot(
            projectID: projectID,
            baseline: nil,
            reviews: [],
            lastApprovedReviewID: nil
        )
        guard review.baselineID == current.baseline?.id else {
            throw NativeGuardianError.staleReview
        }
        try Self.validateReview(review, expectedProjectID: projectID)
        guard !current.reviews.contains(where: { $0.id == review.id }) else {
            throw NativeGuardianError.staleReview
        }
        current = NativeGuardianProjectSnapshot(
            projectID: projectID,
            baseline: current.baseline,
            reviews: Array((current.reviews + [review]).suffix(NativeGuardianScanLimits.maximumReviewHistory)),
            lastApprovedReviewID: current.lastApprovedReviewID
        )
        try save(current)
        return current
    }

    /// Replaces the approved immutable baseline only with the candidate inventory
    /// from a persisted review whose source baseline still exactly matches.
    @discardableResult
    func approveBaseline(projectID: String, reviewID: UUID, approvedAt: Date = .now) throws -> NativeGuardianProjectSnapshot {
        guard var current = try load(projectID: projectID) else {
            throw NativeGuardianError.reviewNotFound
        }
        guard let review = current.reviews.first(where: { $0.id == reviewID }) else {
            throw NativeGuardianError.reviewNotFound
        }
        guard review.baselineID == current.baseline?.id else {
            throw NativeGuardianError.staleReview
        }

        let nextBaseline = NativeGuardianBaseline(approvedAt: approvedAt, files: review.candidateFiles)
        try Self.validateBaseline(nextBaseline)
        current = NativeGuardianProjectSnapshot(
            projectID: projectID,
            baseline: nextBaseline,
            reviews: current.reviews,
            lastApprovedReviewID: review.id
        )
        try save(current)
        return current
    }

    /// Deletes only this project's local Guardian JSON. This intentionally works
    /// even when the existing JSON is malformed, allowing a user to recover from
    /// fail-closed state without touching project files or any other project.
    func deleteHistory(projectID: String) throws {
        let url = try fileURL(forProjectID: projectID)
        do {
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
        } catch {
            throw NativeGuardianError.persistence(error.localizedDescription)
        }
    }

    /// Internal for real filesystem tests; callers cannot derive a path from an
    /// unchecked identifier.
    func fileURL(forProjectID projectID: String) throws -> URL {
        guard NativeGuardianPathGuard.isCanonicalProjectID(projectID) else {
            throw NativeGuardianError.invalidProjectIdentity
        }
        return directoryURL
            .appendingPathComponent(projectID, isDirectory: false)
            .appendingPathExtension("json")
    }

    private func save(_ snapshot: NativeGuardianProjectSnapshot) throws {
        do {
            try Self.validate(snapshot, expectedProjectID: snapshot.projectID)
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            let url = try fileURL(forProjectID: snapshot.projectID)
            try data.write(to: url, options: [.atomic])
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch let error as NativeGuardianError {
            throw error
        } catch {
            throw NativeGuardianError.persistence(error.localizedDescription)
        }
    }

    private static func validate(_ snapshot: NativeGuardianProjectSnapshot, expectedProjectID: String) throws {
        guard snapshot.version == NativeGuardianProjectSnapshot.currentVersion,
              snapshot.projectID == expectedProjectID,
              NativeGuardianPathGuard.isCanonicalProjectID(snapshot.projectID),
              snapshot.reviews.count <= NativeGuardianScanLimits.maximumReviewHistory,
              Set(snapshot.reviews.map(\.id)).count == snapshot.reviews.count
        else {
            throw NativeGuardianError.corruptState
        }
        if let baseline = snapshot.baseline {
            try validateBaseline(baseline)
        }
        for review in snapshot.reviews {
            try validateReview(review, expectedProjectID: expectedProjectID)
        }
    }

    private static func validateBaseline(_ baseline: NativeGuardianBaseline) throws {
        try validateInventory(baseline.files)
    }

    private static func validateReview(_ review: NativeGuardianReviewRecord, expectedProjectID: String) throws {
        guard review.projectID == expectedProjectID,
              NativeGuardianPathGuard.isCanonicalProjectID(review.projectID),
              review.visitedEntries >= 0,
              review.visitedEntries <= NativeGuardianScanLimits.maximumVisitedEntries,
              review.changes.count <= NativeGuardianScanLimits.maximumFiles * 2,
              review.omissions.count <= NativeGuardianScanLimits.maximumOmissions,
              Set(review.changes.map(\.id)).count == review.changes.count,
              Set(review.omissions.map(\.id)).count == review.omissions.count
        else {
            throw NativeGuardianError.corruptState
        }
        try validateInventory(review.candidateFiles)
        for change in review.changes {
            guard NativeGuardianPathGuard.isValidRelativePath(change.relativePath),
                  NativeGuardianPathGuard.depth(of: change.relativePath) <= NativeGuardianScanLimits.maximumDepth
            else { throw NativeGuardianError.corruptState }
            switch change.kind {
            case .added:
                guard change.previousSHA256 == nil,
                      change.previousByteCount == nil,
                      let currentSHA256 = change.currentSHA256,
                      let currentByteCount = change.currentByteCount,
                      NativeGuardianPathGuard.isCanonicalSHA256(currentSHA256),
                      currentByteCount >= 0,
                      currentByteCount <= NativeGuardianScanLimits.maximumFileBytes
                else { throw NativeGuardianError.corruptState }
            case .changed:
                guard let previousSHA256 = change.previousSHA256,
                      let currentSHA256 = change.currentSHA256,
                      let previousByteCount = change.previousByteCount,
                      let currentByteCount = change.currentByteCount,
                      NativeGuardianPathGuard.isCanonicalSHA256(previousSHA256),
                      NativeGuardianPathGuard.isCanonicalSHA256(currentSHA256),
                      previousByteCount >= 0,
                      currentByteCount >= 0,
                      previousByteCount <= NativeGuardianScanLimits.maximumFileBytes,
                      currentByteCount <= NativeGuardianScanLimits.maximumFileBytes
                else { throw NativeGuardianError.corruptState }
            case .deleted:
                guard let previousSHA256 = change.previousSHA256,
                      let previousByteCount = change.previousByteCount,
                      change.currentSHA256 == nil,
                      change.currentByteCount == nil,
                      NativeGuardianPathGuard.isCanonicalSHA256(previousSHA256),
                      previousByteCount >= 0,
                      previousByteCount <= NativeGuardianScanLimits.maximumFileBytes
                else { throw NativeGuardianError.corruptState }
            }
        }
        for omission in review.omissions {
            guard NativeGuardianPathGuard.isValidRelativePath(omission.relativePath) else {
                throw NativeGuardianError.corruptState
            }
            switch omission.reason {
            case .depthLimit:
                guard NativeGuardianPathGuard.depth(of: omission.relativePath) == NativeGuardianScanLimits.maximumDepth + 1 else {
                    throw NativeGuardianError.corruptState
                }
            case .tooLarge, .notUTF8, .unsupportedName:
                guard NativeGuardianPathGuard.depth(of: omission.relativePath) <= NativeGuardianScanLimits.maximumDepth else {
                    throw NativeGuardianError.corruptState
                }
            }
        }
    }

    private static func validateInventory(_ files: [NativeGuardianFileFingerprint]) throws {
        guard files.count <= NativeGuardianScanLimits.maximumFiles else {
            throw NativeGuardianError.corruptState
        }
        var previousPath: String?
        var totalBytes = 0
        for file in files {
            guard NativeGuardianPathGuard.isValidRelativePath(file.relativePath),
                  NativeGuardianPathGuard.depth(of: file.relativePath) <= NativeGuardianScanLimits.maximumDepth,
                  NativeGuardianPathGuard.isCanonicalSHA256(file.sha256),
                  file.byteCount >= 0,
                  file.byteCount <= NativeGuardianScanLimits.maximumFileBytes,
                  previousPath == nil || previousPath! < file.relativePath
            else {
                throw NativeGuardianError.corruptState
            }
            totalBytes += file.byteCount
            guard totalBytes <= NativeGuardianScanLimits.maximumTotalBytes else {
                throw NativeGuardianError.corruptState
            }
            previousPath = file.relativePath
        }
    }
}
