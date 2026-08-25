# In-game mod settings panel.
#
#   F1  open and close the panel
#   F2  toggle auto slot without opening anything
#
# Built in code rather than from a scene file, so it needs nothing inside game.pck. It sits on
# its own CanvasLayer above whatever the game is drawing, and the loader adds it to the tree.
#
# Sizing matters here: the game runs a 640x360 viewport, and a CanvasLayer draws in those
# coordinates, not in window pixels. A panel sized for a desktop window lands almost entirely
# off screen. Everything below is measured against the live viewport rect and the fonts are
# small to match, rather than assuming any particular window size.

extends CanvasLayer

# Filled from mods/config.cfg. Nothing is hardcoded, because a binding that collides with
# play is worse than no binding, and which buttons are free depends on the controller - the
# Deck's back grips are ideal but are not free on every layout.
var _panel_key: int = KEY_F1
var _auto_key: int = KEY_F2
var _panel_buttons: Array[int] = []
var _auto_buttons: Array[int] = []

const MARGIN := 8
const FONT_TITLE := 11
const FONT_BODY := 9

var _loader: Node
var _holder: Control
var _root: PanelContainer
var _rows: VBoxContainer
var _status: Label
var _auto_box: CheckBox
var _toast: Label


func setup(loader: Node) -> void:
	_loader = loader


func _ready() -> void:
	# Above the game's own UI, and still processing while the game pauses itself - otherwise
	# the panel would freeze open on any screen that pauses.
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS
	_read_hotkeys()
	_build()
	_root.visible = false
	# Re-fit if the window is resized or the player changes the scale in game options.
	get_viewport().size_changed.connect(_fit)


func _read_hotkeys() -> void:
	_panel_key = _key_from(_loader.get_setting("hotkeys", "panel_key", "F1"), KEY_F1)
	_auto_key = _key_from(_loader.get_setting("hotkeys", "auto_key", "F2"), KEY_F2)
	_panel_buttons = _buttons_from(_loader.get_setting("hotkeys", "panel_buttons", ""))
	_auto_buttons = _buttons_from(_loader.get_setting("hotkeys", "auto_buttons", ""))


func _key_from(name: Variant, fallback: int) -> int:
	# Godot can turn its own key names back into keycodes, so the config can say "F1" rather
	# than a number nobody can read. An unrecognised name falls back rather than binding
	# nothing, which would leave the panel unreachable with no clue why.
	var text := str(name).strip_edges()
	if text.is_empty():
		return 0
	var code := OS.find_keycode_from_string(text)
	return code if code != 0 else fallback


func _buttons_from(value: Variant) -> Array[int]:
	var out: Array[int] = []
	for part in str(value).split(",", false):
		var text := part.strip_edges()
		if text.is_valid_int():
			out.append(int(text))
	return out


func _viewport_size() -> Vector2:
	return get_viewport().get_visible_rect().size


func _fit() -> void:
	# Anchors are deliberately left at top-left and the position set directly. Applying a
	# preset such as PRESET_CENTER *and* a position makes the two fight, which is what put the
	# panel off screen.
	var view := _viewport_size()
	var width: float = min(300.0, view.x - MARGIN * 2)

	_root.custom_minimum_size = Vector2(width, 0)

	# PRESET_MODE_MINSIZE sets the anchors *and* the offsets together, which is the only form
	# that survives the next layout pass. Setting size directly gets recomputed and reverted -
	# that is why the panel kept coming back 1080 tall when it only needs about 162.
	_root.set_anchors_and_offsets_preset(
		Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE)
	_root.position = Vector2(MARGIN, MARGIN)

	# Never taller than the screen it has to fit on.
	if _root.size.y > view.y - MARGIN * 2:
		_root.size = Vector2(width, view.y - MARGIN * 2)

	if _toast != null:
		_toast.position = Vector2(MARGIN, MARGIN)


func _small(node: Control, size: int) -> Control:
	node.add_theme_font_size_override("font_size", size)
	return node


