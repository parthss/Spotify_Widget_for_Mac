import AppKit
import SwiftUI

// MARK: - Model

enum PlayerState: String {
    case playing, paused, stopped
}

/// Everything the widget shows, as last reported by the Spotify app.
struct NowPlaying {
    var isRunning = false
    var state: PlayerState = .stopped
    var title = ""
    var artist = ""
    var album = ""
    var trackID = ""            // e.g. spotify:track:4uLU6hMCjMI75M1A2tKUQC
    var artworkURL: URL?
    var duration: Double = 0    // seconds
    var position: Double = 0    // seconds, as of `positionDate`
    var positionDate = Date()
    var volume = 50             // 0...100
    var shuffling = false
    var repeating = false

    var hasTrack: Bool { !title.isEmpty }
    var isPlaying: Bool { state == .playing }

    /// Playback position extrapolated to `date`, so the progress bar moves smoothly between polls.
    func playhead(at date: Date) -> Double {
        let elapsed = isPlaying ? date.timeIntervalSince(positionDate) : 0
        let value = max(0, position + elapsed)
        return duration > 0 ? min(value, duration) : value
    }

    /// open.spotify.com link for sharing (songs and podcast episodes).
    var shareURL: URL? {
        let parts = trackID.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify",
              parts[1] == "track" || parts[1] == "episode",
              SpotifyID.isValid(parts[2]) else { return nil }
        return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")
    }
}

extension NowPlaying {
    /// Builds the state from the 11 values `SpotifyScript.status` returns, as a list (so no
    /// character in a song title can shift the fields). Every value is treated as untrusted,
    /// since it can come from a local file's tags, and kept in range.
    init?(fields: [String]) {
        guard fields.count == 11 else { return nil }
        self.init()
        isRunning = true
        state = PlayerState(rawValue: fields[0]) ?? .stopped
        position = Self.seconds(fromMilliseconds: fields[1])
        positionDate = Date()
        volume = min(max(Int(fields[2]) ?? 50, 0), 100)
        shuffling = fields[3] == "true"
        repeating = fields[4] == "true"
        title = String(fields[5].prefix(300))
        artist = String(fields[6].prefix(300))
        album = String(fields[7].prefix(300))
        duration = Self.seconds(fromMilliseconds: fields[8])
        trackID = String(fields[9].prefix(200))
        artworkURL = TrustedImageURL.filter(URL(string: fields[10]))
    }

    /// Milliseconds as text → seconds, kept between 0 and 24 hours (no NaN or infinity).
    private static func seconds(fromMilliseconds text: String) -> Double {
        guard let value = Double(text), value.isFinite else { return 0 }
        return min(max(value, 0), 86_400_000) / 1000
    }
}

// MARK: - Spotify app

enum SpotifyApp {
    static let bundleID = "com.spotify.client"

    static var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { !$0.isTerminated }
    }

    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}

/// The AppleScript Glass Player sends to the Spotify app.
enum SpotifyScript {
    /// One round trip that returns everything the widget needs as a list of 11 texts.
    /// Returns early, without ever launching Spotify, when Spotify isn't running.
    static let status = """
        if application id "com.spotify.client" is not running then return {"NOTRUNNING"}
        set posMs to 0
        set vol to 50
        set shf to false
        set rpt to false
        set tName to ""
        set tArtist to ""
        set tAlbum to ""
        set tDuration to 0
        set tURI to ""
        set tArtwork to ""
        tell application id "com.spotify.client"
            with timeout of 3 seconds
                -- Deliberately outside a try block: if macOS blocks access to Spotify,
                -- this error is how the widget knows to ask for permission.
                set pState to (player state as text)
                try
                    set posMs to ((player position) * 1000) as integer
                end try
                try
                    set vol to sound volume
                end try
                try
                    set shf to shuffling
                end try
                try
                    set rpt to repeating
                end try
                try
                    set t to current track
                    set tName to name of t
                    set tArtist to artist of t
                    set tAlbum to album of t
                    set tDuration to duration of t
                    set tURI to id of t
                    set tArtwork to artwork url of t
                end try
            end timeout
        end tell
        return {txt(pState), txt(posMs), txt(vol), txt(shf), txt(rpt), txt(tName), txt(tArtist), txt(tAlbum), txt(tDuration), txt(tURI), txt(tArtwork)}

        on txt(v)
            try
                if v is missing value then return ""
                return v as text
            on error
                return ""
            end try
        end txt
        """

    static let playPause = tell("playpause")
    static let nextTrack = tell("next track")

    /// Restarts the song if you're more than 3 s in, like the Previous button in Spotify.
    static let previousTrack = tell("""
        if player position > 3 then
            set player position to 0
        else
            previous track
        end if
        """)

