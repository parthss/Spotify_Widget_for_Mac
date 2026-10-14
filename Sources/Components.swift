import AppKit
import SwiftUI

// MARK: - Buttons
//
// Buttons follow Apple's media controls (Control Center, Music): plain SF Symbols on a
// round platter that appears under the pointer, a spring when pressed, and an SF Symbols
// effect when clicked.
//
// `State` and `Environment` are stored as plain values rather than through `@State` and
// `@Environment`, which can be compiler macros in recent SDKs (see WidgetView).

/// What a button's symbol does when it's clicked, on top of the press animation.
enum GlyphEffect {
    /// SF Symbols' bounce, Apple's standard click feedback.
    case bounce
    /// Next and Previous: the symbol nudges that way (macOS 15 and later; a bounce before).
    case forward, backward
    /// No effect: the symbol animates itself (play/pause swaps symbols).
    case plain
}

/// Apple-style symbol button:
/// - a round platter fades in under the pointer and deepens while pressed;
/// - the button springs in when pressed and bounces back out on release;
/// - the symbol plays `effect` on each click;
/// - when `isOn` (shuffle, repeat), the platter is solid with the symbol cut out of it,
///   like the toggles in Control Center.
struct GlyphButtonStyle: ButtonStyle {
    var diameter: CGFloat = 32
    var isOn = false
    var effect: GlyphEffect = .bounce
    var pressedScale: CGFloat = 0.86

    func makeBody(configuration: Configuration) -> some View {
        GlyphButtonBody(configuration: configuration, diameter: diameter, isOn: isOn,
                        effect: effect, pressedScale: pressedScale)
    }
}

private struct GlyphButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let diameter: CGFloat
    let isOn: Bool
    let effect: GlyphEffect
    let pressedScale: CGFloat

    private var hoveringState = State(initialValue: false)
    private var clicksState = State(initialValue: 0)
    private var isEnabled = Environment(\.isEnabled)

    init(configuration: ButtonStyleConfiguration, diameter: CGFloat, isOn: Bool,
         effect: GlyphEffect, pressedScale: CGFloat) {
        self.configuration = configuration
        self.diameter = diameter
        self.isOn = isOn
        self.effect = effect
        self.pressedScale = pressedScale
    }

    private var hovering: Bool {
        get { hoveringState.wrappedValue }
        nonmutating set { hoveringState.wrappedValue = newValue }
    }

    private var clicks: Int {
        get { clicksState.wrappedValue }
        nonmutating set { clicksState.wrappedValue = newValue }
    }

    private var platterOpacity: Double {
        guard isEnabled.wrappedValue else { return 0 }
        if configuration.isPressed { return 0.16 }
        return hovering ? 0.09 : 0
    }

    var body: some View {
        let pressed = configuration.isPressed
        return ZStack {
            if isOn {
                ZStack {
                    Circle()
                        .fill(.primary)
                        .padding(3)
                    configuration.label
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            } else {
                Circle()
                    .fill(.primary)
                    .padding(2)
                    .opacity(platterOpacity)
                configuration.label
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .scaleEffect(pressed ? pressedScale : 1)
        .modifier(GlyphEffectModifier(effect: effect, trigger: clicks))
        .animation(pressed ? .snappy(duration: 0.12) : .bouncy(duration: 0.45, extraBounce: 0.15),
                   value: pressed)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.smooth(duration: 0.25), value: isOn)
        .onHover { hovering = $0 }
        .onChange(of: pressed) { _, isPressed in
            if !isPressed { clicks += 1 } // released: play the symbol effect
        }
    }
}

private struct GlyphEffectModifier: ViewModifier {
    let effect: GlyphEffect
    let trigger: Int

    @ViewBuilder
    func body(content: Content) -> some View {
        switch effect {
        case .plain:
            content
        case .bounce:
            content.symbolEffect(.bounce, value: trigger)
        case .forward:
            #if compiler(>=6.0)
            if #available(macOS 15.0, *) {
                content.symbolEffect(.wiggle.forward, value: trigger)
            } else {
                content.symbolEffect(.bounce, value: trigger)
            }
            #else
            content.symbolEffect(.bounce, value: trigger)
            #endif
        case .backward:
            #if compiler(>=6.0)
            if #available(macOS 15.0, *) {
                content.symbolEffect(.wiggle.backward, value: trigger)
            } else {
                content.symbolEffect(.bounce, value: trigger)
            }
            #else
            content.symbolEffect(.bounce, value: trigger)
            #endif
        }
    }
}

