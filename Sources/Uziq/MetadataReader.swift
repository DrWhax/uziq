import AVFoundation
import Foundation

struct MetadataReader: Sendable {
    private static let audioExtensions: Set<String> = [
        "mp3", "wav", "flac", "m4a", "m4b", "aac", "aiff", "aif", "alac", "ogg", "oga"
    ]

    static func supports(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    static func read(_ url: URL) async throws -> TrackMetadata {
        guard supports(url) else { throw UziqError.unsupportedFile(url) }
        let values = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modifiedAt = (values?[.modificationDate] as? Date) ?? .now
        let fileSize = (values?[.size] as? NSNumber)?.int64Value ?? 0
        let flacMetadata = readFLACMetadata(from: url)
        let fallback = flacMetadata.comments
        let asset = AVURLAsset(url: url)
        async let commonMetadata = asset.load(.commonMetadata)
        async let assetDuration = asset.load(.duration)
        let common = (try? await commonMetadata) ?? []

        let title = firstNonEmpty(await stringValue(common, key: .commonKeyTitle), fallback["TITLE"]) ?? fallbackFileName(for: url)
        let artist = firstNonEmpty(await stringValue(common, key: .commonKeyArtist), fallback["ARTIST"]) ?? ""
        let album = firstNonEmpty(await stringValue(common, key: .commonKeyAlbumName), fallback["ALBUM"]) ?? ""
        let genre = firstNonEmpty(await stringValue(common, identifier: "com.apple.iTunes", key: "Genre"), fallback["GENRE"]) ?? ""
        let year = firstNonEmpty(await stringValue(common, key: .commonKeyCreationDate), fallback["DATE"], fallback["YEAR"]) ?? ""
        let albumArtist = firstNonEmpty(
            await stringValue(common, identifier: "com.apple.iTunes", key: "albumArtist"),
            fallbackValue(fallback, keys: ["ALBUMARTIST", "ALBUM_ARTIST", "ALBUM ARTIST"])
        ) ?? artist
        let trackNumber = await integerValue(common, identifier: "com.apple.iTunes", key: "trackNumber")
            ?? integerTag(fallback, keys: ["TRACKNUMBER", "TRACK", "TRACKNUM", "TRACK_NUMBER"])
        let discNumber = await integerValue(common, identifier: "com.apple.iTunes", key: "discNumber")
            ?? integerTag(fallback, keys: ["DISCNUMBER", "DISC", "DISCNUM", "DISC_NUMBER"])
        let lyrics = firstNonEmpty(await stringValue(common, identifier: "com.apple.iTunes", key: "lyrics"), fallback["LYRICS"])
        let recordingID = firstNonEmpty(await stringValue(common, identifier: "com.apple.iTunes", key: "MusicBrainz Track Id"), fallback["MUSICBRAINZ_TRACKID"])
        let releaseID = firstNonEmpty(await stringValue(common, identifier: "com.apple.iTunes", key: "MusicBrainz Album Id"), fallback["MUSICBRAINZ_ALBUMID"])
        let artworkItem = common.first { item in
            item.commonKey?.rawValue == AVMetadataKey.commonKeyArtwork.rawValue
        }
        let embeddedArtwork: Data? = if let artworkItem {
            try? await artworkItem.load(.dataValue)
        } else {
            nil
        }
        let artwork = embeddedArtwork ?? flacMetadata.artwork

        let duration = (try? await assetDuration) ?? .zero
        let seconds = duration.isNumeric ? CMTimeGetSeconds(duration) : 0
        let format = try? AVAudioFile(forReading: url)
        let sampleRate = format?.processingFormat.sampleRate
        let codec = url.pathExtension.uppercased()
        let bitrate = format.map { Int(formatBitrate($0)) }
        let replayGainTrackDB = decibelTag(fallback, keys: ["REPLAYGAIN_TRACK_GAIN"])
        let replayGainAlbumDB = decibelTag(fallback, keys: ["REPLAYGAIN_ALBUM_GAIN"])

        return TrackMetadata(
            url: url,
            fileName: url.deletingPathExtension().lastPathComponent,
            title: title,
            artist: artist,
            albumArtist: albumArtist,
            album: album,
            genre: genre,
            year: year,
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: seconds.isFinite ? seconds : 0,
            codec: codec,
            bitrate: bitrate,
            sampleRate: sampleRate,
            replayGainTrackDB: replayGainTrackDB,
            replayGainAlbumDB: replayGainAlbumDB,
            artworkData: artwork,
            lyrics: lyrics,
            musicBrainzRecordingID: recordingID,
            musicBrainzReleaseID: releaseID,
            acoustID: nil,
            modifiedAt: modifiedAt,
            fileSize: fileSize
        )
    }

    private static func stringValue(
        _ items: [AVMetadataItem],
        key: AVMetadataKey,
        identifier: AVMetadataIdentifier? = nil
    ) async -> String? {
        let item = items.first { candidate in
            if let identifier { return candidate.identifier?.rawValue == identifier.rawValue }
            return candidate.commonKey?.rawValue == key.rawValue
        }
        guard let item, let value = try? await item.load(.stringValue) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stringValue(_ items: [AVMetadataItem], identifier: String, key: String) async -> String? {
        guard let item = items.first(where: { $0.identifier?.rawValue == "\(identifier)/\(key)" }) else { return nil }
        guard let value = try? await item.load(.stringValue) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func integerValue(_ items: [AVMetadataItem], identifier: String, key: String) async -> Int? {
        guard let string = await stringValue(items, identifier: identifier, key: key) else { return nil }
        return Int(string.components(separatedBy: "/").first ?? string)
    }

    private static func formatBitrate(_ file: AVAudioFile) -> Double {
        file.processingFormat.sampleRate * Double(file.processingFormat.channelCount) * 16
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }

    private static func fallbackFileName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private static func fallbackValue(_ tags: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = tags[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func integerTag(_ tags: [String: String], keys: [String]) -> Int? {
        guard let value = fallbackValue(tags, keys: keys) else { return nil }
        return Int(value.split(separator: "/").first ?? "")
    }

    private static func decibelTag(_ tags: [String: String], keys: [String]) -> Double? {
        guard let value = fallbackValue(tags, keys: keys) else { return nil }
        let number = value
            .replacingOccurrences(of: "dB", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let gain = Double(number), gain.isFinite else { return nil }
        return min(30, max(-30, gain))
    }

    /// AVFoundation can open FLAC audio but does not consistently expose Vorbis
    /// comments on macOS. Parse the small FLAC metadata blocks directly so tags
    /// remain searchable without adding a heavyweight decoder dependency.
    private struct FLACMetadata {
        var comments: [String: String] = [:]
        var artwork: Data?
    }

    private static func readFLACMetadata(from url: URL) -> FLACMetadata {
        guard url.pathExtension.lowercased() == "flac",
              let handle = try? FileHandle(forReadingFrom: url) else { return FLACMetadata() }
        defer { try? handle.close() }
        guard readExactly(4, from: handle) == Data("fLaC".utf8) else { return FLACMetadata() }

        var metadata = FLACMetadata()
        while let header = readExactly(4, from: handle) {
            let lastBlock = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
            guard length <= 64 * 1024 * 1024,
                  let block = readExactly(length, from: handle) else { break }
            if type == 4 {
                metadata.comments = parseVorbisCommentBlock(block)
            } else if type == 6, metadata.artwork == nil {
                metadata.artwork = parseFLACPictureBlock(block)
            }
            if lastBlock { break }
        }
        if metadata.artwork == nil,
           let encoded = metadata.comments["METADATA_BLOCK_PICTURE"],
           let block = Data(base64Encoded: encoded) {
            metadata.artwork = parseFLACPictureBlock(block)
        }
        return metadata
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) -> Data? {
        guard count >= 0 else { return nil }
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try? handle.read(upToCount: count - data.count),
                  !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        return data
    }

    private static func parseVorbisCommentBlock(_ block: Data) -> [String: String] {
        var offset = 0
        guard let vendorLength = littleEndianUInt32(block, at: offset) else { return [:] }
        offset += 4 + Int(vendorLength)
        guard offset <= block.count, let count = littleEndianUInt32(block, at: offset) else { return [:] }
        offset += 4
        var tags: [String: String] = [:]
        for _ in 0..<count {
            guard let length = littleEndianUInt32(block, at: offset) else { break }
            offset += 4
            let end = offset + Int(length)
            guard end <= block.count, let comment = String(data: block[offset..<end], encoding: .utf8) else { break }
            offset = end
            guard let separator = comment.firstIndex(of: "=") else { continue }
            let key = String(comment[..<separator]).uppercased()
            let value = String(comment[comment.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { tags[key] = value }
        }
        return tags
    }

    private static func parseFLACPictureBlock(_ block: Data) -> Data? {
        var offset = 0
        guard skipBigEndianField(block, offset: &offset), let mimeLength = bigEndianUInt32(block, at: offset) else { return nil }
        offset += 4 + Int(mimeLength)
        guard offset <= block.count, let descriptionLength = bigEndianUInt32(block, at: offset) else { return nil }
        offset += 4 + Int(descriptionLength)
        guard offset + 16 <= block.count else { return nil }
        offset += 16
        guard let dataLength = bigEndianUInt32(block, at: offset) else { return nil }
        offset += 4
        let end = offset + Int(dataLength)
        return end <= block.count ? Data(block[offset..<end]) : nil
    }

    private static func skipBigEndianField(_ data: Data, offset: inout Int) -> Bool {
        guard offset + 4 <= data.count else { return false }
        offset += 4
        return true
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
}
