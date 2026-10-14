import AppKit
import CryptoKit
import Foundation
import Network
import Security

// Saving songs and editing playlists isn't possible through Spotify's Mac scripting, so it
// goes through the Spotify Web API (Feb 2026 endpoints: /me/library and /playlists/{id}/items).
// See SECURITY.md for how sign-in, tokens and network access are protected.

// MARK: - Models

struct SpotifyPlaylist: Identifiable, Equatable {
    let id: String
    let name: String
    let imageURL: URL?
    let snapshotID: String
    let itemCount: Int
}

enum SpotifyAPIError: LocalizedError {
    case notConnected
    case sessionExpired
    case keychainUnavailable
    case oauth(code: String, description: String)
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Connect your Spotify account first."
        case .sessionExpired:
            return "Your Spotify sign-in has expired. Right-click the widget to connect again."
        case .keychainUnavailable:
            return "Couldn't use your keychain for the Spotify sign-in (it may be locked, or access was denied)."
        case .oauth(let code, let description):
            return description.isEmpty ? "Spotify sign-in failed (\(code))." : description
        case .http(_, let message):
            return message
        }
    }
}

// MARK: - Account

/// Signs in to the Spotify Web API with the authorization-code + PKCE flow (no client
/// secret needed), keeps the access token fresh, and makes the library and playlist calls.
@MainActor
final class SpotifyAccount: ObservableObject {
    enum Status: Equatable {
        case signedOut
        case signingIn
        case connected(name: String)
    }

    static let redirectURI = "http://127.0.0.1:\(OAuthCallbackServer.port)/callback"
    /// Only what the ＋ button needs: Liked Songs and your playlists. No access to your
    /// email, payment details, account settings, listening history or playback.
    private static let scopes = "user-library-read user-library-modify playlist-read-private playlist-read-collaborative playlist-modify-private playlist-modify-public"

    @Published private(set) var status: Status = .signedOut
    @Published private(set) var signInError: String?
    @Published var clientID: String

    private var userID: String?
    private var accessToken: String?            // memory only, never written anywhere
    private var accessTokenExpiry = Date.distantPast
    private var refreshTask: Task<String, Error>?
    private var pendingSignIn: (state: String, verifier: String)?
    private var signInTimeout: Task<Void, Never>?
    /// Bumped on every sign-in attempt, cancel and sign-out. Work that began under an older
    /// value (a late token response, a stale listener event) is thrown away, not applied.
    private var generation = 0
    private let callbackServer = OAuthCallbackServer()
    /// No disk cache and no cookies: nothing from Spotify's API is written to disk.
    private let urlSession = URLSession(configuration: .ephemeral)

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    var displayName: String? {
        if case .connected(let name) = status { return name }
        return nil
    }

    init() {
        let defaults = UserDefaults.standard
        clientID = defaults.string(forKey: Prefs.spotifyClientID) ?? ""
        userID = defaults.string(forKey: Prefs.spotifyUserID)
        if defaults.bool(forKey: Prefs.spotifyConnected) {
            status = .connected(name: defaults.string(forKey: Prefs.spotifyDisplayName) ?? "Spotify")
        }
    }

    // MARK: Sign in / out

    func signIn() {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            signInError = "Paste your app's Client ID first."
            return
        }
        guard SpotifyID.isValid(id) else {
            signInError = "That doesn't look like a Client ID. Copy it from your app's Settings page."
            return
        }
        clientID = id
        UserDefaults.standard.set(id, forKey: Prefs.spotifyClientID)
        signInError = nil

        cancelSignIn() // stop any earlier attempt; this also bumps `generation`
        let attempt = generation

        // PKCE: the code Spotify sends back is useless without this verifier, which never
        // leaves the app. `state` ties Spotify's reply to this attempt.
        let verifier = PKCE.randomString(length: 64)
        let state = PKCE.randomString(length: 32)

        var components = URLComponents()
        components.scheme = "https"
        components.host = "accounts.spotify.com"
        components.path = "/authorize"
        components.percentEncodedQuery = Self.formEncode([
            ("client_id", id),
            ("response_type", "code"),
            ("redirect_uri", Self.redirectURI),
            ("code_challenge_method", "S256"),
            ("code_challenge", PKCE.challenge(for: verifier)),
            ("scope", Self.scopes),
            ("state", state),
        ])
        guard let url = components.url else {
            signInError = "Couldn't build the Spotify sign-in link."
            return
        }

