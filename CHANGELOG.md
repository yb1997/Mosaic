# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **MAJOR**: changes that break existing setups, such as a saved-settings
  format that needs migrating or a higher minimum macOS version.
- **MINOR**: new features that keep existing setups working.
- **PATCH**: bug fixes only.

## [Unreleased]

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

[Unreleased]: https://github.com/yb1997/WallpaperChanger/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/yb1997/WallpaperChanger/releases/tag/v1.0.0
