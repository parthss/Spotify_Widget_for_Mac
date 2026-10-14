# Glass Player

A Spotify now-playing widget for your Mac desktop, made of Liquid Glass.

- **Lives on the desktop layer**, like Apple's widgets: behind your app windows, above the wallpaper, on every Space. It stays put during Mission Control and Show Desktop, never steals focus, and has no Dock icon.
- **Liquid Glass** on macOS 26 and later (a frosted blur on macOS 14–15).
- **Three glass styles**: Light, Dark, or Tinted by Album Art. A **translucency slider** sets how see-through the glass is, so you can match it to your other widgets.
- **Live**: updates the moment Spotify changes song or play state.
- **Controls**: volume, shuffle, previous, play/pause, next, repeat, share. Drag the progress bar to seek.
- **Buttons in Apple's style**, like Control Center's media controls: a soft highlight under the pointer, a spring when you click, and SF Symbols animations (play and pause morph into each other, Next and Previous nudge forward and back, the others bounce). Shuffle and repeat show a solid circle when on, and the speaker's waves fill with the volume.
- **＋ button, like Spotify's**: saves the song to Liked Songs (it morphs into a green check), then lets you choose playlists instead (or as well).
- **Click the album art** to open Spotify.
- **Right-click it** for: Open Spotify, Copy Song Link, Add to Playlist, Glass (style and translucency), Dim When Using Other Apps, Lock Position, Open at Login, Hide, Quit.

## Install

You need macOS 14 or later, the Spotify desktop app, and Apple's Command Line Tools (or Xcode). For Liquid Glass you need macOS 26+ and Command Line Tools / Xcode 26+.

```bash
xcode-select --install      # skip if you already have Xcode or the Command Line Tools
git clone https://github.com/parthss/SpotifyWidget4Mac.git
cd SpotifyWidget4Mac
./build.sh
```

No git? Click **Code › Download ZIP** on this page, unzip it, open Terminal in that folder and run `bash build.sh`.

The script compiles the app, signs it for your Mac, installs it as `~/Applications/Glass Player.app` and launches it. The widget appears at the top-left of your main display.

The first time it talks to Spotify, macOS asks whether **Glass Player** may control **Spotify**. Click **Allow**. If you clicked Don't Allow, the widget says so; its gear button opens **System Settings › Privacy & Security › Automation**, where you can switch it on.

To keep the widget after a restart, turn on **Open at Login** from its menu.

## Glass

Right-click the widget › **Glass** and pick a style:

- **Light**: white glass with dark text.
- **Dark**: dark glass with white text.
- **Tinted by Album Art**: glass coloured by the current album cover, with white text. The colour fades to the next cover's when the song changes.

Light and Dark stay as you set them, even when your Mac switches between light and dark mode. Until you choose one, the widget starts in whichever your Mac is using.

To set how see-through the glass is, right-click › **Glass** › **Translucency…**. A panel opens beside the widget with the three styles and a **Translucency** slider: 0% is solid, 100% is plain glass (the look of earlier versions; Tinted keeps a hint of its colour), and 50% is the default. The widget changes as you drag, so you can match it to the widgets next to it. **Reset** returns to 50%; **Done**, Esc or clicking elsewhere closes the panel. Your choice is saved straight away.

## The ＋ button (Liked Songs and playlists)

It works like the ＋ in Spotify:

1. Click **＋** and the song is saved to **Liked Songs**. The button turns into a green check and "Added to Liked Songs · Change" appears for a few seconds.
2. Click the **green check** (or **Change**) to open **Add to playlist**: search your playlists, tick or untick Liked Songs and any playlist, make a **New playlist**, then press **Done**. Nothing changes until you press Done; Cancel, Esc or clicking elsewhere closes it.

### One-time setup

Saving songs isn't possible through Spotify's Mac scripting, so this part uses Spotify's Web API, which needs a free developer app on your account. Since February 2026 Spotify only allows this for accounts with **Premium**.

The first time you click ＋, the widget shows these steps:

1. Open the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard), log in, and click **Create app**. Any name and description will do.
2. Under **Redirect URIs** add exactly `http://127.0.0.1:45893/callback`, tick **Web API**, accept the terms and **Save**.
3. Open the app's **Settings**, copy the **Client ID**, paste it into the widget and click **Connect**.
4. Your browser opens Spotify's permission page. Click **Agree**, and the browser shows "All set". The picker then lists your playlists.

Glass Player keeps the sign-in in your login keychain. You stay connected for as long as Spotify allows (currently about six months); after that the widget asks you to connect again. To disconnect, right-click the widget › **Disconnect Spotify Account**.

### If something goes wrong

