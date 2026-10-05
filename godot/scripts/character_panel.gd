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

## Stage 9 P03: the panel has two views — 屬性 (the Stage 7 stats and
## allocation, unchanged) and 裝備 (the selected character's equipped Weapon
## / Armor with 卸下, its own carried equipment, a before -> after preview of
## the chosen item and 裝備). Everything comes from main.gd: the equipment
## state (equipment_provider), the preview stats (preview_provider: a copy
## from CharacterCarrying, no formula here) and the changes (equip_handler /
## unequip_handler: EquipmentService transactions, saved; a failure changes
## nothing and says so).

## Stage 9 P05 (approved): 轉移 — the chosen UNEQUIPPED carried item goes to
## another character shown here (the Hero or an owned Mercenary, by stable
## id). 轉移 (next to the chosen row) opens a picker over the panel: one row
## per other character with its load, then 取消 / 確定轉移. transfer_handler
## does it (EquipmentTransferService: capacity checked, saved; a failure
## changes nothing and says so). The item is never equipped on arrival.

signal opened
signal closed
signal allocation_confirmed(character_id: String)
signal equipment_changed(character_id: String)

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
## Stage 9 P03: the two views and the 裝備 view texts.
const VIEW_STATS := "stats"
const VIEW_EQUIPMENT := "equipment"
const STATS_VIEW_TEXT := "屬性"
const EQUIPMENT_VIEW_TEXT := "裝備"
const EQUIPPED_TEXT := "%s：%s"
const NONE_TEXT := "無"
const UNEQUIP_TEXT := "卸下"
const EQUIP_TEXT := "裝備"
const CURRENT_TEXT := "目前：%s"
const LOAD_TEXT := "負重 %d / %d"
const CARRIED_TITLE := "隨身裝備（點選查看效果）"
const CARRIED_EMPTY := "沒有隨身裝備"
const CARRIED_ROW_TEXT := "%s ×%d　%s　%s　重量 %d"
const PREVIEW_HINT := "選擇一件隨身裝備，查看裝備後的數值"
const PREVIEW_TITLE := "裝備%s後："
const PREVIEW_SWAP := "（%s放回背包）"
const PREVIEW_SAME := "數值不變"
const EQUIPPED_FEEDBACK := "已裝備%s"
const UNEQUIPPED_FEEDBACK := "已卸下%s"
const EQUIP_SAVE_FAILED_TEXT := "無法儲存，裝備變更已取消"
const EQUIP_FAILED_TEXT := "無法變更裝備"
## The values the 裝備 view compares / shows (all read from CharacterStats).
const VALUE_NAMES := ["血量", "魔力", "力量", "敏捷", "智力", "物理攻擊", "魔法攻擊", "物理防禦", "魔法防禦", "負重容量"]
## The current-values line of the 裝備 view (subset of VALUE_NAMES).
const CURRENT_NAMES := ["力量", "智力", "物理攻擊", "魔法攻擊", "物理防禦", "魔法防禦"]
const MAX_CARRIED_ROWS := 4
## Stage 9 P05: the carried rows leave room for 轉移 beside the chosen one.
const CARRIED_ROW_WIDTH := 480.0
const TRANSFER_TEXT := "轉移"
const TRANSFER_TITLE := "將%s轉移給："
const TRANSFER_ROW_TEXT := "%s　負重 %d / %d"
const TRANSFER_CANCEL_TEXT := "取消"
const TRANSFER_CONFIRM_TEXT := "確定轉移"
const TRANSFERRED_FEEDBACK := "已將%s轉移給%s"
const TRANSFER_CAPACITY_TEXT := "%s負重不足，無法轉移"
const TRANSFER_SAVE_FAILED_TEXT := "無法儲存，轉移已取消"
const TRANSFER_FAILED_TEXT := "無法轉移裝備"
## The picker panel (inside the 720 x 1280 canvas) and its rows: every
## other character (the Hero + 5 owned Mercenaries, one of them selected).
const TRANSFER_PANEL_RECT := Rect2(40.0, 240.0, 640.0, 800.0)
const TRANSFER_ROW_SIZE := Vector2(592.0, 88.0)
const TRANSFER_ROWS := 5

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
## Stage 9 P03: id -> {"equipped": {slot: item id}, "carried": {item id:
## quantity}, "load": int, "capacity": int} ({} for no character).
var equipment_provider: Callable
## Stage 9 P03: (id, item id) -> CharacterStats copy after equipping it.
var preview_provider: Callable
## Stage 9 P03: (id, item id) / (id, slot) -> EquipmentService result.
var equip_handler: Callable
var unequip_handler: Callable
## Stage 9 P05: (from id, to id, item id) -> EquipmentTransferService result.
var transfer_handler: Callable

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
## Stage 9 P03: the view, the 裝備 view nodes and the chosen carried item.
var _view := VIEW_STATS
var _view_button: Button
var _equip_button: Button
var _equipment_view: Control
var _slot_labels := {}
var _unequip_buttons := {}
var _current_label: Label
var _carried_title: Label
var _carried_rows: Array[Button] = []
var _preview_label: Label
var _selected_item := ""
## Stage 9 P05: 轉移 and its picker (the item being moved, the chosen
## destination id, the destination rows).
var _transfer_button: Button
var _transfer_modal: Control
var _transfer_title: Label
var _transfer_rows: Array[Button] = []
var _transfer_confirm: Button
var _transfer_item := ""
var _transfer_destination := ""


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
	# Stage 9 P03: the bottom bar holds the view switch, 確認分配 (屬性) /
	# 裝備 (裝備) and 關閉 (208 x 96 each).
	_view_button = _button("ViewButton", EQUIPMENT_VIEW_TEXT, Vector2(32.0, 1140.0), Vector2(208.0, 96.0), 32)
	_view_button.pressed.connect(toggle_view)
	_panel.add_child(_view_button)
	_confirm_button = _button("ConfirmButton", CONFIRM_TEXT, Vector2(256.0, 1140.0), Vector2(208.0, 96.0), 32)
	_confirm_button.pressed.connect(confirm)
	_panel.add_child(_confirm_button)
	_equip_button = _button("EquipButton", EQUIP_TEXT, Vector2(256.0, 1140.0), Vector2(208.0, 96.0), 32)
	_equip_button.pressed.connect(equip_selected)
	_panel.add_child(_equip_button)
	_build_equipment_view()
	var close_button := _button("CloseButton", CLOSE_TEXT, Vector2(480.0, 1140.0), Vector2(208.0, 96.0), 32)
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
	_view = VIEW_STATS
	_selected_item = ""
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
	close_transfer()
	_panel.visible = false
	closed.emit()


