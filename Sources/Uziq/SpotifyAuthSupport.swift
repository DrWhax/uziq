import Combine
import Foundation
import Network
import Security
import SpotifyWebAPI

typealias UziqSpotifyAuthorizationManager =
    AuthorizationCodeFlowPKCEBackendManager<UziqSpotifyPKCEBackend>

struct UziqSpotifyPKCEBackend: AuthorizationCodeFlowPKCEBackend {
    let clientId: String

    private enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
    }

    func requestAccessAndRefreshTokens(
        code: String,
        codeVerifier: String,
        redirectURIWithQuery: URL
    ) -> AnyPublisher<(data: Data, response: HTTPURLResponse), Error> {
        standardBackend.requestAccessAndRefreshTokens(
            code: code,
            codeVerifier: codeVerifier,
            redirectURIWithQuery: redirectURIWithQuery
        )
    }

    func refreshTokens(
        refreshToken: String
    ) -> AnyPublisher<(data: Data, response: HTTPURLResponse), Error> {
        standardBackend.refreshTokens(refreshToken: refreshToken)
            .map { output in
                guard (200..<300).contains(output.response.statusCode) else { return output }
                return (
                    data: Self.retainingRefreshToken(in: output.data, fallback: refreshToken),
                    response: output.response
                )
            }
            .eraseToAnyPublisher()
    }

    nonisolated static func retainingRefreshToken(in data: Data, fallback: String) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["refresh_token"] == nil else { return data }
        object["refresh_token"] = fallback
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }

    private var standardBackend: AuthorizationCodeFlowPKCEClientBackend {
        AuthorizationCodeFlowPKCEClientBackend(clientId: clientId)
    }
}

extension AuthorizationCodeFlowPKCEBackendManager where Backend == UziqSpotifyPKCEBackend {
    var clientId: String { backend.clientId }
}

enum SpotifyKeychain {
    private static let service = "app.uziq.spotify"

    static func read(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data, account: String) {
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

    static func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class SpotifyLoopbackServer: @unchecked Sendable {
    static let port: UInt16 = 8_989
    static let callbackURL = URL(string: "http://127.0.0.1:\(port)/callback")!

    private let queue = DispatchQueue(label: "app.uziq.spotify-oauth")
    private var listener: NWListener?

    func start(
        onReady: @escaping @Sendable () -> Void,
        onCallback: @escaping @Sendable (URL) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws {
        stop()
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                onReady()
            case .failed(let error):
                self?.stop()
                onError(error)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                if let error {
                    onError(error)
                    connection.cancel()
                    return
                }
                guard let data,
                      let request = String(data: data, encoding: .utf8),
                      let requestLine = request.components(separatedBy: "\r\n").first,
                      requestLine.hasPrefix("GET "),
                      let target = requestLine.split(separator: " ").dropFirst().first,
                      let callbackURL = URL(string: "http://127.0.0.1:\(Self.port)\(target)") else {
                    connection.cancel()
                    return
                }

                let body = "<html><body style='font-family:system-ui;text-align:center;padding:4rem'><h2>Spotify connected</h2><p>You can close this tab and return to Uziq.</p></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                self?.stop()
                onCallback(callbackURL)
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    deinit { stop() }
}
