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

# Video wallpaper spike (macOS 27.2, 2026-11-05)

## videospike.swift: looping video in a desktop-level window (works)
`./videospike <video> [seconds]` puts one borderless, click-through window per
screen at `desktopWindow + 1` (the fade overlay's level), with
`[.canJoinAllSpaces, .stationary, .ignoresCycle]`, and plays the video muted
in an `AVPlayerLayer` through `AVQueuePlayer` + `AVPlayerLooper`. It quits by
itself after `seconds` (default 20).
- Test clip: 10 s, 3840×2160, 30 fps HEVC, made with
  `ffmpeg -f lavfi -i "testsrc2=size=3840x2160:rate=30,hue=H=2*PI*t/10" -t 10
  -c:v hevc_videotoolbox -b:v 20M -tag:v hvc1 -pix_fmt yuv420p clip.mp4`.
  Without `-tag:v hvc1` AVFoundation may refuse HEVC in MP4.
- Played on the built-in display and an LG 4608×2592 at once; the translucent
  menu bar on both picked up the video's colours.
- Cost on AC, M4 Pro: the spike used 1.4–2.3 % CPU and `top` power 1.7–2.4,
  27 MB. WindowServer was about 48 % during the run and 60 % right after
  without it (YouTube was open), so no visible extra compositing cost.
- With `preventsDisplaySleepDuringVideoPlayback = false` the spike holds no
  power assertion (`pmset -g assertions`). It defaults to true.
- Checked by eye on 2026-11-05 (screenshots with `screencapture`, keys sent
  with computer use):
  - Desktop icons and widgets draw over the video on both screens; a click on
    the desktop goes through to Finder.
  - Space switch (Ctrl+→ and back): the video slides with the Space on both
    sides of the slide, so neither Space ever shows the system picture. The
    window reports occluded during the slide and visible after it.
  - Mission Control: the video stays full size behind the window thumbnails
    (it is not shrunk like the desktop picture) and keeps playing. The Spaces
    bar is tinted by it. Occlusion doesn't change.
  - Full-screen app (TextEdit): the covered screen reports occluded until the
    app leaves full screen, so pausing on occlusion works. The spike doesn't
    pause, so its CPU stayed at about 1.3 %.
  - Show Desktop (F11): windows move to the edges; video and icons stay.
- Not checked: Stage Manager and "click wallpaper to reveal desktop" (both off
  on this Mac), a screen-parameter change, lock and sleep. The lock screen is
  WallpaperAgent's picture, so it can't show a window.
