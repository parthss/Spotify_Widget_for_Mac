# mediaremote-adapter (vendored)

Source: https://github.com/ungive/mediaremote-adapter
Version: v0.7.7 (commit e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6)
Licence: BSD 3-Clause, see [LICENSE](LICENSE).

Glass Player uses it to read and control macOS's system-wide Now Playing (the media
panel in Control Center), so the widget also works with players that don't support
AppleScript, such as Mornye. Since macOS 15.4 only Apple-signed programs may use the
private MediaRemote framework, so the adapter is loaded into Apple's own `/usr/bin/perl`.

Only the files needed to build the adapter framework are included. Left out: the test
client, the `test` command (`src/adapter/test.m`, which needs the test client and isn't
used by Glass Player) and the project's build files. The included files are unmodified. `build.sh`
compiles them with Apple's `clang` into
`Glass Player.app/Contents/Frameworks/MediaRemoteAdapter.framework`, and copies
`bin/mediaremote-adapter.pl` into the app's Resources.

To update: replace these files with the same paths from a newer tag, update the
version above, then review the diff.
