import AppKit
import SwiftUI

/// A borderless, see-through panel on the desktop layer, the same layer macOS uses for its
/// own desktop widgets: above the wallpaper and desktop icons, below every app window.
/// It appears on every Space, stays put during Mission Control and Show Desktop,
/// never takes keyboard focus, and never shows up in Cmd-Tab or the Dock.
final class DesktopPanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // Liquid Glass draws its own edge. A window shadow would be cast from the
        // full rectangle and show square corners.
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false // the widget handles dragging itself
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        acceptsMouseMovedEvents = true // for the buttons' hover effects
    }

    // Clicking the widget never pulls keyboard focus away from the app you're working in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the very first click on the (never focused) widget reach its buttons, and keeps
/// hover effects working there.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    private var pointerArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The widget never becomes the key window, and pointer tracking can stop in windows
    // that aren't key. An always-on tracking area keeps the buttons' hover platters working.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea, trackingAreas.contains(pointerArea) {
            return
        }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        pointerArea = area
    }
}

@MainActor
final class WidgetWindowController {
    /// Called when the widget comes back into view, e.g. when you reveal the desktop.
    var onBecameVisible: (() -> Void)?

    private let panel: DesktopPanel
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var observers: [NSObjectProtocol] = []

    init() {
        panel = DesktopPanel(size: Metrics.size)
        panel.setFrameOrigin(Self.savedOrigin() ?? Self.defaultOrigin())

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.keepOnScreen() }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                if self.panel.occlusionState.contains(.visible) {
                    self.onBecameVisible?()
                }
            }
        })
    }

    func setContent<V: View>(_ view: V) {
        let host = FirstMouseHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: Metrics.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    /// Where the widget is on screen (the playlist picker opens beside it).
    var frame: NSRect { panel.frame }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }

    /// Light or Dark for the whole window, so the glass, text and symbols all follow the
    /// widget's glass style rather than the system appearance.
    func setAppearance(for style: GlassStyle) {
        panel.appearance = NSAppearance(named: style == .light ? .aqua : .darkAqua)
    }

    // MARK: Dragging

    func dragChanged() {
        guard !UserDefaults.standard.bool(forKey: Prefs.lockPosition) else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            dragStart = (mouse: mouse, origin: panel.frame.origin)
        }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(
            x: start.origin.x + mouse.x - start.mouse.x,
            y: start.origin.y + mouse.y - start.mouse.y
        ))
    }

    func dragEnded() {
        guard dragStart != nil else { return }
        dragStart = nil
        keepOnScreen()
        let origin = panel.frame.origin
        UserDefaults.standard.set(Double(origin.x), forKey: Prefs.originX)
        UserDefaults.standard.set(Double(origin.y), forKey: Prefs.originY)
    }

    // MARK: Placement

    private func keepOnScreen() {
        let frame = panel.frame
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func savedOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Prefs.originX) != nil,
              defaults.object(forKey: Prefs.originY) != nil else { return nil }
        let origin = NSPoint(x: defaults.double(forKey: Prefs.originX),
                             y: defaults.double(forKey: Prefs.originY))
        let frame = NSRect(origin: origin, size: Metrics.size)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) } ? origin : nil
    }

    /// Top-left of the main display, where macOS places new desktop widgets.
    private static func defaultOrigin() -> NSPoint {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.minX + 24, y: visible.maxY - Metrics.size.height - 24)
    }
}
