# Mod loader for Colorful Slots.
#
# Registered as an autoload by override.cfg. Nothing it needs lives inside game.pck, so a
# Steam update - which replaces game.exe and game.pck and leaves added files alone - cannot
# undo it. It works because Godot resolves res:// against the real filesystem beside the
# executable when a path is not in the pack, which lets an autoload point at a script that
# was never exported with the game.
#
#
# HOW MODS CHANGE THE GAME
#
# A mod supplies a script that extends one of the game's own scripts and overrides whatever
# methods it wants, calling super() where it still wants the original behaviour. The loader
# then hands that script the vanilla script's resource path with take_over_path(), so every
# later load of that path returns the mod's subclass instead. The game instantiates its own
# scenes as usual and gets the modified class without knowing anything happened.
#
# This is the same idea as GodotModLoader's script extensions. That project cannot be used
# here directly: its files reference each other through global class names registered in the
# pack's class cache, and rebuilding that needs the file index, which is encrypted in this
# game. So this is one self-contained script with no class_name and no cross-file references.
#
# Two earlier approaches did not work and are worth not repeating:
#
#   Replacing files through a mounted mod pack. The packs mount and their files genuinely
#   win - res://scene/Title.gdc served the mod's copy - but the game references its scripts
#   by uid://, and the uid to path mapping lives in the encrypted index, so the override
#   never reached the running code.
#
#   Patching game.pck in place. It works, but the index still records each file's original
#   length, so a patched script has to be exactly the same size. That allows changing
#   constants and little else, and an update reverts it.
#
#
# WHAT CANNOT BE EXTENDED
#
# The five autoloads the game registers itself - Demo, Steamworks, Data, Sound, Setting -
# are instantiated before this loader, because override.cfg appends autoloads after the ones
# baked into the pack rather than reordering them. Their scripts are already resolved by the
# time anything here runs. Everything else - every scene and every class - is fair game.

extends Node

const LOG_PATH := "user://mod_loader.log"
const CONFIG_NAME := "config.cfg"
# Changed settings live here, not next to the game, which may be read-only.
const USER_CONFIG := "user://mod_settings.cfg"
const MANIFEST_NAME := "mod.cfg"

var _log: Array[String] = []
var _config := ConfigFile.new()
var _mods: Array[String] = []


func _init() -> void:
	_load_config()
	_mount_packs()
	_install_extensions()


func _ready() -> void:
	_apply_input_bindings()
	_add_panel()
	_write_log()


func _process(_delta: float) -> void:
	_keep_fullscreen_borderless()


func _keep_fullscreen_borderless() -> void:
	# The game asks for EXCLUSIVE_FULLSCREEN, which changes the display mode to its own
	# 640x360-multiple window size - on anything larger than 1080p that means the desktop
	# switches resolution and the image sits centred. Borderless fullscreen covers the screen
	# at its native resolution instead and lets the stretch settings do the scaling.
	#
	# Corrected here rather than in the Setting autoload that requests it, because autoloads
	# registered by the game are built before this loader and cannot be extended. Watching for
	# the mode is equivalent and needs nothing patched into game.pck.
	if not _config.get_value("display", "borderless_fullscreen", true):
		return
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


func _add_panel() -> void:
	# The settings panel is drawn by the loader rather than added to the game's own options
	# screen, because that screen is built by an autoload this loader cannot extend.
	var script: Script = load("res://mods/ui/panel.gd")
	if script == null:
		_log.append("no settings panel found")
		return
	var panel: Node = script.new()
	panel.setup(self)
	get_tree().root.call_deferred("add_child", panel)
	_log.append("settings panel ready (F1)")


func _base_dir() -> String:
	return OS.get_executable_path().get_base_dir().path_join("mods")


# ---------------------------------------------------------------- configuration

func _load_config() -> void:
	# Shipped defaults, from beside the game.
	if _config.load(_base_dir().path_join(CONFIG_NAME)) != OK:
		_log.append("no %s, using defaults" % CONFIG_NAME)

	# Then anything the player has changed, from the writable user directory. Settings are not
	# saved back next to the game because that folder is often not writable - under Program
	# Files, or on a Steam Deck - and a toggle that silently fails to persist is worse than one
	# that is obviously unavailable.
	var overrides := ConfigFile.new()
	if overrides.load(USER_CONFIG) == OK:
		for section in overrides.get_sections():
			for key in overrides.get_section_keys(section):
				_config.set_value(section, key, overrides.get_value(section, key))
		_log.append("player settings loaded from %s" % USER_CONFIG)


# ---------------------------------------------------------------- resource packs

