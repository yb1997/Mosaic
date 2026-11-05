# Video wallpapers: design

Built 2026-11-05, apart from the follow-ups listed in TODO.md (the Still
frame submenu, hover playback, hiding frame rates above the source). How playback was tested is in
`Spikes/README.md` (`videospike.swift`).

## Playback
- One borderless, click-through window per screen at `desktopWindow + 1` (the
  fade overlay's level), on every Space
  (`[.canJoinAllSpaces, .stationary, .ignoresCycle]`), playing the video muted
  through `AVQueuePlayer` + `AVPlayerLooper` in an `AVPlayerLayer`.
- `preventsDisplaySleepDuringVideoPlayback = false` (it defaults to true).
- Underneath, the video's still frame is set with `setDesktopImageURL`, so
  Mission Control's Spaces bar, the lock-time swap and quitting Mosaic all show
  a matching picture. `pendingChanges()` works against that still unchanged.
- Pauses, with no setting, when the window is occluded (full-screen apps),
  when the Mac is locked or asleep, and in Low Power Mode. "Pause on battery
  power" is a setting, off by default. A "Pause videos" button shows in the
  panel's bottom row while any video is set.
- Scaling: Fill, Fit and Stretch map to `videoGravity`; Center sizes the layer
  to the video's natural size.
- Fades: a change to or from a video fades the video window in or out.

## Interface
- No image/video mode: a Desktop tile takes either, decided by the file. The
  open panel and drops accept movies (`.mov`, `.mp4`, `.m4v`). "Choose image or
  video…". Error for anything else: "It isn't an image or a video."
- A video tile shows its still frame with a play badge and the duration
  (▶ 0:12) top-left; it may play muted on hover.
- Lock Screen is images only (it's WallpaperAgent's picture, not windows).
  - "Same as desktop" with a video desktop shows the still, with a note under
    the screen: "Lock screen shows a still from the video."
  - A video dropped on the Lock Screen tile is refused: "The lock screen can
    only show images."
  - "Swap desktop and lock screen" is disabled when it would put a video on
    the lock screen.
- Tile menu additions: a "Still frame" submenu (default about 1 s in, since
  first frames are often black) and a "Video" submenu:
  - Frame rate: 24, 30, 60 fps, Original (shows the source rate, e.g.
    "Original (120 fps)"). Rates above the source are hidden.
  - Quality: Smaller, Balanced, High, Original. Original keeps the source's
    video track untouched, so it also forces Original frame rate.
  - Use default.
  - A footer line with the stored size and resolution, e.g. "45 MB · 4608×2592".
- Settings, new "Videos" section: default Frame rate (30 fps) and Quality
  (Balanced), Pause on battery power, and the total stored ("Wallpapers use
  340 MB", Show in Finder). Footer: "New videos use these settings. Change one
  screen's video from its tile's menu."

## Storage
On import (and when a screen's video settings change):
1. Keep only the video track. Drop audio, subtitles, timecode and metadata.
2. Re-encode to HEVC with VideoToolbox constant quality when it saves space:
   - long side no larger than the biggest connected screen, and at least 3840;
   - frame rate as chosen, never above the source;
   - quality: Smaller 0.5, Balanced 0.65, High 0.75 on AVFoundation's
     `AVVideoQualityKey` scale (measured below; worth re-checking on real
     nature footage);
   - HDR sources stay 10-bit with their colour metadata; others 8-bit.
3. Copy the source's track as it is when Quality is Original, or when
   re-encoding wouldn't make it smaller. For a video longer than 20 s, 10 s
   from the middle are encoded first; if that sample's bit rate is at least
   90 % of the source's, the full re-encode is skipped. A 16-minute slide
   video at 153 kbps took 97 s to re-encode and came out 6× bigger; with the
   trial it took 1.7 s (the sample came out at 506 kbps). A screen recording
   that does shrink (61 → 15 MB) took about 3 s longer. Every re-encode is
   still compared with the source's track afterwards, in case the trial
   guessed wrong.
4. Write the still frame next to it as `<name>.heic`.

Measured on a 28 s HEVC 3024×1964 120 fps screen recording (61 MB, with AAC
audio). First with ffmpeg's `hevc_videotoolbox` as a stand-in:

| Output | Size | SSIM vs. source |
| :--- | ---: | :--- |
| Video track only | 60 MB | identical |
| HEVC q65, 60 fps | 45 MB | 0.991 |
| HEVC q65, 30 fps | 27 MB | 0.991 |
| HEVC q50, 60 fps | 16 MB | 0.974 |

Then with Mosaic's own encoder (`VideoEncoder`, AVAssetWriter), at the
source frame rate so frames line up for SSIM:

| `AVVideoQualityKey` | Size | SSIM vs. source |
| :--- | ---: | :--- |
| 0.5 | 5.5 MB | 0.973 |
| 0.6 | 11 MB | 0.987 |
| 0.7 | 27 MB | 0.995 |
| 0.75 | 33 MB | 0.996 |

### Naming and the original file
- Stored files are named after a hash of the source plus the settings:
  `<source sha256>-<fps>-<quality>.mov`. The source is hashed before encoding,
  so picking the same video with the same settings reuses the stored file
  without re-encoding.
- Each video keeps a bookmark to its original file (`URL.bookmarkData()`; the
  app isn't sandboxed, so no security scope), so a screen's settings can be
  raised later by re-encoding from the original. If the bookmark no longer
  resolves (or the file's hash changed), options above the stored copy are
  disabled: "Choose the video again to use a higher setting." Lowering a
  setting always works from the stored copy.
- The original is never modified, and no full copy of it is kept.
- Each screen saves the settings its video was encoded with (in
  `ScreenWallpapers`, so profiles bring them back). Changing the default in
  Settings doesn't re-encode existing videos.
- Cleanup of unused files also removes a video's `.heic` still and its bookmark.

### Import progress
Re-encoding takes seconds (about 10–20 s for the clip above with ffmpeg;
AVFoundation's hardware decode should be faster). The tile shows a ring and
"Optimizing… 42%"; × cancels; closing the panel doesn't. When a screen's
settings change, the old video keeps playing until the new one is ready, then
fades over. Undo works as for images.

## Not checked yet
Stage Manager, "click wallpaper to reveal desktop", monitor changes, lock and
sleep (see `Spikes/README.md`).
