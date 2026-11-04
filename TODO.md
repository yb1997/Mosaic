# To-do

Open items for Mosaic, roughly in priority order. Last updated 2026-11-04,
after the 1.2.0 release.

## Next release

- [ ] **Release 1.2.1.** `main` has an unpushed fix (`3420607`: linked lock
  tiles showed "Same as desktop" twice), listed under Unreleased in
  CHANGELOG.md. Bump to 1.2.1 and run `./scripts/release.sh v1.2.1`, or wait
  and ship it with the next feature release as 1.3.0.

## Not yet verified

- [ ] **Screen-change debounce.** Plugging in or waking a monitor should
  re-apply wallpapers once, 300 ms after the notifications stop
  (`WallpaperEngine`). Not seen happen on a real monitor change yet.

## Improvements

- [ ] **Unique profile names.** Two profiles can share a name; block or flag
  duplicates when saving or renaming.
- [ ] **Tests and CI.** No test target yet. Start with `isNewerVersion`,
  decoding older `state.json` / `profiles.json`, `activeProfile` matching,
  which files image cleanup keeps (including pending undo and imports in
  progress). Add a GitHub Action running `xcodebuild test`.
- [ ] **Logging.** Replace `NSLog` with `os.Logger` (subsystem
  `in.ybear.Mosaic`, categories for engine, lock swap, updater, imports).

## Features

- [ ] **Tile context menu.** Use on All Screens, Swap Desktop ↔ Lock, Copy to
  another screen, Show in Finder.
- [ ] **Shortcuts / App Intents.** A "Switch to Profile" intent, usable from
  Shortcuts, Spotlight and Focus filters.
- [ ] **Profile per monitor setup.** Remember a profile for each set of
  connected screens and switch when that set reconnects.
- [ ] **Rotate from a folder.** A slot can point at a folder and change every
  N minutes, on wake, or daily.
- [ ] **Scaling per image.** Fill / Fit / Center / Stretch; currently always
  fill-and-crop.
- [ ] **Disconnected screens.** Saved entries for screens that aren't
  connected are invisible; list them in Settings so they can be cleared.

## Drop shelf limits

- [ ] Shows at most four screens; more would need scrolling.
- [ ] A Lock Screen tile set to "Same as desktop" doesn't accept a drop. Could
  turn the switch off and use the image, or drop it on the desktop.

## Housekeeping

- [ ] `scripts/build-dmg.sh` uses `hdiutil create`, which macOS reports as
  deprecated; move to `diskutil image create` when convenient.
- [ ] Old DMGs and zips in the project folder (1.0.0, 1.1.0 and WallpaperChanger
  builds, ~10 MB) are git-ignored and can be deleted.

## Decided, not doing

- Undo lasts until the panel closes or the next change, so an old Undo doesn't
  linger and keep its image on disk. Making it last until the next change only
  is a one-line change in `MenuContent` if wanted.
- Dropping onto the menu panel itself can't work: it closes as soon as another
  app is clicked, and on macOS 26 the app can't open it mid-drag. Hence the
  drop shelf on the menu bar icon.
