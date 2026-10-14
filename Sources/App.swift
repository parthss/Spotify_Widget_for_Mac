import AppKit
import SwiftUI

// Glass Player is an agent app: no Dock icon and no menu bar, just the widget on your desktop.
@main
enum GlassPlayerMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
            withExtendedLifetime(delegate) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var spotify: SpotifyController?
    private var focus: DesktopFocus?
    private var account: SpotifyAccount?
    private var library: LibraryController?
    private var picker: PlaylistPickerController?
    private var glassPanel: GlassPanelController?
    private var widget: WidgetWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        GlassLook.registerDefaults()

        let spotify = SpotifyController()
        let focus = DesktopFocus()
        let account = SpotifyAccount()
        let library = LibraryController(account: account)
        let picker = PlaylistPickerController(account: account, library: library)
        let glassPanel = GlassPanelController(spotify: spotify)
        let widget = WidgetWindowController()
        widget.setAppearance(for: GlassLook.savedStyle) // before the first frame, so it never flashes

        library.openPickerHandler = { [weak picker, weak widget] in
            guard let picker, let widget else { return }
            picker.open(near: widget.frame)
        }
        library.togglePickerHandler = { [weak picker, weak widget] in
            guard let picker, let widget else { return }
            picker.toggle(near: widget.frame)
        }

        widget.setContent(WidgetView(spotify: spotify, focus: focus, library: library,
                                     window: widget, glassPanel: glassPanel))
        widget.onBecameVisible = { [weak spotify, weak library] in
            spotify?.refresh()
            library?.refreshSavedState()
        }
        widget.show()
        spotify.start()

        self.spotify = spotify
        self.focus = focus
        self.account = account
        self.library = library
        self.picker = picker
        self.glassPanel = glassPanel
        self.widget = widget
    }

    // Opening the app again (Spotlight, Finder, Launchpad) brings a hidden widget back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        widget?.show()
        return false
    }
}
