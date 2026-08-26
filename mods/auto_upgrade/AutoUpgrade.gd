# Remembers which upgrades you have bought, and buys them back after an all-in.
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

var _targets: Dictionary = {}
var _last_allin: int = -1
var _pending: bool = false
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
	_log("auto upgrade ready, tracking %d upgrade(s)" % _targets.size())


func _process(_delta: float) -> void:
	_refresh_debug()

	# An all-in is detected by its counter moving. By the time this is noticed the levels are
	# already reset - _allin() does it synchronously - which is exactly why the targets are
	# kept as a running record rather than snapshotted when a prestige begins.
	if Data.allin_count != _last_allin:
		var prestiged := Data.allin_count > _last_allin
		_last_allin = Data.allin_count
		if prestiged and bool(ModLoader.get_setting("upgrades", "repurchase_on_prestige", true)):
			_pending = true
			_log("all-in detected, will buy back what it can")

	if _pending and not Data.btn_lock:
		_pending = false
		_repurchase()


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

func _repurchase() -> void:
	var bought := 0
	var spent_cash := 0.0
	var spent_gold := 0.0

	# Repeated passes, because buying a parent unlocks its children and a single pass would
	# stop at whatever happened to be reachable at the start.
	while true:
		var progress := false
		for key: String in _targets:
			var target: int = int(_targets[key])
			if not Data.upgrade.has(key) or Data.upgrade[key] >= target:
				continue
			if not Data.upg_list.has(key):
				continue

			var upg = Data.upg_list[key]
			if not _available(upg):
				continue

			var level: int = Data.upgrade[key]
			var cost := _cost(upg, level)
			if upg.gold:
				if Data.gold < cost:
					continue
				Data.gold -= cost
				spent_gold += cost
			else:
				if Data.cash < cost:
					continue
				Data.cash -= cost
				spent_cash += cost

			Data.upgrade[key] = level + 1
			bought += 1
			progress = true

		if not progress:
			break

	if bought == 0:
		_log("nothing affordable to buy back")
		return

	# Once at the end rather than per purchase: ach_check and save are not free, and the UI
	# only needs telling that something changed.
	Data.ach_check()
	Data.save()
	Data.upgrade_sig.emit()
	_log("bought back %d level(s), spending %.0f cash and %.0f gold" % [
		bought, spent_cash, spent_gold])


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
