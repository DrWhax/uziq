import Foundation

struct LyricsPayload: Sendable, Equatable {
    let plain: String
    let synced: String?
}

struct TimedLyricsLine: Identifiable, Sendable, Equatable {
    let id: String
    let time: Double
    let text: String
}

struct LyricsPresentation: Sendable, Equatable {
    let plainText: String
    let timedLines: [TimedLyricsLine]

    init(plain: String, synced: String? = nil) {
        let parsed = SyncedLyricsParser.parse(synced ?? plain)
        timedLines = parsed
        if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            plainText = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            plainText = parsed.map(\.text).joined(separator: "\n")
        }
    }
}

enum SyncedLyricsParser {
    private static let timestampExpression = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
    )
    private static let offsetExpression = try! NSRegularExpression(
        pattern: #"\[offset:([+-]?\d+)\]"#,
        options: [.caseInsensitive]
    )

    static func parse(_ value: String) -> [TimedLyricsLine] {
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let offsetMilliseconds = offsetExpression.firstMatch(in: value, range: fullRange)
            .flatMap { match -> Int? in
                guard let range = Range(match.range(at: 1), in: value) else { return nil }
                return Int(value[range])
            } ?? 0

        var lines: [(time: Double, order: Int, text: String)] = []
        for (order, rawLine) in value.components(separatedBy: .newlines).enumerated() {
            let lineRange = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            let matches = timestampExpression.matches(in: rawLine, range: lineRange)
            guard !matches.isEmpty else { continue }
            let text = timestampExpression.stringByReplacingMatches(
                in: rawLine,
                range: lineRange,
                withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: rawLine),
                      let secondRange = Range(match.range(at: 2), in: rawLine),
                      let minutes = Double(rawLine[minuteRange]),
                      let seconds = Double(rawLine[secondRange]) else { continue }
                let fraction: Double
                if let fractionRange = Range(match.range(at: 3), in: rawLine) {
                    let digits = String(rawLine[fractionRange])
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                } else {
                    fraction = 0
                }
                let time = max(0, minutes * 60 + seconds + fraction + Double(offsetMilliseconds) / 1_000)
                lines.append((time, order, text))
            }
        }

        return lines.sorted {
            $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time
        }.enumerated().map { index, line in
            TimedLyricsLine(
                id: "\(Int((line.time * 1_000).rounded()))-\(index)",
                time: line.time,
                text: line.text
            )
        }
    }
}
