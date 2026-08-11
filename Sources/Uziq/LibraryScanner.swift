import Foundation

struct IndexedAudioFile: Sendable, Equatable {
    let modifiedAt: Date
    let fileSize: Int64
}

struct LibraryReconciliation: Sendable {
    let changedMetadata: [TrackMetadata]
    let removedPaths: [String]
    let discoveredCount: Int

    var hasChanges: Bool { !changedMetadata.isEmpty || !removedPaths.isEmpty }
}

struct LibraryScanner: Sendable {
    func scan(
        roots: [URL],
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async -> [TrackMetadata] {
        let files = await Task.detached(priority: .utility) {
            collectFiles(roots: roots)
        }.value
        progress(ScanProgress(completed: 0, discovered: files.count, currentFile: "Preparing metadata…"))

        guard !files.isEmpty else {
            progress(ScanProgress(completed: 0, discovered: 0, currentFile: "Finished"))
            return []
        }

        let workerCount = min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 8)
        var nextIndex = 0
        var completed = 0
        var metadata: [TrackMetadata] = []
        metadata.reserveCapacity(files.count)

        await withTaskGroup(of: (Int, TrackMetadata?).self) { group in
            for _ in 0..<min(workerCount, files.count) {
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    (index, try? await MetadataReader.read(files[index]))
                }
            }

            while let (_, item) = await group.next() {
                if let item { metadata.append(item) }
                completed += 1
                progress(ScanProgress(
                    completed: completed,
                    discovered: files.count,
                    currentFile: item?.fileName ?? "Skipped unreadable file"
                ))
                if nextIndex < files.count {
                    let index = nextIndex
                    nextIndex += 1
                    group.addTask {
                        (index, try? await MetadataReader.read(files[index]))
                    }
                }
            }
        }

        progress(ScanProgress(completed: completed, discovered: files.count, currentFile: "Finished"))
        return metadata
    }

    func reconcile(
        root: URL,
        indexedFiles: [String: IndexedAudioFile]
    ) async -> LibraryReconciliation? {
        let files = await Task.detached(priority: .utility) {
            collectFiles(root: root)
        }.value
        guard let files else { return nil }
        let paths = Set(files.map { $0.standardizedFileURL.path })
        let removedPaths = indexedFiles.keys.filter { !paths.contains($0) }
        let changedFiles = files.filter { url in
            guard let indexed = indexedFiles[url.standardizedFileURL.path],
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modifiedAt = values.contentModificationDate,
                  let fileSize = values.fileSize else { return true }
            return indexed.fileSize != Int64(fileSize)
                || abs(indexed.modifiedAt.timeIntervalSince1970 - modifiedAt.timeIntervalSince1970) > 0.001
        }

        let metadata = await readMetadata(changedFiles)
        return LibraryReconciliation(
            changedMetadata: metadata,
            removedPaths: removedPaths.sorted(),
            discoveredCount: files.count
        )
    }

    private func collectFiles(roots: [URL]) -> [URL] {
        roots.flatMap { collectFiles(root: $0) ?? [] }
    }

    private func collectFiles(root: URL) -> [URL]? {
        let accessGranted = root.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { root.stopAccessingSecurityScopedResource() }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return nil }
        var files: [URL] = []
        for case let url as URL in enumerator where MetadataReader.supports(url) {
            files.append(url.standardizedFileURL)
        }
        return files
    }

    private func readMetadata(_ files: [URL]) async -> [TrackMetadata] {
        guard !files.isEmpty else { return [] }
        let workerCount = min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 8)
        return await withTaskGroup(of: TrackMetadata?.self, returning: [TrackMetadata].self) { group in
            var iterator = files.makeIterator()
            for _ in 0..<min(workerCount, files.count) {
                guard let file = iterator.next() else { break }
                group.addTask { try? await MetadataReader.read(file) }
            }
            var result: [TrackMetadata] = []
            result.reserveCapacity(files.count)
            while let metadata = await group.next() {
                if let metadata { result.append(metadata) }
                if let file = iterator.next() {
                    group.addTask { try? await MetadataReader.read(file) }
                }
            }
            return result
        }
    }
}
