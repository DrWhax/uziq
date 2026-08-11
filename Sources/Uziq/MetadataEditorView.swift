import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct TrackMetadataEditorView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let track: Track

    @State private var title: String
    @State private var artist: String
    @State private var albumArtist: String
    @State private var album: String
    @State private var genre: String
    @State private var year: String
    @State private var trackNumber: String
    @State private var discNumber: String
    @State private var artworkData: Data?
    @State private var artworkChanged = false
    @State private var showingArtworkImporter = false
    @State private var showingRevertConfirmation = false
    @State private var isSaving = false

    init(track: Track) {
        self.track = track
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
        _albumArtist = State(initialValue: track.albumArtist)
        _album = State(initialValue: track.album)
        _genre = State(initialValue: track.genre)
        _year = State(initialValue: track.year)
        _trackNumber = State(initialValue: track.trackNumber.map(String.init) ?? "")
        _discNumber = State(initialValue: track.discNumber.map(String.init) ?? "")
        _artworkData = State(initialValue: track.artworkData)
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader(title: "Edit Track Metadata", subtitle: track.fileName)
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 26) {
                    artworkEditor(label: "Track artwork")
                    metadataFields
                }
                .padding(24)
            }
            Divider()
            HStack {
                Button("Revert to File Metadata", role: .destructive) {
                    showingRevertConfirmation = true
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid || isSaving)
            }
            .padding(16)
        }
        .frame(width: 680, height: 570)
        .fileImporter(
            isPresented: $showingArtworkImporter,
            allowedContentTypes: [.image]
        ) { result in
            guard case .success(let url) = result,
                  let data = MetadataArtworkImporter.data(from: url) else { return }
            artworkData = data
            artworkChanged = true
        }
        .confirmationDialog(
            "Discard every Uziq override for this track?",
            isPresented: $showingRevertConfirmation
        ) {
            Button("Revert to File Metadata", role: .destructive) { revert() }
        } message: {
            Text("The audio file is unchanged. Metadata read from it will become visible again.")
        }
    }

    private var metadataFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            metadataRow("Title", text: $title)
            metadataRow("Artist", text: $artist)
            metadataRow("Album artist", text: $albumArtist)
            metadataRow("Album", text: $album)
            metadataRow("Genre", text: $genre)
            metadataRow("Year", text: $year)
            GridRow {
                Text("Track / Disc").foregroundStyle(.secondary)
                HStack {
                    TextField("Track", text: $trackNumber).frame(width: 90)
                    TextField("Disc", text: $discNumber).frame(width: 90)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataRow(_ label: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            TextField(label, text: text).frame(minWidth: 300)
        }
    }

    private func editorHeader(title: String, subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.bold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(18)
    }

    private func artworkEditor(label: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ArtworkView(data: artworkData)
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(label).font(.caption).foregroundStyle(.secondary)
            Button("Choose Image…") { showingArtworkImporter = true }
            Button("Remove Artwork", role: .destructive) {
                artworkData = nil
                artworkChanged = true
            }
            .disabled(artworkData == nil)
        }
        .buttonStyle(.borderless)
        .frame(width: 180, alignment: .leading)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            parsedNumber(trackNumber).valid && parsedNumber(discNumber).valid
    }

    private func parsedNumber(_ value: String) -> (value: Int?, valid: Bool) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, true) }
        guard let number = Int(trimmed), number > 0 else { return (nil, false) }
        return (number, true)
    }

    private func save() {
        isSaving = true
        let changes = MetadataOverrideChanges(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            albumArtist: albumArtist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: album.trimmingCharacters(in: .whitespacesAndNewlines),
            genre: genre.trimmingCharacters(in: .whitespacesAndNewlines),
            year: year.trimmingCharacters(in: .whitespacesAndNewlines),
            trackNumber: parsedNumber(trackNumber).value,
            discNumber: parsedNumber(discNumber).value,
            overridesTrackNumber: true,
            overridesDiscNumber: true,
            artworkData: artworkData,
            overridesArtwork: artworkChanged
        )
        Task {
            if await library.applyMetadataOverrides(trackIDs: [track.id], changes: changes) { dismiss() }
            isSaving = false
        }
    }

    private func revert() {
        isSaving = true
        Task {
            if await library.clearMetadataOverrides(trackIDs: [track.id]) { dismiss() }
            isSaving = false
        }
    }
}

enum MetadataBatchScope {
    case album
    case artist
}

