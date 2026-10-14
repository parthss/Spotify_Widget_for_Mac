import AppKit
import SwiftUI

/// Behind the widget's + button: whether the current song is in Liked Songs, the
/// "Added to Liked Songs · Change" toast, and a cache of which playlists hold which songs.
@MainActor
final class LibraryController: ObservableObject {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let offersChange: Bool
    }

    @Published private(set) var isSaved = false
    @Published private(set) var toast: Toast?

    let account: SpotifyAccount
    /// Set by the app delegate: open the playlist picker, or toggle it open/closed.
    var openPickerHandler: (() -> Void)?
    var togglePickerHandler: (() -> Void)?

    private(set) var trackURI = ""
    private(set) var trackTitle = ""
    private var checkTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    /// Song URIs per playlist, valid while the playlist's snapshot ID is unchanged.
    private var playlistContents: [String: (snapshot: String, uris: Set<String>)] = [:]

    init(account: SpotifyAccount) {
        self.account = account
    }

    /// Only songs can go into Liked Songs (not podcast episodes, ads or local files).
    var canSave: Bool { SpotifyID.isTrackURI(trackURI) }

    func trackChanged(uri: String, title: String) {
        trackTitle = title
        guard uri != trackURI else { return }
        trackURI = uri
        isSaved = false
        refreshSavedState()
    }

    func refreshSavedState() {
        checkTask?.cancel()
        guard canSave, account.isConnected else {
            isSaved = false
            return
        }
        let uri = trackURI
        checkTask = Task {
            guard let saved = try? await self.account.isSaved(uri),
                  !Task.isCancelled, uri == self.trackURI else { return }
            self.isSaved = saved
        }
    }

    func setSaved(_ saved: Bool, for uri: String) {
        if uri == trackURI { isSaved = saved }
    }

    /// Spotify's behaviour: the first click saves to Liked Songs; clicking the green check
    /// opens the playlist picker. Before you've connected, it opens the connect screen.
    func plusTapped() {
        guard canSave else { return }
        guard account.isConnected, !isSaved else {
            dismissToast()
            togglePickerHandler?()
            return
        }
        let uri = trackURI
        isSaved = true
        showToast("Added to Liked Songs", offersChange: true)
        Task {
            do {
                try await self.account.save(uri)
            } catch {
                self.setSaved(false, for: uri)
                self.showToast(error.localizedDescription)
            }
        }
    }

    func openPicker() {
        dismissToast()
        openPickerHandler?()
    }

    func showToast(_ message: String, offersChange: Bool = false) {
        toastTask?.cancel()
        toast = Toast(message: message, offersChange: offersChange)
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return }
            self.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    // MARK: Playlist membership cache

    func knownMembership(of uri: String, in playlist: SpotifyPlaylist) -> Bool? {
        guard let entry = playlistContents[playlist.id], entry.snapshot == playlist.snapshotID else { return nil }
        return entry.uris.contains(uri)
    }

    func membership(of uri: String, in playlist: SpotifyPlaylist) async throws -> Bool {
        if let known = knownMembership(of: uri, in: playlist) { return known }
        let uris = try await account.playlistItemURIs(playlist.id, limit: PlaylistPickerModel.maxScannedItems)
        playlistContents[playlist.id] = (snapshot: playlist.snapshotID, uris: uris)
        return uris.contains(uri)
    }

    func recordChange(_ uri: String, playlistID: String, added: Bool, snapshot: String?) {
        guard var entry = playlistContents[playlistID] else { return }
        if added {
            entry.uris.insert(uri)
        } else {
            entry.uris.remove(uri)
        }
        if let snapshot { entry.snapshot = snapshot }
        playlistContents[playlistID] = entry
    }

    func recordNewPlaylist(_ playlist: SpotifyPlaylist) {
        playlistContents[playlist.id] = (snapshot: playlist.snapshotID, uris: [])
    }
}

/// State for one opening of the "Add to playlist" picker. Ticks are only applied when you
/// press Done, like in Spotify.
@MainActor
final class PlaylistPickerModel: ObservableObject {
    enum CheckState {
        case checked, unchecked, loading
    }

    /// Playlists longer than this aren't scanned for the song (their tick starts empty).
    static let maxScannedItems = 5000

    @Published var searchText = ""
    @Published var newPlaylistName = ""
    @Published var isNamingPlaylist = false
    @Published private(set) var playlists: [SpotifyPlaylist] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private var likedOriginal: Bool
    @Published private var likedDesired: Bool?
    @Published private var membership: [String: Bool] = [:]
    @Published private var desired: [String: Bool] = [:]
    @Published private var checking: Set<String> = []

    let trackURI: String
    let trackTitle: String
    private let account: SpotifyAccount
    private let library: LibraryController
    private let onClose: () -> Void

