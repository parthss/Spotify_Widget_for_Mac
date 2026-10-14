import AppKit
import SwiftUI

enum PickerMetrics {
    static let size = CGSize(width: 320, height: 450)
    static let cornerRadius: CGFloat = 22
}

// MARK: - Window

/// A floating, popover-like panel, used by the playlist picker and the Glass panel. It can
/// take keyboard focus (to search or name a playlist) without bringing Glass Player to the
/// front, and it's always dark, like Spotify.
final class PickerPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(size: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // see DesktopPanel: a window shadow would have square corners
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Esc closes the panel.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Beside the widget like a submenu (right first, then left, then below), on screen.
    static func origin(near anchor: NSRect, size: CGSize) -> NSPoint {
        let gap: CGFloat = 10
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var frame = NSRect(x: anchor.maxX + gap, y: anchor.maxY - size.height,
                           width: size.width, height: size.height)
        if frame.maxX > visible.maxX {
            frame.origin.x = anchor.minX - gap - size.width
        }
        if frame.minX < visible.minX {
            frame.origin.x = anchor.maxX - size.width
            frame.origin.y = anchor.minY - gap - size.height
        }
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        return frame.origin
    }
}

@MainActor
final class PlaylistPickerController: NSObject, NSWindowDelegate {
    private let account: SpotifyAccount
    private let library: LibraryController
    private var panel: PickerPanel?

    init(account: SpotifyAccount, library: LibraryController) {
        self.account = account
        self.library = library
        super.init()
    }

    func toggle(near anchor: NSRect) {
        if panel != nil {
            close()
        } else {
            open(near: anchor)
        }
    }

    func open(near anchor: NSRect) {
        close()
        let model = PlaylistPickerModel(account: account, library: library) { [weak self] in
            self?.close()
        }
        let panel = PickerPanel(size: PickerMetrics.size)
        panel.onCancel = { [weak self] in self?.close() }
        let host = FirstMouseHostingView(rootView: PlaylistPickerView(model: model, account: account))
        host.frame = NSRect(origin: .zero, size: PickerMetrics.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.delegate = self
        panel.setFrameOrigin(PickerPanel.origin(near: anchor, size: PickerMetrics.size))
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.orderOut(nil)
        // Closing mid-sign-in also shuts the local sign-in listener.
        if account.status == .signingIn { account.cancelSignIn() }
    }

    // Clicking anywhere else closes the picker, like a popover. While you're approving
    // access in the browser it stays open, so you can see when Spotify connects.
    func windowDidResignKey(_ notification: Notification) {
        guard account.status != .signingIn else { return }
        close()
    }
}

// MARK: - Picker

@MainActor
struct PlaylistPickerView: View {
    @ObservedObject var model: PlaylistPickerModel
    @ObservedObject var account: SpotifyAccount

