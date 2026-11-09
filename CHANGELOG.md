# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **MAJOR**: changes that break existing setups, such as a saved-settings
  format that needs migrating or a higher minimum macOS version.
- **MINOR**: new features that keep existing setups working.
- **PATCH**: bug fixes only.

## [Unreleased]

## [1.6.0] - 2026-11-10

### Added
- Video on the lock screen. A lock screen tile now takes a video too, and a
  screen whose lock screen has nothing of its own (or is set to the same as
  the desktop) plays its desktop video there. macOS only animates aerial
  wallpapers on the lock screen, so Mosaic makes a lock copy of the video
  (HEVC Main 10 with a half-rate base layer, which the lock screen needs to
  pause cleanly at unlock), lists it as a "Mosaic" aerial and makes it that
  screen's system wallpaper on every Space. It becomes that screen's screen
  saver too, since a Mac that locks after sitting idle shows the screen saver
  on the lock screen; the old screen saver comes back when the video stops.
  While a screen plays a video, the other screens' screen savers show their
  lock pictures, so an idle lock matches the menu on every screen. Mosaic also
  points macOS at its own aerial list while it has lock videos, because macOS
  otherwise can't find them and shows Golden Gate.
  Mosaic's own window keeps showing
  the desktop picture or video on top. WallpaperAgent restarts once (every
  screen flashes) when a screen starts or stops playing a lock video, never
  while locked. See docs/LOCK_SCREEN_VIDEO.md.

### Changed
- Swap Desktop and Lock Screen now works with videos.
- The Settings window looks like System Settings: a sidebar with General,
  Videos, Profiles and Updates (the desktop shows through it), and the chosen
  pane beside it, with back and forward buttons (⌘[ and ⌘]). The window can
  be resized and reopens on the last pane. Its sidebar icons follow the icon
  style chosen in System Settings → Appearance: coloured, dark, clear glass
  or tinted.

### Fixed
- The file picker for a wallpaper and the Settings window now come to the
  front with keyboard focus instead of staying among the other app's windows.
  Mosaic shows in the Dock while either is open.
- A settings file that can't be read no longer costs any images: it's kept as
  `<name>.unreadable` and nothing is cleaned up while it's there.
- A video still converting no longer overwrites a profile switch, Undo, Swap
  or Copy made in the meantime.
- Updates are checked again at the next launch or wake after a failed check,
  instead of a day later.
- A full disk can no longer leave a video conversion stuck.
- Picking an image or video for a slot now replaces whatever was still being
  copied or converted for it, and a copy that finishes after a profile switch
  no longer overwrites that profile. Two picks for one slot can't finish out
  of order, and the Undo note says "video" when a video was replaced.
- If macOS's wallpaper settings can't be written, the screen saver choices
  saved for putting back after a lock video are no longer lost.
- Cancelling a video conversion also stops reading the file, and a lock
  screen video that no screen wants any more stops encoding.

### Performance
- Switching Spaces no longer reads macOS's wallpaper settings when no screen
  has a lock video, and restarting WallpaperAgent no longer launches `pgrep`.
- A picture drawn under a lock video is decoded at screen size, not full size
  (about 80 MB less per 6K screen).

## [1.5.0] - 2026-11-06

### Added
- Video wallpapers. A desktop tile takes a video (`.mov`, `.mp4`, `.m4v`) as
  well as an image, picked or dropped; it plays muted on a loop under the
  desktop icons and widgets, on every Space. Its tile shows a still frame
  with a play badge and the length. Videos pause while hidden (under a
  full-screen app), while the Mac is locked or asleep, and in Low Power Mode;
  Pause on Battery Power in Settings pauses them on battery too, and Pause
  Videos in the panel pauses them all. The lock screen can't play video, so
  it shows a still from the video, and a lock screen tile only takes images.
