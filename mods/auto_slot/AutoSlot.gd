# Presses the slot for you.
#
# WHY THIS IS NOT A SCRIPT EXTENSION
#
# It was one, and it silently never ran. The Data autoload holds
#
#     const field_scene: PackedScene = preload("res://scene/Field.tscn")
#
# and preload() resolves when Data's own script is compiled. Data is one of the game's five
# autoloads and the mod loader is appended after them, so Field.tscn - with the vanilla
# Field.gd baked into it - is already in the resource cache before take_over_path() runs.
# instantiate() then hands back the original class, and the extension is simply never used.
# Nothing errors; the mod just does nothing.
#
# So instead of replacing the class, this drives the instance. The game funnels every use
# through Field._coin_use(), which guards itself and sets m_use before it awaits anything, so
# calling it on the same terms the player's input would is enough - and it is self-pacing,
# because the next call cannot start until the previous roll finishes.

extends Node

const FIELD_SCRIPT := "res://scene/Field.gd"

var _field: Node = null
var _waited: float = 0.0
var _debug: bool = false
var _last_state: String = ""


func _ready() -> void:
	# The slot screen is built and freed repeatedly across a session, so it has to be caught as
	# it appears rather than looked up once.
	get_tree().node_added.connect(_on_node_added)
	_find_existing()
	_refresh_debug()
	_log("auto slot ready, watching for the slot screen")


func _find_existing() -> void:
	# In case a run is already open - loading a save, or the mod being added mid-session.
	for node in get_tree().root.find_children("*", "", true, false):
		if _is_field(node):
			_field = node
			return


func _on_node_added(node: Node) -> void:
	if _is_field(node):
		_field = node
		_log("slot screen opened")


func _is_field(node: Node) -> bool:
	# Matched on the script's path rather than with `is Field`, so this keeps working if the
	# global class name is ever removed, and so it cannot accidentally match a subclass a
	# different mod installed.
	var script: Script = node.get_script()
	return script != null and script.resource_path == FIELD_SCRIPT


func _process(delta: float) -> void:
	if not is_instance_valid(_field):
		return

	var enabled: bool = bool(ModLoader.get_setting("auto", "enabled", false))
	_refresh_debug()

	if _debug:
		# On change rather than per frame, so a session is a handful of lines that say what
		# happened instead of hundreds repeating themselves.
		var state := "enabled=%s end=%s m_use=%s btn_lock=%s coin=%s" % [
			enabled, _field.end, _field.m_use, Data.btn_lock, _field.coin]
		if state != _last_state:
			_last_state = state
			_log(state)

	if not enabled:
		_waited = 0.0
		return

	# The same conditions the game checks before a manual use. Without them the coin counter
	# and the end-of-run state can be driven somewhere the game never expects.
	if _field.end or _field.m_use or Data.btn_lock or _field.coin <= 0:
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
