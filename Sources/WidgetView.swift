import AppKit
import SwiftUI

/// What the widget is showing right now.
private enum Mode {
    case needsPermission, notRunning, idle, track
}

@MainActor
struct WidgetView: View {
    @ObservedObject private var spotify: SpotifyController
    @ObservedObject private var focus: DesktopFocus
    @ObservedObject private var library: LibraryController
    @ObservedObject private var account: SpotifyAccount
    private let window: WidgetWindowController
    private let glassPanel: GlassPanelController

    // Defaults are registered at launch (`GlassLook.registerDefaults`), so these initial
    // values are only a fallback.
    @AppStorage(Prefs.glassStyle) private var glassStyle: GlassStyle = .dark
    @AppStorage(Prefs.glassTranslucency) private var glassTranslucency = GlassLook.defaultTranslucency
    @AppStorage(Prefs.dimWithApps) private var dimWithApps = false
    @AppStorage(Prefs.lockPosition) private var lockPosition = false

    // In the macOS 27 SDK `@State` is a compiler macro, and command-line builds can't load
    // SwiftUI's macro plugin. Storing `State` values directly behaves the same without it.
    private var openAtLoginState = State(initialValue: LoginItem.isEnabled)
    private var showingVolumeState = State(initialValue: false)
    private var volumeActivityState = State(initialValue: 0)
    private var artworkClicksState = State(initialValue: 0)

    private var openAtLogin: Bool { openAtLoginState.wrappedValue }

    private var artworkClicks: Int {
        get { artworkClicksState.wrappedValue }
        nonmutating set { artworkClicksState.wrappedValue = newValue }
    }

    private var showingVolume: Bool {
        get { showingVolumeState.wrappedValue }
        nonmutating set { showingVolumeState.wrappedValue = newValue }
    }

    private var volumeActivity: Int {
        get { volumeActivityState.wrappedValue }
        nonmutating set { volumeActivityState.wrappedValue = newValue }
    }

