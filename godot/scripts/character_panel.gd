class_name CharacterPanel
extends CanvasLayer

## Stage 7 S04: the Character UI (functional Prototype, portrait 720 x 1280).
## Opened from the 角色 button in the world (hidden in cities, while
## travelling and in battle). For the selected character (主角 / 傭兵A /
## 傭兵B) it shows Level, EXP, unspent Stat Points, Max HP / Max MP, STR / AGI /
## INT and the derived values, and lets the player allocate Stat Points to
## HP / STR / AGI / INT: + / - change a pending preview only (shown as
## before -> after, computed on a copy of the character's stats with the
## same CharacterStats rules), 確認分配 applies it at once
## (CharacterStats.confirm_allocation). - only removes points of the current
## preview; no Stat Reset. Closing, switching character or an encounter
## discards the preview. Nothing here is saved (S05).

signal opened
signal closed
signal allocation_confirmed(character_id: String)

const ORDER := ["hero", "merc_a", "merc_b"]
const NAMES := {"hero": "主角", "merc_a": "傭兵A", "merc_b": "傭兵B"}
## Allocation rows (CharacterConfig.ALLOCATABLE order) and their labels.
const ROWS := ["hp", "str", "agi", "int"]
const ROW_NAMES := {"hp": "生命上限", "str": "力量", "agi": "敏捷", "int": "智力"}
const OPEN_TEXT := "角色"
const OPEN_POINTS_TEXT := "角色（屬性點 %d）"
const TITLE_TEXT := "角色"
const LEVEL_TEXT := "等級 %d　經驗 %d / %d"
const LEVEL_MAX_TEXT := "等級 %d（最高等級）"
const POINTS_TEXT := "未分配屬性點 %s"
const HP_POINT_TEXT := "每點生命 +%d 生命上限"
const MP_TEXT := "魔力上限 %s（不可直接分配）"
const DERIVED_TITLE := "能力"
const CONFIRM_TEXT := "確認分配"
const CLOSE_TEXT := "關閉"
const PENDING_TEXT := "+%d"
const DERIVED_NAMES := ["物理攻擊", "魔法攻擊", "物理防禦", "魔法防禦", "攻擊間隔", "移動速度", "負重容量"]
const ARROW := " → "

## Character id -> CharacterStats of the party (main.gd).
var party_provider: Callable
var progression: ProgressionState
## Whether the 角色 button may show (the player is in the world).
var can_open: Callable

var _open_button: Button
var _panel: Control
var _tabs := {}
var _info_labels: Array[Label] = []
var _row_labels := {}
var _plus := {}
var _minus := {}
var _pending_labels := {}
var _mp_label: Label
var _derived_labels: Array[Label] = []
var _confirm_button: Button
var _selected := "hero"
var _pending := {}


