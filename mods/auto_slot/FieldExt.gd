extends "res://scene/Field.gd"

# Presses the slot for you.
#
# The game already funnels every use through _coin_use(), which _process calls while the
# coin_use action is held. That method guards itself - it returns immediately if a roll is in
# progress, if the buttons are locked, or if there are no coins - and it sets m_use before it
# awaits anything. So calling it on the same terms the player's input would is enough, and it
# is self-pacing: the next call cannot start until the previous roll has finished.
#
# _process is extended rather than replaced, so holding the button by hand still behaves
# exactly as it did.

var _waited: float = 0.0


func _process(delta: float) -> void:
	super(delta)

	if not ModLoader.get_setting("auto", "enabled", false):
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

	_coin_use()