        pendingSignIn = (state: state, verifier: verifier)
        status = .signingIn
        do {
            try callbackServer.start(
                expectedState: state,
                onReady: { [weak self] in
                    Task { @MainActor [weak self] in self?.openBrowser(url, attempt: attempt) }
                },
                onCallback: { [weak self] components in
                    Task { @MainActor [weak self] in self?.finishSignIn(components, attempt: attempt) }
                },
                onFailure: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.failSignIn("Couldn't start the local sign-in listener (\(message)). Nothing was sent to Spotify.",
                                         attempt: attempt)
                    }
                }
            )
        } catch {
            failSignIn("Couldn't start the local sign-in listener (\(error.localizedDescription)).", attempt: attempt)
            return
        }

        // Never leave the listener waiting: give up after five minutes.
        signInTimeout = Task {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard !Task.isCancelled, attempt == self.generation else { return }
            if self.status == .signingIn {
                self.failSignIn("Sign-in timed out after 5 minutes. Click Connect to try again.", attempt: attempt)
            } else {
                self.callbackServer.stop()
            }
        }
    }

    func cancelSignIn() {
        generation += 1
        callbackServer.stop()
        signInTimeout?.cancel()
        signInTimeout = nil
        pendingSignIn = nil
        if status == .signingIn { status = .signedOut }
    }

    /// Removes the sign-in from this Mac. To revoke Glass Player's access on Spotify's side
    /// too, remove it at spotify.com/account/apps (see SECURITY.md).
    func signOut() {
        cancelSignIn() // also bumps `generation`, so in-flight token work is discarded
        refreshTask?.cancel()
        refreshTask = nil
        accessToken = nil
        accessTokenExpiry = .distantPast
        userID = nil
        Task.detached(priority: .userInitiated) { Keychain.delete(Keychain.refreshToken) }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Prefs.spotifyConnected)
        defaults.removeObject(forKey: Prefs.spotifyUserID)
        defaults.removeObject(forKey: Prefs.spotifyDisplayName)
        status = .signedOut
    }

    /// Opens Spotify's consent page only once the listener really holds 127.0.0.1:45893, so
    /// Spotify's reply can't go to another program that grabbed the port first.
    private func openBrowser(_ url: URL, attempt: Int) {
        guard attempt == generation, status == .signingIn else { return }
        _ = NSWorkspace.shared.open(url)
    }

    private func finishSignIn(_ components: URLComponents, attempt: Int) {
        guard attempt == generation, let pending = pendingSignIn else { return }
        let items = components.queryItems ?? []
        let value: (String) -> String? = { name in items.first { $0.name == name }?.value }

        // The callback server already refuses replies without this attempt's state. Check
        // again, and ignore (rather than act on) anything else, so no other app or web page
        // can complete, hijack or cancel your sign-in.
        guard value("state") == pending.state else { return }
        callbackServer.stop()
        signInTimeout?.cancel()
        signInTimeout = nil
        pendingSignIn = nil

        if let error = value("error") {
            failSignIn(error == "access_denied" ? "Access wasn't allowed in Spotify." : "Spotify sign-in failed.",
                       attempt: attempt)
            return
        }
        guard let code = value("code"), !code.isEmpty, code.count <= 2048 else {
            failSignIn("Spotify didn't send a valid sign-in code. Please try again.", attempt: attempt)
            return
        }

        Task {
            do {
                try await self.requestToken([
                    ("grant_type", "authorization_code"),
                    ("code", code),
                    ("redirect_uri", Self.redirectURI),
                    ("client_id", self.clientID),
                    ("code_verifier", pending.verifier),
                ], generation: attempt)
                let profile = try await self.fetchProfile()
                guard attempt == self.generation else { return }
                let name = String((profile.display_name ?? "Spotify").prefix(80))
                let defaults = UserDefaults.standard
                defaults.set(true, forKey: Prefs.spotifyConnected)
                defaults.set(profile.id, forKey: Prefs.spotifyUserID)
                defaults.set(name, forKey: Prefs.spotifyDisplayName)
                self.userID = profile.id
                self.signInError = nil
                self.status = .connected(name: name)
            } catch {
                self.failSignIn(error.localizedDescription, attempt: attempt)
            }
        }
    }

    private func failSignIn(_ message: String, attempt: Int) {
        guard attempt == generation else { return } // a newer attempt is in charge
        callbackServer.stop()
        signInTimeout?.cancel()
        signInTimeout = nil
        pendingSignIn = nil
        signInError = message
        if !isConnected { status = .signedOut }
    }

    // MARK: Tokens

    /// Exchanges a code or refresh token at Spotify's token endpoint. `generation` is the
    /// value the request belongs to: if it changes before Spotify answers (you cancelled or
    /// disconnected), the answer is thrown away and nothing is stored.
    @discardableResult
    private func requestToken(_ form: [(String, String)], generation: Int) async throws -> String {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else {
            throw SpotifyAPIError.notConnected
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(form).utf8)

        let (data, response) = try await urlSession.data(for: request)
        guard generation == self.generation else { throw CancellationError() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data)
            throw SpotifyAPIError.oauth(code: String((detail?.error ?? "\(status)").prefix(64)),
                                        description: String((detail?.error_description ?? "").prefix(200)))
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)

        // Spotify may or may not send a new refresh token; keep the old one if it doesn't.
        if let refresh = token.refresh_token {
            let saved = await Task.detached(priority: .userInitiated) {
                Keychain.write(refresh, account: Keychain.refreshToken)
            }.value
            guard generation == self.generation else {
                // Disconnected while saving: don't leave the token behind.
                await Task.detached(priority: .userInitiated) { Keychain.delete(Keychain.refreshToken) }.value
                throw CancellationError()
            }
            if !saved { throw SpotifyAPIError.keychainUnavailable }
        }
        accessToken = token.access_token
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(min(max(token.expires_in - 60, 30), 3600)))
        return token.access_token
    }

    private func accessTokenValue() async throws -> String {
        if let token = accessToken, Date() < accessTokenExpiry { return token }
        if let task = refreshTask { return try await task.value }
        let clientID = self.clientID
        let generation = self.generation
        let task = Task<String, Error> {
            // Reading the keychain can show a macOS prompt, so it runs off the main thread.
            let stored = await Task.detached(priority: .userInitiated) {
                Keychain.read(Keychain.refreshToken)
            }.value
            switch stored {
            case .found(let refresh):
                return try await self.requestToken([
                    ("grant_type", "refresh_token"),
                    ("refresh_token", refresh),
                    ("client_id", clientID),
                ], generation: generation)
            case .notFound:
                throw SpotifyAPIError.notConnected
            case .failed:
                throw SpotifyAPIError.keychainUnavailable
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch SpotifyAPIError.notConnected {
            if isConnected { signOut() }
            throw SpotifyAPIError.notConnected
        } catch SpotifyAPIError.oauth(let code, _) where code == "invalid_grant" {
            // Refresh tokens expire (currently six months after you first connect).
            signOut()
            throw SpotifyAPIError.sessionExpired
        }
    }

    // MARK: Requests

    func call(_ method: String, _ path: String,
              query: [(String, String)] = [], json: Any? = nil) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.spotify.com"
        components.path = "/v1" + path
        if !query.isEmpty { components.percentEncodedQuery = Self.formEncode(query) }
        guard let url = components.url else {
            throw SpotifyAPIError.http(status: 0, message: "Couldn't build the request.")
        }
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await send(method, url: url, body: body, attemptsLeft: 2)
    }

    private func send(_ method: String, url: URL, body: Data?, attemptsLeft: Int) async throws -> Data {
        let token = try await accessTokenValue()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await urlSession.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if (200..<300).contains(status) { return data }

        if attemptsLeft > 0 {
            if status == 401 {
                accessToken = nil // expired early: refresh and try once more
                return try await send(method, url: url, body: body, attemptsLeft: attemptsLeft - 1)
            }
            if status == 429 {
                let requested = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
                let wait = requested.isFinite ? min(max(requested, 1), 10) : 2
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                return try await send(method, url: url, body: body, attemptsLeft: attemptsLeft - 1)
            }
        }
        throw SpotifyAPIError.http(status: status, message: Self.message(from: data, status: status))
    }

    private func fetchProfile() async throws -> ProfileResponse {
        let data = try await call("GET", "/me")
        return try JSONDecoder().decode(ProfileResponse.self, from: data)
    }

    private static func message(from data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let text = error["message"] as? String, !text.isEmpty {
            return "Spotify: \(text.prefix(200))"
        }
        if status == 403 {
            return "Spotify refused the request. In your Spotify app's settings, check that your account is listed under User Management."
        }
        return "Spotify returned an error (\(status))."
    }

    static func formEncode(_ pairs: [(String, String)]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return pairs.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)"
        }.joined(separator: "&")
    }
}

