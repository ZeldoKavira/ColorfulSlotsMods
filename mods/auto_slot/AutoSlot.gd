# Automates the parts of the loop that are just repetition.
#
#   - uses the slot for you while you have coins
#   - a button in the lobby that starts a run without reaching for Start
#   - restarts from the result screen when a run ends
#
#
# WHY THIS IS NOT A SCRIPT EXTENSION
#
# It was one, and it silently never ran. The Data autoload holds
#
#     const field_scene: PackedScene = preload("res://scene/Field.tscn")
#     const lobby_scene: PackedScene = preload("res://scene/Lobby.tscn")
#
# and preload() resolves when Data's own script is compiled. Data is one of the game's five
# autoloads and the mod loader is appended after them, so those scenes - with the vanilla
# scripts baked into them - are already cached before take_over_path() runs. instantiate()
# then hands back the original class and the extension is never used. Nothing errors; the mod
# just does nothing.
#
# So this drives the instances instead of replacing the classes. Everything it calls is a
# method the game already calls itself from a button, under the same conditions.

extends Node

const FIELD_SCRIPT := "res://scene/Field.gd"
const LOBBY_SCRIPT := "res://scene/Lobby.gd"

var _field: Node = null
var _lobby: Node = null

var _waited: float = 0.0
var _restart_waited: float = 0.0
var _restart_sent: bool = false

var _debug: bool = false
var _last_state: String = ""

var _start_keys: Array[int] = []
var _start_buttons: Array[int] = []
var _lobby_keys: Array[int] = []
var _lobby_buttons: Array[int] = []


func _ready() -> void:
	# Both screens are built and freed repeatedly across a session, so they have to be caught
	# as they appear rather than looked up once.
	get_tree().node_added.connect(_on_node_added)
	_find_existing()
	_read_hotkeys()
	_refresh_debug()
	_log("auto slot ready")


func _find_existing() -> void:
	# In case a screen is already open - loading a save, or the mod arriving mid-session.
	for node in get_tree().root.find_children("*", "", true, false):
		_remember(node)


func _on_node_added(node: Node) -> void:
	_remember(node)


func _remember(node: Node) -> void:
	# Matched on the script's path rather than with `is Field`, so this keeps working if a
	# global class name is ever removed, and cannot accidentally match another mod's subclass.
	var script: Script = node.get_script()
	if script == null:
		return
	if script.resource_path == FIELD_SCRIPT:
		_field = node
		# A new slot screen means the previous run is over and a restart may be wanted again.
		_restart_sent = false
		_restart_waited = 0.0
		_log("slot screen opened")
	elif script.resource_path == LOBBY_SCRIPT:
		_lobby = node
		_log("lobby opened")


func _read_hotkeys() -> void:
	_start_keys = _keys_from(ModLoader.get_setting("hotkeys", "start_run_key", ""))
	_start_buttons = _ints_from(ModLoader.get_setting("hotkeys", "start_run_buttons", ""))
	_lobby_keys = _keys_from(ModLoader.get_setting("hotkeys", "to_lobby_key", ""))
	_lobby_buttons = _ints_from(ModLoader.get_setting("hotkeys", "to_lobby_buttons", ""))


func _keys_from(value: Variant) -> Array[int]:
	var out: Array[int] = []
	for part in str(value).split(",", false):
		var code := OS.find_keycode_from_string(part.strip_edges())
		if code != 0:
			out.append(code)
	return out


func _ints_from(value: Variant) -> Array[int]:
	var out: Array[int] = []
	for part in str(value).split(",", false):
		var text := part.strip_edges()
		if text.is_valid_int():
			out.append(int(text))
	return out


# ---------------------------------------------------------------- starting a run

func _input(event: InputEvent) -> void:
	var wants_start := false
	var wants_lobby := false

	if event is InputEventKey and event.pressed and not event.echo:
		var code: int = (event as InputEventKey).keycode
		wants_start = _start_keys.has(code)
		wants_lobby = _lobby_keys.has(code)
	elif event is InputEventJoypadButton and event.pressed:
		var button: int = (event as InputEventJoypadButton).button_index
		wants_start = _start_buttons.has(button)
		wants_lobby = _lobby_buttons.has(button)
	else:
		return

	if wants_start and _can_start():
		_log("starting a run")
		get_viewport().set_input_as_handled()
		_lobby._start()
	elif wants_lobby and _can_leave():
		# Cancels any pending auto restart. Asking to leave and then being restarted a second
		# later would be the opposite of what the press meant.
		_restart_sent = true
		_log("returning to the upgrade menu")
		get_viewport().set_input_as_handled()
		_field._lobby()


