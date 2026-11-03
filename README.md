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