## Shows another character (the current preview is discarded). Only a
## character the provider lists can be selected.
func select_character(id: String) -> void:
	if _entry(id).is_empty():
		return
	_selected = id
	_pending.clear()
	_selected_item = ""
	close_transfer()
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
	# Stage 9 P03: one view at a time.
	var stats_view := _view == VIEW_STATS
	for stat in ROWS:
		for node in [_row_labels[stat], _minus[stat], _plus[stat], _pending_labels[stat]]:
			(node as Control).visible = stats_view
	_mp_label.visible = stats_view
	for label in _derived_labels:
		label.visible = stats_view
	_confirm_button.visible = stats_view
	_equip_button.visible = not stats_view
	_equipment_view.visible = not stats_view
	_view_button.text = EQUIPMENT_VIEW_TEXT if stats_view else STATS_VIEW_TEXT
	_refresh_equipment_view()
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


# --- Stage 9 P03: 裝備 view --------------------------------------------------

func _build_equipment_view() -> void:
	_equipment_view = Control.new()
	_equipment_view.name = "EquipmentView"
	_equipment_view.position = Vector2.ZERO
	_equipment_view.size = Vector2(720.0, 1130.0)
	_equipment_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_equipment_view)
	var y := 330.0
	for slot in EquipmentCatalog.SLOTS:
		var label := _label("Slot_" + slot, "", Vector2(32.0, y), Vector2(480.0, 80.0), 28)
		_equipment_view.add_child(label)
		_slot_labels[slot] = label
		var button := _button("Unequip_" + slot, UNEQUIP_TEXT, Vector2(528.0, y), Vector2(160.0, 80.0), 30)
		button.pressed.connect(unequip_slot.bind(slot))
		_equipment_view.add_child(button)
		_unequip_buttons[slot] = button
		y += 90.0
	_current_label = _label("CurrentStats", "", Vector2(32.0, 512.0), Vector2(656.0, 72.0), 22)
	_current_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_equipment_view.add_child(_current_label)
	_carried_title = _label("CarriedTitle", CARRIED_TITLE, Vector2(32.0, 590.0), Vector2(656.0, 36.0), 24)
	_equipment_view.add_child(_carried_title)
	for index in range(MAX_CARRIED_ROWS):
		var row := _button("Carried%d" % index, "", Vector2(32.0, 632.0 + index * 88.0), Vector2(CARRIED_ROW_WIDTH, 80.0), 22)
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.add_theme_color_override("font_disabled_color", Color(1.0, 0.85, 0.4))
		row.pressed.connect(_on_carried_row_pressed.bind(index))
		_equipment_view.add_child(row)
		_carried_rows.append(row)
	_preview_label = _label("Preview", "", Vector2(32.0, 990.0), Vector2(656.0, 140.0), 22)
	_preview_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_equipment_view.add_child(_preview_label)
	# Stage 9 P05: 轉移, beside the chosen carried row.
	_transfer_button = _button("TransferButton", TRANSFER_TEXT, Vector2(32.0 + CARRIED_ROW_WIDTH + 16.0, 632.0), Vector2(160.0, 80.0), 30)
	_transfer_button.pressed.connect(open_transfer)
	_equipment_view.add_child(_transfer_button)
	_build_transfer_modal()


