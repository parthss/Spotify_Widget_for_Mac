import AppKit
import CoreImage
import ImageIO
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Constants

enum Metrics {
    static let size = CGSize(width: 372, height: 168)
    static let cornerRadius: CGFloat = 28
    static let padding: CGFloat = 16
    static let artworkSize: CGFloat = 84
    /// Concentric with the widget's corners, the way Apple nests rounded shapes.
    static let artworkCornerRadius: CGFloat = 12
}

enum Prefs {
    static let glassStyle = "glassStyle"
    static let glassTranslucency = "glassTranslucency"
    static let dimWithApps = "dimWhenUsingOtherApps"
    static let lockPosition = "lockPosition"
    static let originX = "widgetOriginX"
    static let originY = "widgetOriginY"
    static let spotifyClientID = "spotifyClientID"
    static let spotifyConnected = "spotifyConnected"
    static let spotifyUserID = "spotifyUserID"
    static let spotifyDisplayName = "spotifyDisplayName"
}

enum Palette {
    static let spotifyGreen = Color(red: 30 / 255, green: 215 / 255, blue: 96 / 255)
}

// MARK: - Glass

/// The widget's three looks. Light and Dark keep their colours whatever the system
/// appearance is; Tinted washes the glass with the colour of the album cover.
enum GlassStyle: String, CaseIterable, Identifiable {
    case light, dark, tinted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .tinted: return "Tinted by Album Art"
        }
    }

    /// Label under the style's preview in the Glass panel.
    var shortTitle: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .tinted: return "Tinted"
        }
    }

    /// Dark text and glass on Light; white text and dark glass on Dark and Tinted.
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

/// The widget's colours, and how see-through it is.
///
/// Translucency runs from 0 (a solid widget) to 1 (plain glass). The style's colour is laid
/// over the glass, behind the controls, at an opacity of 1 − translucency, so the slider
/// fades the widget smoothly between the two.
enum GlassLook {
    /// Halfway: frosted, but solid enough to sit with the system's own desktop widgets.
    static let defaultTranslucency = 0.5

    /// The background of macOS's dark widgets.
    static let darkGray = Color(red: 0.11, green: 0.11, blue: 0.12)

    /// Shown in the Tinted preview while there's no album cover to take a colour from.
    static let sampleTint = Color(red: 0.36, green: 0.24, blue: 0.52)

    /// Colour washed over the glass for a style at a translucency.
    static func fill(_ style: GlassStyle, translucency: Double, album: Color?) -> Color {
        let opacity = 1 - clamped(translucency)
        switch style {
        case .light:
            return Color.white.opacity(opacity)
        case .dark:
            return darkGray.opacity(opacity)
        case .tinted:
            guard let album else { return darkGray.opacity(opacity) }
            // Some colour stays even at 100 %, or Tinted would look just like Dark.
            return album.opacity(0.2 + 0.8 * opacity)
        }
    }

    /// Settings can be edited outside the app (`defaults write`), so never trust the value.
    static func clamped(_ translucency: Double) -> Double {
        translucency.isFinite ? min(max(translucency, 0), 1) : defaultTranslucency
    }

    /// Light or Dark, whichever the Mac is using.
    @MainActor
    static var systemStyle: GlassStyle {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// The saved style (or the default, until you pick one).
    @MainActor
    static var savedStyle: GlassStyle {
        GlassStyle(rawValue: UserDefaults.standard.string(forKey: Prefs.glassStyle) ?? "") ?? systemStyle
    }

    /// Called once at launch. Until you pick a style, the widget matches the system's
    /// Light or Dark appearance; styles from earlier versions (Regular, Clear) give way to that.
    @MainActor
    static func registerDefaults() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: Prefs.glassStyle), GlassStyle(rawValue: saved) == nil {
            defaults.removeObject(forKey: Prefs.glassStyle)
        }
        defaults.register(defaults: [
            Prefs.glassStyle: systemStyle.rawValue,
            Prefs.glassTranslucency: defaultTranslucency,
        ])
    }
}