// MARK: - Library and playlists

extension SpotifyAccount {
    /// Whether a song is in Liked Songs.
    func isSaved(_ uri: String) async throws -> Bool {
        try Self.checkTrack(uri)
        let data = try await call("GET", "/me/library/contains", query: [("uris", uri)])
        let flags = try JSONDecoder().decode([Bool].self, from: data)
        return flags.first ?? false
    }

    func save(_ uri: String) async throws {
        try Self.checkTrack(uri)
        _ = try await call("PUT", "/me/library", query: [("uris", uri)])
    }

    func unsave(_ uri: String) async throws {
        try Self.checkTrack(uri)
        _ = try await call("DELETE", "/me/library", query: [("uris", uri)])
    }

    /// Your playlists that you can add songs to: ones you own or collaborate on.
    func editablePlaylists() async throws -> [SpotifyPlaylist] {
        let me: String
        if let userID {
            me = userID
        } else {
            me = try await fetchProfile().id
        }
        var playlists: [SpotifyPlaylist] = []
        var offset = 0
        while offset < 1000 {
            let data = try await call("GET", "/me/playlists",
                                      query: [("limit", "50"), ("offset", String(offset))])
            let page = try JSONDecoder().decode(PlaylistPage.self, from: data)
            for dto in page.items where SpotifyID.isValid(dto.id)
                && (dto.owner?.id == me || dto.collaborative == true) {
                playlists.append(SpotifyPlaylist(dto))
            }
            if page.next == nil || page.items.isEmpty { break }
            offset += 50
        }
        return playlists
    }