struct BatchMetadataEditorView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let tracks: [Track]
    let scope: MetadataBatchScope

    @State private var editsArtist: Bool
    @State private var artist: String
    @State private var editsAlbumArtist: Bool
    @State private var albumArtist: String
    @State private var editsAlbum: Bool
    @State private var album: String
    @State private var editsGenre = false
    @State private var genre: String
    @State private var editsYear = false
    @State private var year: String
    @State private var editsDiscNumber = false
    @State private var discNumber: String
    @State private var artworkData: Data?
    @State private var artworkChanged = false
    @State private var showingArtworkImporter = false
    @State private var showingRevertConfirmation = false
    @State private var isSaving = false

    init(tracks: [Track], scope: MetadataBatchScope) {
        self.tracks = tracks
        self.scope = scope
        let first = tracks.first
        _editsArtist = State(initialValue: scope == .artist)
        _artist = State(initialValue: first?.artist ?? "")
        _editsAlbumArtist = State(initialValue: scope == .album)
        _albumArtist = State(initialValue: first?.albumArtist ?? "")
        _editsAlbum = State(initialValue: scope == .album)
        _album = State(initialValue: first?.album ?? "")
        _genre = State(initialValue: first?.genre ?? "")
        _year = State(initialValue: first?.year ?? "")
        _discNumber = State(initialValue: first?.discNumber.map(String.init) ?? "")
        _artworkData = State(initialValue: first?.artworkData)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(scope == .album ? "Edit Album Metadata" : "Edit Artist Metadata")
                        .font(.title2.weight(.bold))
                    Text("Changes apply to \(tracks.count) tracks and survive rescans.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 26) {
                    batchArtworkEditor
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                        batchRow("Artist", enabled: $editsArtist, text: $artist)
                        batchRow("Album artist", enabled: $editsAlbumArtist, text: $albumArtist)
                        batchRow("Album", enabled: $editsAlbum, text: $album)
                        batchRow("Genre", enabled: $editsGenre, text: $genre)
                        batchRow("Year", enabled: $editsYear, text: $year)
                        batchRow("Disc number", enabled: $editsDiscNumber, text: $discNumber)
                    }
                    .textFieldStyle(.roundedBorder)
                }
                .padding(24)
            }
            Divider()
            HStack {
                Button("Revert Track Overrides", role: .destructive) {
                    showingRevertConfirmation = true
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply to \(tracks.count) Tracks") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges || !discNumberIsValid || isSaving)
            }
            .padding(16)
        }
        .frame(width: 720, height: 560)
        .fileImporter(isPresented: $showingArtworkImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result,
                  let data = MetadataArtworkImporter.data(from: url) else { return }
            artworkData = data
            artworkChanged = true
        }
        .confirmationDialog(
            "Discard every Uziq metadata override for these \(tracks.count) tracks?",
            isPresented: $showingRevertConfirmation
        ) {
            Button("Revert Track Overrides", role: .destructive) { revert() }
        } message: {
            Text("The original audio files remain untouched.")
        }
    }

    private func batchRow(
        _ label: String,
        enabled: Binding<Bool>,
        text: Binding<String>
    ) -> some View {
        GridRow {
            Toggle(label, isOn: enabled).toggleStyle(.checkbox).frame(width: 120, alignment: .leading)
            TextField(label, text: text).disabled(!enabled.wrappedValue).frame(minWidth: 300)
        }
    }

    private var batchArtworkEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ArtworkView(data: artworkData)
                .frame(width: 180, height: 180)
                .clipShape(scope == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 14)))
            Text(scope == .album ? "Album artwork" : "Artist picture")
                .font(.caption).foregroundStyle(.secondary)
            Button("Choose Image…") { showingArtworkImporter = true }
            if scope == .album {
                Button("Remove Artwork", role: .destructive) {
                    artworkData = nil
                    artworkChanged = true
                }
                .disabled(artworkData == nil)
            }
        }
        .buttonStyle(.borderless)
        .frame(width: 180, alignment: .leading)
    }

    private var hasChanges: Bool {
        editsArtist || editsAlbumArtist || editsAlbum || editsGenre || editsYear ||
            editsDiscNumber || artworkChanged
    }

    private var discNumberIsValid: Bool {
        guard editsDiscNumber else { return true }
        let trimmed = discNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || (Int(trimmed).map { $0 > 0 } == true)
    }

    private func save() {
        isSaving = true
        let changes = MetadataOverrideChanges(
            artist: editsArtist ? artist.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            albumArtist: editsAlbumArtist ? albumArtist.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            album: editsAlbum ? album.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            genre: editsGenre ? genre.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            year: editsYear ? year.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            discNumber: editsDiscNumber ? Int(discNumber.trimmingCharacters(in: .whitespacesAndNewlines)) : nil,
            overridesDiscNumber: editsDiscNumber,
            artworkData: scope == .album ? artworkData : nil,
            overridesArtwork: scope == .album && artworkChanged
        )
        Task {
            var succeeded = await library.applyMetadataOverrides(
                trackIDs: tracks.map(\.id),
                changes: changes
            )
            if scope == .artist, artworkChanged, let artworkData {
                let effectiveArtist = editsArtist ? artist : (tracks.first?.displayArtist ?? "")
                succeeded = await library.overrideArtistArtwork(
                    artist: effectiveArtist,
                    artworkData: artworkData
                ) && succeeded
            }
            if succeeded { dismiss() }
            isSaving = false
        }
    }

    private func revert() {
        isSaving = true
        Task {
            var succeeded = await library.clearMetadataOverrides(trackIDs: tracks.map(\.id))
            if scope == .artist {
                let effectiveArtist = tracks.first?.displayArtist ?? ""
                succeeded = await library.clearArtistArtworkOverride(artist: effectiveArtist) && succeeded
            }
            if succeeded { dismiss() }
            isSaving = false
        }
    }
}

private enum MetadataArtworkImporter {
    static func data(from url: URL) -> Data? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_400
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