func _build() -> void:
	# Godot auto-resizes a Control parented straight to a CanvasLayer, stretching it to the
	# window - which is what made the panel 1080 tall when it only needed 162. A holder
	# absorbs that: children of a Control are laid out normally and keep their own size.
	_holder = Control.new()
	_holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_holder)

	_root = PanelContainer.new()
	_holder.add_child(_root)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 6)
	_root.add_child(margin)

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 4)
	margin.add_child(_rows)

	var title := Label.new()
	title.text = "Mods   %s close   %s auto" % [
		OS.get_keycode_string(_panel_key), OS.get_keycode_string(_auto_key)]
	_rows.add_child(_small(title, FONT_TITLE))

	var mods: Array = _loader.get_loaded_mods() if _loader != null else []
	var listed := Label.new()
	listed.text = "loaded: %s" % (", ".join(mods) if mods else "none")
	listed.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rows.add_child(_small(listed, FONT_BODY))

	_rows.add_child(HSeparator.new())
	_add_auto_rows()

	_status = Label.new()
	_rows.add_child(_small(_status, FONT_BODY))

	# Drawn outside the panel so F2 still gives feedback when the panel is closed.
	_toast = Label.new()
	_toast.visible = false
	_holder.add_child(_small(_toast, FONT_TITLE))

	_fit()


func _add_auto_rows() -> void:
	_auto_box = CheckBox.new()
	_auto_box.text = "Auto slot"
	_auto_box.button_pressed = _loader.get_setting("auto", "enabled", false)
	_auto_box.toggled.connect(func(on: bool) -> void: _set_auto(on, false))
	_rows.add_child(_small(_auto_box, FONT_BODY))

	var explain := Label.new()
	explain.text = "Keeps using the slot while you have coins."
	explain.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rows.add_child(_small(explain, FONT_BODY))

	var delay: float = _loader.get_setting("auto", "delay_seconds", 0.0)
	var label := Label.new()
	label.text = "Pause between rolls: %.2fs" % delay
	_rows.add_child(_small(label, FONT_BODY))

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 2.0
	slider.step = 0.05
	slider.value = delay
	slider.value_changed.connect(func(value: float) -> void:
		label.text = "Pause between rolls: %.2fs" % value
		_loader.set_setting("auto", "delay_seconds", value)
		_status.text = "saved"
	)
	_rows.add_child(slider)

	# Exposed here rather than left to a file edit. mods/config.cfg is replaced wholesale when
	# the mod updates, so a flag set there silently reverts - and the moment it matters most is
	# exactly when someone is chasing a problem and least wants a second one.
	var debug_box := CheckBox.new()
	debug_box.text = "Log diagnostics"
	debug_box.button_pressed = bool(_loader.get_setting("debug", "auto_slot", false))
	debug_box.toggled.connect(func(on: bool) -> void:
		_loader.set_setting("debug", "auto_slot", on)
		_status.text = "diagnostics %s - user://auto_slot.log" % ("on" if on else "off")
	)
	_rows.add_child(_small(debug_box, FONT_BODY))


func _set_auto(on: bool, from_hotkey: bool) -> void:
	_loader.set_setting("auto", "enabled", on)
	if _auto_box != null and _auto_box.button_pressed != on:
		# no_signal, so updating the box from the hotkey does not re-enter this.
		_auto_box.set_pressed_no_signal(on)
	_status.text = "auto slot %s" % ("on" if on else "off")
	if from_hotkey:
		_flash("Auto slot %s" % ("ON" if on else "OFF"))


func _flash(text: String) -> void:
	_toast.text = text
	_toast.visible = true
	await get_tree().create_timer(1.2).timeout
	if is_instance_valid(_toast):
		_toast.visible = false


func _process(_delta: float) -> void:
	# Re-asserted while open. The game re-lays-out its own UI as scenes change, and a single
	# fit at build time does not survive that.
	if _root != null and _root.visible and _root.size.y > _viewport_size().y:
		_fit()


func _input(event: InputEvent) -> void:
	var wants_panel := false
	var wants_auto := false

	if event is InputEventKey and event.pressed and not event.echo:
		var code: int = (event as InputEventKey).keycode
		wants_panel = _panel_key != 0 and code == _panel_key
		wants_auto = _auto_key != 0 and code == _auto_key
	elif event is InputEventJoypadButton and event.pressed:
		var button: int = (event as InputEventJoypadButton).button_index
		wants_panel = _panel_buttons.has(button)
		wants_auto = _auto_buttons.has(button)
	else:
		return

	if wants_panel:
		_toggle_panel()
		get_viewport().set_input_as_handled()
	elif wants_auto:
		_set_auto(not bool(_loader.get_setting("auto", "enabled", false)), true)
		get_viewport().set_input_as_handled()


func _toggle_panel() -> void:
	_root.visible = not _root.visible
	if _root.visible:
		_status.text = ""
		_fit()
