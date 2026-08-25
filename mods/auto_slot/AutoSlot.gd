# Automates the parts of the loop that are just repetition.
#
#   - uses the slot for you while you have coins
#   - the top face button moves between the lobby and a run, in both directions
#   - the right face button leaves the result screen for the upgrade menu
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

# How long to let _end() settle before leaving. It is still working through its own awaits
# when the result panel first appears, and leaving on that frame races it.
const LEAVE_SETTLE := 0.4

var _field: Node = null
var _lobby: Node = null

var _waited: float = 0.0
var _restart_waited: float = 0.0
var _restart_sent: bool = false

# Leaving happens in two steps, because the press and the moment it can be honoured are rarely
# the same frame - see _input.
var _leave_requested: bool = false
var _leave_after_end: bool = false
var _leave_waited: float = 0.0

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
		# A new slot screen means anything pending from the previous run is stale.
		_restart_sent = false
		_restart_waited = 0.0
		_leave_requested = false
		_leave_after_end = false
		_leave_waited = 0.0
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


# ---------------------------------------------------------------- input

func _input(event: InputEvent) -> void:
	var wants_move := false
	var wants_lobby := false

	if event is InputEventKey and event.pressed and not event.echo:
		var code: int = (event as InputEventKey).keycode
		wants_move = _start_keys.has(code)
		wants_lobby = _lobby_keys.has(code)
	elif event is InputEventJoypadButton and event.pressed:
		var button: int = (event as InputEventJoypadButton).button_index
		wants_move = _start_buttons.has(button)
		wants_lobby = _lobby_buttons.has(button)
	else:
		return

	if wants_move and _can_start():
		_log("starting a run")
		get_viewport().set_input_as_handled()
		_lobby._start()

	elif wants_move and _in_a_run():
		# Recorded rather than acted on, and this is the whole reason leaving takes two steps.
		# The press is nearly always made while a spin is resolving - with auto slot running,
		# m_use is true most of the time - and acting then would cut across the game's own
		# await chain. An earlier version refused outright in that state, which meant the
		# button did nothing on most presses and looked broken.
		_leave_requested = true
		_log("leave requested, waiting for the spin to finish")
		get_viewport().set_input_as_handled()

	elif wants_lobby and _result_up():
		# Cancels any pending auto restart. Asking to leave and then being restarted a second
		# later would be the opposite of what the press meant.
		_restart_sent = true
		_log("returning to the upgrade menu")
		get_viewport().set_input_as_handled()
		_field._lobby()


func _can_start() -> bool:
	if not is_instance_valid(_lobby) or not _lobby.visible:
		return false
	# Only when the game itself would allow it. The lobby hides its Start button while a
	# transition is playing, and calling _start() through that would begin a run the game is
	# midway through setting up.
	var button: Node = _lobby.get_node_or_null("%Start")
	return button != null and button.visible


func _in_a_run() -> bool:
	return is_instance_valid(_field) and not _field.end and not _result_up()


# ---------------------------------------------------------------- per frame

func _process(delta: float) -> void:
	if not is_instance_valid(_field):
		return

	var enabled: bool = bool(ModLoader.get_setting("auto", "enabled", false))
	_refresh_debug()

	if _debug:
		# On change rather than per frame, so a session is a handful of lines that say what
		# happened instead of hundreds repeating themselves.
		var panel := _result_panel()
		var state := "enabled=%s end=%s m_use=%s btn_lock=%s coin=%s result=%s leave=%s" % [
			enabled, _field.end, _field.m_use, Data.btn_lock, _field.coin,
			"up" if panel != null and panel.visible else ("hidden" if panel != null else "?"),
			_leave_requested]
		if state != _last_state:
			_last_state = state
			_log(state)

	# Gated on the result panel, not on `end`. The game has two ways out of a run and only one
	# sets that flag: _ending() does, for beating the target score, but _exit() - the ordinary
	# finish - calls _end() directly and leaves `end` false. _end() raises the panel in both
	# cases, so the panel is what actually means "run over".
	if _result_up():
		_after_result(delta)
		return

	if _field.end:
		return

	# A queued leave takes priority over spinning again.
	if _leave_requested:
		_try_leave()
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


func _try_leave() -> void:
	# As soon as the game is between spins. Nothing is lost by waiting a few frames.
	if _field.m_use or Data.btn_lock:
		return

	# The game has no mid-run exit to the lobby - its Lobby button only appears once the result
	# screen is up - and going straight there would skip the scoring and the save that _end()
	# performs, losing the run. So this does what holding Exit does: zero the coins and end the
	# run properly. _leave_after_end then carries on to the upgrade menu.
	_leave_requested = false
	_leave_after_end = true
	_restart_sent = true
	_leave_waited = 0.0
	_log("ending the run to return to the upgrade menu")

	_field.coin = 0
	var counter: Node = _field.get_node_or_null("%CoinCount")
	if counter != null:
		counter.t_float = 0
	_field._end()


func _after_result(delta: float) -> void:
	if _leave_after_end:
		_leave_waited += delta
		if _leave_waited >= LEAVE_SETTLE:
			_leave_after_end = false
			_log("returning to the upgrade menu")
			_field._lobby()
		return
	_maybe_restart(delta)


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

func _result_panel() -> Node:
	if not is_instance_valid(_field):
		return null
	# The scene marks it as a unique name, but % resolution depends on scene ownership and is
	# not guaranteed to work from another script, so there is a plain search behind it.
	var node: Node = _field.get_node_or_null("%Result")
	if node == null:
		node = _field.find_child("Result", true, false)
	return node


func _result_up() -> bool:
	var panel := _result_panel()
	return panel != null and panel.visible


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