    /// Every song URI in a playlist (up to `limit` entries).
    func playlistItemURIs(_ playlistID: String, limit: Int) async throws -> Set<String> {
        try Self.checkPlaylist(playlistID)
        var uris = Set<String>()
        var offset = 0
        while offset < limit {
            let data = try await call("GET", "/playlists/\(playlistID)/items",
                                      query: [("limit", "50"), ("offset", String(offset))])
            let page = try JSONDecoder().decode(PlaylistItemsPage.self, from: data)
            for entry in page.items {
                if let uri = entry?.uri { uris.insert(uri) }
            }
            if page.next == nil || page.items.isEmpty { break }
            offset += 50
        }
        return uris
    }

    /// Returns the playlist's new snapshot ID.
    func add(_ uri: String, toPlaylist playlistID: String) async throws -> String? {
        try Self.checkTrack(uri)
        try Self.checkPlaylist(playlistID)
        let data = try await call("POST", "/playlists/\(playlistID)/items", json: ["uris": [uri]])
        return (try? JSONDecoder().decode(SnapshotResponse.self, from: data))?.snapshot_id
    }

    /// Returns the playlist's new snapshot ID.
    func remove(_ uri: String, fromPlaylist playlistID: String) async throws -> String? {
        try Self.checkTrack(uri)
        try Self.checkPlaylist(playlistID)
        let data = try await call("DELETE", "/playlists/\(playlistID)/items", json: ["items": [["uri": uri]]])
        return (try? JSONDecoder().decode(SnapshotResponse.self, from: data))?.snapshot_id
    }

    func createPlaylist(named name: String) async throws -> SpotifyPlaylist {
        let body: [String: Any] = ["name": String(name.prefix(100)), "public": false]
        let data = try await call("POST", "/me/playlists", json: body)
        let dto = try JSONDecoder().decode(PlaylistDTO.self, from: data)
        try Self.checkPlaylist(dto.id)
        return SpotifyPlaylist(dto)
    }

