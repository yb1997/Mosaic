# Lock screen spikes (macOS 27.2, 2026-11-03)

Build either one with `swiftc -O <file>.swift -o <name>`. The test images
(not committed) were copies of `Red Orange.png` and `Electric Blue.png` from
`/System/Library/Desktop Pictures/Solid Colors/`.

## lockspike.swift: separate `Idle` image (doesn't work)
Writes a `com.apple.wallpaper.choice.image` choice into the `Idle` slot of
`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`, then
restarts WallpaperAgent.
- WallpaperAgent keeps the change, but `Idle` is only the screen saver. The
  lock screen still shows the `Desktop` wallpaper.
- Image choice format that WallpaperAgent accepts:
  `Configuration = bplist {type: imageFile, url: {relative: file://…}}`,
  `Files = [{relative: file://…}]`.
- `Type` takes one of: `linked` (one `Linked` choice for both desktop and
  screen saver), `individual` (separate `Desktop` and `Idle`), or `desktop`.
- `show` prints the displays with their UUIDs and the current choices.
  `restore <backup>` puts a saved Index.plist back.

## lockswap.swift: swap the desktop at lock time (works)
Listens for the `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`
distributed notifications. On lock it calls
`NSWorkspace.setDesktopImageURL(_:for:options:)` for each screen. On unlock it
writes back the saved settings file and restarts WallpaperAgent.
- Confirmed by eye: on lock, the built-in screen showed orange and the LG
  showed blue, so each screen gets its own lock image.
- In `lockswap.log`, the swap finished in the same second the screen locked.
- Not checked yet: whether the old wallpaper flashes before the swap, what
  happens with "Show on all Spaces" and multiple Spaces, and the FileVault
  login screen after a restart (it is not covered by this approach).
