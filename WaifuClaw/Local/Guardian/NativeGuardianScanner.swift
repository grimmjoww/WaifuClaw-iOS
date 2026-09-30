import CryptoKit
import Foundation

/// Enumerates a user-selected project without invoking a shell, build tool,
/// test runner, model provider, or network client. Every file content read goes
/// through ScopedWorkspace, so its approved root, sensitive-path, regular-file,
/// size, and UTF-8 guards are applied again immediately before hashing.
struct NativeGuardianScanner {
    private let workspace: ScopedWorkspace
    private let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) throws {
        let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isReadableKey])
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              values.isReadable != false
        else {
            throw NativeGuardianError.invalidProject
        }
        self.workspace = try ScopedWorkspace(rootURL: rootURL)
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func scan(
        baseline: NativeGuardianBaseline?,
        progress: ((NativeGuardianScanProgress) -> Void)? = nil
    ) throws -> NativeGuardianReviewRecord {
        let projectID = NativeProjectIdentity.id(for: rootURL)
        let standardizedRoot = rootURL.standardizedFileURL
        let canonicalRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let trackingPaths = Set((baseline?.files ?? []).map(\.relativePath))
        var candidateFiles: [NativeGuardianFileFingerprint] = []
        var omissions: [NativeGuardianOmission] = []
        var visitedEntries = 0
        var totalHashedBytes = 0
        var enumerationError: Error?

        progress?(NativeGuardianScanProgress(
            phase: .enumerating,
            visitedEntries: 0,
            hashedFiles: 0,
            omittedFiles: 0
        ))

        let accessing = rootURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { rootURL.stopAccessingSecurityScopedResource() }
        }

        let propertyKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: propertyKeys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw NativeGuardianError.enumerationFailed("The Files folder could not be opened.")
        }

        while let rawURL = enumerator.nextObject() as? URL {
            visitedEntries += 1
            guard visitedEntries <= NativeGuardianScanLimits.maximumVisitedEntries else {
                throw NativeGuardianError.entryLimitExceeded(NativeGuardianScanLimits.maximumVisitedEntries)
            }
            let standardizedURL = rawURL.standardizedFileURL
            guard isInside(standardizedURL.path, root: standardizedRoot.path) else {
                throw NativeGuardianError.inspectionFailed(rawURL.lastPathComponent)
            }
            let relativePath = relativePath(for: standardizedURL, root: standardizedRoot)
            guard !relativePath.isEmpty else { continue }

            // Never inspect a protected directory/file's metadata or content.
            // Skipping descendants also prevents an accidental traversal of .git.
            if NativeGuardianPathGuard.isSensitive(relativePath: relativePath) {
                enumerator.skipDescendants()
                continue
            }

            if !NativeGuardianPathGuard.isValidRelativePath(relativePath) {
                enumerator.skipDescendants()
                continue
            }

            let values: URLResourceValues
            do {
                values = try rawURL.resourceValues(forKeys: Set(propertyKeys))
            } catch {
                throw NativeGuardianError.inspectionFailed(relativePath)
            }

            // Symlinks are never followed, including a symlink whose target is
            // currently inside the root. A later target swap therefore cannot
            // turn an admitted read into a traversal outside the project.
            if values.isSymbolicLink == true {
                try failIfTracked(relativePath, trackingPaths, reason: "it has become a symlink")
                enumerator.skipDescendants()
                continue
            }

            let canonicalURL = standardizedURL.resolvingSymlinksInPath()
            guard isInside(canonicalURL.path, root: canonicalRoot.path) else {
                throw NativeGuardianError.inspectionFailed(relativePath)
            }

            if values.isDirectory == true {
                if NativeGuardianPathGuard.depth(of: relativePath) >= NativeGuardianScanLimits.maximumDepth {
                    enumerator.skipDescendants()
                }
                reportProgress(progress, visitedEntries, candidateFiles.count, omissions.count)
                continue
            }

            guard values.isRegularFile == true else {
                try failIfTracked(relativePath, trackingPaths, reason: "it is no longer a regular file")
                reportProgress(progress, visitedEntries, candidateFiles.count, omissions.count)
                continue
            }

            if NativeGuardianPathGuard.depth(of: relativePath) > NativeGuardianScanLimits.maximumDepth {
                try appendOmission(NativeGuardianOmission(relativePath: relativePath, reason: .depthLimit), to: &omissions)
                reportProgress(progress, visitedEntries, candidateFiles.count, omissions.count)
                continue
            }

            let text: String
            do {
                // This repeats canonical-root, sensitive component, regular file,
                // 128 KB, and UTF-8 checks directly before the content is hashed.
                text = try workspace.readFile(relativePath: relativePath)
            } catch let error as ScopedWorkspace.WorkspaceError {
                switch error {
                case .fileTooLarge:
                    try failIfTracked(relativePath, trackingPaths, reason: "it exceeds the 128 KB UTF-8 text limit")
                    try appendOmission(NativeGuardianOmission(relativePath: relativePath, reason: .tooLarge), to: &omissions)
                    reportProgress(progress, visitedEntries, candidateFiles.count, omissions.count)
                    continue
                case .notText:
                    try failIfTracked(relativePath, trackingPaths, reason: "it is no longer valid UTF-8 text")
                    try appendOmission(NativeGuardianOmission(relativePath: relativePath, reason: .notUTF8), to: &omissions)
                    reportProgress(progress, visitedEntries, candidateFiles.count, omissions.count)
                    continue
                case .invalidFolder, .invalidPath, .deniedPath, .notAFile:
                    throw NativeGuardianError.inspectionFailed(relativePath)
                }
            } catch {
                throw NativeGuardianError.inspectionFailed(relativePath)
            }

            let data = Data(text.utf8)
            guard candidateFiles.count < NativeGuardianScanLimits.maximumFiles else {
                throw NativeGuardianError.fileLimitExceeded(NativeGuardianScanLimits.maximumFiles)
            }
            let nextTotal = totalHashedBytes + data.count
            guard nextTotal <= NativeGuardianScanLimits.maximumTotalBytes else {
                throw NativeGuardianError.totalByteLimitExceeded(NativeGuardianScanLimits.maximumTotalBytes)
            }
            candidateFiles.append(NativeGuardianFileFingerprint(
                relativePath: relativePath,
                sha256: Self.sha256(data),
                byteCount: data.count
            ))
            totalHashedBytes = nextTotal
            reportProgress(progress, visitedEntries, candidateFiles.count, omissions.count)
        }

        if let enumerationError {
            throw NativeGuardianError.enumerationFailed(enumerationError.localizedDescription)
        }

        candidateFiles.sort { $0.relativePath < $1.relativePath }
        omissions.sort { $0.relativePath < $1.relativePath }
        let changes = Self.changes(baseline: baseline?.files ?? [], candidate: candidateFiles)
        let review = NativeGuardianReviewRecord(
            projectID: projectID,
            baselineID: baseline?.id,
            candidateFiles: candidateFiles,
            changes: changes,
            omissions: omissions,
            visitedEntries: visitedEntries
        )
        progress?(NativeGuardianScanProgress(
            phase: .complete,
            visitedEntries: visitedEntries,
            hashedFiles: candidateFiles.count,
            omittedFiles: omissions.count
        ))
        return review
    }

    private func failIfTracked(_ path: String, _ trackedPaths: Set<String>, reason: String) throws {
        guard trackedPaths.contains(path) else { return }
        throw NativeGuardianError.trackedFileCannotBeRead(path, reason)
    }

    private func appendOmission(_ omission: NativeGuardianOmission, to omissions: inout [NativeGuardianOmission]) throws {
        guard omissions.count < NativeGuardianScanLimits.maximumOmissions else {
            throw NativeGuardianError.omissionLimitExceeded(NativeGuardianScanLimits.maximumOmissions)
        }
        omissions.append(omission)
    }

    private func reportProgress(
        _ progress: ((NativeGuardianScanProgress) -> Void)?,
        _ visitedEntries: Int,
        _ hashedFiles: Int,
        _ omittedFiles: Int
    ) {
        progress?(NativeGuardianScanProgress(
            phase: .enumerating,
            visitedEntries: visitedEntries,
            hashedFiles: hashedFiles,
            omittedFiles: omittedFiles
        ))
    }

    private func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
        guard url.path.hasPrefix(rootPath + "/") else { return "" }
        return String(url.path.dropFirst(rootPath.count + 1))
    }

    private func isInside(_ candidatePath: String, root rootPath: String) -> Bool {
        if rootPath == "/" {
            return candidatePath.hasPrefix("/") && candidatePath != "/"
        }
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func changes(
        baseline: [NativeGuardianFileFingerprint],
        candidate: [NativeGuardianFileFingerprint]
    ) -> [NativeGuardianFileChange] {
        let oldByPath = Dictionary(uniqueKeysWithValues: baseline.map { ($0.relativePath, $0) })
        let newByPath = Dictionary(uniqueKeysWithValues: candidate.map { ($0.relativePath, $0) })
        let allPaths = Set(oldByPath.keys).union(newByPath.keys).sorted()

        return allPaths.compactMap { path in
            let old = oldByPath[path]
            let new = newByPath[path]
            switch (old, new) {
            case (nil, let current?):
                return NativeGuardianFileChange(
                    kind: .added,
                    relativePath: path,
                    previousSHA256: nil,
                    currentSHA256: current.sha256,
                    previousByteCount: nil,
                    currentByteCount: current.byteCount
                )
            case (let previous?, nil):
                return NativeGuardianFileChange(
                    kind: .deleted,
                    relativePath: path,
                    previousSHA256: previous.sha256,
                    currentSHA256: nil,
                    previousByteCount: previous.byteCount,
                    currentByteCount: nil
                )
            case (let previous?, let current?):
                guard previous.sha256 != current.sha256 || previous.byteCount != current.byteCount else { return nil }
                return NativeGuardianFileChange(
                    kind: .changed,
                    relativePath: path,
                    previousSHA256: previous.sha256,
                    currentSHA256: current.sha256,
                    previousByteCount: previous.byteCount,
                    currentByteCount: current.byteCount
                )
            case (nil, nil):
                return nil
            }
        }
    }
}
