# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **MAJOR**: changes that break existing setups, such as a saved-settings
  format that needs migrating or a higher minimum macOS version.
- **MINOR**: new features that keep existing setups working.
- **PATCH**: bug fixes only.

## [Unreleased]

### Changed
- An error in the panel (such as an image that couldn't be copied) now has a
  close button, and goes away when the panel closes instead of staying until
  a later pick succeeds.
- The same image picked for several screens, or as both desktop and lock
  screen, is now stored once. Copied images are named by a hash of their
  contents. Images already stored keep their names.

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

[Unreleased]: https://github.com/yb1997/Mosaic/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/yb1997/Mosaic/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/yb1997/Mosaic/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/yb1997/Mosaic/releases/tag/v1.0.0