    static let toggleShuffle = tell("set shuffling to not shuffling")
    static let toggleRepeat = tell("set repeating to not repeating")

    /// Opens Spotify if needed and resumes playback. Long timeout: launching can take a while.
    static let launchAndPlay = """
        tell application id "com.spotify.client"
            with timeout of 60 seconds
                play
            end timeout
        end tell
        """

    static func setVolume(_ volume: Int) -> String {
        tell("set sound volume to \(volume)")
    }

    static func seek(to seconds: Double) -> String {
        tell("set player position to \(Int(seconds.rounded()))")
    }

    private static func tell(_ body: String) -> String {
        """
        tell application id "com.spotify.client"
            with timeout of 3 seconds
                \(body)
            end timeout
        end tell
        """
    }
}

// MARK: - AppleScript runner

enum ScriptResult: Sendable {
    /// A list result as its items' text; any other result as a single string.
    case success([String])
    case failure(code: Int)

    /// -1743 / -1744: Automation access to Spotify was denied or hasn't been granted yet.
    var isPermissionError: Bool {
        if case .failure(let code) = self { return code == -1743 || code == -1744 }
        return false
    }
}

/// Runs AppleScript off the main thread, one script at a time, compiling each script once.
final class AppleScriptRunner: @unchecked Sendable {
    static let shared = AppleScriptRunner()

    private let queue = DispatchQueue(label: "glassplayer.applescript", qos: .userInitiated)
    private var compiled: [String: NSAppleScript] = [:] // only touched on `queue`