- **"INVALID_CLIENT: Invalid redirect URI"** in the browser: the Redirect URI in your Spotify app doesn't match `http://127.0.0.1:45893/callback` exactly (it must be `127.0.0.1`, not `localhost`).
- **"Spotify refused the request" / "user not registered"**: in your Spotify app's settings, open **User Management** and add the email address of your Spotify account.
- **"Couldn't start the local sign-in listener"**: another program is using port 45893. Sign-in stops before anything is sent to Spotify; quit that program (or restart your Mac) and try again.
- **macOS asks to allow access to the keychain** right after you rebuild: click **Always Allow**. The rebuilt app has a new signature, so macOS checks again. If that prompt appears when you haven't just rebuilt, click **Deny** and rebuild (see [SECURITY.md](SECURITY.md)).
- **macOS asks whether Glass Player may accept incoming connections**: you shouldn't see this, because the sign-in listener only accepts connections from your own Mac. If you do, click **Deny**.

## Security

Read [SECURITY.md](SECURITY.md) for what the app can access, how sign-in and tokens are protected, and commands to check it yourself. In short:

- **Signed with the Hardened Runtime**, which blocks code injection.
- **Talks only to Spotify**, over HTTPS.
- **No incoming connections**, except a 127.0.0.1-only listener that runs for a few minutes while you connect Spotify.
- **Tokens are protected**: kept in your keychain or in memory, never in logs or URLs.

For a stricter build, `./build.sh --sandbox` also turns on App Sandbox.

## Using it

| Action | How |
| --- | --- |
| Move | Drag anywhere on the glass (except the buttons). The position is remembered. |
| Seek | Click or drag on the progress bar. |
| Volume | Click the speaker, then drag. It slides back to the controls after a few seconds. |
| Save a song | Click ＋. Click the green check to choose playlists. |
| Open Spotify | Click the album art. |
| Glass style | Right-click › Glass › Light, Dark or Tinted by Album Art. |
| Translucency | Right-click › Glass › Translucency…, then drag the slider. |
| Options | Right-click (or Control-click) anywhere on the widget. |
| Hide | Right-click › Hide Widget. Open Glass Player again (Spotlight, Finder) to bring it back. |
| Quit | Right-click › Quit Glass Player. |

## How it works

Playback goes through the Spotify desktop app directly, using macOS scripting: no login needed for that part. Spotify broadcasts a notification whenever the song or play state changes, and the widget also checks every 2 seconds to catch shuffle, repeat, volume and seeking done in the Spotify window.

Liked Songs and playlists go through the Spotify Web API (sign-in with PKCE, so no client secret is stored). The picker checks which of your playlists already contain the song as you scroll, and remembers it until a playlist changes, so it never adds a song twice.

The window is a borderless panel placed just above the desktop-icon layer, set to appear on all Spaces and to ignore Mission Control, which is what makes it behave like a built-in desktop widget.

**Why not a real WidgetKit widget?** System widgets can only refresh a limited number of times per day, so a now-playing widget built that way lags behind the music. A small app drawing a widget-style glass panel on the desktop layer looks and behaves the same, and updates instantly.

## Limitations

- **The ＋ button needs Spotify Premium** and the one-time setup above.
- **Very long playlists** (over 5,000 songs) aren't checked for the current song, so their tick starts empty.
- **Repeat is on/off.** Scripting can't select repeat-one.
- **Only the Spotify app on this Mac.** When you play to another device over Spotify Connect, Spotify sometimes stops reporting song details to scripts; the widget then shows "Spotify is playing".
- After you rebuild, macOS may ask for the Spotify and keychain permissions again, because the app's signature changed.

## Customising

- Size, corner radius and artwork size: `Metrics` in `Sources/Support.swift`.
- Glass colours and the default translucency: `GlassLook` in `Sources/Support.swift`. The Glass panel: `Sources/GlassPanel.swift`.
- Layout and controls: `Sources/WidgetView.swift`. The playlist picker: `Sources/PlaylistPicker.swift`.
- Rebuild with `./build.sh` after any change.

## Uninstall

Right-click › Disconnect Spotify Account, revoke access at [spotify.com/account/apps](https://www.spotify.com/account/apps/), then right-click › Quit Glass Player (turn off Open at Login first if you enabled it), then:

```bash
rm -rf ~/Applications/"Glass Player.app"
defaults delete local.glassplayer
tccutil reset AppleEvents local.glassplayer
rm -rf ~/Library/Containers/local.glassplayer   # only if you built with --sandbox
```

You can also delete the developer app from the Spotify Developer Dashboard.

## Licence

MIT. See [LICENSE](LICENSE).

Glass Player isn't made or endorsed by Spotify. Spotify is a trademark of Spotify AB.
