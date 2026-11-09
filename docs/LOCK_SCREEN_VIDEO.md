# Video on the lock screen

**Built** (unreleased, after 1.5.0) and working on macOS 27.2: tested on the
built-in screen on 2026-11-07, playing, looping and surviving unlock. An idle
lock was confirmed on 2026-11-08: the built-in screen played the video and the
LG, with no video of its own, showed its picture. The investigation and spikes
that led here follow below.

## How Mosaic does it
- **What plays:** a screen's lock slot video, or its desktop video when the
  lock screen has nothing of its own or is "same as desktop"
  (`ScreenWallpapers.lockVideo`).
- **Lock copy:** `VideoEncoder.encodeAerial` re-encodes the stored video
  upright, at most 3840 px, to HEVC Main 10 with `BaseLayerFrameRate` at half
  the frame rate, SDR BT.709, as `<stem>-aerial.mov` next to it in `Images`.
- **Catalog:** `AerialCatalog` clones that into `aerials/videos/<id>.mov`
  with a PNG thumbnail and lists it in a "Mosaic" category in the manifest and
  the override catalog. `<id>` is a name-based UUID of the stored video and
  the scaling, so registering is idempotent.
- **Override:** the extension only sees a custom asset through an override
  (bug below). With none set, Mosaic makes `aerials/mosaic/entries.json` from
  the current catalog and sets `AerialManifestForceLocal` and
  `AerialManifestLocalPathOverride` to it. It uses another app's override if
  one is in place, and removes its own once it has no lock videos. While
  Mosaic's override is on, the list of Apple's aerials doesn't update.
- **Screens without a video:** while any screen plays one, the others' `Idle`
  choices become their lock picture on every Space, so an idle lock matches
  the menu. What was there is saved, and comes back when the last video stops.
  Changing such a screen's picture restarts WallpaperAgent (every screen
  flashes). `Spaces/<id>/Default` entries aren't touched.
- **System wallpaper:** `LockScreenVideos.update` writes the aerial into every
  entry for the screen in `Index.plist` and restarts WallpaperAgent, only
  when something changed and never while locked. What the screen had before
  is saved first (by entry, in the `lockVideoWallpapers` default). Stopping
  writes the screen's Mosaic picture back into every entry, or the saved
  wallpaper if it has none. Unused Mosaic assets are removed afterwards.
- **Desktop:** the engine leaves those screens alone (no `setDesktopImageURL`,
  no lock swap) and Mosaic's window shows the desktop video or picture over
  the aerial's still frame (`VideoScreen` shows pictures too).
- **Repair:** on launch and wake Mosaic re-reads which screens show its
  aerials and mends a catalog it left invalid.

## Bug found 2026-11-08: no override, no custom aerials
Native Aerials' override was on during all the earlier testing. Once it was
gone (about 23:15 on 2026-11-07) the extension logged
`Loading fallback manifest (AerialManifestLocalPathOverride: none)` and never
`Loading downloaded manifest`. Every Mosaic aerial then failed with
`WallpaperAerialsExtensionError (0)` and the lock screen showed Golden Gate,
even though `manifest/entries.json` listed the asset. The extension's built-in
catalog (`Contents/Resources/entries.json`) doesn't. Pointing the override at
a copy of the manifest stopped the failures at once, so Mosaic now sets one.

## Bug found in testing: one bad category breaks every aerial
After the lock video changed, the old asset was removed but the Mosaic
category still named it as `representativeAssetID`. The aerials extension
then refused the whole catalog (`Unable to load initial aerial manifest:
ManifestDecodingError`, "No aerial categories found"), every aerial failed
(`WallpaperAerialsExtensionError (0)`) and the lock screen showed Golden
Gate. The category is now rebuilt on every change and checked before saving.

The extension also logs "Re-downloading 1 in-use video(s) whose URL changed"
and fails to "download" the `file://` URL; the file stays and the wallpaper
loads, so this is harmless.

