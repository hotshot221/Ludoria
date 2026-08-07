# Ludoria Nexus

**Your entire game library, summoned like a superpower.** Press one key and a
fullscreen acrylic carousel fades in over whatever you're doing - pick a game,
press Enter, and Ludoria melts away into the launch. No window to manage, no
app to "open", no waiting.

<p align="center">
  <img src="docs/screenshot-1.png" width="100%">
  <img src="docs/screenshot-2.png" width="100%">
</p>

## Why not Playnite / LaunchBox / Steam Big Picture?

- **It's an overlay, not an app.** Everything else is a windowed program you
  alt-tab to. Ludoria summons and vanishes in-place - F7 or the controller
  Guide button, from anywhere, even mid-desktop.
- **Zero configuration.** Steam, Epic and locally installed games are found
  automatically; official cover/hero/logo art is fetched for you. First run is
  a library, not a setup wizard.
- **Controller-first.** Full couch navigation - stick, d-pad, A/B/X/Y, Guide to
  summon - with keyboard and mouse equally at home.
- **It themes itself per game.** Accent colours are extracted from each game's
  artwork; the glass, the glow, the whole UI re-tints as you browse.
- **Absurdly light.** One AutoHotkey script + one CSV. No database, no account,
  no telemetry, no background bloat - the GPU surface exists only while the
  overlay is on screen.
- **Yours.** The library is a plain `games.csv` you can edit in Notepad. Art is
  a folder of PNGs. Portable folder, copy it anywhere.

## Quick start

1. Install [AutoHotkey v2](https://www.autohotkey.com/).
2. Run `LudoriaNexus.ahk` (or compile with Ahk2Exe for a single .exe).
3. Press **F7** or the controller **Guide** button.

## Controls

| Input | Action |
|---|---|
| Left/Right, wheel, stick, d-pad | Browse |
| Up / Down | Favourites / Library decks |
| Enter / Space / A / click | Launch |
| F / X | Favourite |
| H | Hide from wheel |
| M / Y | Action sheet (rescan, repair art, edit CSV) |
| P / Tab / View | Power tab (hold to confirm) |
| Esc / B | Back / close |

## Files

| Path | What it is |
|---|---|
| `data/games.csv` | Your library - edit directly or via the action sheet |
| `data/art/` | Drop in `Game Name_cover.png` / `_hero.png` / `_logo.png` |
| `sfx/` | UI sounds |

`data/` is created on first run and is intentionally not tracked here.