    private static func checkTrack(_ uri: String) throws {
        guard SpotifyID.isTrackURI(uri) else {
            throw SpotifyAPIError.http(status: 0, message: "That isn't a Spotify song.")
        }
    }

    private static func checkPlaylist(_ id: String) throws {
        guard SpotifyID.isValid(id) else {
            throw SpotifyAPIError.http(status: 0, message: "Spotify sent an unexpected playlist ID.")
        }
    }
}

// MARK: - Response shapes

private struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
}

private struct OAuthErrorResponse: Decodable {
    let error: String?
    let error_description: String?
}

private struct ProfileResponse: Decodable {
    let id: String
    let display_name: String?
}

private struct SnapshotResponse: Decodable {
    let snapshot_id: String?
}

private struct PlaylistDTO: Decodable {
    struct Owner: Decodable { let id: String? }
    struct ImageRef: Decodable { let url: String? }
    struct Count: Decodable { let total: Int? }

    let id: String
    let name: String?
    let images: [ImageRef]?
    let owner: Owner?
    let collaborative: Bool?
    let snapshot_id: String?
    let items: Count?   // song count (current field)
    let tracks: Count?  // song count (deprecated field)
}

/// Skips any playlist entry that doesn't decode instead of failing the whole page.
private struct PlaylistPage: Decodable {
    let items: [PlaylistDTO]
    let next: String?

    private enum CodingKeys: String, CodingKey { case items, next }

    private struct Lossy: Decodable {
        let value: PlaylistDTO?
        init(from decoder: Decoder) throws {
            value = try? PlaylistDTO(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lossy = try container.decodeIfPresent([Lossy].self, forKey: .items) ?? []
        items = lossy.compactMap { $0.value }
        next = try container.decodeIfPresent(String.self, forKey: .next)
    }
}

private struct PlaylistItemsPage: Decodable {
    /// One playlist entry. The song is under `item` (current) or `track` (deprecated).
    struct Entry: Decodable {
        let uri: String?

        private enum CodingKeys: String, CodingKey { case item, track }
        private struct Ref: Decodable { let uri: String? }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let item = try? container.decodeIfPresent(Ref.self, forKey: .item)
            let track = try? container.decodeIfPresent(Ref.self, forKey: .track)
            uri = item?.uri ?? track?.uri
        }
    }

    let items: [Entry?]
    let next: String?
}

private extension SpotifyPlaylist {
    init(_ dto: PlaylistDTO) {
        // Images come largest first; the middle one (~300 px) suits a small thumbnail.
        let images = dto.images ?? []
        let imageURL = images.isEmpty ? nil : images[images.count / 2].url.flatMap { URL(string: $0) }
        self.init(id: dto.id,
                  name: String((dto.name ?? "Untitled").prefix(200)),
                  imageURL: TrustedImageURL.filter(imageURL),
                  snapshotID: dto.snapshot_id ?? "",
                  itemCount: max(dto.items?.total ?? dto.tracks?.total ?? 0, 0))
    }
}

// MARK: - Sign-in helpers

enum PKCE {
    private static let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    /// Cryptographically secure (SystemRandomNumberGenerator uses the OS's CSPRNG).
    static func randomString(length: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in characters.randomElement(using: &generator) ?? "a" })
    }

    /// base64url(SHA-256(verifier)) without padding.
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The refresh token lives in your login keychain, in an item Glass Player creates itself.
enum Keychain {
    enum ReadResult {
        case found(String)
        case notFound
        case failed(OSStatus)
    }

    static let refreshToken = "spotify-refresh-token"
    private static let service = "local.glassplayer"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(_ account: String) -> ReadResult {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                return .failed(errSecDecode)
            }
            return .found(value)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(status) // locked keychain, denied prompt…: not the same as "signed out"
        }
    }

    /// Replaces the item instead of updating it in place, so the token always goes into a
    /// fresh item created by Glass Player (whose access list trusts only Glass Player), never
    /// into an item some other program might have planted with a looser access list.
    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        _ = SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        // Shows up under this name in Keychain Access, so you can see (or delete) it.
        item[kSecAttrLabel as String] = "Glass Player – Spotify sign-in"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        _ = SecItemDelete(query(account) as CFDictionary)
    }
}