func get_view() -> String:
	return _view


## 屬性 <-> 裝備 (an unconfirmed allocation preview is discarded).
func toggle_view() -> void:
	show_view(VIEW_EQUIPMENT if _view == VIEW_STATS else VIEW_STATS)


func show_view(view: String) -> void:
	if view != VIEW_STATS and view != VIEW_EQUIPMENT:
		return
	_view = view
	_pending.clear()
	_selected_item = ""
	close_transfer()
	_feedback_label.text = ""
	_refresh()


## The selected character's equipment state from main.gd ({} without).
func get_equipment_state() -> Dictionary:
	if not equipment_provider.is_valid():
		return {}
	var state: Variant = equipment_provider.call(_selected)
	return state if typeof(state) == TYPE_DICTIONARY else {}


## The carried item ids in the rows, in EquipmentCatalog order.
func get_carried_ids() -> Array:
	var carried: Dictionary = get_equipment_state().get("carried", {})
	return EquipmentCatalog.get_ids().filter(func(item_id: String) -> bool: return int(carried.get(item_id, 0)) > 0)


## Chooses a carried item for the preview ("" clears). False when the
## selected character does not carry it.
func select_item(item_id: String) -> bool:
	if item_id != "" and not get_carried_ids().has(item_id):
		return false
	_selected_item = item_id
	_feedback_label.text = ""
	_refresh()
	return true


func get_selected_item() -> String:
	return _selected_item


## The 裝備 button: equips the chosen carried item of the selected
## character (equip_handler, saved); the result is shown either way.
func equip_selected() -> bool:
	if _selected_item == "" or not equip_handler.is_valid():
		return false
	var item_id := _selected_item
	var result: Dictionary = equip_handler.call(_selected, item_id)
	_selected_item = ""
	_show_change_result(result, EQUIPPED_FEEDBACK, item_id)
	return result.get("success", false)


## 卸下: the item in `slot` back to the selected character's carried
## equipment (unequip_handler, saved).
func unequip_slot(slot: String) -> bool:
	if not unequip_handler.is_valid():
		return false
	var item_id: String = get_equipment_state().get("equipped", {}).get(slot, "")
	var result: Dictionary = unequip_handler.call(_selected, slot)
	_selected_item = ""
	_show_change_result(result, UNEQUIPPED_FEEDBACK, item_id)
	return result.get("success", false)