func _ready() -> void:
	layer = 12
	_open_button = _button("OpenButton", OPEN_TEXT, Vector2(500.0, 24.0), Vector2(200.0, 76.0), 28)
	_open_button.pressed.connect(open)
	add_child(_open_button)
	_panel = ColorRect.new()
	_panel.name = "Panel"
	(_panel as ColorRect).color = Color(0.07, 0.08, 0.1, 0.97)
	_panel.position = Vector2.ZERO
	_panel.size = Vector2(720.0, 1280.0)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.visible = false
	add_child(_panel)
	_panel.add_child(_label("Title", TITLE_TEXT, Vector2(0.0, 30.0), Vector2(720.0, 60.0), 40, HORIZONTAL_ALIGNMENT_CENTER))
	for index in range(ORDER.size()):
		var id: String = ORDER[index]
		var tab := _button("Tab_" + id, NAMES[id], Vector2(24.0 + index * 228.0, 110.0), Vector2(216.0, 72.0), 28)
		tab.pressed.connect(select_character.bind(id))
		_panel.add_child(tab)
		_tabs[id] = tab
	for index in range(3):
		var info := _label("Info%d" % index, "", Vector2(32.0, 196.0 + index * 40.0), Vector2(656.0, 40.0), 26)
		_panel.add_child(info)
		_info_labels.append(info)
	for index in range(ROWS.size()):
		var stat: String = ROWS[index]
		var y := 320.0 + index * 96.0
		var label := _label("Row_" + stat, "", Vector2(32.0, y), Vector2(400.0, 80.0), 28)
		_panel.add_child(label)
		_row_labels[stat] = label
		var minus := _button("Minus_" + stat, "－", Vector2(440.0, y), Vector2(80.0, 80.0), 34)
		minus.pressed.connect(press_minus.bind(stat))
		_panel.add_child(minus)
		_minus[stat] = minus
		var pending := _label("Pending_" + stat, "", Vector2(520.0, y), Vector2(80.0, 80.0), 28, HORIZONTAL_ALIGNMENT_CENTER)
		_panel.add_child(pending)
		_pending_labels[stat] = pending
		var plus := _button("Plus_" + stat, "＋", Vector2(608.0, y), Vector2(80.0, 80.0), 34)
		plus.pressed.connect(press_plus.bind(stat))
		_panel.add_child(plus)
		_plus[stat] = plus
	_mp_label = _label("Mp", "", Vector2(32.0, 704.0), Vector2(656.0, 50.0), 26)
	_panel.add_child(_mp_label)
	for index in range(DERIVED_NAMES.size() + 1):
		var derived := _label("Derived%d" % index, "", Vector2(32.0, 764.0 + index * 44.0), Vector2(656.0, 44.0), 26)
		_panel.add_child(derived)
		_derived_labels.append(derived)
	_confirm_button = _button("ConfirmButton", CONFIRM_TEXT, Vector2(32.0, 1140.0), Vector2(320.0, 96.0), 32)
	_confirm_button.pressed.connect(confirm)
	_panel.add_child(_confirm_button)
	var close_button := _button("CloseButton", CLOSE_TEXT, Vector2(368.0, 1140.0), Vector2(320.0, 96.0), 32)
	close_button.pressed.connect(close)
	_panel.add_child(close_button)
	_refresh()


func _process(_delta: float) -> void:
	var allowed := can_open.is_valid() and bool(can_open.call())
	if not allowed and is_open():
		close()
	_open_button.visible = allowed and not is_open()
	if _open_button.visible:
		var stats := _stats(_selected)
		var points := 0
		for id in ORDER:
			var character := _stats(id)
			if character != null:
				points += character.get_unspent_points()
		_open_button.text = OPEN_POINTS_TEXT % points if points > 0 else OPEN_TEXT
		if stats == null:
			_open_button.text = OPEN_TEXT


func is_open() -> bool:
	return _panel != null and _panel.visible


func open() -> bool:
	if is_open() or not (can_open.is_valid() and bool(can_open.call())):
		return false
	_pending.clear()
	_panel.visible = true
	_refresh()
	opened.emit()
	return true


## Closes the panel; an unconfirmed preview is discarded.
func close() -> void:
	if not is_open():
		return
	_pending.clear()
	_panel.visible = false
	closed.emit()


## Shows another character (the current preview is discarded).
func select_character(id: String) -> void:
	if not ORDER.has(id):
		return
	_selected = id
	_pending.clear()
	_refresh()


func get_selected() -> String:
	return _selected


## + : one more pending point for `stat`, while unspent points remain.
func press_plus(stat: String) -> bool:
	var stats := _stats(_selected)
	if stats == null or not ROWS.has(stat) or _pending_total() >= stats.get_unspent_points():
		return false
	_pending[stat] = int(_pending.get(stat, 0)) + 1
	_refresh()
	return true


## - : one pending point less for `stat` (never below this preview's 0: the
## points already confirmed cannot be taken back).
func press_minus(stat: String) -> bool:
	if int(_pending.get(stat, 0)) <= 0:
		return false
	_pending[stat] = int(_pending[stat]) - 1
	if _pending[stat] == 0:
		_pending.erase(stat)
	_refresh()
	return true


## Applies the preview to the character at once; the preview is cleared.
func confirm() -> bool:
	var stats := _stats(_selected)
	if stats == null or _pending.is_empty() or not stats.confirm_allocation(_pending.duplicate()):
		return false
	_pending.clear()
	_refresh()
	allocation_confirmed.emit(_selected)
	return true


func get_pending() -> Dictionary:
	return _pending.duplicate()