func _can_leave() -> bool:
	# Only from the result screen, where the game itself offers a Lobby button. Elsewhere this
	# would abandon a run mid-play on a single press.
	var result := _result_panel()
	return result != null and result.visible


func _can_start() -> bool:
	if not is_instance_valid(_lobby) or not _lobby.visible:
		return false
	# Only when the game itself would allow it. The lobby hides its Start button while a
	# transition is playing or the run is not ready, and calling _start() through that would
	# begin a run the game is midway through setting up.
	var button: Node = _lobby.get_node_or_null("%Start")
	return button != null and button.visible


# ---------------------------------------------------------------- the slot, and restarting

func _process(delta: float) -> void:
	if not is_instance_valid(_field):
		return

	var enabled: bool = bool(ModLoader.get_setting("auto", "enabled", false))
	_refresh_debug()

	if _debug:
		# On change rather than per frame, so a session is a handful of lines that say what
		# happened instead of hundreds repeating themselves.
		var panel := _result_panel()
		var state := "enabled=%s end=%s m_use=%s btn_lock=%s coin=%s result=%s" % [
			enabled, _field.end, _field.m_use, Data.btn_lock, _field.coin,
			"up" if panel != null and panel.visible else ("hidden" if panel != null else "not found")]
		if state != _last_state:
			_last_state = state
			_log(state)

	# Gated on the result panel, not on `end`. The game has two ways out of a run and only one
	# of them sets that flag: _ending() does, for beating the target score, but _exit() - the
	# ordinary finish - calls _end() directly and leaves `end` false. _end() is what raises the
	# result panel in both cases, so the panel is the signal that actually means "run over".
	var result := _result_panel()
	if result != null and result.visible:
		_maybe_restart(delta)
		return

	if _field.end:
		return

	if not enabled:
		_waited = 0.0
		return

	# The same conditions the game checks before a manual use. Without them the coin counter
	# and the end-of-run state can be driven somewhere the game never expects.
	if _field.m_use or Data.btn_lock or _field.coin <= 0:
		_waited = 0.0
		return

	# Optional pause between rolls. m_use already prevents overlap, so this is only for
	# watchability - at 0 it rolls again the moment the previous one finishes.
	var delay: float = ModLoader.get_setting("auto", "delay_seconds", 0.0)
	if delay > 0.0:
		_waited += delta
		if _waited < delay:
			return
	_waited = 0.0

	_log("using the slot")
	_field._coin_use()


func _result_panel() -> Node:
	if not is_instance_valid(_field):
		return null
	# The scene marks it as a unique name, but % resolution depends on scene ownership and is
	# not guaranteed to work from another script, so there is a plain search behind it.
	var node: Node = _field.get_node_or_null("%Result")
	if node == null:
		node = _field.find_child("Result", true, false)
	return node


func _maybe_restart(delta: float) -> void:
	if _restart_sent or not bool(ModLoader.get_setting("auto", "restart_on_result", false)):
		return

	# A pause so the result is readable rather than flashing past. Deliberately separate from
	# the between-rolls delay - one is pacing, this is a chance to see what you scored.
	var wait: float = ModLoader.get_setting("auto", "restart_delay_seconds", 2.0)
	_restart_waited += delta
	if _restart_waited < wait:
		return

	_restart_sent = true
	_log("restarting from the result screen")
	_field._re()


# ---------------------------------------------------------------- odds and ends

func _refresh_debug() -> void:
	_debug = bool(ModLoader.get_setting("debug", "auto_slot", false))


func _log(text: String) -> void:
	if not _debug:
		return
	var f := FileAccess.open("user://auto_slot.log", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("user://auto_slot.log", FileAccess.WRITE)
		if f == null:
			return
	f.seek_end()
	f.store_line(text)
