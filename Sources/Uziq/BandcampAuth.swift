import CryptoKit
import Foundation
import Security

struct BandcampOAuthSession: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expirationDate: Date

    var needsRefresh: Bool {
        expirationDate <= Date.now.addingTimeInterval(60)
    }
}

struct BandcampCollectionPage: Sendable {
    let items: [BandcampResult]
    let nextOffset: String?
}

enum BandcampKeychain {
    private static let service = "app.uziq.bandcamp"
    private static let account = "oauth-session"

    static func readSession() -> BandcampOAuthSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(BandcampOAuthSession.self, from: data)
    }

    static func writeSession(_ session: BandcampOAuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func removeSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct BandcampAuthClient: Sendable {
    private static let clientID = "134"
    private static let clientSecret = "1myK12VeCL3dWl9o/ncV2VyUUbOJuNPVJK6bZZJxHvk="
    private static let userAgent = "Dalvik/2.1.0 (Linux; U; Android 13) Bandcamp/3.3.6"
    private static let requestedWith = "com.bandcamp.android"
    private static let baseURL = URL(string: "https://bandcamp.com")!

    func login(email: String, password: String, authCode: String?) async throws -> BandcampOAuthSession {
        var fields = [
            ("grant_type", "password"),
            ("username", email),
            ("password", password),
            ("client_id", Self.clientID),
            ("client_secret", Self.clientSecret)
        ]
        if let authCode, !authCode.isEmpty { fields.append(("authcode", authCode)) }
        return try await tokenRequest(path: "oauth_login", fields: fields, usesDM: true)
    }

    func refresh(_ session: BandcampOAuthSession) async throws -> BandcampOAuthSession {
        try await tokenRequest(path: "oauth_token", fields: [
            ("grant_type", "refresh_token"),
            ("refresh_token", session.refreshToken),
            ("client_id", Self.clientID),
            ("client_secret", Self.clientSecret)
        ], usesDM: false)
    }

    func revoke(_ session: BandcampOAuthSession) async {
        let fields = [
            ("refresh_token", session.refreshToken),
            ("client_id", Self.clientID),
            ("client_secret", Self.clientSecret)
        ]
        _ = try? await postForm(path: "oauth_revoke", fields: fields, usesDM: false)
    }

    func ownedStreamURLs(trackIDs: [Int], accessToken: String) async throws -> [Int: URL] {
        guard !trackIDs.isEmpty else { return [:] }
        let url = Self.baseURL.appendingPathComponent("api/mobile/26/collection_track_urls")
        var request = baseRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["track_ids": trackIDs])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw BandcampAuthError.serverMessage(Self.errorMessage(in: data) ?? "Could not load owned Bandcamp streams.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawInfos = object["track_url_infos"] as? [String: Any] else { return [:] }

        var urls: [Int: URL] = [:]
        for (rawID, value) in rawInfos {
            guard let id = Int(rawID), let info = value as? [String: Any] else { continue }
            let rawURL = info["hq_audio_url"] as? String ?? info["audio_url"] as? String
            if let rawURL, let url = URL(string: rawURL) { urls[id] = url }
        }
        return urls
    }

    func collectionPage(
        accessToken: String,
        offset: String? = nil,
        pageSize: Int = 100
    ) async throws -> BandcampCollectionPage {
        let url = Self.baseURL.appendingPathComponent("api/collectionsync/1/collection")
        var request = baseRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["page_size": pageSize]
        if let offset, !offset.isEmpty { body["offset"] = offset }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw BandcampAuthError.serverMessage(Self.errorMessage(in: data) ?? "Could not load your Bandcamp collection.")
        }
        return try Self.parseCollectionPage(data, pageSize: pageSize)
    }

    nonisolated static func parseCollectionPage(
        _ data: Data,
        pageSize: Int = 100
    ) throws -> BandcampCollectionPage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = object["items"] as? [[String: Any]] else {
            throw BandcampAuthError.invalidResponse
        }

        let items = rawItems.compactMap { raw -> BandcampResult? in
            guard let tralbumID = integer(raw["tralbum_id"]),
                  let bandID = integer(raw["band_id"]) else { return nil }
            let rawType = string(raw["tralbum_type"])?.lowercased() ?? ""
            let type = rawType == "album" ? "a" : rawType == "track" ? "t" : rawType
            guard type == "a" || type == "t" else { return nil }

            let bandInfo = raw["band_info"] as? [String: Any]
            let tracks = raw["tracks"] as? [[String: Any]]
            let title = firstString(raw, keys: ["title", "album_title", "name"]) ?? "Untitled"
            let artist = firstString(raw, keys: ["artist", "band_name"])
                ?? bandInfo.flatMap { firstString($0, keys: ["name", "band_name", "artist"]) }
                ?? tracks?.lazy.compactMap { firstString($0, keys: ["artist", "band_name"]) }.first
                ?? "Unknown Artist"
            let pageURL = resolvedURL(firstString(raw, keys: ["page_url", "url", "item_url"]))
                ?? collectionSearchURL(title: title, artist: artist)
            let artworkURL = integer(raw["art_id"])
                .flatMap { URL(string: "https://f4.bcbits.com/img/a\($0)_16.jpg") }

            return BandcampResult(
                id: "owned-\(type)-\(bandID)-\(tralbumID)",
                title: title,
                artist: artist,
                url: pageURL,
                type: type,
                bandID: bandID,
                tralbumID: tralbumID,
                artworkURL: artworkURL
            )
        }

        let explicitOffset = firstString(object, keys: ["next_offset", "next_page_token", "last_token"])
        let fallbackOffset = rawItems.count >= pageSize
            ? rawItems.last.flatMap { firstString($0, keys: ["token"]) }
            : nil
        return BandcampCollectionPage(items: items, nextOffset: explicitOffset ?? fallbackOffset)
    }

    private func tokenRequest(
        path: String,
        fields: [(String, String)],
        usesDM: Bool
    ) async throws -> BandcampOAuthSession {
        let (data, response) = try await postForm(path: path, fields: fields, usesDM: usesDM)
        guard (200..<300).contains(response.statusCode) else {
            let message = Self.errorMessage(in: data) ?? "Bandcamp login failed."
            if path == "oauth_login" {
                throw BandcampAuthError.loginRejected(message)
            }
            throw BandcampAuthError.serverMessage(message)
        }
        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard payload.tokenType.lowercased() == "bearer" else {
            throw BandcampAuthError.invalidResponse
        }
        return BandcampOAuthSession(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expirationDate: Date.now.addingTimeInterval(TimeInterval(payload.expiresIn))
        )
    }

    private func postForm(
        path: String,
        fields: [(String, String)],
        usesDM: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        let body = Self.formEncoded(fields)
        var dmHeader: String?
        for _ in 0..<4 {
            var request = baseRequest(url: Self.baseURL.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            if let dmHeader { request.setValue(dmHeader, forHTTPHeaderField: "X-Bandcamp-DM") }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw BandcampAuthError.invalidResponse
            }
            if usesDM, httpResponse.statusCode == 418,
               let challenge = httpResponse.value(forHTTPHeaderField: "X-Bandcamp-DM") {
                dmHeader = try Self.dmValue(challenge: challenge, body: body)
                continue
            }
            return (data, httpResponse)
        }
        throw BandcampAuthError.challengeFailed
    }

    private func baseRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.requestedWith, forHTTPHeaderField: "X-Requested-With")
        request.setValue("client_id=\(Self.clientID)", forHTTPHeaderField: "Cookie")
        return request
    }

    nonisolated static func dmValue(challenge: String, body: Data) throws -> String {
        let challengeBytes = Array(challenge.utf8)
        guard challengeBytes.count > 22,
              let last = challengeBytes.last,
              let index = hexDigit(last),
              challengeBytes.indices.contains(index),
              let type = hexDigit(challengeBytes[index]) else {
            throw BandcampAuthError.invalidChallenge
        }
        let nonce = Data(challengeBytes[..<19] + challengeBytes[22...])
        let message = nonce + body
        switch type {
        case 3:
            return hmacHex(SHA256.self, key: dmKeyU(challengeBytes), message: message)
        case 4:
            return hmacHex(SHA512.self, key: dmKeyF(challengeBytes), message: message)
        default:
            return hmacHex(Insecure.SHA1.self, key: Data("dtmfa".utf8), message: message)
        }
    }

    nonisolated static func formEncoded(_ fields: [(String, String)]) -> Data {
        let body = fields.map { "\(formComponent($0.0))=\(formComponent($0.1))" }.joined(separator: "&")
        return Data(body.utf8)
    }

    private nonisolated static func formComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+") ?? value
    }

    private nonisolated static func dmKeyU(_ challenge: [UInt8]) -> Data {
        let prefix = String("MF5yONmGN98zmdRZhbRDiwiTv52zJQCxGIdPhuGg9PQ5IzP3CKq6xFUdAluDOlY1".reversed())
        var value = prefix + "vqcGAbRi3vrBD6vbwQriX2PSs9iRfWpcG4kn9mlPbwQRjWVAtiwb5PMKNTcuuY92"
        let rounds = ((hexDigit(challenge.last ?? 48) ?? 0) * 3) % 4
        for _ in 0..<rounds {
            let midpoint = value.count / 2
            let first = String(value.prefix(midpoint).reversed())
            let second = String(value.suffix(value.count - midpoint).reversed()).uppercased()
            let digest = hmacHex(SHA256.self, key: Data((first + second).utf8), message: Data(value.utf8))
            value = digest
        }
        return Data(value.utf8)
    }

    private nonisolated static func dmKeyF(_ challenge: [UInt8]) -> Data {
        let prefix = String("F2klFqsVfSbKrZ3ph5IjMQ8r7qKku1ofc2Mzp39IIg0RP9R9SoZjlivPp7sCA5Q5".reversed())
        let value = prefix + "TNER82FIHkFGaajaReNDryho0gbiPyTFV9KsSt5OucVPGIYwZmYKQPzXTSWHSBf7"
        let index = min(hexDigit(challenge.last ?? 48) ?? 0, value.count)
        let rotated = String(value.dropFirst(index)) + String(value.prefix(index))
        let digest = hmacHex(SHA512.self, key: Data(rotated.utf8), message: Data(value.utf8))
        return Data(digest.utf8)
    }

    private nonisolated static func hmacHex<H: HashFunction>(
        _ hash: H.Type,
        key: Data,
        message: Data
    ) -> String {
        let code = HMAC<H>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(code).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func hexDigit(_ value: UInt8) -> Int? {
        switch value {
        case 48...57: Int(value - 48)
        case 65...70: Int(value - 55)
        case 97...102: Int(value - 87)
        default: nil
        }
    }

    private static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let validationMessages = (object["validation_errors"] as? [[String: Any]])?
            .compactMap { $0["message"] as? String }
            .joined(separator: ", ")
        return [
            object["error"] as? String,
            object["error_description"] as? String,
            object["error_message"] as? String,
            validationMessages
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ": ")
    }

    private nonisolated static func firstString(_ object: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { string(object[$0]) }.first { !$0.isEmpty }
    }

    private nonisolated static func string(_ value: Any?) -> String? {
        if let value = value as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private nonisolated static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private nonisolated static func resolvedURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("//") { return URL(string: "https:\(value)") }
        if let url = URL(string: value), url.scheme != nil { return url }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    private nonisolated static func collectionSearchURL(title: String, artist: String) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "q", value: "\(artist) \(title)")]
        return components?.url ?? baseURL
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let tokenType: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
        }
    }
}

enum BandcampAuthError: LocalizedError {
    case invalidChallenge
    case challengeFailed
    case invalidResponse
    case loginRejected(String)
    case serverMessage(String)

    var isLoginRejection: Bool {
        if case .loginRejected = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidChallenge: "Bandcamp returned an invalid login challenge."
        case .challengeFailed: "Bandcamp login challenge failed after several attempts."
        case .invalidResponse: "Bandcamp returned an invalid authentication response."
        case .loginRejected(let message): message
        case .serverMessage(let message): message
        }
    }
}
