import AppKit
import Foundation

/// What macOS's system-wide Now Playing (the media panel in Control Center) reports.
/// Every value comes from another app, so it's treated as untrusted and kept in range.
struct SystemTrack: Equatable {
    var bundleID = ""
    var parentBundleID = ""
    var isPlaying = false
    var title = ""
    var artist = ""
    var album = ""
    var duration: Double = 0       // seconds
    var elapsed: Double = 0        // seconds, as of `timestamp`
    var timestamp = Date()
    /// nil when the player doesn't report it (the button is then disabled).
    var shuffleMode: Int?          // 1 off, 2 albums, 3 songs
    var repeatMode: Int?           // 1 off, 2 one, 3 all
    var artworkData: Data?

    /// The app that's playing. Browsers report a helper process as the player and the
    /// browser itself as the parent.
    var appBundleID: String { parentBundleID.isEmpty ? bundleID : parentBundleID }

    init() {}

    init?(payload: [String: Any]) {
        guard let bundleID = payload["bundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
        self.bundleID = String(bundleID.prefix(200))
        parentBundleID = String(((payload["parentApplicationBundleIdentifier"] as? String) ?? "").prefix(200))
        isPlaying = (payload["playing"] as? NSNumber)?.boolValue ?? false
        title = String(((payload["title"] as? String) ?? "").prefix(300))
        artist = String(((payload["artist"] as? String) ?? "").prefix(300))
        album = String(((payload["album"] as? String) ?? "").prefix(300))
        duration = Self.seconds(fromMicros: payload["durationMicros"])
        elapsed = Self.seconds(fromMicros: payload["elapsedTimeMicros"])
        if let micros = (payload["timestampEpochMicros"] as? NSNumber)?.doubleValue, micros.isFinite {
            // Never in the future, so the progress bar can't run backwards.
            timestamp = min(Date(timeIntervalSince1970: micros / 1_000_000), Date())
        }
        shuffleMode = Self.mode(payload["shuffleMode"])
        repeatMode = Self.mode(payload["repeatMode"])
        if let base64 = payload["artworkData"] as? String, base64.utf8.count <= TrustedImageURL.maxBytes * 4 / 3 + 4 {
            artworkData = Data(base64Encoded: base64)
        }
    }

    private static func seconds(fromMicros value: Any?) -> Double {
        guard let micros = (value as? NSNumber)?.doubleValue, micros.isFinite else { return 0 }
        return min(max(micros, 0), 86_400_000_000) / 1_000_000
    }

    private static func mode(_ value: Any?) -> Int? {
        guard let mode = (value as? NSNumber)?.intValue, (1...3).contains(mode) else { return nil }
        return mode
    }
}

/// Reads and controls macOS's Now Playing through the vendored mediaremote-adapter
/// (see Vendor/mediaremote-adapter). Since macOS 15.4 only Apple-signed programs may use
/// the private MediaRemote framework, so the adapter runs inside Apple's `/usr/bin/perl`
/// as a child process that streams one JSON line per change.
@MainActor
final class SystemNowPlaying {
    enum Command: Int {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    /// Called with each change; nil when no app is reporting anything.
    var onChange: ((SystemTrack?) -> Void)?
    private(set) var track: SystemTrack?

    private var process: Process?
    private var state: [String: Any] = [:]
    private var stopped = true
    private var restartDelay: TimeInterval = 2
    private var restartTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?

    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")

    /// The script and framework `build.sh` puts in the app. Missing in `--sandbox` builds.
    private static let paths: (script: String, framework: String)? = {
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        let framework = frameworks.appendingPathComponent("MediaRemoteAdapter.framework")
        let binary = framework.appendingPathComponent("MediaRemoteAdapter")
        let files = FileManager.default
        guard files.isExecutableFile(atPath: SystemNowPlaying.perl.path),
              files.fileExists(atPath: script.path),
              files.fileExists(atPath: binary.path) else { return nil }
        return (script.path, framework.path)
    }()

    static var isAvailable: Bool { paths != nil }

    func start() {
        guard Self.isAvailable, stopped else { return }
        stopped = false
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.stop() }
        }
        launch()
    }

    func stop() {
        stopped = true
        restartTask?.cancel()
        process?.terminate()
        process = nil
    }

    // MARK: Commands

    func send(_ command: Command) {
        Self.run(["send", String(command.rawValue)])
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        Self.run(["seek", String(Int64(max(seconds, 0) * 1_000_000))])
    }

    func setShuffle(_ on: Bool) {
        Self.run(["shuffle", on ? "3" : "1"])
    }

    func setRepeat(_ on: Bool) {
        Self.run(["repeat", on ? "3" : "1"])
    }

    // MARK: Stream

    private func launch() {
        guard !stopped, let paths = Self.paths else { return }
        let process = Self.makeProcess(paths, ["stream", "--micros", "--debounce=100"])
        let pipe = Pipe()
        process.standardOutput = pipe
        let reader = LineReader { [weak self] line in
            Task { @MainActor in self?.handle(line) }
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                reader.append(data)
            }
        }
        let started = Date()
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.streamEnded(after: Date().timeIntervalSince(started)) }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            NSLog("Glass Player: couldn't start the Now Playing adapter: %@", error.localizedDescription)
            streamEnded(after: 0)
        }
    }

    private func streamEnded(after runtime: TimeInterval) {
        process = nil
        state = [:]
        publish(nil)
        guard !stopped else { return }
        // Back off if it keeps failing straight away (for example, if a macOS update
        // blocks the adapter); restart promptly after a long, healthy run.
        restartDelay = runtime > 60 ? 2 : min(restartDelay * 2, 120)
        let delay = restartDelay
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.launch()
        }
    }

    private func handle(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "data",
              let payload = object["payload"] as? [String: Any] else { return }
        if (object["diff"] as? NSNumber)?.boolValue == true {
            for (key, value) in payload {
                if value is NSNull { state.removeValue(forKey: key) } else { state[key] = value }
            }
        } else {
            state = payload
        }
        publish(SystemTrack(payload: state))
    }

    private func publish(_ track: SystemTrack?) {
        guard track != self.track else { return }
        self.track = track
        onChange?(track)
    }

    // MARK: Process

    private static func makeProcess(_ paths: (script: String, framework: String), _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = perl
        process.arguments = [paths.script, paths.framework] + arguments
        // A clean environment, so nothing like PERL5OPT or PERL5LIB can change what perl runs.
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Runs a one-off command, giving up after 5 seconds.
    private static func run(_ arguments: [String]) {
        guard let paths else { return }
        let process = makeProcess(paths, arguments)
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Splits the adapter's output into lines. Artwork makes lines long (base64 images), so
/// any line over 16 MB is dropped rather than buffered without limit.
private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var skipping = false
    private let onLine: @Sendable (Data) -> Void
    private static let maxLine = 16_000_000

    init(onLine: @escaping @Sendable (Data) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        lock.lock()
        var lines: [Data] = []
        var chunk = data[...]
        // Only the new bytes are searched for line breaks, so a long line isn't rescanned.
        while let newline = chunk.firstIndex(of: 0x0A) {
            if !skipping {
                buffer.append(chunk[chunk.startIndex..<newline])
                if !buffer.isEmpty { lines.append(buffer) }
            }
            buffer = Data()
            skipping = false
            chunk = chunk[chunk.index(after: newline)...]
        }
        if !skipping { buffer.append(chunk) }
        if buffer.count > Self.maxLine {
            buffer = Data()
            skipping = true
        }
        lock.unlock()
        lines.forEach(onLine)
    }
}