/// An SF Symbol button in Apple's style (see `GlyphButtonStyle`).
struct IconButton: View {
    let symbol: String
    /// For symbols that show a level, such as the speaker's waves for the volume (0...1).
    var variableValue: Double?
    var size: CGFloat = 15
    var weight: Font.Weight = .medium
    var diameter: CGFloat = 32
    var isOn = false
    var effect: GlyphEffect = .bounce
    let label: String
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: symbol, variableValue: variableValue)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(.primary)
        }
        .buttonStyle(GlyphButtonStyle(diameter: diameter, isOn: isOn, effect: effect))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Text and capsule buttons: spring in when pressed, bounce back out on release, and dim
/// when disabled.
struct PressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        PressableButtonBody(configuration: configuration, pressedScale: pressedScale)
    }
}

private struct PressableButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let pressedScale: CGFloat

    private var isEnabled = Environment(\.isEnabled)

    init(configuration: ButtonStyleConfiguration, pressedScale: CGFloat) {
        self.configuration = configuration
        self.pressedScale = pressedScale
    }

    private var labelOpacity: Double {
        guard isEnabled.wrappedValue else { return 0.4 }
        return configuration.isPressed ? 0.7 : 1
    }

    var body: some View {
        let pressed = configuration.isPressed
        return configuration.label
            .opacity(labelOpacity)
            .scaleEffect(pressed ? pressedScale : 1)
            .animation(pressed ? .snappy(duration: 0.12) : .bouncy(duration: 0.4, extraBounce: 0.12),
                       value: pressed)
    }
}

/// List rows: a rounded highlight under the pointer that deepens while pressed, like the
/// rows in macOS menus and sidebars.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration)
    }
}

private struct RowButtonBody: View {
    let configuration: ButtonStyleConfiguration

    private var hoveringState = State(initialValue: false)
    private var isEnabled = Environment(\.isEnabled)

    init(configuration: ButtonStyleConfiguration) {
        self.configuration = configuration
    }

    private var hovering: Bool {
        get { hoveringState.wrappedValue }
        nonmutating set { hoveringState.wrappedValue = newValue }
    }

    private var highlight: Double {
        guard isEnabled.wrappedValue else { return 0 }
        if configuration.isPressed { return 0.14 }
        return hovering ? 0.07 : 0
    }

    var body: some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary)
                    .opacity(highlight)
            }
            .opacity(isEnabled.wrappedValue ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: highlight)
            .onHover { hovering = $0 }
    }
}

// MARK: - Artwork and slider

/// Album cover with a crossfade when the song changes.
struct ArtworkView: View {
    let image: NSImage?
    let placeholder: String

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.artworkCornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            shape.fill(.quaternary)
            Image(systemName: placeholder)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            }
        }
        .frame(width: Metrics.artworkSize, height: Metrics.artworkSize)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        .animation(.easeInOut(duration: 0.4), value: image.map { ObjectIdentifier($0) })
    }
}

/// A Control Centre style capsule slider. Reports a fraction (0...1) while you drag
/// and again when you let go.
struct CapsuleSlider: View {
    let value: Double
    let height: CGFloat
    let onScrub: (Double) -> Void
    let onRelease: (Double) -> Void

    // Plain `State` storage rather than `@State` (a macro in the macOS 27 SDK; see WidgetView).
    private var dragState = State<Double?>(initialValue: nil)

    private var dragValue: Double? {
        get { dragState.wrappedValue }
        nonmutating set { dragState.wrappedValue = newValue }
    }

    init(value: Double,
         height: CGFloat,
         onScrub: @escaping (Double) -> Void = { _ in },
         onRelease: @escaping (Double) -> Void) {
        self.value = value
        self.height = height
        self.onScrub = onScrub
        self.onRelease = onRelease
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let shown = min(max(dragValue ?? value, 0), 1)
            let barHeight = dragValue == nil ? height : height + 2
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.primary)
                    .frame(width: max(barHeight, width * CGFloat(shown)))
            }
            .frame(height: barHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = Double(min(max(drag.location.x / width, 0), 1))
                        dragValue = fraction
                        onScrub(fraction)
                    }
                    .onEnded { drag in
                        let fraction = Double(min(max(drag.location.x / width, 0), 1))
                        dragValue = nil
                        onRelease(fraction)
                    }
            )
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.15), value: dragValue == nil)
    }
}
