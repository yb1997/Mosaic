# To-do

Open items for Mosaic, roughly in priority order. Last updated 2026-11-04,
after the 1.4.0 release.

## Not yet verified

- [ ] **Screen-change debounce.** Plugging in or waking a monitor should
  re-apply wallpapers once, 300 ms after the notifications stop
  (`WallpaperEngine`). Not seen happen on a real monitor change yet.
- [ ] **1.3.0 and 1.4.0 changes in the app.** Covered by unit tests but not yet tried by
  hand: × on a desktop tile shows the default wallpaper (on every Space), the
  error close button, and the duplicate-name note in both name fields.
- [ ] **Tile context menu.** Store actions are unit-tested; the menu itself
  (items enabled at the right times, Show in Finder) not yet tried by hand.

## Improvements

_All done for now._

## Features

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

_All done for now._

## Decided, not doing

- Undo lasts until the panel closes or the next change, so an old Undo doesn't
  linger and keep its image on disk. Making it last until the next change only
  is a one-line change in `MenuContent` if wanted.
- Dropping onto the menu panel itself can't work: it closes as soon as another
  app is clicked, and on macOS 26 the app can't open it mid-drag. Hence the
  drop shelf on the menu bar icon.
