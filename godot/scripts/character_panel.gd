class_name CharacterPanel
extends CanvasLayer

## Stage 7 S04: the Character UI (functional Prototype, portrait 720 x 1280).
## Opened from the 角色 button in the world (hidden in cities, while
## travelling and in battle). For the selected character (P05: the Hero or
## an owned Mercenary) it shows Level, EXP, unspent Stat Points, Max HP / Max MP, STR / AGI /
## INT and the derived values, and lets the player allocate Stat Points to
## HP / STR / AGI / INT: + / - change a pending preview only (shown as
## before -> after, computed on a copy of the character's stats with the
## same CharacterStats rules), 確認分配 applies it at once
## (CharacterStats.confirm_allocation). - only removes points of the current
## preview; no Stat Reset. Closing, switching character or an encounter
## discards the preview. Nothing here is saved (S05).
## Stage 7 corrective: characters carry their Prototype role labels
## (CharacterConfig.DISPLAY_NAMES) and the selected one is named at the top;
## HP reads 血量 and MP 魔力 as plain values, with no formula / instruction
## copy (the HP +10 per point and the not-allocatable MP rules are unchanged).

## Stage 8 P05 (approved Q2): the panel shows the Hero + every owned roster
## Mercenary (up to 6 characters; the pending legacy ones never). Tabs come
## from characters_provider on every open / refresh, in a horizontally
## scrolling strip (720 x 1280: about three visible, swipe or tap for the
## rest). A Mercenary's points are confirmed through confirm_handler, a
## roster transaction (PartyService.allocate: save failure restores
## everything, the panel says so); the Hero keeps the S04 / S05 path. The old
## fixed Merc A / Merc B tabs are gone.

signal opened
signal closed
signal allocation_confirmed(character_id: String)

## Allocation rows (CharacterConfig.ALLOCATABLE order) and their labels.
const ROWS := ["hp", "str", "agi", "int"]
const ROW_NAMES := {"hp": "血量", "str": "力量", "agi": "敏捷", "int": "智力"}
const OPEN_TEXT := "角色"
const OPEN_POINTS_TEXT := "角色（屬性點 %d）"
const TITLE_TEXT := "角色"
const LEVEL_TEXT := "等級 %d　經驗 %d / %d"
const LEVEL_MAX_TEXT := "等級 %d（最高等級）"
const POINTS_TEXT := "未分配屬性點 %s"
const MP_TEXT := "魔力 %s"
const DERIVED_TITLE := "能力"
const CONFIRM_TEXT := "確認分配"
const CLOSE_TEXT := "關閉"
const PENDING_TEXT := "+%d"
const DERIVED_NAMES := ["物理攻擊", "魔法攻擊", "物理防禦", "魔法防禦", "攻擊間隔", "移動速度", "負重容量"]
const ARROW := " → "
## Stage 8 P05: a Mercenary allocation whose save failed (rolled back).
const SAVE_FAILED_TEXT := "無法儲存，分配已取消"
## Stage 8 P05: the tab strip and one tab.
const TAB_STRIP_RECT := Rect2(24.0, 104.0, 672.0, 88.0)
const TAB_SIZE := Vector2(208.0, 72.0)
## Stage 8 iPhone L3 corrective (AC02): the whole tab strip takes a finger
## swipe (TabTouch over the strip): a press that moves farther than this is
## a horizontal scroll, not a tab tap; a press released without moving that
## far selects the tab under it. The thin scrollbar is only an indicator.
const TAB_DRAG_THRESHOLD := 12.0

## Stage 8 P05: the characters shown, in order (main.gd: the Hero, then the
## owned Mercenaries): [{"id", "name", "stats": CharacterStats, "level",
## "exp"}]. A Mercenary's stats are built from its instance on every call.
var characters_provider: Callable
## Stage 8 P05: (id, pending {stat: points}) -> bool, confirming a pending
## allocation for real (main.gd: the Hero's CharacterStats, a Mercenary's
## roster transaction). Not set: CharacterStats.confirm_allocation.
var confirm_handler: Callable
## Whether the 角色 button may show (the player is in the world).
var can_open: Callable