## The selected character as the preview would make it (a copy; the real
## stats when nothing is pending).
func get_preview_stats() -> CharacterStats:
	var stats := _stats(_selected)
	if stats == null:
		return null
	var preview := stats.duplicate_stats()
	if not _pending.is_empty():
		preview.confirm_allocation(_pending.duplicate())
	return preview


## Every line the panel shows for the selected character (info, rows, MP,
## derived), before -> after where the preview changes a value.
func get_lines() -> Array[String]:
	var lines: Array[String] = []
	var stats := _stats(_selected)
	if stats == null:
		return lines
	var after := get_preview_stats()
	var level := progression.get_level(_selected) if progression != null else ProgressionState.START_LEVEL
	if level >= ProgressionState.MAX_LEVEL:
		lines.append(LEVEL_MAX_TEXT % level)
	else:
		lines.append(LEVEL_TEXT % [level, progression.get_exp(_selected) if progression != null else 0, ProgressionState.required_exp(level)])
	lines.append(POINTS_TEXT % _pair(stats.get_unspent_points(), after.get_unspent_points()))
	lines.append(HP_POINT_TEXT % int(CharacterConfig.ALLOCATION_VALUE["hp"]))
	for stat in ROWS:
		lines.append("%s %s" % [ROW_NAMES[stat], _pair(_row_value(stats, stat), _row_value(after, stat))])
	lines.append(MP_TEXT % _pair(stats.get_max_mp(), after.get_max_mp()))
	lines.append(DERIVED_TITLE)
	var before_values := _derived(stats)
	var after_values := _derived(after)
	for index in range(DERIVED_NAMES.size()):
		lines.append("%s %s" % [DERIVED_NAMES[index], _pair(before_values[index], after_values[index])])
	return lines


func _refresh() -> void:
	if _panel == null:
		return
	for id in _tabs:
		(_tabs[id] as Button).disabled = id == _selected
	var lines := get_lines()
	if lines.is_empty():
		return
	var stats := _stats(_selected)
	for index in range(3):
		_info_labels[index].text = lines[index]
	for index in range(ROWS.size()):
		var stat: String = ROWS[index]
		(_row_labels[stat] as Label).text = lines[3 + index]
		var count := int(_pending.get(stat, 0))
		(_pending_labels[stat] as Label).text = PENDING_TEXT % count if count > 0 else ""
		(_minus[stat] as Button).disabled = count <= 0
		(_plus[stat] as Button).disabled = _pending_total() >= stats.get_unspent_points()
	_mp_label.text = lines[3 + ROWS.size()]
	var derived := lines.slice(4 + ROWS.size())
	for index in range(_derived_labels.size()):
		_derived_labels[index].text = derived[index] if index < derived.size() else ""
	_confirm_button.disabled = _pending.is_empty()


func _row_value(stats: CharacterStats, stat: String) -> int:
	return stats.get_max_hp() if stat == "hp" else stats.get_effective(stat)


## The derived values shown (formatted), all from CharacterStats.
func _derived(stats: CharacterStats) -> Array:
	return [
		str(stats.get_physical_attack()),
		str(stats.get_magic_attack()),
		str(stats.get_physical_defense()),
		str(stats.get_magic_defense()),
		"%.2f 秒" % (stats.get_attack_interval_ms() / 1000.0),
		"%.1f 格／秒" % stats.get_move_speed(),
		str(stats.get_max_capacity()),
	]


func _pair(before: Variant, after: Variant) -> String:
	return str(before) if str(before) == str(after) else str(before) + ARROW + str(after)


func _pending_total() -> int:
	var total := 0
	for stat in _pending:
		total += int(_pending[stat])
	return total


func _stats(id: String) -> CharacterStats:
	if not party_provider.is_valid():
		return null
	var party: Dictionary = party_provider.call()
	return party.get(id)


func _button(node_name: String, text: String, at: Vector2, button_size: Vector2, font_size: int) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.position = at
	button.size = button_size
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", font_size)
	return button


func _label(node_name: String, text: String, at: Vector2, label_size: Vector2, font_size: int, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label := Label.new()
	label.name = node_name
	label.text = text
	label.position = at
	label.size = label_size
	label.horizontal_alignment = align
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
