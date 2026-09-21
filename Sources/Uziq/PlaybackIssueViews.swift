import SwiftUI
import UniformTypeIdentifiers

struct TrackPlaybackIssue {
    let item: UnifiedQueueItem
    let message: String
    let missingFile: Bool
}

struct PlaybackIssueActions: View {
    @Environment(PlaybackQueueStore.self) private var queue
    @Environment(SpotifyStore.self) private var spotify
    let source: PlaybackSource
    let sourceID: String
    @State private var choosingFile = false

    private var issue: TrackPlaybackIssue? {
        if let known = queue.issue(source: source, id: sourceID) { return known }
        if source == .spotify, let item = queue.currentItem,
           item.source == .spotify, item.sourceID == sourceID,
           !spotify.isStartingPlayback, let message = spotify.playbackRecoveryError {
            return TrackPlaybackIssue(item: item, message: message, missingFile: false)
        }
        return nil
    }

    var body: some View {
        if let issue {
            VStack(alignment: .leading, spacing: 6) {
                Label(issue.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Retry") {
                        if source == .spotify && queue.currentItem?.sourceID == sourceID { queue.retrySpotifyPlayback() }
                        else { queue.retry(issue.item) }
                    }
                    if issue.missingFile {
                        Button("Locate File…") { choosingFile = true }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, 6)
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.audio]) { result in
                if case .success(let url) = result {
                    Task { await queue.locate(issue.item, at: url) }
                }
            }
        }
    }
}

struct PlaybackRecoveryBar: View {
    @Environment(PlaybackQueueStore.self) private var queue
    @Environment(SpotifyStore.self) private var spotify

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let item = queue.currentItem {
                PlaybackIssueActions(source: item.source, sourceID: item.sourceID)
                if item.source == .spotify {
                    if let message = spotify.playbackMessage {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(message).font(.caption)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }
}