/// The glass surface of the widget and its panels: Liquid Glass on macOS 26 and later,
/// a frosted blur before that.
struct GlassBackground: ViewModifier {
    /// Colour washed over the glass, behind the content. The more opaque it is, the less of
    /// the desktop shows through.
    var fill: Color = .clear
    /// Colours the glass itself (Liquid Glass); on older systems it's laid over the blur.
    var tint: Color?
    var cornerRadius: CGFloat = Metrics.cornerRadius

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .background { shape.fill(fill) }
                .glassEffect(liquidGlass, in: shape)
        } else {
            frosted(content)
        }
        #else
        frosted(content)
        #endif
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private var liquidGlass: Glass {
        guard let tint else { return .regular }
        return .regular.tint(tint)
    }
    #endif

    private func frosted(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    VisualEffectBlur(cornerRadius: cornerRadius)
                    if let tint {
                        shape.fill(tint)
                    }
                    shape.fill(fill)
                }
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            }
    }
}

/// Behind-window blur for systems without Liquid Glass.
struct VisualEffectBlur: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active // the widget is never the key window, so don't follow window state
        view.maskImage = Self.roundedMask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Album colour

enum ArtworkColor {
    /// Average colour of the cover, as a deep shade (like Spotify's own tinted views) so the
    /// widget's white text stays readable on it. Black-and-white covers stay grey.
    static func from(_ cgImage: CGImage) -> NSColor? {
        let image = CIImage(cgImage: cgImage)
        guard !image.extent.isEmpty,
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: image,
                  kCIInputExtentKey: CIVector(cgRect: image.extent),
              ]),
              let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        let average = NSColor(srgbRed: CGFloat(pixel[0]) / 255,
                              green: CGFloat(pixel[1]) / 255,
                              blue: CGFloat(pixel[2]) / 255,
                              alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let isGray = saturation < 0.08
        return NSColor(hue: hue,
                       saturation: isGray ? 0 : min(max(saturation * 1.25, 0.35), 0.85),
                       brightness: min(max(brightness * 0.85, 0.22), 0.46),
                       alpha: 1)
    }
}

// MARK: - Input checks

/// Spotify IDs are base-62 (letters and digits). Anything else is refused before it goes
/// into a URL path, an API call or a shared link.
enum SpotifyID {
    static func isValid<S: StringProtocol>(_ id: S) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// `spotify:track:<id>`
    static func isTrackURI(_ uri: String) -> Bool {
        let parts = uri.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "spotify" && parts[1] == "track" && isValid(parts[2])
    }
}

/// Cover images are only downloaded over HTTPS from Spotify's image servers. Anything else
/// (another site, a file on disk, plain HTTP) shows the placeholder instead.
enum TrustedImageURL {
    private static let hostSuffixes = ["scdn.co", "spotifycdn.com"]
    static let maxBytes = 8_000_000

    static func filter(_ url: URL?) -> URL? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased() else { return nil }
        let trusted = hostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
        return trusted ? url : nil
    }
}

/// Downloads and decodes cover images defensively:
/// - only HTTPS URLs on Spotify's image servers, checked again after any redirect;
/// - at most `TrustedImageURL.maxBytes`, counted while downloading;
/// - only common bitmap formats (no PDF or other document types);
/// - decoded straight to a small thumbnail, so a huge image can't exhaust memory;
/// - an ephemeral session, so nothing (cover art included) is cached on disk.
final class SafeImageLoader: @unchecked Sendable {
    static let shared = SafeImageLoader()

    private let session = URLSession(configuration: .ephemeral)
    private let cache = NSCache<NSString, CGImage>()

    private static let allowedTypes: Set<String> = [
        UTType.jpeg.identifier,
        UTType.png.identifier,
        UTType.webP.identifier,
        UTType.heic.identifier,
        UTType.gif.identifier,
    ]

    func image(for url: URL, maxPixelSize: Int) async -> CGImage? {
        guard let url = TrustedImageURL.filter(url) else { return nil }
        let key = "\(maxPixelSize)|\(url.absoluteString)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = await download(url),
              let image = Self.decode(data, maxPixelSize: maxPixelSize) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let result = try? await session.bytes(for: request) else { return nil }
        let (bytes, response) = result
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              TrustedImageURL.filter(http.url) != nil,                       // after redirects
              http.expectedContentLength <= Int64(TrustedImageURL.maxBytes) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > TrustedImageURL.maxBytes { return nil }
            }
        } catch {
            return nil
        }
        return data
    }

    static func decode(_ data: Data, maxPixelSize: Int) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              let type = CGImageSourceGetType(source).map({ $0 as String }),
              allowedTypes.contains(type) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }
}

// MARK: - Open at Login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Glass Player: couldn't change Open at Login: %@", error.localizedDescription)
        }
    }
}
