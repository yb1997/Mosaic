# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **MAJOR**: changes that break existing setups, such as a saved-settings
  format that needs migrating or a higher minimum macOS version.
- **MINOR**: new features that keep existing setups working.
- **PATCH**: bug fixes only.

## [Unreleased]

## [1.1.0] - 2026-11-03

### Added
- In-app updates: Wallpaper Changer checks GitHub once a day (at launch and
  after waking) and shows a banner in the menu panel when a new version is out.
  Install downloads it, checks that it's signed by the same developer and is
  newer, replaces the app and restarts it. Settings → Updates has Check Now and
  a switch to turn automatic checks off.
- DMG installer: drag Wallpaper Changer to Applications.

### Changed
- Releases are signed with a stable local certificate instead of ad-hoc, which
  is what lets an installed copy accept the next version as an update.
  Version 1.0.0 was ad-hoc signed, so it can't update itself: install 1.1.0 by
  hand once.

## [1.0.0] - 2026-11-03

### Added
- Menu bar app with no Dock icon, for macOS 26 and later.
- A desktop image and a lock screen image for each connected screen. Screens
  are recognised by display UUID, so plugging monitors in or out doesn't mix
  them up.
- Lock screen images are shown by swapping the desktop wallpaper while the Mac
  is locked, and restored on unlock (see `docs/PRIVATE_APIS.md`).
- "Lock screen same as desktop" switch for each screen. The chosen lock image
  is kept for when it's turned off.
- Menu panel tiles: click to choose an image, × to clear. With more than three
  screens the list scrolls.
- Settings window with Open at Login.
- Liquid Glass controls and app icon.
- Wallpapers are re-applied after switching Spaces, waking, and screen changes.
  The app does nothing in between.

[Unreleased]: https://github.com/yb1997/WallpaperChanger/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/yb1997/WallpaperChanger/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/yb1997/WallpaperChanger/releases/tag/v1.0.0
