import AppKit
import SwiftUI

enum GlassPanelMetrics {
    static let size = CGSize(width: 304, height: 276)
    static let cornerRadius: CGFloat = 22
}

// MARK: - Window

/// The Glass panel: pick Light, Dark or Tinted by Album Art, and set how see-through the
/// glass is. It opens beside the widget and the widget changes as you go, so you can match
/// it to the other widgets on your desktop.
@MainActor
final class GlassPanelController: NSObject, NSWindowDelegate {
    private let spotify: SpotifyController
    private var panel: PickerPanel?

    init(spotify: SpotifyController) {
        self.spotify = spotify
        super.init()
    }

    func open(near anchor: NSRect) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let size = GlassPanelMetrics.size
        let panel = PickerPanel(size: size)
        panel.onCancel = { [weak self] in self?.close() }
        let view = GlassPanelView(spotify: spotify) { [weak self] in
            self?.close()
        }
        let host = FirstMouseHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.delegate = self
        panel.setFrameOrigin(PickerPanel.origin(near: anchor, size: size))
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.orderOut(nil)
    }

    // Like a popover: clicking anywhere else closes it. Every change is already saved.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

// MARK: - Panel

@MainActor
struct GlassPanelView: View {
    @ObservedObject private var spotify: SpotifyController
    // Shared with the widget through UserDefaults, so it redraws as these change.
    @AppStorage(Prefs.glassStyle) private var style: GlassStyle = .dark
    @AppStorage(Prefs.glassTranslucency) private var translucency = GlassLook.defaultTranslucency
    private let onDone: () -> Void

    init(spotify: SpotifyController, onDone: @escaping () -> Void) {
        _spotify = ObservedObject(wrappedValue: spotify)
        self.onDone = onDone
    }

    private var level: Double { GlassLook.clamped(translucency) }

    private var percent: String { "\(Int((level * 100).rounded()))%" }

    private var resetHelp: String {
        "Set translucency back to \(Int((GlassLook.defaultTranslucency * 100).rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Glass")
                    .font(.system(size: 15, weight: .bold))
                Text("Changes show on the widget right away.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                ForEach(GlassStyle.allCases) { option in
                    GlassSwatch(style: option,
                                translucency: level,
                                album: spotify.artworkColor ?? GlassLook.sampleTint,
                                isSelected: option == style) {
                        style = option
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Translucency")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(percent)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    sliderEnd("circle.fill", help: "Solid")
                    Slider(value: $translucency, in: 0...1)
                        .tint(Palette.spotifyGreen)
                        .accessibilityLabel("Translucency")
                        .accessibilityValue(percent)
                    sliderEnd("circle.dashed", help: "Clear")
                }
            }
            .padding(.top, 18)

            Spacer(minLength: 12)

            HStack(spacing: 16) {
                Button("Reset") {
                    translucency = GlassLook.defaultTranslucency
                }
                .buttonStyle(PressableButtonStyle())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .disabled(abs(level - GlassLook.defaultTranslucency) < 0.005)
                .help(resetHelp)
                Spacer()
                Button {
                    onDone()
                } label: {
                    Text("Done")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.black)
                        .frame(width: 72, height: 30)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: GlassPanelMetrics.size.width, height: GlassPanelMetrics.size.height)
        .modifier(GlassBackground(tint: Color.black.opacity(0.35),
                                  cornerRadius: GlassPanelMetrics.cornerRadius))
    }

    private func sliderEnd(_ symbol: String, help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .help(help)
            .accessibilityHidden(true)
    }
}

/// One style drawn as a tiny widget over a stand-in wallpaper, at the current translucency.
struct GlassSwatch: View {
    let style: GlassStyle
    let translucency: Double
    let album: Color
    let isSelected: Bool
    let action: () -> Void

    private var outline: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    private var card: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    /// Text and symbols: black on Light, white on Dark and Tinted.
    private var ink: Color { style == .light ? Color.black : Color.white }

    /// Stands in for the frosted glass under the colour.
    private var glass: Color {
        style == .light ? Color.white.opacity(0.35) : Color.black.opacity(0.3)
    }

    var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 6) {
                preview
                    .frame(width: 82, height: 56)
                    .clipShape(outline)
                    .overlay {
                        outline.strokeBorder(isSelected ? Palette.spotifyGreen : Color.white.opacity(0.15),
                                             lineWidth: isSelected ? 2 : 0.5)
                    }
                Text(style.shortTitle)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .opacity(isSelected ? 1 : 0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(style.title)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var preview: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.98, green: 0.64, blue: 0.40),
                                    Color(red: 0.42, green: 0.36, blue: 0.86)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            card
                .fill(glass)
                .overlay {
                    card.fill(GlassLook.fill(style, translucency: translucency, album: album))
                }
                .overlay {
                    card.strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5)
                }
                .overlay {
                    miniWidget
                }
                .padding(9)
        }
    }

    private var miniWidget: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(ink.opacity(0.3))
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                Capsule()
                    .fill(ink.opacity(0.9))
                    .frame(width: 24, height: 3)
                Capsule()
                    .fill(ink.opacity(0.55))
                    .frame(width: 16, height: 3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
    }
}