## Every line of the 裝備 view (slots, current values, carried rows,
## preview), for checks.
func get_equipment_lines() -> Dictionary:
	var rows := []
	for row in _carried_rows:
		if row.visible:
			rows.append(row.text)
	return {
		"slots": EquipmentCatalog.SLOTS.map(func(slot: String) -> String: return (_slot_labels[slot] as Label).text),
		"current": _current_label.text,
		"carried_title": _carried_title.text,
		"rows": rows,
		"preview": _preview_label.text,
	}


func _show_change_result(result: Dictionary, success_text: String, item_id: String) -> void:
	if result.get("success", false):
		_feedback_label.text = success_text % EquipmentCatalog.get_item(item_id).get("display_name", item_id)
		equipment_changed.emit(_selected)
	else:
		_feedback_label.text = EQUIP_SAVE_FAILED_TEXT if result.get("reason", "") == "ERR_SAVE_FAILED" else EQUIP_FAILED_TEXT
	_refresh()


func _on_carried_row_pressed(index: int) -> void:
	var ids := get_carried_ids()
	if index < ids.size():
		select_item(ids[index])


func _refresh_equipment_view() -> void:
	var state := get_equipment_state()
	var equipped: Dictionary = state.get("equipped", {})
	for slot in EquipmentCatalog.SLOTS:
		var item_id: String = equipped.get(slot, "")
		var shown := NONE_TEXT
		if item_id != "":
			shown = "%s（%s）" % [EquipmentCatalog.get_item(item_id).get("display_name", item_id), EquipmentCatalog.describe_bonuses(item_id)]
		(_slot_labels[slot] as Label).text = EQUIPPED_TEXT % [EquipmentCatalog.slot_name(slot), shown]
		(_unequip_buttons[slot] as Button).disabled = item_id == ""
	var stats := _stats(_selected)
	var current := []
	if stats != null:
		var values := _values(stats)
		for name in CURRENT_NAMES:
			current.append("%s %s" % [name, values[name]])
		current.append(LOAD_TEXT % [int(state.get("load", 0)), int(state.get("capacity", stats.get_max_capacity()))])
	_current_label.text = CURRENT_TEXT % "　".join(current) if not current.is_empty() else ""
	var carried: Dictionary = state.get("carried", {})
	var ids := get_carried_ids()
	if _selected_item != "" and not ids.has(_selected_item):
		_selected_item = ""
	_carried_title.text = CARRIED_TITLE if not ids.is_empty() else CARRIED_EMPTY
	for index in range(_carried_rows.size()):
		var row := _carried_rows[index]
		row.visible = index < ids.size()
		if not row.visible:
			continue
		var item_id: String = ids[index]
		var item := EquipmentCatalog.get_item(item_id)
		row.text = CARRIED_ROW_TEXT % [item["display_name"], int(carried[item_id]), EquipmentCatalog.slot_name(item["slot"]), EquipmentCatalog.describe_bonuses(item_id), int(item["capacity_cost"])]
		row.disabled = item_id == _selected_item
	# Stage 9 P05: 轉移 sits beside the chosen row (only while one is chosen).
	var chosen := ids.find(_selected_item)
	_transfer_button.visible = chosen >= 0 and chosen < _carried_rows.size()
	if _transfer_button.visible:
		_transfer_button.position.y = 632.0 + chosen * 88.0
	_transfer_button.disabled = _transfer_destinations().is_empty()
	_preview_label.text = _preview_text(stats, equipped)
	_equip_button.disabled = _selected_item == ""


# --- Stage 9 P05: 轉移 ---------------------------------------------------------