var _open_button: Button
var _panel: Control
var _tab_strip: ScrollContainer
var _tab_row: HBoxContainer
var _tab_touch: Control
## The finger (or mouse) on the tab strip: its pointer id (-1: none), where
## it pressed, the scroll then, and whether it became a swipe.
var _tab_pointer := -1
var _tab_press := Vector2.ZERO
var _tab_press_scroll := 0
var _tab_swiping := false
var _tabs := {}
var _info_labels: Array[Label] = []
var _row_labels := {}
var _plus := {}
var _minus := {}
var _pending_labels := {}
var _mp_label: Label
var _derived_labels: Array[Label] = []
var _confirm_button: Button
var _feedback_label: Label
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
	_tab_strip = ScrollContainer.new()
	_tab_strip.name = "TabStrip"
	_tab_strip.position = TAB_STRIP_RECT.position
	_tab_strip.size = TAB_STRIP_RECT.size
	_tab_strip.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tab_strip.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_panel.add_child(_tab_strip)
	_tab_row = HBoxContainer.new()
	_tab_row.name = "Tabs"
	_tab_row.add_theme_constant_override("separation", 12)
	_tab_strip.add_child(_tab_row)
	# Every touch on the strip goes to TabTouch (the tabs ignore input), so a
	# swipe anywhere on the tabs scrolls and a still tap selects.
	_tab_touch = Control.new()
	_tab_touch.name = "TabTouch"
	_tab_touch.position = TAB_STRIP_RECT.position
	_tab_touch.size = TAB_STRIP_RECT.size
	_tab_touch.mouse_filter = Control.MOUSE_FILTER_STOP
	_tab_touch.gui_input.connect(_on_tab_touch_input)
	_panel.add_child(_tab_touch)
	for index in range(3):
		var info := _label("Info%d" % index, "", Vector2(32.0, 196.0 + index * 40.0), Vector2(656.0, 40.0), 26)
		if index == 0:
			# The selected character's name, so it is never in doubt.
			info.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
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
	_feedback_label = _label("FeedbackLabel", "", Vector2(32.0, 1236.0), Vector2(656.0, 40.0), 24, HORIZONTAL_ALIGNMENT_CENTER)
	_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
	_panel.add_child(_feedback_label)
	_refresh()


func _process(_delta: float) -> void:
	var allowed := can_open.is_valid() and bool(can_open.call())
	if not allowed and is_open():
		close()
	_open_button.visible = allowed and not is_open()
	if _open_button.visible:
		# P05: the unspent points of the Hero + every owned Mercenary.
		var points := 0
		for entry in get_characters():
			points += (entry["stats"] as CharacterStats).get_unspent_points()
		_open_button.text = OPEN_POINTS_TEXT % points if points > 0 else OPEN_TEXT


func is_open() -> bool:
	return _panel != null and _panel.visible


func open() -> bool:
	if is_open() or not (can_open.is_valid() and bool(can_open.call())):
		return false
	_pending.clear()
	_feedback_label.text = ""
	_panel.visible = true
	if _entry(_selected).is_empty():
		_selected = "hero"
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


## Shows another character (the current preview is discarded). Only a
## character the provider lists can be selected.
func select_character(id: String) -> void:
	if _entry(id).is_empty():
		return
	_selected = id
	_pending.clear()
	_feedback_label.text = ""
	_refresh()


func get_selected() -> String:
	return _selected


## Stage 8 P05: the characters shown now (characters_provider; [] without).
func get_characters() -> Array:
	return characters_provider.call() if characters_provider.is_valid() else []


## Stage 8 P05: the ids of the tabs shown, in order.
func get_tab_ids() -> Array:
	return get_characters().map(func(entry: Dictionary) -> String: return entry["id"])


## Stage 8 iPhone L3 corrective: one touch / mouse event on the tab strip
## (positions local to the strip). Press: remember; move past
## TAB_DRAG_THRESHOLD horizontally: scroll with the finger; release: a tap
## (never moved that far) selects the tab under it.
func _on_tab_touch_input(event: InputEvent) -> void:
	var touch := event as InputEventScreenTouch
	var drag := event as InputEventScreenDrag
	var click := event as InputEventMouseButton
	var motion := event as InputEventMouseMotion
	if click != null and click.pressed and click.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_RIGHT]:
		var step := -TAB_SIZE.x / 2.0 if click.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT] else TAB_SIZE.x / 2.0
		_tab_strip.scroll_horizontal = int(_tab_strip.scroll_horizontal + step)
		_tab_touch.accept_event()
		return
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	if touch != null or (click != null and click.button_index == MOUSE_BUTTON_LEFT):
		var pointer: int = touch.index if touch != null else -2
		var pressed: bool = touch.pressed if touch != null else click.pressed
		var at: Vector2 = touch.position if touch != null else click.position
		if pressed and _tab_pointer == -1:
			_tab_pointer = pointer
			_tab_press = at
			_tab_press_scroll = _tab_strip.scroll_horizontal
			_tab_swiping = false
		elif not pressed and pointer == _tab_pointer:
			if not _tab_swiping and not (touch != null and touch.canceled):
				var tab_id := tab_at(at)
				if tab_id != "":
					select_character(tab_id)
			_tab_pointer = -1
		_tab_touch.accept_event()
		return
	if drag != null or (motion != null and motion.button_mask & MOUSE_BUTTON_MASK_LEFT):
		var pointer: int = drag.index if drag != null else -2
		if pointer != _tab_pointer:
			return
		var at: Vector2 = drag.position if drag != null else motion.position
		if not _tab_swiping and absf(at.x - _tab_press.x) > TAB_DRAG_THRESHOLD:
			_tab_swiping = true
		if _tab_swiping:
			_tab_strip.scroll_horizontal = roundi(_tab_press_scroll - (at.x - _tab_press.x))
		_tab_touch.accept_event()