    init(account: SpotifyAccount, library: LibraryController, onClose: @escaping () -> Void) {
        self.account = account
        self.library = library
        self.onClose = onClose
        trackURI = library.trackURI
        trackTitle = library.trackTitle
        likedOriginal = library.isSaved
    }

    var canEdit: Bool { SpotifyID.isTrackURI(trackURI) }

    var likedState: CheckState { (likedDesired ?? likedOriginal) ? .checked : .unchecked }

    var showsLikedSongs: Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || "Liked Songs".localizedCaseInsensitiveContains(query)
    }

    var visiblePlaylists: [SpotifyPlaylist] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return playlists }
        return playlists.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func state(of playlist: SpotifyPlaylist) -> CheckState {
        if let want = desired[playlist.id] { return want ? .checked : .unchecked }
        if let have = membership[playlist.id] { return have ? .checked : .unchecked }
        return checking.contains(playlist.id) ? .loading : .unchecked
    }

    func toggleLiked() {
        likedDesired = !(likedDesired ?? likedOriginal)
    }

    func toggle(_ playlist: SpotifyPlaylist) {
        desired[playlist.id] = state(of: playlist) != .checked
    }

    func load() {
        guard account.isConnected, canEdit, playlists.isEmpty, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        let uri = trackURI
        Task {
            if let saved = try? await self.account.isSaved(uri) {
                self.likedOriginal = saved
                self.library.setSaved(saved, for: uri)
            }
            do {
                self.playlists = try await self.account.editablePlaylists()
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    /// Called as each playlist row appears, so only visible playlists are checked.
    func loadMembership(of playlist: SpotifyPlaylist) async {
        guard membership[playlist.id] == nil, !checking.contains(playlist.id) else { return }
        if playlist.itemCount == 0 {
            membership[playlist.id] = false
            return
        }
        if let known = library.knownMembership(of: trackURI, in: playlist) {
            membership[playlist.id] = known
            return
        }
        guard playlist.itemCount <= Self.maxScannedItems else { return }
        checking.insert(playlist.id)
        let contains = try? await library.membership(of: trackURI, in: playlist)
        checking.remove(playlist.id)
        if let contains { membership[playlist.id] = contains }
    }

    func createPlaylist() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let playlist = try await self.account.createPlaylist(named: name)
                self.library.recordNewPlaylist(playlist)
                self.playlists.insert(playlist, at: 0)
                self.membership[playlist.id] = false
                self.desired[playlist.id] = true
                self.newPlaylistName = ""
                self.isNamingPlaylist = false
                self.searchText = ""
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isWorking = false
        }
    }

    func cancel() {
        onClose()
    }

    func done() {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            let succeeded = await self.applyChanges()
            self.isWorking = false
            if succeeded { self.onClose() }
        }
    }

    private func applyChanges() async -> Bool {
        let uri = trackURI
        var added: [String] = []
        var removed: [String] = []
        var failed: [String] = []

        if let want = likedDesired, want != likedOriginal {
            do {
                if want {
                    try await account.save(uri)
                } else {
                    try await account.unsave(uri)
                }
                library.setSaved(want, for: uri)
                likedOriginal = want
                likedDesired = nil
                if want { added.append("Liked Songs") } else { removed.append("Liked Songs") }
            } catch {
                failed.append("Liked Songs")
            }
        }

        for playlist in playlists {
            guard let want = desired[playlist.id] else { continue }
            var have = membership[playlist.id]
            if have == nil && want {
                // Not checked yet: look before adding so the song isn't added twice.
                have = try? await library.membership(of: uri, in: playlist)
            }
            guard want != (have ?? false) else {
                desired[playlist.id] = nil
                continue
            }
            do {
                let snapshot: String?
                if want {
                    snapshot = try await account.add(uri, toPlaylist: playlist.id)
                } else {
                    snapshot = try await account.remove(uri, fromPlaylist: playlist.id)
                }
                library.recordChange(uri, playlistID: playlist.id, added: want, snapshot: snapshot)
                membership[playlist.id] = want
                desired[playlist.id] = nil
                if want { added.append(playlist.name) } else { removed.append(playlist.name) }
            } catch {
                failed.append(playlist.name)
            }
        }

        if !failed.isEmpty {
            errorMessage = "Couldn't update \(failed.joined(separator: ", ")). Try again."
            return false
        }
        if let message = Self.summary(added: added, removed: removed) {
            library.showToast(message)
        }
        return true
    }

    private static func summary(added: [String], removed: [String]) -> String? {
        switch (added.count, removed.count) {
        case (0, 0): return nil
        case (1, 0): return "Added to \(added[0])"
        case (0, 1): return "Removed from \(removed[0])"
        case (_, 0): return "Added to \(added.count) playlists"
        case (0, _): return "Removed from \(removed.count) playlists"
        default: return "Updated \(added.count + removed.count) playlists"
        }
    }
}