func _build_transfer_modal() -> void:
	_transfer_modal = ColorRect.new()
	_transfer_modal.name = "TransferModal"
	(_transfer_modal as ColorRect).color = Color(0.0, 0.0, 0.0, 0.7)
	_transfer_modal.position = Vector2.ZERO
	_transfer_modal.size = Vector2(720.0, 1280.0)
	_transfer_modal.mouse_filter = Control.MOUSE_FILTER_STOP
	_transfer_modal.visible = false
	_panel.add_child(_transfer_modal)
	var box := Panel.new()
	box.name = "TransferPanel"
	box.position = TRANSFER_PANEL_RECT.position
	box.size = TRANSFER_PANEL_RECT.size
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.12, 0.13)
	style.border_color = Color(0.88, 0.75, 0.36)
	style.set_border_width_all(3)
	box.add_theme_stylebox_override("panel", style)
	_transfer_modal.add_child(box)
	_transfer_title = _label("TransferTitle", "", Vector2(24.0, 24.0), Vector2(592.0, 64.0), 30, HORIZONTAL_ALIGNMENT_CENTER)
	_transfer_title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	box.add_child(_transfer_title)
	for index in range(TRANSFER_ROWS):
		var row := _button("Destination%d" % index, "", Vector2(24.0, 104.0 + index * 100.0), TRANSFER_ROW_SIZE, 26)
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.add_theme_color_override("font_disabled_color", Color(1.0, 0.85, 0.4))
		row.pressed.connect(_on_destination_pressed.bind(index))
		box.add_child(row)
		_transfer_rows.append(row)
	var cancel := _button("TransferCancel", TRANSFER_CANCEL_TEXT, Vector2(24.0, TRANSFER_PANEL_RECT.size.y - 120.0), Vector2(280.0, 96.0), 30)
	cancel.pressed.connect(close_transfer)
	box.add_child(cancel)
	_transfer_confirm = _button("TransferConfirm", TRANSFER_CONFIRM_TEXT, Vector2(336.0, TRANSFER_PANEL_RECT.size.y - 120.0), Vector2(280.0, 96.0), 30)
	_transfer_confirm.pressed.connect(confirm_transfer)
	box.add_child(_transfer_confirm)


## The characters the chosen item may go to: every character shown except
## the selected one (the provider's order: the Hero, then owned Mercenaries).
func _transfer_destinations() -> Array:
	return get_characters().filter(func(entry: Dictionary) -> bool: return entry["id"] != _selected)


## 轉移: opens the picker for the chosen carried item. False when nothing is
## chosen or no other character exists.
func open_transfer() -> bool:
	if _selected_item == "" or _transfer_destinations().is_empty():
		return false
	_transfer_item = _selected_item
	_transfer_destination = ""
	_feedback_label.text = ""
	_transfer_modal.visible = true
	_refresh_transfer()
	return true


func close_transfer() -> void:
	_transfer_item = ""
	_transfer_destination = ""
	if _transfer_modal != null:
		_transfer_modal.visible = false


func is_transfer_open() -> bool:
	return _transfer_modal != null and _transfer_modal.visible


## Chooses the destination (a character the picker lists). False otherwise.
func choose_destination(id: String) -> bool:
	if not is_transfer_open() or not _transfer_destinations().any(func(entry: Dictionary) -> bool: return entry["id"] == id):
		return false
	_transfer_destination = id
	_refresh_transfer()
	return true


## The picker's destination ids, in order (for checks).
func get_transfer_destination_ids() -> Array:
	return _transfer_destinations().map(func(entry: Dictionary) -> String: return entry["id"])


## {"title", "rows": [text], "destination", "confirm_disabled"} (checks).
func get_transfer_state() -> Dictionary:
	var rows := []
	for row in _transfer_rows:
		if row.visible:
			rows.append(row.text)
	return {"open": is_transfer_open(), "item": _transfer_item, "title": _transfer_title.text, "rows": rows, "destination": _transfer_destination, "confirm_disabled": _transfer_confirm.disabled}


