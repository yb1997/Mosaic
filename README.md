# Wallpaper Changer

A small macOS menu bar app that sets a desktop image and a separate lock
screen image for each connected screen.

- Click a tile in the menu bar panel to pick an image; the × clears it.
- A screen with no lock screen image shows its desktop image when locked.
  "Lock screen same as desktop" does the same while keeping the chosen lock
  image for when it's turned off.
- Settings… has Open at Login (`SMAppService`).
- Runs on notifications only (lock/unlock, Space change, wake, screen
  changes), with no polling. Previews are downsampled with ImageIO.
- UI uses SwiftUI Liquid Glass (`.glassEffect`, `.buttonStyle(.glass)`).

How the lock screen works, and the private pieces it needs, are described in
[docs/PRIVATE_APIS.md](docs/PRIVATE_APIS.md). The experiments behind it are in
[Spikes/](Spikes/README.md).

## Install
1. Download `WallpaperChanger-<version>.zip` from
   [Releases](https://github.com/yb1997/WallpaperChanger/releases), unzip it,
   and move `WallpaperChanger.app` to `/Applications`.
2. The app is ad-hoc signed, not notarized, so macOS blocks the first launch
   of a downloaded copy. Either allow it in System Settings → Privacy &
   Security → Open Anyway, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/WallpaperChanger.app
   ```
3. Open it, then turn on Settings… → Open at Login.

Changes are listed in [CHANGELOG.md](CHANGELOG.md). Versions follow
[Semantic Versioning](https://semver.org).

## Release
1. Move the `[Unreleased]` notes in `CHANGELOG.md` under the new version.
2. Set `MARKETING_VERSION` in `project.yml`, and bump `CURRENT_PROJECT_VERSION`.
3. Build, zip, tag and publish:
   ```bash
   xcodegen generate
   xcodebuild -project WallpaperChanger.xcodeproj -scheme WallpaperChanger -configuration Release -derivedDataPath build clean build
   ditto -c -k --keepParent build/Build/Products/Release/WallpaperChanger.app WallpaperChanger-X.Y.Z.zip
   git tag -a vX.Y.Z -m "Wallpaper Changer X.Y.Z" && git push origin vX.Y.Z
   gh release create vX.Y.Z WallpaperChanger-X.Y.Z.zip --title "Wallpaper Changer X.Y.Z" --notes-file <notes>
   ```

## Build
Requires macOS 26+, Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project WallpaperChanger.xcodeproj -scheme WallpaperChanger -derivedDataPath build build
open build/Build/Products/Debug/WallpaperChanger.app
```

To check the menu panel layout without clicking the menu bar, run a Debug
build with `-snapshotMenu out.png`, and add `-fakeDisplays N` to pretend there
are N screens:

```bash
build/Build/Products/Debug/WallpaperChanger.app/Contents/MacOS/WallpaperChanger -snapshotMenu /tmp/menu.png -fakeDisplays 4
```

Images and settings live in `~/Library/Application Support/WallpaperChanger/`.
