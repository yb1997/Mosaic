# To-do

Open items for Mosaic, roughly in priority order. Last updated 2026-11-05,
after adding scaling.

## Not yet verified

- [ ] **Screen-change debounce.** Plugging in or waking a monitor should
  re-apply wallpapers once, 300 ms after the notifications stop
  (`WallpaperEngine`). Not seen happen on a real monitor change yet.
- [ ] **1.3.0 and 1.4.0 changes in the app.** Covered by unit tests but not yet tried by
  hand: × on a desktop tile shows the default wallpaper (on every Space), the
  error close button, and the duplicate-name note in both name fields.
- [ ] **Tile context menu.** Store actions are unit-tested; the menu itself
  (items enabled at the right times, Show in Finder) not yet tried by hand.

- [ ] **Fade between wallpapers.** Checked with a harness on the built-in
  display (2026-11-05): the overlay matches macOS for all four scalings
  (Center with small, large, wide and tall images), stays under widgets and
  app windows, and crossfades. Still to see by eye: a fade on an external
  display with its desktop visible, the fade on arriving at a Space that
  missed a change (and a Space switch mid-fade), and whether the
  450 ms wait for WallpaperAgent (`WallpaperFade.agentDelay`) is enough for
  very large images (6K HEIC).

## Improvements

_All done for now._

## Features

- [ ] **Shortcuts / App Intents.** A "Switch to Profile" intent, usable from
  Shortcuts, Spotlight and Focus filters.
- [ ] **Profile per monitor setup.** Remember a profile for each set of
  connected screens and switch when that set reconnects.
- [ ] **Rotate from a folder.** A slot can point at a folder and change every
  N minutes, on wake, or daily.
- [ ] **Video wallpapers.** Built (design in `docs/VIDEO_WALLPAPERS.md`);
  store, encoder and cleanup are unit-tested, and playback on the LG was
  checked in the debug build (2026-11-06). Still to try by hand: picking and dropping a
  video on a tile (and from Photos), the progress ring and × to stop it, the
  Video submenu (frame rate, quality, Use Default, greyed options once the
  original is gone), Pause Videos, the Settings section, fades to and from a
  video. Checked in the app: it pauses at once behind a full-screen app
  (0 % CPU) and holds no power assertions. Also unchecked: Stage Manager,
  "click wallpaper to reveal desktop", monitor changes, lock and sleep.
- [ ] **Video wallpaper follow-ups.** Not built yet: the Still frame submenu
  (the still is always about 1 s in), playing the video in its tile on hover,
  and hiding frame rates above the source's.
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