    init(spotify: SpotifyController, focus: DesktopFocus, library: LibraryController,
         window: WidgetWindowController, glassPanel: GlassPanelController) {
        _spotify = ObservedObject(wrappedValue: spotify)
        _focus = ObservedObject(wrappedValue: focus)
        _library = ObservedObject(wrappedValue: library)
        _account = ObservedObject(wrappedValue: library.account)
        self.window = window
        self.glassPanel = glassPanel
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 8)
            ZStack {
                if showingVolume {
                    volumeRow.transition(.opacity)
                } else {
                    transportRow.transition(.opacity)
                }
            }
            .frame(height: 46)
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.top, Metrics.padding)
        .padding(.bottom, 12)
        .saturation(isDimmed ? 0 : 1)
        .opacity(isDimmed ? 0.75 : 1)
        .animation(.easeInOut(duration: 0.35), value: isDimmed)
        .frame(width: Metrics.size.width, height: Metrics.size.height)
        .overlay(alignment: .bottom) { toastOverlay }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: library.toast?.id)
        .modifier(GlassBackground(fill: glassFill))
        .animation(.easeInOut(duration: 0.6), value: spotify.artworkColor) // fade to the new cover's colour
        .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        .gesture(windowDrag)
        .contextMenu { optionsMenu }
        // Light glass gets dark text; Dark and Tinted get white text.
        .environment(\.colorScheme, glassStyle.colorScheme)
        .onChange(of: glassStyle, initial: true) { _, style in
            window.setAppearance(for: style)
        }
        .onChange(of: openAtLogin) { _, enabled in
            LoginItem.setEnabled(enabled)
        }
        .onChange(of: spotify.now.trackID, initial: true) { _, uri in
            library.trackChanged(uri: uri, title: spotify.now.title)
        }
        .onChange(of: account.isConnected) { _, _ in
            library.refreshSavedState()
        }
    }

    // MARK: State

    private var mode: Mode {
        if spotify.needsPermission { return .needsPermission }
        if !spotify.now.isRunning { return .notRunning }
        return spotify.now.hasTrack ? .track : .idle
    }

    /// Mimics macOS desktop widgets, which fade back while you're using another app.
    private var isDimmed: Bool { dimWithApps && !focus.isDesktopActive }

    /// The style's colour over the glass, as opaque as the translucency setting asks.
    private var glassFill: Color {
        GlassLook.fill(glassStyle, translucency: glassTranslucency, album: spotify.artworkColor)
    }

    private var title: String {
        switch mode {
        case .needsPermission: return "Allow control of Spotify"
        case .notRunning: return "Spotify isn't open"
        case .idle: return spotify.now.isPlaying ? "Spotify is playing" : "Nothing playing"
        case .track: return spotify.now.title
        }
    }

    private var subtitle: String {
        switch mode {
        case .needsPermission:
            return "Privacy & Security › Automation"
        case .notRunning:
            return SpotifyApp.appURL == nil ? "Install Spotify to get started" : "Press play to start listening"
        case .idle:
            return spotify.now.isPlaying ? "Song details aren't available" : "Pick something in Spotify"
        case .track:
            return spotify.now.artist
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ArtworkView(
                image: (mode == .track || mode == .idle) ? spotify.artwork : nil,
                placeholder: mode == .needsPermission ? "lock.fill" : "music.note"
            )
            // A quick spring when clicked, like the buttons: in to 93%, then bounce back out.
            .phaseAnimator([CGFloat(1), 0.93], trigger: artworkClicks) { view, scale in
                view.scaleEffect(scale)
            } animation: { scale in
                scale < 1 ? .snappy(duration: 0.12) : .bouncy(duration: 0.5, extraBounce: 0.15)
            }
            // Clicking the cover opens Spotify. A tap (not a button) so you can still drag
            // the widget by its cover.
            .contentShape(RoundedRectangle(cornerRadius: Metrics.artworkCornerRadius, style: .continuous))
            .onTapGesture {
                artworkClicks += 1
                spotify.openSpotify()
            }
            .help("Open Spotify")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Open Spotify")

            VStack(alignment: .leading, spacing: 0) {
                if mode != .track { Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .padding(.top, mode == .track ? 4 : 0)
                .padding(.trailing, 36) // room for the + button
                Spacer(minLength: 0)
                if mode == .track { progress }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.artworkSize)
        }
        .overlay(alignment: .topTrailing) {
            // Tucked into the corner, concentric with the widget's rounded corner.
            likeButton
                .offset(x: 8, y: -8)
        }
    }

    /// Spotify's + : saves to Liked Songs, then morphs into a green check that opens the
    /// playlist picker.
    private var likeButton: some View {
        let enabled = mode == .track && library.canSave
        let saved = enabled && library.isSaved
        return Button {
            library.plusTapped()
        } label: {
            Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle")
                .font(.system(size: 24, weight: .regular))
                .symbolRenderingMode(saved ? .palette : .monochrome)
                .foregroundStyle(saved ? Color.black : Color.primary, Palette.spotifyGreen)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(GlyphButtonStyle(diameter: 38))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .animation(.snappy(duration: 0.3), value: saved)
        .help(saved ? "Saved. Click to choose playlists" : "Add to Liked Songs")
        .accessibilityLabel(saved ? "Add to playlist" : "Add to Liked Songs")
    }

    /// "Added to Liked Songs · Change", sliding up over the controls for a few seconds.
    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = library.toast {
            HStack(spacing: 12) {
                Text(toast.message)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if toast.offersChange {
                    Button("Change") { library.openPicker() }
                        .buttonStyle(PressableButtonStyle())
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.spotifyGreen)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.horizontal, Metrics.padding)
            .padding(.bottom, 16)
            .id(toast.id)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let track = spotify.now
            let position = track.playhead(at: context.date)
            VStack(spacing: 3) {
                CapsuleSlider(
                    value: track.duration > 0 ? position / track.duration : 0,
                    height: 4,
                    onRelease: { fraction in spotify.seek(toFraction: fraction) }
                )
                HStack {
                    Text(timeString(position))
                    Spacer()
                    Text("-" + timeString(track.duration - position))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Controls

    private var transportRow: some View {
        let hasTrack = mode == .track
        let canAdjustVolume = mode == .track || mode == .idle
        return HStack(spacing: 0) {
            control(volumeSymbol, variableValue: volumeLevel, label: "Volume", enabled: canAdjustVolume) {
                withAnimation(.easeInOut(duration: 0.2)) { showingVolume = true }
            }
            control("shuffle", label: "Shuffle", enabled: hasTrack, isOn: spotify.now.shuffling) {
                spotify.toggleShuffle()
            }
            control("backward.fill", size: 20, diameter: 38, label: "Previous", enabled: hasTrack,
                    effect: .backward) {
                spotify.previousTrack()
            }
            playButton
                .frame(maxWidth: .infinity)
            control("forward.fill", size: 20, diameter: 38, label: "Next", enabled: hasTrack,
                    effect: .forward) {
                spotify.nextTrack()
            }
            control("repeat", label: "Repeat", enabled: hasTrack, isOn: spotify.now.repeating) {
                spotify.toggleRepeat()
            }
            shareButton
                .frame(maxWidth: .infinity)
        }
    }

    private func control(_ symbol: String,
                         variableValue: Double? = nil,
                         size: CGFloat = 15,
                         diameter: CGFloat = 32,
                         label: String,
                         enabled: Bool = true,
                         isOn: Bool = false,
                         effect: GlyphEffect = .bounce,
                         action: @escaping () -> Void) -> some View {
        IconButton(symbol: symbol, variableValue: variableValue, size: size, diameter: diameter,
                   isOn: isOn, effect: effect, label: label, action: action)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
            .frame(maxWidth: .infinity)
    }

    /// Play/pause as a plain symbol, like Apple's media controls. The symbols morph into
    /// each other rather than bouncing.
    private var playButton: some View {
        Button {
            primaryAction()
        } label: {
            Image(systemName: playSymbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.primary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(GlyphButtonStyle(diameter: 46, effect: .plain, pressedScale: 0.9))
        .animation(.snappy(duration: 0.25), value: playSymbol)
        .help(playLabel)
        .accessibilityLabel(playLabel)
    }

    private var playSymbol: String {
        switch mode {
        case .needsPermission: return "gearshape.fill"
        case .notRunning: return "play.fill"
        case .idle, .track: return spotify.now.isPlaying ? "pause.fill" : "play.fill"
        }
    }

    private var playLabel: String {
        switch mode {
        case .needsPermission: return "Open Automation settings"
        case .notRunning: return "Open Spotify and play"
        case .idle, .track: return spotify.now.isPlaying ? "Pause" : "Play"
        }
    }

    private func primaryAction() {
        switch mode {
        case .needsPermission: spotify.openAutomationSettings()
        case .notRunning: spotify.launchAndPlay()
        case .idle, .track: spotify.playPause()
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        if mode == .track, let url = spotify.now.shareURL {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(GlyphButtonStyle())
            .help("Share song")
            .accessibilityLabel("Share song")
        } else {
            IconButton(symbol: "square.and.arrow.up", label: "Share song") {}
                .disabled(true)
                .opacity(0.35)
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            IconButton(symbol: volumeSymbol, variableValue: volumeLevel, label: "Back to controls") {
                withAnimation(.easeInOut(duration: 0.2)) { showingVolume = false }
            }
            CapsuleSlider(
                value: Double(spotify.now.volume) / 100,
                height: 6,
                onScrub: { fraction in
                    volumeActivity += 1
                    spotify.setVolume(Int((fraction * 100).rounded()))
                },
                onRelease: { fraction in
                    volumeActivity += 1
                    spotify.setVolume(Int((fraction * 100).rounded()), immediately: true)
                }
            )
            Text("\(spotify.now.volume)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        // Slide back to the playback controls after a few idle seconds.
        .task(id: volumeActivity) {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { showingVolume = false }
        }
    }

    /// Muted, or a speaker whose waves fill with the volume, as in macOS's own volume control.
    private var volumeSymbol: String {
        spotify.now.volume == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill"
    }

    private var volumeLevel: Double {
        min(max(Double(spotify.now.volume) / 100, 0), 1)
    }

    // MARK: Menu (right-click or Control-click anywhere on the widget)

    @ViewBuilder
    private var optionsMenu: some View {
        Button("Open Spotify") { spotify.openSpotify() }
        if let url = spotify.now.shareURL {
            Button("Copy Song Link") {
                _ = NSPasteboard.general.clearContents()
                _ = NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        Button("Add to Playlist…") { library.openPicker() }
            .disabled(!(mode == .track && library.canSave))
        Divider()
        if let name = account.displayName {
            Button("Disconnect Spotify Account (\(name))") {
                account.signOut()
                library.refreshSavedState()
            }
        } else {
            Button("Connect Spotify Account…") { library.openPicker() }
        }
        Divider()
        Menu("Glass") {
            Picker("Glass Style", selection: $glassStyle) {
                ForEach(GlassStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Translucency…") { glassPanel.open(near: window.frame) }
        }
        Toggle("Dim When Using Other Apps", isOn: $dimWithApps)
        Toggle("Lock Position", isOn: $lockPosition)
        Toggle("Open at Login", isOn: openAtLoginState.projectedValue)
        Divider()
        Button("Hide Widget") { window.hide() }
        Button("Quit Glass Player") { NSApp.terminate(nil) }
    }

    // MARK: Helpers

    private var windowDrag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in window.dragChanged() }
            .onEnded { _ in window.dragEnded() }
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(min(seconds, 359_999).rounded(.down))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
