import Foundation

struct SmartPlaylistSQLQuery {
    let havingClause: String
    let orderClause: String
    let bindings: [String]

    static func build(
        configuration: SmartPlaylistConfiguration,
        includeOrder: Bool,
        now: Date = .now
    ) throws -> SmartPlaylistSQLQuery {
        var conditions: [String] = []
        var bindings: [String] = []
        for rule in configuration.rules {
            guard rule.isValid else {
                throw UziqError.database("The smart playlist contains an invalid rule")
            }
            let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let textExpression: String? = switch rule.field {
            case .title: "COALESCE(o.title, t.title)"
            case .artist: "COALESCE(o.artist, t.artist)"
            case .albumArtist: "COALESCE(o.album_artist, t.album_artist)"
            case .album: "COALESCE(o.album, t.album)"
            case .genre: "COALESCE(o.genre, t.genre)"
            case .codec: "t.codec"
            default: nil
            }

            if let textExpression {
                switch rule.comparison {
                case .contains:
                    conditions.append("instr(lower(\(textExpression)), lower(?)) > 0")
                case .doesNotContain:
                    conditions.append("instr(lower(\(textExpression)), lower(?)) = 0")
                case .equals:
                    conditions.append("lower(trim(\(textExpression))) = lower(trim(?))")
                case .notEquals:
                    conditions.append("lower(trim(\(textExpression))) <> lower(trim(?))")
                default:
                    throw UziqError.database("The smart playlist uses an unsupported text comparison")
                }
                bindings.append(value)
                continue
            }

            switch rule.field {
            case .year, .playCount:
                let expression = rule.field == .year
                    ? "CAST(COALESCE(NULLIF(COALESCE(o.year, t.year), ''), '0') AS REAL)"
                    : "COUNT(ph.id)"
                let comparison: String = switch rule.comparison {
                case .equals: "="
                case .notEquals: "<>"
                case .greaterThan: ">"
                case .lessThan: "<"
                default: throw UziqError.database("The smart playlist uses an unsupported number comparison")
                }
                conditions.append("\(expression) \(comparison) CAST(? AS REAL)")
                bindings.append(value)
            case .favorite:
                conditions.append("t.is_favorite = \(rule.comparison == .isTrue ? 1 : 0)")
            case .dateAdded:
                let cutoff = now.addingTimeInterval(-(Double(value) ?? 0) * 86_400).timeIntervalSince1970
                conditions.append("t.added_at \(rule.comparison == .inLastDays ? ">=" : "<") CAST(? AS REAL)")
                bindings.append(String(cutoff))
            case .lastPlayed:
                let cutoff = now.addingTimeInterval(-(Double(value) ?? 0) * 86_400).timeIntervalSince1970
                if rule.comparison == .inLastDays {
                    conditions.append("MAX(ph.played_at) >= CAST(? AS REAL)")
                } else {
                    conditions.append("(MAX(ph.played_at) IS NULL OR MAX(ph.played_at) < CAST(? AS REAL))")
                }
                bindings.append(String(cutoff))
            case .title, .artist, .albumArtist, .album, .genre, .codec:
                break
            }
        }

        let separator = configuration.matchMode == .all ? " AND " : " OR "
        let havingClause = conditions.isEmpty ? "" : "HAVING " + conditions.joined(separator: separator)
        let orderClause: String
        if includeOrder {
            orderClause = switch configuration.sortOrder {
            case .title:
                "ORDER BY COALESCE(o.title, t.title) COLLATE NOCASE, COALESCE(o.artist, t.artist) COLLATE NOCASE"
            case .artist:
                "ORDER BY COALESCE(o.artist, t.artist) COLLATE NOCASE, COALESCE(o.album, t.album) COLLATE NOCASE, COALESCE(o.title, t.title) COLLATE NOCASE"
            case .album:
                "ORDER BY COALESCE(o.album, t.album) COLLATE NOCASE, "
                    + "CASE WHEN o.disc_number_overridden = 1 THEN o.disc_number ELSE t.disc_number END, "
                    + "CASE WHEN o.track_number_overridden = 1 THEN o.track_number ELSE t.track_number END, "
                    + "COALESCE(o.title, t.title) COLLATE NOCASE"
            case .recentlyAdded:
                "ORDER BY t.added_at DESC"
            case .recentlyPlayed:
                "ORDER BY MAX(ph.played_at) IS NULL, MAX(ph.played_at) DESC"
            case .mostPlayed:
                "ORDER BY COUNT(ph.id) DESC, COALESCE(o.title, t.title) COLLATE NOCASE"
            case .leastPlayed:
                "ORDER BY COUNT(ph.id), COALESCE(o.title, t.title) COLLATE NOCASE"
            case .random:
                "ORDER BY RANDOM()"
            }
        } else {
            orderClause = ""
        }
        return SmartPlaylistSQLQuery(
            havingClause: havingClause,
            orderClause: orderClause,
            bindings: bindings
        )
    }
}