func _mount_packs() -> void:
	# Mod packs are still supported for adding *new* files - art, audio, data. They cannot
	# override the game's existing scripts, for the uid reason described above; use a script
	# extension for that.
	var dir := DirAccess.open(_base_dir())
	if dir == null:
		return
	var packs: Array[String] = []
	for file in dir.get_files():
		if file.get_extension().to_lower() == "pck":
			packs.append(file)
	packs.sort()
	for file in packs:
		if ProjectSettings.load_resource_pack(_base_dir().path_join(file)):
			_log.append("mounted pack %s" % file)
		else:
			_log.append("FAILED to mount pack %s" % file)


# ---------------------------------------------------------------- script extensions

func _install_extensions() -> void:
	var dir := DirAccess.open(_base_dir())
	if dir == null:
		_log.append("no mods directory")
		return

	# Sorted so load order is predictable: if two mods extend the same script, the later name
	# ends up outermost, and a mod can be made to win deliberately rather than by accident.
	var names := dir.get_directories()
	names.sort()

	for mod_name in names:
		var mod_dir := _base_dir().path_join(mod_name)
		var manifest_path := mod_dir.path_join(MANIFEST_NAME)
		if not FileAccess.file_exists(manifest_path):
			continue

		var manifest := ConfigFile.new()
		if manifest.load(manifest_path) != OK:
			_log.append("%s: unreadable %s" % [mod_name, MANIFEST_NAME])
			continue

		if not manifest.get_value("mod", "enabled", true):
			_log.append("%s: disabled" % mod_name)
			continue

		_mods.append(mod_name)
		if manifest.has_section("extensions"):
			for target in manifest.get_section_keys("extensions"):
				_install_one(mod_name, mod_dir, target,
						str(manifest.get_value("extensions", target, "")))


func _install_one(mod_name: String, mod_dir: String, target: String, script_file: String) -> void:
	if script_file.is_empty():
		return

	if not ResourceLoader.exists(target):
		_log.append("%s: no such script to extend: %s" % [mod_name, target])
		return

	# res:// rather than an absolute path, so the extension's own `extends "res://..."` line
	# resolves the same way the engine resolves everything else.
	var ext_path := "res://mods/%s/%s" % [mod_name, script_file]
	var ext: Script = load(ext_path)
	if ext == null:
		_log.append("%s: could not load %s" % [mod_name, script_file])
		return

	# The extension must actually derive from the script it is replacing. Without this check
	# a mistyped target silently substitutes an unrelated class and the failure surfaces much
	# later as a missing method on a node.
	var base: Script = ext.get_base_script()
	if base == null or base.resource_path != target:
		_log.append("%s: %s must extend \"%s\" (found %s)" % [
			mod_name, script_file, target,
			base.resource_path if base != null else "nothing"])
		return

	# The substitution itself: the extension becomes the resource living at the vanilla path,
	# so everything that loads that path from here on gets the subclass.
	ext.take_over_path(target)
	_log.append("%s: extended %s" % [mod_name, target])


# ---------------------------------------------------------------- input

func _apply_input_bindings() -> void:
	# The game binds only keyboard and mouse to several of its actions, which is why parts of
	# it cannot be reached on a controller. These are added to the existing actions, so the
	# keyboard bindings keep working.
	if not _config.has_section("controller"):
		return
	for action in _config.get_section_keys("controller"):
		if not InputMap.has_action(action):
			_log.append("unknown action '%s'" % action)
			continue
		for button in str(_config.get_value("controller", action, "")).split(",", false):
			var event := InputEventJoypadButton.new()
			event.button_index = int(button.strip_edges())
			event.pressed = true
			if not InputMap.action_has_event(action, event):
				InputMap.action_add_event(action, event)
				_log.append("bound joypad %d to '%s'" % [event.button_index, action])


# ---------------------------------------------------------------- reporting

## Mods can read this to cooperate, e.g. to skip work another mod already did.
func get_loaded_mods() -> Array[String]:
	return _mods.duplicate()


## Settings from mods/config.cfg, so a mod does not need its own config file for simple values.
func get_setting(section: String, key: String, default: Variant) -> Variant:
	return _config.get_value(section, key, default)


## Change a setting and persist it, so the in-game panel does not need anyone to edit a file.
func set_setting(section: String, key: String, value: Variant) -> void:
	_config.set_value(section, key, value)

	# Only the changed values are written, so editing the shipped config.cfg still works and a
	# mod update does not get overwritten by a stale copy of every default.
	var overrides := ConfigFile.new()
	overrides.load(USER_CONFIG)
	overrides.set_value(section, key, value)
	var err := overrides.save(USER_CONFIG)
	if err != OK:
		_log.append("could not save settings: error %d" % err)


func _write_log() -> void:
	# A release export has no console, so this file is the only way to see what happened.
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_line("mods: %s" % (", ".join(_mods) if _mods else "none"))
	for line in _log:
		f.store_line(line)
