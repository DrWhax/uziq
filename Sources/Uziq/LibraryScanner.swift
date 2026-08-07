import Foundation

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
                    (index, try? MetadataReader.read(files[index]))
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
                        (index, try? MetadataReader.read(files[index]))
                    }
                }
            }
        }

        progress(ScanProgress(completed: completed, discovered: files.count, currentFile: "Finished"))
        return metadata
    }

    private func collectFiles(roots: [URL]) -> [URL] {
        var files: [URL] = []
        for root in roots {
            let accessGranted = root.startAccessingSecurityScopedResource()
            defer {
                if accessGranted { root.stopAccessingSecurityScopedResource() }
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where MetadataReader.supports(url) {
                files.append(url)
            }
        }
        return files
    }
}
