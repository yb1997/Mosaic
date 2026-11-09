# Private and undocumented things this app relies on

The app is not sandboxed and is not meant for the Mac App Store. Everything
below can break with any macOS update. Check it after each major release.
Last verified on macOS 27.2 (2026-11-03).

| What | Where | Why | If it breaks |
| :--- | :--- | :--- | :--- |
| Reads and writes `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` | `SystemWallpaperStore` | Snapshot before a lock swap; put it back on unlock. NSWorkspace can't set Photos pictures, aerials or dynamic wallpapers back. | After unlock, a screen with only a lock image keeps showing it, or shows the default wallpaper. |
| Writes every `Displays/<id>` and `Spaces/*/Displays/<id>` entry in `Index.plist` to an aerial choice (`{assetID}`), or back to an image | `SystemWallpaperStore.setAerial` / `setImage`, `LockScreenVideos` | Lock screen video: the lock screen plays the screen's wallpaper only if it is an aerial. Writing only the top-level entry is undone: the agent copies the current Space's choice back on start. | The lock screen shows the still frame, or the video stops on some Spaces. |
| SIGSTOP, write, SIGKILL `WallpaperAgent`; SIGTERM `WallpaperAerialsExtension` | `SystemWallpaperStore.write`, `restore` | The agent saves its own copy of `Index.plist` now and then; pausing it stops a save landing between our write and the restart. | A lock video doesn't take, or takes only after the next restart. |
| Adds assets to `~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json`, and to the `AerialManifestLocalPathOverride` file when `AerialManifestForceLocal` is set (Native Aerials sets it); copies videos to `aerials/videos/<id>.mov`, thumbnails to `aerials/thumbnails/<id>.png` | `AerialCatalog` | Makes a Mosaic video an aerial the agent can show. **A category whose `representativeAssetID` names a missing asset makes the extension reject the whole catalog** (`ManifestDecodingError`): every aerial fails and the lock screen falls back to Golden Gate. `rebuildCategory` and `hasValidCategory` guard this; launch and wake mend it. | Lock screen videos show Golden Gate or a still; check the extension log (`/usr/bin/log show --predicate 'process == "WallpaperAerialsExtension"'`, category `aerial-assets`). |
| Sets `AerialManifestForceLocal` and `AerialManifestLocalPathOverride` in `com.apple.wallpaper.aerial` to `aerials/mosaic/entries.json`, unless another app's override is in place | `AerialCatalog.claimOverride` | With no override the aerials extension loads the catalog in its own bundle and can't find a Mosaic asset. Removed again when no lock videos are left. | Lock screen videos show Golden Gate; the extension logs `Loading fallback manifest (…: none)`. |
| Writes every `Idle` choice of a screen without a lock video to its picture while another screen plays one | `SystemWallpaperStore.setScreenSaver`, `LockScreenVideos` | A Mac that locks after sitting idle shows `Idle`, not the desktop choice. | That screen shows its old screen saver on an idle lock. |
| `kVTCompressionPropertyKey_BaseLayerFrameRate` (public, but AVAssetWriter refuses it for HEVC) | `VideoEncoder.encodeAerial` | Without a temporal base layer the aerial player fails as it slows to a stop at unlock (`VideoSampleReadingErrors Code=4`): the next lock is black and the desktop gray. | Same symptoms; re-check with a two-lock test. |
| `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` distributed notifications | `WallpaperEngine` | The lock screen shows the desktop wallpaper, so we swap it while the screen is locked. Undocumented, but widely used and stable for years. | Lock screen images never appear. |
| `AppleIconAppearanceTheme` global default (`RegularAutomatic`, `RegularDark`, `ClearLight`, `TintedDark`…) and `NSWorkspaceIconAppearanceConfigurationDidChangeNotification` | `IconAppearance` in `SettingsView.swift` | Settings' sidebar icons follow the icon style in System Settings → Appearance (Default, Dark, Clear, Tinted). No public API exposes it. Run with `-AppleIconAppearanceTheme TintedDark` to try a style without changing the system. | The icons stay in the Default colours whatever style is chosen. |

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
- `Idle` is the screen saver. A lock you start shows `Desktop`/`Linked`, but a
  lock after sitting idle starts the screen saver first and shows `Idle`
  (see `docs/LOCK_SCREEN_VIDEO.md`).
- An image choice: `Provider = com.apple.wallpaper.choice.image`,
  `Configuration = bplist {type: imageFile, url: {relative: file://…}}`,
  `Files = [{relative: file://…}]`.