## The id of the tab under `at` (strip-local), "" for none.
func tab_at(at: Vector2) -> String:
	var row_x := at.x + _tab_strip.scroll_horizontal
	for id in _tabs:
		var tab: Button = _tabs[id]
		if row_x >= tab.position.x and row_x < tab.position.x + tab.size.x and at.y >= 0.0 and at.y < TAB_SIZE.y:
			return id
	return ""


func get_tab_scroll() -> int:
	return _tab_strip.scroll_horizontal


## Stage 8 P05: the tab button of `id` (null when not shown).
func get_tab(id: String) -> Button:
	return _tabs.get(id)


func get_feedback_text() -> String:
	return _feedback_label.text if _feedback_label != null else ""


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


## Applies the preview to the character at once (P05: confirm_handler; a
## refused or unsaved Mercenary allocation changes nothing and says so); the
## preview is cleared either way.
func confirm() -> bool:
	var stats := _stats(_selected)
	if stats == null or _pending.is_empty():
		return false
	var pending := _pending.duplicate()
	var done: bool = confirm_handler.call(_selected, pending) if confirm_handler.is_valid() else stats.confirm_allocation(pending)
	_pending.clear()
	_feedback_label.text = "" if done else SAVE_FAILED_TEXT
	_refresh()
	if done:
		allocation_confirmed.emit(_selected)
	return done


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
	var entry := _entry(_selected)
	if entry.is_empty():
		return lines
	var stats: CharacterStats = entry["stats"]
	var after := get_preview_stats()
	var level: int = entry["level"]
	lines.append(entry["name"])
	if level >= ProgressionState.MAX_LEVEL:
		lines.append(LEVEL_MAX_TEXT % level)
	else:
		lines.append(LEVEL_TEXT % [level, entry["exp"], ProgressionState.required_exp(level)])
	lines.append(POINTS_TEXT % _pair(stats.get_unspent_points(), after.get_unspent_points()))
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
	_sync_tabs()
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


## Stage 8 P05: rebuilds the tab row when the characters changed (ids or
## names), keeping the selected tab in view.
func _sync_tabs() -> void:
	var entries := get_characters()
	var wanted := entries.map(func(entry: Dictionary) -> String: return "%s|%s" % [entry["id"], entry["name"]])
	var current := []
	for child in _tab_row.get_children():
		current.append(child.get_meta("key", ""))
	if wanted != current:
		for child in _tab_row.get_children():
			_tab_row.remove_child(child)
			child.free()
		_tabs.clear()
		for index in range(entries.size()):
			var entry: Dictionary = entries[index]
			var tab := _button("Tab_" + entry["id"], entry["name"], Vector2.ZERO, TAB_SIZE, 28)
			tab.custom_minimum_size = TAB_SIZE
			tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
			tab.set_meta("key", wanted[index])
			tab.pressed.connect(select_character.bind(entry["id"]))
			# The selected (disabled) tab reads gold, not greyed out.
			tab.add_theme_color_override("font_disabled_color", Color(1.0, 0.85, 0.4))
			_tab_row.add_child(tab)
			_tabs[entry["id"]] = tab
	if _tabs.has(_selected) and _tab_strip.is_inside_tree():
		_tab_strip.ensure_control_visible(_tabs[_selected])


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
	var entry := _entry(id)
	return entry["stats"] if not entry.is_empty() else null


## The provider's entry of `id` ({} when not shown).
func _entry(id: String) -> Dictionary:
	for entry in get_characters():
		if entry["id"] == id:
			return entry
	return {}


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
