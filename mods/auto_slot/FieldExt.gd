extends "res://scene/Field.gd"

# Presses the slot for you.
#
# The game funnels every use through _coin_use(), which _process calls while the coin_use
# action is held. That method guards itself - it returns immediately if a roll is running, if
# the buttons are locked, or if there are no coins - and it sets m_use before it awaits
# anything. So calling it on the same terms the player's input would is enough, and it is
# self-pacing: the next call cannot start until the previous roll finishes.
#
# _process is extended rather than replaced, so holding the button by hand still behaves
# exactly as it did.
#
# If this appears to do nothing, turn on [debug] auto_slot in mods/config.cfg. It then writes
# to user://auto_slot.log, which names the condition that is stopping it rather than leaving
# it to guesswork - and works anywhere, including on a Steam Deck, where hand-patching a file
# to add logging is not practical.

var _waited: float = 0.0
var _debug: bool = false
var _last_state: String = ""


func _ready() -> void:
	super()
	_refresh_debug()
	_log("Field ready, auto slot extension is live")


func _process(delta: float) -> void:
	super(delta)

	var enabled: bool = bool(ModLoader.get_setting("auto", "enabled", false))

	# Re-read rather than cached at ready, so turning diagnostics on from the panel takes
	# effect immediately instead of at the next run. It is an in-memory dictionary lookup.
	_refresh_debug()

	if _debug:
		# Reported on change rather than on a timer. A run produces a handful of lines that
		# say what actually happened, instead of hundreds saying the same thing.
		var state := "enabled=%s end=%s m_use=%s btn_lock=%s coin=%s" % [
			enabled, end, m_use, Data.btn_lock, coin]
		if state != _last_state:
			_last_state = state
			_log(state)

	if not enabled:
		_waited = 0.0
		return

	# The same conditions the game checks before a manual use. Without them the coin counter
	# and the end-of-run state can be driven somewhere the game never expects.
	if end or m_use or Data.btn_lock or coin <= 0:
		_waited = 0.0
		return

	# An optional pause between rolls. m_use already prevents overlap, so this is only for
	# watchability - at 0 it rolls again the moment the previous one finishes.
	var delay: float = ModLoader.get_setting("auto", "delay_seconds", 0.0)
	if delay > 0.0:
		_waited += delta
		if _waited < delay:
			return
	_waited = 0.0

	_log("using the slot")
	_coin_use()


func _refresh_debug() -> void:
	_debug = bool(ModLoader.get_setting("debug", "auto_slot", false))


func _log(text: String) -> void:
	if not _debug:
		return
	# Appended rather than rewritten, so a whole session is visible and not just its last line.
	var f := FileAccess.open("user://auto_slot.log", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("user://auto_slot.log", FileAccess.WRITE)
		if f == null:
			return
	f.seek_end()
	f.store_line(text)