- Videos are stored small: only the video track is kept (no audio or
  subtitles), re-encoded to HEVC at the chosen frame rate (24, 30 or 60 fps,
  or the original) and quality (Smaller, Balanced, High, or Original to keep
  the source's track as it is), and no larger than the screens need. The
  default is 30 fps, Balanced, set in Settings; each screen can use other
  settings from Video in its tile's right-click menu. Mosaic remembers where
  the original file is, so a setting can be raised later while it's there.
  A long video is tried on a 10-second sample first, so one that wouldn't
  get smaller (such as a slide video) isn't re-encoded in full for nothing.
  While a video converts, its tile shows the progress and × stops it.
  Settings shows how much space wallpapers use.
- Scaling for each desktop and lock screen image: Fill Screen (the default,
  as before), Fit to Screen, Stretch to Fill, or Center, from the Scaling
  item in the tile's right-click menu. Fit and Center show black bars;
  Center shows the image at actual size, shrunk only when it is bigger than
  the screen both ways, as macOS does. The
  tile preview shows the chosen scaling. A slot keeps its scaling when its
  image changes; Use on All Screens, Copy to and Swap take it along, and
  profiles save it.
- Wallpaper changes made in Mosaic fade in over half a second instead of
  switching instantly. Turn it off with Fade Between Wallpapers in Settings.
  A Space that still shows the old wallpaper when you switch to it fades to
  the new one instead of snapping (macOS only lets apps change the current
  Space, so it can't be updated before you get there). Waking, locking and
  unlocking stay instant, and so does replacing a wallpaper Mosaic didn't set
  (such as an aerial or a Photos picture), since it can't be redrawn.

## [1.4.0] - 2026-11-04

### Added
- Right-click menu on each tile: Choose Image…, Use on All Screens, Copy to
  another screen, Swap Desktop and Lock Screen, Show in Finder, and Clear.
  Copying a lock screen image turns off "Same as desktop" on the screens it
  goes to. One Undo puts back every screen the change touched.

### Changed
- The updater mounts and ejects the downloaded DMG with `diskutil image
  attach` / `diskutil eject` instead of the deprecated `hdiutil`, which stays
  as a fallback.

## [1.3.0] - 2026-11-04

### Changed
- An error in the panel (such as an image that couldn't be copied) now has a
  close button, and goes away when the panel closes instead of staying until
  a later pick succeeds.
- The same image picked for several screens, or as both desktop and lock
  screen, is now stored once. Copied images are named by a hash of their
  contents. Images already stored keep their names.
- Two profiles can no longer share a name (ignoring case). Saving or renaming
  to a name in use is refused, with a note under the name field.
- Errors are logged with `os.Logger` (subsystem `in.ybear.Mosaic`) instead of
  `NSLog`, including failed update checks and installs.
- Unit tests and a GitHub Actions workflow that runs them. Debug builds no
  longer use the hardened runtime, so the tests can load into the app.
- The DMG is built with `diskutil image create` instead of the deprecated
  `hdiutil create`.

### Fixed
- Clearing a desktop image now puts the macOS default wallpaper on that
  screen. Before, the cleared image stayed on screen even though its file
  could be deleted.
- A Lock Screen tile set to "Same as desktop" no longer shows the words twice
  when the desktop has no image.

## [1.2.0] - 2026-11-04

### Added
- Drag an image onto the menu bar icon to show a drop shelf with every
  screen's tiles, and drop it on one. Works with files from Finder and on the
  icon on every display. (The menu panel itself can't take drops: it closes
  as soon as you click in another app.)
- Undo after clearing or replacing an image: the panel shows what changed with
  an Undo button (⌘Z) until the next change or until the panel closes.

### Changed
- Thumbnails are decoded in the background, so the panel opens without
  waiting on full-size photos. Tiles show a spinner until they're ready.
- Picked images are copied in the background (large files, external drives
  and iCloud files that still need downloading no longer freeze the panel).
  The tile shows a spinner while it copies.
- Plugging in or waking a monitor re-applies wallpapers once, after the
  burst of screen-change notifications settles, instead of once for each.

## [1.1.0] - 2026-11-03

### Added
- Profiles: save every screen's desktop and lock screen images (and the
  "Lock screen same as desktop" switches) under a name, and switch between
  them from the menu at the top of the panel. "Update" saves edits back to the
  profile you last used. Settings has a Profiles section to rename and delete
  them. Profiles are kept in `profiles.json`; `state.json` is unchanged.

## [1.0.0] - 2026-11-03

### Added
- Menu bar app with no Dock icon, for macOS 26 and later.
- A separate wallpaper for each connected screen, plus an optional lock screen
  image per screen. Screens are recognised by display UUID, so plugging
  monitors in or out doesn't mix them up.
- Lock screen images are shown by swapping the desktop wallpaper while the Mac
  is locked, and restored on unlock (see `docs/PRIVATE_APIS.md`).
- "Lock screen same as desktop" switch for each screen. The chosen lock image
  is kept for when it's turned off.
- Menu panel tiles: click to choose an image, × to clear. With more than three
  screens the list scrolls.
- Settings window with Open at Login.
- In-app updates: Mosaic checks GitHub once a day (at launch and after waking)
  and shows a banner in the menu panel when a new version is out. Install
  downloads it, checks that it's signed by the same developer and is newer,
  replaces the app and restarts it. Settings → Updates has Check Now and a
  switch to turn automatic checks off.
- DMG installer: drag Mosaic to Applications. Releases are signed with a
  stable local certificate, so installed copies accept later versions as
  updates.
- Liquid Glass controls and app icon.
- Wallpapers are re-applied after switching Spaces, waking, and screen changes.
  The app does nothing in between.

[Unreleased]: https://github.com/yb1997/Mosaic/compare/v1.6.0...HEAD
[1.6.0]: https://github.com/yb1997/Mosaic/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/yb1997/Mosaic/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/yb1997/Mosaic/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/yb1997/Mosaic/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/yb1997/Mosaic/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/yb1997/Mosaic/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/yb1997/Mosaic/releases/tag/v1.0.0