    var body: some View {
        ZStack {
            if account.isConnected {
                picker
            } else {
                ConnectSpotifyView(account: account, onCancel: { model.cancel() })
            }
        }
        .frame(width: PickerMetrics.size.width, height: PickerMetrics.size.height)
        .modifier(GlassBackground(tint: Color.black.opacity(0.35),
                                  cornerRadius: PickerMetrics.cornerRadius))
        .onChange(of: account.isConnected, initial: true) { _, connected in
            if connected { model.load() }
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add to playlist")
                    .font(.system(size: 15, weight: .bold))
                Text(model.canEdit ? model.trackTitle : "Play a song to add it to a playlist")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if model.canEdit {
                searchField
                newPlaylistRow
                Divider()
                list
            } else {
                Spacer()
            }
            footer
        }
        .padding(16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Find a playlist", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var newPlaylistRow: some View {
        if model.isNamingPlaylist {
            HStack(spacing: 10) {
                TextField("Playlist name", text: $model.newPlaylistName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onSubmit { model.createPlaylist() }
                Button("Create") { model.createPlaylist() }
                    .buttonStyle(PressableButtonStyle())
                    .font(.system(size: 13, weight: .bold))
                    .disabled(model.newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty || model.isWorking)
            }
        } else {
            Button {
                model.isNamingPlaylist = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 40, height: 28)
                    Text("New playlist")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if model.showsLikedSongs {
                    PickerRow(title: "Liked Songs", subtitle: "Playlist",
                              artwork: .liked, state: model.likedState) {
                        model.toggleLiked()
                    }
                }
                ForEach(model.visiblePlaylists) { playlist in
                    PickerRow(title: playlist.name,
                              subtitle: Self.songCount(playlist.itemCount),
                              artwork: .url(playlist.imageURL),
                              state: model.state(of: playlist)) {
                        model.toggle(playlist)
                    }
                    .task(id: playlist.id) {
                        await model.loadMembership(of: playlist)
                    }
                }
                if model.isLoading {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.errorMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .buttonStyle(PressableButtonStyle())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Button {
                    model.done()
                } label: {
                    ZStack {
                        if model.isWorking {
                            ProgressView()
                                .controlSize(.small)
                                .environment(\.colorScheme, .light)
                        } else {
                            Text("Done")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.black)
                        }
                    }
                    .frame(width: 72, height: 30)
                    .background(Color.white, in: Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(model.isWorking || !model.canEdit)
            }
        }
    }

    private static func songCount(_ count: Int) -> String {
        count == 1 ? "1 song" : "\(count) songs"
    }
}

/// One line in the picker: cover, name, and Spotify's round check.
struct PickerRow: View {
    enum Artwork {
        case liked
        case url(URL?)
    }

    let title: String
    let subtitle: String
    let artwork: Artwork
    let state: PlaylistPickerModel.CheckState
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 10) {
                thumbnail
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                checkmark
                    .frame(width: 22, height: 22)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch artwork {
        case .liked:
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "heart.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.spotifyGreen)
            }
        case .url(let url):
            RemoteThumbnail(url: url)
        }
    }

    @ViewBuilder
    private var checkmark: some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small)
        case .checked:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.black, Palette.spotifyGreen)
        case .unchecked:
            Image(systemName: "circle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Connect

/// One-time setup: create a Spotify developer app, paste its Client ID, approve in the browser.
@MainActor
struct ConnectSpotifyView: View {
    @ObservedObject var account: SpotifyAccount
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect Spotify")
                    .font(.system(size: 15, weight: .bold))
                Text("Saving songs goes through Spotify's Web API. Set it up once (needs Premium):")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            step(1, "Open the dashboard and click Create app.") {
                Button("Open Spotify Developer Dashboard") {
                    if let url = URL(string: "https://developer.spotify.com/dashboard") {
                        _ = NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.spotifyGreen)
            }

            step(2, "Add this Redirect URI, tick Web API, then Save.") {
                HStack(spacing: 8) {
                    Text(SpotifyAccount.redirectURI)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Copy") {
                        _ = NSPasteboard.general.clearContents()
                        _ = NSPasteboard.general.setString(SpotifyAccount.redirectURI, forType: .string)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .font(.system(size: 11, weight: .bold))
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            step(3, "Paste your app's Client ID.") {
                TextField("Client ID", text: $account.clientID)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onSubmit { account.signIn() }
            }

            if let error = account.signInError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                if account.status == .signingIn {
                    ProgressView().controlSize(.small)
                    Text("Approve in your browser…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    account.cancelSignIn()
                    onCancel()
                }
                .buttonStyle(PressableButtonStyle())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                Button {
                    account.signIn()
                } label: {
                    Text(account.status == .signingIn ? "Retry" : "Connect")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.black)
                        .frame(width: 80, height: 30)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(16)
    }

    private func step<Content: View>(_ number: Int, _ text: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .font(.system(size: 12, weight: .bold))
                Text(text)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }
}

/// A playlist cover loaded through `SafeImageLoader` (rather than `AsyncImage`, which would
/// fetch any URL with no host, size or format limits).
struct RemoteThumbnail: View {
    let url: URL?

    // Plain `State` storage rather than `@State` (a macro in the macOS 27 SDK; see WidgetView).
    private var imageState = State<CGImage?>(initialValue: nil)

    init(url: URL?) {
        self.url = url
    }

    var body: some View {
        ZStack {
            if let image = imageState.wrappedValue {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.note.list")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            guard let url else { return }
            let image = await SafeImageLoader.shared.image(for: url, maxPixelSize: 160)
            if !Task.isCancelled { imageState.wrappedValue = image }
        }
    }
}
