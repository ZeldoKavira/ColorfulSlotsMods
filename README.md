# Colorful Slots Mods

A mod loader for [Colorful Slots](https://store.steampowered.com/app/4526100/), plus the mods
built on it. Works on a stock installation — **no game file is modified**, so a Steam update
cannot undo it and nothing needs re-applying afterwards.

## Install

1. Download `ColorfulSlotsMods-<version>.zip` from
   [Releases](https://github.com/ZeldoKavira/ColorfulSlotsMods/releases).
2. Extract it into the game folder, next to `game.exe`
   (Steam → right click the game → Manage → Browse local files).
3. Launch. The window title reads **Colorful Slots (Modded)** when the loader is running.

To uninstall, delete `override.cfg` and the `mods` folder.

## What you get

| | |
|---|---|
| **Auto slot** | Uses the slot for you while you have coins. `F2` toggles it. |
| **Settings panel** | `F1`. Lists loaded mods, toggles auto slot, sets the pause between rolls. |
| **Rebindable** | Both hotkeys take a key name or joypad buttons, in `[hotkeys]`. On a Steam Deck the back grip buttons are the ones to use — unbound by default, and Godot sees them as joypad buttons 16-19. |
| **Borderless fullscreen** | The game requests *exclusive* fullscreen, which switches your display to its own window size and centres the image. This makes it borderless at your native resolution. |
| **Correct scaling** | The shipped `stretch/scale_mode` is `integer`, which only scales in whole multiples. Set to `fractional` so the image fills the screen. |
| **V-sync** | Stated explicitly. No game script touches it, so the project setting is the only thing deciding it. |
| **Controller bindings** | Adds joypad buttons to the game's existing actions, including tab switching, which is what reaches the slots screen. Keyboard and mouse bindings are untouched. |

Everything is configurable in `mods/config.cfg`, and the parts worth changing mid-game are on
the `F1` panel. Changes you make in game are saved to `user://mod_settings.cfg` rather than
back into the game folder, which is often read-only — under Program Files, or on a Deck.

## How it works

Godot resolves `res://` against the real filesystem beside the executable when a path is not
inside the game's pack. So `override.cfg` can register an autoload pointing at
`res://mods/loader.gd` — a script that was never exported with the game — and the loader takes
it from there. Steam replaces `game.exe` and `game.pck` on an update and leaves added files
alone, which is why this survives updates.

Mods change the game by **extending its own classes**:

```gdscript
extends "res://scene/Field.gd"      # the game's real class, straight out of the pack

func _process(delta: float) -> void:
    super(delta)                    # keep what the game did
    # ... then add to it
```

The loader loads that script, checks it really derives from the script it claims to replace,
and calls `take_over_path()` so the subclass *becomes* the resource at the vanilla path. Every
later load of that path returns the mod's class. The game builds its own scenes as usual and
gets the modified behaviour without knowing anything happened.

See [MODDING.md](MODDING.md) to write one.

## What this repo does not contain

No game files, and no recompiled game bytecode. Everything here is original work that runs
alongside the game. Two smaller fixes — the default screen-scale step, and a space between
large numbers and their `K`/`M`/`B` suffix — live in the game's own autoloads, which are
constructed before any loader can reach them. Doing those means patching the pack directly,
which would mean redistributing the developer's compiled scripts, so they are deliberately
left out.

## Licence

MIT — see [LICENSE](LICENSE). This is an unofficial fan project with no affiliation with the
developers of Colorful Slots.