## 確定轉移: moves the item (transfer_handler, saved) and closes the picker;
## the result is shown either way.
func confirm_transfer() -> bool:
	if not is_transfer_open() or _transfer_destination == "" or not transfer_handler.is_valid():
		return false
	var item_id := _transfer_item
	var destination := _transfer_destination
	var destination_name: String = _entry(destination).get("name", "")
	var result: Dictionary = transfer_handler.call(_selected, destination, item_id)
	close_transfer()
	_selected_item = ""
	var item_name: String = EquipmentCatalog.get_item(item_id).get("display_name", item_id)
	if result.get("success", false):
		_feedback_label.text = TRANSFERRED_FEEDBACK % [item_name, destination_name]
		equipment_changed.emit(_selected)
		equipment_changed.emit(destination)
	else:
		_feedback_label.text = {
			"ERR_OVER_CAPACITY": TRANSFER_CAPACITY_TEXT % destination_name,
			"ERR_SAVE_FAILED": TRANSFER_SAVE_FAILED_TEXT,
		}.get(result.get("reason", ""), TRANSFER_FAILED_TEXT)
	_refresh()
	return result.get("success", false)


func _on_destination_pressed(index: int) -> void:
	var destinations := _transfer_destinations()
	if index < destinations.size():
		choose_destination(destinations[index]["id"])


func _refresh_transfer() -> void:
	if not is_transfer_open():
		return
	var destinations := _transfer_destinations()
	if not EquipmentCatalog.has_item(_transfer_item) or destinations.is_empty():
		close_transfer()
		return
	if not destinations.any(func(entry: Dictionary) -> bool: return entry["id"] == _transfer_destination):
		_transfer_destination = ""
	_transfer_title.text = TRANSFER_TITLE % EquipmentCatalog.get_item(_transfer_item)["display_name"]
	for index in range(_transfer_rows.size()):
		var row := _transfer_rows[index]
		row.visible = index < destinations.size()
		if not row.visible:
			continue
		var id: String = destinations[index]["id"]
		var state: Variant = equipment_provider.call(id) if equipment_provider.is_valid() else {}
		state = state if typeof(state) == TYPE_DICTIONARY else {}
		row.text = TRANSFER_ROW_TEXT % [destinations[index]["name"], int(state.get("load", 0)), int(state.get("capacity", 0))]
		row.disabled = id == _transfer_destination
	_transfer_confirm.disabled = _transfer_destination == ""


## "裝備X後：力量 10 → 12　…" from the preview stats (preview_provider: a
## CharacterStats copy); only the values that change.
func _preview_text(stats: CharacterStats, equipped: Dictionary) -> String:
	if _selected_item == "" or stats == null or not preview_provider.is_valid():
		return PREVIEW_HINT
	var after: Variant = preview_provider.call(_selected, _selected_item)
	if not after is CharacterStats:
		return PREVIEW_HINT
	var name: String = EquipmentCatalog.get_item(_selected_item).get("display_name", _selected_item)
	var text := PREVIEW_TITLE % name
	var replaced: String = equipped.get(EquipmentCatalog.get_slot(_selected_item), "")
	if replaced != "":
		text += PREVIEW_SWAP % EquipmentCatalog.get_item(replaced).get("display_name", replaced)
	var before_values := _values(stats)
	var after_values := _values(after)
	var changes := []
	for value_name in VALUE_NAMES:
		if before_values[value_name] != after_values[value_name]:
			# Non-breaking spaces: one change never wraps across lines.
			changes.append("%s\u00a0%s\u00a0→\u00a0%s" % [value_name, before_values[value_name], after_values[value_name]])
	return text + "\n" + ("　".join(changes) if not changes.is_empty() else PREVIEW_SAME)


## The compared values, all read from CharacterStats.
func _values(stats: CharacterStats) -> Dictionary:
	return {
		"血量": str(stats.get_max_hp()),
		"魔力": str(stats.get_max_mp()),
		"力量": str(stats.get_effective("str")),
		"敏捷": str(stats.get_effective("agi")),
		"智力": str(stats.get_effective("int")),
		"物理攻擊": str(stats.get_physical_attack()),
		"魔法攻擊": str(stats.get_magic_attack()),
		"物理防禦": str(stats.get_physical_defense()),
		"魔法防禦": str(stats.get_magic_defense()),
		"負重容量": str(stats.get_max_capacity()),
	}


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
