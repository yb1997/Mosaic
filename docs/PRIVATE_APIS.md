# Private and undocumented things this app relies on

The app is not sandboxed and is not meant for the Mac App Store. Everything
below can break with any macOS update. Check it after each major release.
Last verified on macOS 27.2 (2026-11-03).

| What | Where | Why | If it breaks |
| :--- | :--- | :--- | :--- |
| Reads and writes `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` | `SystemWallpaperStore` | Snapshot before a lock swap; put it back on unlock. NSWorkspace can't set Photos pictures, aerials or dynamic wallpapers back. | After unlock, a screen with only a lock image keeps showing it, or shows the default wallpaper. |
| `killall WallpaperAgent` | `SystemWallpaperStore.restore` | Makes the agent reload `Index.plist`. launchd restarts it on demand. | The restored wallpaper shows up late (at the next login). |
| `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` distributed notifications | `WallpaperEngine` | The lock screen shows the desktop wallpaper, so we swap it while the screen is locked. Undocumented, but widely used and stable for years. | Lock screen images never appear. |

## Public APIs with surprising limits
- `NSWorkspace.setDesktopImageURL(_:for:options:)` only changes the current
  Space and turns off "Show on all Spaces". The engine re-applies on
  `activeSpaceDidChangeNotification`, which arrives only after the Space has
  slid in, so a Space that missed a change shows the old picture for a moment
  and then fades. Writing every Space into `Index.plist` would avoid that, but
  the agent only reloads it on `killall WallpaperAgent`, which flashes every
  screen.
- `NSWorkspace.desktopImageURL(for:)` can't describe Photos or aerial
  wallpapers. In the sandboxed test build, it led to the Golden Gate default
  being set back on unlock. That's why a non-sandboxed `Index.plist` snapshot
  is used instead.

## Index.plist format (as seen on macOS 27.2)
- Top-level keys: `AllSpacesAndDisplays`, `Displays`, `Spaces`, `SystemDefault`.
- Each entry has a `Type`: `linked` (one `Linked` choice for both desktop and
  screen saver), `individual` (separate `Desktop` and `Idle` choices), or
  `desktop`.
- `Idle` is the screen saver, not the lock screen (see `Spikes/README.md`).
- An image choice: `Provider = com.apple.wallpaper.choice.image`,
  `Configuration = bplist {type: imageFile, url: {relative: file://…}}`,
  `Files = [{relative: file://…}]`.
