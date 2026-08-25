# Writing a mod for Colorful Slots

A mod can override any method of any of the game's scripts. It is not a config file and it is
not limited to values the loader happens to expose - it is the game's own class with your
code in front of it.


## How It Works

The game's scripts live inside game.pck, but they can still be extended, because a GDScript
can inherit from one by path:

    extends "res://scene/Field.gd"

The loader loads your script, checks it really does derive from the one it claims to replace,
and then calls take_over_path() so your subclass becomes the resource living at the vanilla
path. From that moment every load of that path returns your class. The game builds its own
scenes exactly as before and gets your version without knowing anything changed.

Nothing is written into game.pck, so a Steam update cannot undo any of this.


## Making One

Create a folder under mods/ with a mod.cfg:

    mods/
      my_mod/
        mod.cfg
        FieldExt.gd

mod.cfg:

    [mod]
    name="My mod"
    description="What it does"
    enabled=true

    [extensions]
    "res://scene/Field.gd"="FieldExt.gd"

FieldExt.gd:

    extends "res://scene/Field.gd"

    func _timer_set() -> void:
        super()                      # keep what the game did
        # ... then change what you want

Restart the game. mods/auto_slot is a real, working example of exactly this - it extends
the slot machine scene and adds auto-play in about a dozen lines.


## The Rules That Matter

Call super() unless you deliberately mean to replace the original behaviour entirely. Skipping
it silently removes whatever the game did in that method, and the symptom usually appears
somewhere else entirely.

The extends path must match the target in mod.cfg exactly. The loader refuses to install a
mismatch rather than substituting an unrelated class, because that failure otherwise surfaces
much later as a missing method.

Mods load in folder-name order. If two mods extend the same script, the later name ends up
outermost, wrapping the earlier one. Both still run, in that order.


## What You Can Extend

Anything the game loads after the loader starts: every scene and every class.

    res://scene/Field.gd            the slot machine
    res://scene/Lobby.gd            the lobby and its tabs
    res://scene/Title.gd            the title screen
    res://scene/All_inTab.gd        res://scene/RelicTab.gd
    res://scene/VipTab.gd           res://scene/UpgradeSlot.gd
    res://scene/ScoreLabel.gd       res://scene/end_chip.gd
    res://scene/Key.gd
    res://script/class/Slot1.gd     res://script/class/Slot2.gd
    res://script/class/Upg.gd       res://script/class/UpgTree.gd
    res://script/class/Member.gd    res://script/class/PlayerStat.gd
    res://script/class/Info.gd      res://script/class/CustomButton.gd
    res://script/class/RewardLabel.gd


## What You Cannot Extend

The five autoloads the game registers itself:

    Data  Setting  Sound  Demo  Steamworks

Godot applies override.cfg by appending autoloads after the ones baked into the pack rather
than reordering them, so those five are already built by the time the loader runs and their
scripts are resolved. Reaching them needs the loader registered ahead of them, which needs the
pack's project.binary rebuilt, which needs its file index - and this game's index is
encrypted.

You can still change their *behaviour* from a script you do control, because they are
globals: Data.stat, Setting.focus and so on are all reachable and writable from any extension.


## What The Loader Offers

    ModLoader.get_setting(section, key, default)   read from mods/config.cfg
    ModLoader.set_setting(section, key, value)     write and save
    ModLoader.get_loaded_mods()                    array of folder names

Use get_setting for anything a player might want to tune, and it can be driven from the F1
panel instead of a text file.

Read defaults from mods/config.cfg, but never expect an edit there to persist: it is a shipped
file and an update replaces it. set_setting writes to user://mod_settings.cfg, which is layered
over the defaults at load and survives updating. If your mod has a setting a person will
realistically want to change, give it a control on the panel rather than a line in a file they
will lose.


## Adding New Files

Art, audio and data that the game does not already have can ship as a .pck placed in mods/;
the loader mounts any it finds. This cannot be used to *replace* an existing game file - the
game references its resources by uid://, and that mapping lives in the encrypted index, so a
replacement at the same path never gets reached. Replacing behaviour is what extensions are
for.


## Debugging

There is no console in a release build. The loader writes what it did to:

    Windows          %APPDATA%\Colorful_Slots\mod_loader.log
    Deck / Proton    steamapps/compatdata/4526100/pfx/drive_c/users/steamuser/
                     Application Data/Colorful_Slots/mod_loader.log

Note the Proton path is `Application Data`, not `AppData/Roaming` - the latter does not exist
in the prefix, so checking there finds nothing whether or not the loader ran.

It records every extension installed and every one it refused, with the reason. If a mod does
nothing, read that file first - a rejected extension is named there.