## Spike run 2 (2026-11-06, same clip as HEVC with a base layer): works
- Re-encoded with `Spikes/aerialenc.swift`: HEVC Main 10 (`hvc1`), 10-bit,
  1920×1080, 24 fps, 12 Mbps, `BaseLayerFrameRate` 12 (half the frame rate),
  key frame every 1 s, BT.709, no audio. 82 s, 94 MB.
- Two lock and unlock cycles on the built-in screen. Both played. Both unlocks
  ramped down cleanly (no `Code=4`), and the desktop kept a still of the video.
- So 1080p and 24 fps are fine; 4K and 240 fps aren't needed. The base layer
  is what matters.
- Encoding: `AVAssetWriterInput` throws for `BaseLayerFrameRateFraction` with
  `hvc1`. The hardware encoder rejects the fraction too (-12900) unless
  low-latency rate control is on, but accepts the absolute
  `kVTCompressionPropertyKey_BaseLayerFrameRate`. Mosaic's `VideoEncoder`
  (AVAssetWriter) would need a VTCompressionSession path for the aerial copy.
- `aerialspike set` now writes every Space's entry; Mosaic was quit.
- Still untested: the LG (per-display aerials), sleep and wake while locked,
  looping past the clip's end (82 s), and a 30/60 fps source.

## Spike run 1 (2026-11-06, 1080p 24 fps H.264, built-in screen)
- **It played on the lock screen.** The agent took a plain 1920×1080 H.264
  `.mov` in `videos/<id>.mov`, with no re-encode. The desktop showed a still
  frame of it, as expected.
- **It broke on unlock.** At unlock the aerial player slows the video to a
  stop ("beginRampingDown"), then failed with
  `WallpaperExtensionKit.VideoSampleReadingErrors Code=4`. It reset and
  flushed its layers, so the next lock was black ("Play Called" but never
  started) and the desktop went plain gray. A WallpaperAgent restart, or a
  restore, clears it.
  - Cause: the slow-down needs a temporal base layer. Run 2 confirmed it.
- **The choice must be written in every Space.** `Index.plist` has
  `Spaces/<space>/Displays/<display>/Desktop` for each Space (25 here) as well
  as the top-level `Displays/<display>`. Writing only the top-level one is
  undone the moment the agent starts: it copies the current Space's image
  back, even for a real Apple aerial. Writing all 21 Space entries for the
  display made it stick. `aerialspike set` now does this.
- **Mosaic fights it.** It reapplies its images on screen-parameter and Space
  changes and swaps the desktop at lock, so it was quit for the run. The real
  feature has to stop calling `setDesktopImageURL` on a screen whose
  wallpaper is an aerial.
- **Native Aerials kept the entry.** Adding the video to `aerials/videos` and
  both catalogs didn't lose it in the following minutes.
- Debugging tip: in zsh, `log` is a builtin. Use `/usr/bin/log show
  --info --predicate 'process == "WallpaperAerialsExtension"'`; the
  `com.apple.wallpaper:video-player` category shows play, pause and errors.

## Summary
- The lock screen can't show Mosaic's video window. It is WallpaperAgent's
  picture.
- But WallpaperAgent animates **aerial** wallpapers on the lock screen by
  itself. On the desktop an aerial is a still frame, so it costs nothing there.
- So the way in is to register the video as a custom aerial asset and make it
  the screen's desktop choice in `Index.plist`. Every open-source app that does
  this works the same way.
- Mosaic's own video window keeps playing on the desktop, on top of it.

## Open-source references