    func run(_ source: String, cache: Bool = true) async -> ScriptResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ScriptResult, Never>) in
            queue.async {
                continuation.resume(returning: self.execute(source, cache: cache))
            }
        }
    }

    private func execute(_ source: String, cache: Bool) -> ScriptResult {
        var errorInfo: NSDictionary?
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            let created: NSAppleScript? = NSAppleScript(source: source)
            guard let created, created.compileAndReturnError(&errorInfo) else {
                return .failure(code: Self.errorCode(errorInfo))
            }
            if cache { compiled[source] = created }
            script = created
        }
        let output: NSAppleEventDescriptor? = script.executeAndReturnError(&errorInfo)
        if errorInfo != nil {
            return .failure(code: Self.errorCode(errorInfo))
        }
        return .success(Self.strings(from: output))
    }

    private static func strings(from descriptor: NSAppleEventDescriptor?) -> [String] {
        guard let descriptor else { return [] }
        let listType: UInt32 = 0x6C69_7374 // 'list' (typeAEList)
        guard descriptor.descriptorType == listType else { return [descriptor.stringValue ?? ""] }
        let count = descriptor.numberOfItems
        guard count > 0 else { return [] }
        return (1...count).map { descriptor.atIndex($0)?.stringValue ?? "" }
    }

    private static func errorCode(_ info: NSDictionary?) -> Int {
        (info?["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue ?? 0
    }
}

// MARK: - Controller

/// Keeps `now` in sync with the Spotify app and sends it commands.
///
/// Updates arrive two ways: Spotify broadcasts a notification whenever the song or the
/// play state changes (instant), and a light poll every 2 s catches everything else
/// (shuffle, repeat, volume, seeking from the Spotify window).
@MainActor
final class SpotifyController: ObservableObject {
    @Published private(set) var now = NowPlaying()
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artworkColor: Color?
    @Published private(set) var needsPermission = false

    private enum Field: Hashable {
        case state, position, volume, shuffle, repeating
    }

    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var isRefreshing = false
    private var refreshQueued = false
    private var artworkURL: URL?
    private var artworkTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    /// Right after you press a button, the widget trusts its own state for a moment,
    /// so a status read that was already in flight can't flip the button back.
    private var holdUntil: [Field: Date] = [:]

    func start() {
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refresh() }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let self, app?.bundleIdentifier == SpotifyApp.bundleID else { return }
                MainActor.assumeIsolated { self.refresh() }
            })
        }
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refresh() }
        })

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        refresh()
    }

    func refresh() {
        guard SpotifyApp.isRunning else {
            if now.isRunning { now = NowPlaying() }
            setArtwork(nil)
            return
        }
        if !now.isRunning { now.isRunning = true }
        guard !isRefreshing else {
            refreshQueued = true
            return
        }
        isRefreshing = true
        Task {
            let result = await AppleScriptRunner.shared.run(SpotifyScript.status)
            self.isRefreshing = false
            self.apply(result)
            if self.refreshQueued {
                self.refreshQueued = false
                self.refresh()
            }
        }
    }

    // MARK: Commands

    func playPause() {
        hold(.state, .position)
        let date = Date()
        var updated = now
        updated.position = now.playhead(at: date)
        updated.positionDate = date
        updated.state = now.isPlaying ? .paused : .playing
        now = updated
        send(SpotifyScript.playPause)
    }

    func nextTrack() { send(SpotifyScript.nextTrack) }
    func previousTrack() { send(SpotifyScript.previousTrack) }

    func toggleShuffle() {
        hold(.shuffle)
        now.shuffling.toggle()
        send(SpotifyScript.toggleShuffle)
    }

    func toggleRepeat() {
        hold(.repeating)
        now.repeating.toggle()
        send(SpotifyScript.toggleRepeat)
    }

    func seek(toFraction fraction: Double) {
        guard now.duration > 0, fraction.isFinite else { return }
        let seconds = min(max(fraction, 0), 1) * now.duration
        hold(.position)
        now.position = seconds
        now.positionDate = Date()
        send(SpotifyScript.seek(to: seconds), cache: false)
    }

    /// Called continuously while you drag the volume slider; only the latest value is sent.
    func setVolume(_ value: Int, immediately: Bool = false) {
        let volume = min(max(value, 0), 100)
        hold(.volume)
        now.volume = volume
        volumeTask?.cancel()
        volumeTask = Task {
            if !immediately {
                try? await Task.sleep(nanoseconds: 60_000_000)
                if Task.isCancelled { return }
            }
            _ = await AppleScriptRunner.shared.run(SpotifyScript.setVolume(volume), cache: false)
        }
    }

    func launchAndPlay() {
        guard SpotifyApp.appURL != nil else {
            openSpotify() // not installed: opens the download page
            return
        }
        Task {
            let result = await AppleScriptRunner.shared.run(SpotifyScript.launchAndPlay)
            if result.isPermissionError { self.needsPermission = true }
            self.refresh()
        }
    }

    func openSpotify() {
        if let url = SpotifyApp.appURL {
            NSWorkspace.shared.openApplication(at: url,
                                               configuration: NSWorkspace.OpenConfiguration(),
                                               completionHandler: nil)
        } else if let url = URL(string: "https://www.spotify.com/download/mac/") {
            _ = NSWorkspace.shared.open(url)
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            _ = NSWorkspace.shared.open(url)
        }
    }

    // MARK: Internals

    private func send(_ script: String, cache: Bool = true) {
        guard SpotifyApp.isRunning else { return }
        Task {
            let result = await AppleScriptRunner.shared.run(script, cache: cache)
            if result.isPermissionError { self.needsPermission = true }
            // Give Spotify a beat to apply the change, then read back the real state.
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.refresh()
        }
    }

    private func apply(_ result: ScriptResult) {
        guard case .success(let fields) = result else {
            if result.isPermissionError { needsPermission = true }
            return
        }
        needsPermission = false
        guard fields != ["NOTRUNNING"] else {
            now = NowPlaying()
            setArtwork(nil)
            return
        }
        guard var fresh = NowPlaying(fields: fields) else { return }

        let current = now
        let date = Date()
        if isHeld(.state, date) { fresh.state = current.state }
        if isHeld(.position, date), fresh.trackID == current.trackID {
            fresh.position = current.playhead(at: date)
            fresh.positionDate = date
        }
        if isHeld(.volume, date) { fresh.volume = current.volume }
        if isHeld(.shuffle, date) { fresh.shuffling = current.shuffling }
        if isHeld(.repeating, date) { fresh.repeating = current.repeating }

        now = fresh
        setArtwork(fresh.artworkURL)
    }

    private func hold(_ fields: Field...) {
        let until = Date().addingTimeInterval(1.5)
        for field in fields { holdUntil[field] = until }
    }

    private func isHeld(_ field: Field, _ date: Date) -> Bool {
        (holdUntil[field] ?? .distantPast) > date
    }

    private func setArtwork(_ url: URL?) {
        guard url != artworkURL else { return }
        artworkURL = url
        artworkTask?.cancel()
        guard let url else {
            artwork = nil
            artworkColor = nil
            return
        }
        artworkTask = Task {
            let cgImage = await SafeImageLoader.shared.image(for: url, maxPixelSize: 640)
            guard !Task.isCancelled, self.artworkURL == url else { return }
            if let cgImage {
                self.artwork = NSImage(cgImage: cgImage,
                                       size: NSSize(width: cgImage.width, height: cgImage.height))
                self.artworkColor = ArtworkColor.from(cgImage).map { Color(nsColor: $0) }
            } else {
                self.artwork = nil
                self.artworkColor = nil
            }
        }
    }
}

// MARK: - Desktop focus

/// Tracks whether you're "on the desktop" (Finder in front), to mimic how macOS
/// desktop widgets fade back while you work in other apps.
@MainActor
final class DesktopFocus: ObservableObject {
    @Published private(set) var isDesktopActive = false
    private var observer: NSObjectProtocol?

    init() {
        update()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.update() }
        }
    }

    private func update() {
        isDesktopActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }
}