/// A tiny web server that waits for Spotify to send your browser back after you approve
/// access. It runs only while you're connecting (five minutes at most), listens on 127.0.0.1
/// through the loopback interface, drops any connection that isn't from this Mac, and
/// accepts exactly one reply: the one carrying this sign-in's secret `state`.
final class OAuthCallbackServer: @unchecked Sendable {
    static let port: UInt16 = 45893
    private static let maxConnections = 16

    private let queue = DispatchQueue(label: "glassplayer.oauth-callback")
    // Only touched on `queue`.
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var expectedState = ""
    private var onCallback: (@Sendable (URLComponents) -> Void)?

    func start(expectedState: String,
               onReady: @escaping @Sendable () -> Void,
               onCallback: @escaping @Sendable (URLComponents) -> Void,
               onFailure: @escaping @Sendable (String) -> Void) throws {
        stop()
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let parameters = NWParameters.tcp
        // Bind to 127.0.0.1 on the loopback interface only: nothing on your network or the
        // internet can reach this port. No address reuse, so nothing can share the port.
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                // Only go ahead if we really hold the expected port.
                if listener?.port?.rawValue == OAuthCallbackServer.port {
                    onReady()
                } else {
                    listener?.cancel()
                    onFailure("port \(OAuthCallbackServer.port) isn't available")
                }
            case .waiting(let error), .failed(let error):
                listener?.cancel()
                onFailure(error.localizedDescription)
            default:
                break
            }
        }
        queue.sync {
            self.expectedState = expectedState
            self.onCallback = onCallback
            self.listener = listener
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            onCallback = nil
            expectedState = ""
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    // Runs on `queue`.
    private func accept(_ connection: NWConnection) {
        // Second line of defence after the loopback binding: only this Mac may connect.
        guard Self.isLoopback(connection.endpoint), connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections[id] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Drop connections that don't send a request promptly.
        queue.asyncAfter(deadline: .now() + 10) { [weak connection] in connection?.cancel() }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            self?.respond(to: data, on: connection)
        }
    }

    // Runs on `queue`.
    private func respond(to data: Data?, on connection: NWConnection) {
        let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let requestLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.components(separatedBy: " ")
        let target = parts.count > 1 ? parts[1] : ""
        let components = target.hasPrefix("/") ? URLComponents(string: "http://127.0.0.1" + target) : nil
        let isCallback = parts.first == "GET" && components?.path == "/callback"
        let state = components?.queryItems?.first { $0.name == "state" }?.value ?? ""
        let isValid = isCallback && !expectedState.isEmpty && Self.constantTimeEquals(state, expectedState)

        let status: String
        let body: String
        if isValid {
            status = "200 OK"
            body = Self.page(title: "All set", message: "You can close this tab and go back to Glass Player.")
        } else if isCallback {
            status = "400 Bad Request"
            body = Self.page(title: "Link not valid", message: "This link doesn't belong to the current Glass Player sign-in.")
        } else {
            status = "404 Not Found"
            body = Self.page(title: "Not found", message: "")
        }
        // Nothing from the request is echoed back, and the page can't load or run anything.
        let head = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.utf8.count)",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'",
            "X-Content-Type-Options: nosniff",
            "Referrer-Policy: no-referrer",
            "Cache-Control: no-store",
            "Connection: close",
        ].joined(separator: "\r\n")
        connection.send(content: Data((head + "\r\n\r\n" + body).utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })

        if isValid, let components, let callback = onCallback {
            onCallback = nil // accept exactly one sign-in reply
            callback(components)
        }
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.isLoopback
        case .ipv6(let address):
            return address.isLoopback || (address.asIPv4?.isLoopback ?? false)
        default:
            return false
        }
    }

    /// Compares without leaking, through timing, how much of the secret matched.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in x.indices { difference |= x[index] ^ y[index] }
        return difference == 0
    }

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Glass Player</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;display:grid;place-items:center;
        height:100vh;margin:0;background:#121212;color:#fff}p{color:#b3b3b3}</style></head>
        <body><div><h2>\(title)</h2><p>\(message)</p></div></body></html>
        """
    }
}
