# Glass Player security

Glass Player is about 3,900 lines of Swift that you compile yourself from this folder. The build uses only Apple's own tools: no third-party code, nothing downloaded, no `sudo`. The app has no telemetry. It talks to two things only: the Spotify app on your Mac and Spotify's servers.

## What it can access

| Access | Why | Who grants it |
| --- | --- | --- |
| Control the Spotify app (Apple Events) | Read what's playing; play, pause, skip, shuffle, repeat, volume | You, when macOS asks the first time. Revoke in System Settings › Privacy & Security › Automation. |
| Your Liked Songs and playlists | The ＋ button | You, on Spotify's consent page, and only if you connect. |
| One keychain item, "Glass Player – Spotify sign-in" | Staying connected | Created when you connect; removed when you disconnect. |
| Open at Login | Optional | Only if you switch it on. |

It does **not** ask for Accessibility, Screen Recording, Input Monitoring, Full Disk Access, Contacts, Location, Camera, Microphone or an administrator password, and it can't control any app other than Spotify without macOS asking you.

## Network

**Outgoing**, HTTPS only, to:

- `accounts.spotify.com` (sign-in and token refresh)
- `api.spotify.com` (Liked Songs and playlists)
- `*.scdn.co` and `*.spotifycdn.com` (cover images)

All connections use ephemeral sessions, so nothing, cover art included, is cached on disk.

**Incoming**: none in normal use. Only while you're connecting your Spotify account (five minutes at most), a small listener waits for Spotify's reply on `127.0.0.1:45893`. It:

- is bound to the loopback interface, so other computers can't reach it;
- drops any connection that isn't from this Mac;
- takes at most 16 connections, 10 seconds each, and reads at most 16 KB per request;
- accepts exactly one reply, and only one carrying this sign-in's secret `state`;
- echoes nothing back, and serves a page that can't load or run anything (strict `Content-Security-Policy`, `no-referrer`, `no-store`).

The browser is opened only after the listener actually holds that port. If another program already holds it, sign-in stops and nothing is sent to Spotify.

## Sign-in and tokens

- **OAuth 2.0 authorization code with PKCE (S256).** There is no client secret. The code Spotify returns is useless without a verifier that never leaves the app.
- **State check.** A random 32-character `state` is compared in constant time. Replies without it are ignored, so a web page or another app can neither complete, hijack nor cancel your sign-in.
- **Cancel and disconnect stop everything in flight.** Late responses are discarded.
- **Access token**: held in memory only, for at most an hour.
- **Refresh token**: kept in your login keychain, in an item Glass Player creates itself. It is never written into an existing item, so it can't land in one another program planted.
- **Tokens never appear** in URLs, logs or on screen.
- **Requested permissions (scopes)**: `user-library-read`, `user-library-modify`, `playlist-read-private`, `playlist-read-collaborative`, `playlist-modify-private`, `playlist-modify-public`. Glass Player can't see your email, payment details, account settings or listening history, and it doesn't control playback through Spotify's servers.
- **Disconnect** (right-click the widget) removes the token from this Mac. To revoke access on Spotify's side as well, go to [spotify.com/account/apps](https://www.spotify.com/account/apps/) and click **Remove access** next to your app. You can also delete the app in the Spotify Developer Dashboard.
- **Expiry**: Spotify ends the sign-in on its own after about six months.

## Untrusted input

- **AppleScript**: the scripts are fixed text, and only clamped numbers are ever inserted. The app never runs shell commands.
- **What Spotify reports** (which can include a local file's tags) is read as a list, length-limited and range-checked. Song and playlist IDs must be plain base-62 before they go into an API path or a link.
- **Images** are only downloaded:
  - over HTTPS, from Spotify's image servers (checked again after any redirect);
  - up to 8 MB, counted while downloading;
  - in common bitmap formats (JPEG, PNG, WebP, HEIC, GIF);
  - and are decoded straight to a small thumbnail.
- **Opened URLs**: the app only opens fixed addresses: Spotify's sign-in page, the Developer Dashboard, Spotify's download page and the Automation settings.
- **Settings** (glass style, translucency, position) are checked when read, so a hand-edited value can't break the widget.

## Hardening

- **Hardened Runtime** blocks code injection: `DYLD_*` variables, unsigned libraries, debugger attach. Its only exception is permission to send Apple Events.
- **No URL schemes and no App Transport Security exceptions.**
- **Optional App Sandbox**: `./build.sh --sandbox` confines the app to its own container. It can then reach only the network, the loopback listener, and Apple Events to Spotify; it can't read your files. I couldn't test this build on a Mac. If Spotify control stops working with it, rebuild without `--sandbox`.

## Check it yourself on your Mac

```bash
codesign -dv --entitlements - ~/Applications/"Glass Player.app"
```
Expect `flags=0x10002(adhoc,runtime)`. The only entitlement should be `com.apple.security.automation.apple-events`, plus the sandbox keys if you built with `--sandbox`.

```bash
lsof -nP -iTCP -sTCP:LISTEN | grep -i glass
```
Normally this prints nothing. While you're connecting Spotify it shows `127.0.0.1:45893`. If it shows `*:45893` instead, the listener still rejects connections from other computers, but it's bound more widely than intended.

```bash
nettop -p GlassPlayer
```
Shows its live connections. You should see only Spotify's hosts. Little Snitch or LuLu work too.

In **Keychain Access**, search for "Glass Player": you'll find one item, which you can inspect or delete.

## Keychain prompts after rebuilding

The app is signed only for your Mac (ad-hoc), so every rebuild changes its signature, and macOS asks again before it reads the keychain item. Click **Always Allow** only right after you've run `build.sh` yourself. If a prompt appears out of the blue, click **Deny** and rebuild from this folder: something else may have modified the app.

## What's left (residual risk)

- **Not sandboxed by default.** It runs with your user account's rights, like most Mac apps outside the App Store. Injection is blocked and all input is checked, but for containment use `--sandbox`.
- **Ad-hoc signed and not notarized.** That's normal for an app you compile yourself, and you can read every line. macOS doesn't run its Gatekeeper check on apps you build locally.
- **Keychain access.** Anyone using your unlocked Mac account can read keychain items in Keychain Access. That's true of every app.
- **Who reviewed it.** The code was reviewed by its author and then audited by an independent reviewer who hadn't written it. It hasn't had a professional penetration test.
