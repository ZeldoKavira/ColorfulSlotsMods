# Remembers which upgrades you have bought, and buys them back as you can afford them.
#
# Buying back is continuous, not a one-shot after an all-in. An all-in zeroes your cash, so
# there is nothing to spend at the moment it happens - the upgrades have to be bought back
# gradually, out of what comes in while you roll. So this keeps checking, and buys each level
# the moment it becomes affordable.
#
# It works entirely on Data - Data.upgrade is a plain dictionary of key to level, and the cost
# of the next level is derivable from the Upg resource. Nothing here touches an UpgradeSlot
# node, which is what lets it run while the slot screen is up: the upgrade tree does not have
# to be on screen, or even built.
#
# It replicates the game's own arithmetic rather than approximating it:
#
#     value      = reward_value * (level + 1) if increase else reward_value
#     value     *= 1.0 - Data.stat.upg_discount          (UpgradeSlot._value)
#     buyable    = level < max_level and funds >= value  (UpgradeSlot._is_upgradable)
#     available  = tier <= Data.tier and (parent == "" or Data.upgrade[parent] > 0)
#
# One thing it deliberately does not copy: UpgradeSlot._upgrade() has a bulk-buy loop that
# keeps levelling a cash upgrade while a quarter of your cash still covers it. That is right
# for a person clicking a button and wrong here - the point is to get back to where you were,
# not past it.

extends Node

const TARGETS_PATH := "user://upgrade_targets.cfg"

# How often to look. Every frame would be wasteful for something that can only change when
# money does, and a quarter second is far below noticing.
const CHECK_EVERY := 0.25

# Saving is deferred this long after the last purchase. While cash is coming in quickly the
# buying comes in bursts, and writing the save file on each one would mean disk writes several
# times a second for no benefit.
const SAVE_AFTER := 2.0

var _targets: Dictionary = {}
var _last_allin: int = -1
var _since_check: float = 0.0
var _dirty: bool = false
var _since_buy: float = 0.0
var _debug: bool = false


func _ready() -> void:
	_load_targets()
	# Levels change through this signal, so it is the cheap place to keep the record current
	# rather than diffing the whole dictionary every frame.
	if Data.has_signal("upgrade_sig"):
		Data.upgrade_sig.connect(_remember_levels)
	_remember_levels()
	_last_allin = Data.allin_count
	_refresh_debug()
	_log("ready, tracking %d upgrade(s)" % _targets.size())


func _process(delta: float) -> void:
	_refresh_debug()

	# Noted for the log only. The buying does not wait for it - it is continuous, and an
	# all-in is simply the moment the gap between the record and reality opens up.
	if Data.allin_count != _last_allin:
		if Data.allin_count > _last_allin:
			_log("all-in detected, %d level(s) to buy back" % _outstanding())
		_last_allin = Data.allin_count

	if _dirty:
		_since_buy += delta
		if _since_buy >= SAVE_AFTER:
			_flush()

	_since_check += delta
	if _since_check < CHECK_EVERY:
		return
	_since_check = 0.0

	if not bool(ModLoader.get_setting("upgrades", "buy_back",
			ModLoader.get_setting("upgrades", "repurchase_on_prestige", true))):
		return
	if Data.btn_lock:
		return

	_buy_what_we_can()


# ---------------------------------------------------------------- the record

func _remember_levels() -> void:
	# Highest level seen, not current level. After an all-in the current levels are zero, and a
	# record that followed them down would forget everything at the moment it is needed.
	var changed := false
	for key: String in Data.upgrade:
		var level: int = Data.upgrade[key]
		if level > int(_targets.get(key, 0)):
			_targets[key] = level
			changed = true
	if changed:
		_save_targets()


func _outstanding() -> int:
	var total := 0
	for key: String in _targets:
		if Data.upgrade.has(key):
			total += maxi(0, int(_targets[key]) - Data.upgrade[key])
	return total


func _load_targets() -> void:
	var file := ConfigFile.new()
	if file.load(TARGETS_PATH) != OK:
		return
	for key in file.get_section_keys("levels"):
		_targets[key] = int(file.get_value("levels", key, 0))


func _save_targets() -> void:
	var file := ConfigFile.new()
	for key in _targets:
		file.set_value("levels", key, _targets[key])
	file.save(TARGETS_PATH)


# ---------------------------------------------------------------- buying back

func _buy_what_we_can() -> void:
	var bought := 0

	# Repeated passes, because buying a parent unlocks its children and a single pass would
	# stop at whatever happened to be reachable when it started.
	while true:
		var progress := false
		for key: String in _targets:
			if not Data.upgrade.has(key) or not Data.upg_list.has(key):
				continue
			var level: int = Data.upgrade[key]
			if level >= int(_targets[key]):
				continue

			var upg = Data.upg_list[key]
			if not _available(upg):
				continue

			var cost := _cost(upg, level)
			if upg.gold:
				if Data.gold < cost:
					continue
				Data.gold -= cost
			else:
				if Data.cash < cost:
					continue
				Data.cash -= cost

			Data.upgrade[key] = level + 1
			bought += 1
			progress = true

		if not progress:
			break

	if bought == 0:
		return

	# Emitted straight away so the purchase actually takes effect - upgrade_sig is what
	# recalculates the player stats - but the save is deferred, since this can fire repeatedly
	# while cash is flowing.
	Data.upgrade_sig.emit()
	_dirty = true
	_since_buy = 0.0
	_log("bought back %d level(s), %d still to go" % [bought, _outstanding()])


func _flush() -> void:
	_dirty = false
	_since_buy = 0.0
	Data.ach_check()
	Data.save()


func _available(upg) -> bool:
	# The same gate UpgradeSlot uses to decide whether to show itself at all.
	if upg.tier > Data.tier:
		return false
	if upg.parent != "" and int(Data.upgrade.get(upg.parent, 0)) == 0:
		return false
	return true


func _cost(upg, level: int) -> float:
	var value: float = upg.reward_value * (level + 1) if upg.increase else upg.reward_value
	value *= 1.0 - Data.stat.upg_discount
	return value


# ---------------------------------------------------------------- odds and ends

func _exit_tree() -> void:
	# Anything bought but not yet written would otherwise be lost on the way out.
	if _dirty:
		_flush()


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
	f.store_line("[upgrades] " + text)