| Project | How | Notes |
| :--- | :--- | :--- |
| [LivePaper](https://github.com/Raunik2/LivePaper) (MIT) | Copies the video unchanged to `aerials/videos/<UUID>.mov` and a 480 px thumbnail to `aerials/thumbnails/<UUID>.png`. Adds its own category and asset to `aerials/manifest/entries.json`. Points every entry in `Index.plist` at `{assetID: <UUID>}`. Clears the agent's `.bmp` cache. Runs `killall WallpaperAgent`. | Claims Tahoe only. No transcode. |
| [AerialMotion](https://github.com/imsachink/AerialMotion) (MIT) | Same files. Re-encodes to HEVC Main10, 3840×2160 letterboxed, 18 Mbps, with the base layer at half the frame rate. Backs up `entries.json` once. Rebuilds the whole `Index.plist` and drops keys it doesn't know. Runs `killall -9 WallpaperAgent WallpaperAerialsExtension`. | Sonoma/Sequoia. One real Apple aerial must be downloaded first, or the lock screen is black. The most invasive of the four. |
| [macos-screensaver-deployer](https://github.com/feebbass/macos-screensaver-deployer) (MIT) | Overwrites an Apple aerial's `.mov` (`4C108785-…`) in place, then `pkill WallpaperAgent`. | README only. A crude approach. |
| [Customized Aerial Screen Saver](https://github.com/FalconLee1011/Customized-Aerial-Screen-Saver) (no license) | Edited `/Library/Application Support/com.apple.idleassetsd/Customer/entries.json` as root. | Its README says it's broken since Tahoe. That folder is now nearly empty here. Don't copy code (no license). |
| [Native Aerials](https://git.hloth.dev/hloth/native-aerials) (MIT, **installed on this Mac**) | Doesn't add videos. It merges Apple's Golden Gate and Tahoe sets into one time-of-day aerial. Sets `defaults write com.apple.wallpaper.aerial AerialManifestForceLocal -bool true` and `AerialManifestLocalPathOverride = …/aerials/custom/entries.json`, then writes that file as a patched copy of `manifest/entries.json`. | Its LaunchAgent rebuilds the file whenever `aerials/videos`, `aerials/manifest` or the app changes. It refuses to run if the override points elsewhere. |
| [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) (MIT) | A different approach: puts an `NSWindow` in a private SkyLight space at absolute level 400 (`…NotificationCenterAtScreenLock`), using `SLSSpaceCreate`, `SLSSpaceSetAbsoluteLevel`, `SLSShowSpaces` and `SLSSpaceAddWindowsAndRemoveFromSpaces`. | **Rejected.** Level 400 is above the lock UI (300), so a full-screen video would cover the clock and the password field. It has no sleep or display-change handling, and it crashes on a missing symbol. |

## What's on this Mac (macOS 27.2)
- The old `/Library/Application Support/com.apple.idleassetsd/Customer/` has
  no videos any more. Aerials live per user in
  `~/Library/Application Support/com.apple.wallpaper/aerials/`:
  - `videos/<assetID>.mov`
  - `thumbnails/<assetID>.png`
  - `manifest/entries.json`, unpacked from `manifest.tar`, which comes from
    `sylvan.apple.com`
  - `custom/`, written by Native Aerials
- WallpaperAgent and WallpaperAerialsExtension contain the strings
  `AerialManifestForceLocal`, `AerialManifestLocalPathOverride` and
  `AerialManifestURLOverride`. They also contain the log line
  "AerialManifestForceLocal is set; skipping downloaded manifest". That's a
  real switch in Apple's code, not a guess.
- **Edits to `manifest/entries.json` alone are ignored**, with or without an
  override (see the 2026-11-08 bug). LivePaper and AerialMotion would silently
  fail on this Mac.
- Apple's aerials are HEVC Main 10 (`hvc1`), 3840×2160, 240 fps, BT.709, about
  12 Mbps, 5 min, around 450 MB each.
- An aerial choice in `Index.plist` is
  `Provider = com.apple.wallpaper.choice.aerials`,
  `Configuration = bplist {assetID: <UUID>}`, `Files = []`. Today it only sits
  in the `Idle` (screen saver) slot. A lock you start (⌃⌘Q, the menu) shows
  `Desktop` or `Linked`, not `Idle` (`Spikes/README.md`), so the video has to
  go there.
- **But a Mac that locks after sitting idle shows `Idle`** (found
  2026-11-07). loginwindow starts the screen saver ("starting screen saver due
  to user idle") just before the lock, WallpaperAgent gets an `idle` assertion
  with `contentType: screenSaver`, and each screen keeps showing its `Idle`
  choice through the lock. A `linked` screen shows its one `Linked` choice
  either way; an `individual` one showed its old screen saver (Tahoe Night)
  instead of the video. So Mosaic writes the aerial into every `Idle` of an
  `individual` screen too, saves what was there first (by entry, in the
  `lockVideoScreenSavers` default), and puts it back when the video stops,
  unless the screen saver was changed in System Settings meanwhile.

## Proposed design (if the spike works)
1. **On import**, also write the video as an aerial:
   - `aerials/videos/<id>.mov`, where `<id>` is a UUID derived from the stored
     file's hash.
   - The still as `thumbnails/<id>.png`.
   - An asset in a "Mosaic" category in the catalog the agent actually reads.
     That's the override path if `AerialManifestForceLocal` is set, otherwise
     `manifest/entries.json`.
   - A hard link or APFS clone of Mosaic's stored `.mov` would avoid a second
     copy.
2. **The screen's persistent desktop choice becomes that aerial**, in place of
   today's still-frame `setDesktopImageURL`. Mosaic's playback window covers
   it on the desktop, and the lock screen plays it.
   - "Same as desktop" then needs no lock-time swap.
   - A different lock-screen video per screen is just a different `assetID` per
     display.
   - This has to be a planned `Index.plist` write plus a WallpaperAgent
     restart, done when the wallpaper changes. Not at lock time:
     `setDesktopImageURL` can't pick an aerial, and restarting the agent while
     the screen locks would race the lock and flash.
3. **On unset or cleanup**, remove the asset, video and thumbnail, and set the
   still image back.
4. **Re-check on launch and wake.** Put the entry back if Apple's manifest
   refresh or Native Aerials' rebuild dropped it. None of the reference apps
   do this.

Side effects to accept:
- Quitting Mosaic, the Spaces bar and Mission Control would show the aerial's
  still frame, not Mosaic's still. They should look the same if the thumbnail
  is the still.
- Each video restarts WallpaperAgent once, so every screen flashes briefly.

## Unknowns the spike must answer
- Does a local `file://` URL in `url-4K-SDR-240FPS` play, or does the agent
  only look at `videos/<assetID>.mov`? The spike writes both.
- Format: does Mosaic's 30 fps, 8-bit HEVC (or H.264) play on the lock screen
  and loop cleanly? Or does it need Main10, 240 fps, or a specific size? Try
  Mosaic's encoder output first.
- Does the agent need the thumbnail, or a cache reset (LivePaper deletes the
  `.bmp` cache and resets `cacheVersion.db`)?
- Does it play per display (a different `assetID` on the LG and the built-in
  screen)?
- **Native Aerials coexistence.** Its LaunchAgent watches `aerials/videos`, so
  adding a video triggers a rebuild of `custom/entries.json` from the
  manifest. Does an entry added to both files survive that? If not, options:
  - write only to the manifest and let Native Aerials carry it over;
  - ask the user to turn Native Aerials off;
  - use Mosaic's own override, which Native Aerials refuses to share.
- Does Apple's periodic manifest refresh (`manifest.tar` from sylvan) wipe
  added entries when no override is set?
- What does unlock look like, and do lock, sleep and wake keep playing?
- Not covered: the FileVault login screen after a restart. That's a pre-boot
  picture, not the agent's.
- Disk: the data disk was 95 % full on 2026-10-22, and videos here are big.
  Linking rather than copying matters.

## Running the spike (needs you to lock the Mac)
```
swiftc -O Spikes/aerialspike.swift -o /tmp/aerialspike
/tmp/aerialspike show
/tmp/aerialspike add ~/Movies/clip.mov        # prints <assetID>, backs up first
/tmp/aerialspike set <assetID> --display 37D8832A-2D66-02CA-B9F7-8F30A301B230
# lock with ⌃⌘Q, watch, unlock
/tmp/aerialspike restore ~/backups/aerialspike-<stamp>   # once per backup, newest first
```
