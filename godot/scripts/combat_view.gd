class_name CombatView
extends CanvasLayer

## Combat C01: Prototype presentation of one CombatBattle. It draws the grid,
## units, HP, countdown and result, feeds the battle physics time and turns
## taps into CombatBattle commands. It owns no combat truth.
##
## C08 Mobile Combat HUD (functional Prototype, portrait 720 x 1280):
##   top row      [全體撤退]  Combat Clock  [全體進攻]
##                phase line, aggregate HP (friendly shrinks centre -> left,
##                enemy centre -> right; independent percentages)
##                [群組①] [群組②] [全體], then one portrait per friendly unit
##                (selected / Active Caster / dead / group marks, ⓘ info)
##   battlefield  never follows a unit: drag it to pan (taps resolve on
##                release; a drag past DRAG_THRESHOLD only moves the camera)
##   skill bar    the selected units' Skills (one unit: full text; several:
##                compact icons with their owner)
##   navigator    horizontal camera strip with the visible range
## Multi-touch: every finger is its own pointer (pointer_event()). The
## battlefield, the navigator, the portraits and the Gesture Window each
## follow only the finger that pressed them, so one hand can hold the
## navigator while the other selects, commands or uses Skills; buttons
## already take any finger.
## Selection, groups, camera and the open info panel are runtime UI / battle
## state only (never saved).
##
## The result screen's 「返回世界」 only asks main.gd to commit the battle's
## BattleResult (C02 world lifecycle); it never decides the outcome.

## Pressed 「返回世界」 on the result screen.
signal exit_requested

const SCREEN_WIDTH := 720.0
## C08: battlefield cells (a little larger than C01's 48 x 100 for touch).
const CELL_SIZE := Vector2(56.0, 108.0)
const FIELD_TOP := 400.0
const FIELD_HEIGHT := 540.0
## C08: a press that moves farther than this is a camera drag, not a tap.
const DRAG_THRESHOLD := 12.0
## C08 multi-touch: the pointer id of a real (desktop) mouse; fingers use
## their touch index (0, 1, ...).
const MOUSE_POINTER := -2
## C08: the HUD has room for this many friendly portraits (party of 3 now).
const MAX_PORTRAITS := 4
const PORTRAIT_TOP := 282.0
const PORTRAIT_SIZE := Vector2(168.0, 108.0)
const SKILL_BAR_TOP := 950.0
const NAVIGATOR_RECT := Rect2(12.0, 1120.0, 696.0, 56.0)
const PREPARATION_TEXT := "備戰 %d"
const FIGHTING_TEXT := "戰鬥"
const VICTORY_TEXT := "勝利"
const DEFEAT_TEXT := "戰敗"
## C04 Retreat (C08: 全體撤退 top-left).
const RETREATING_TEXT := "撤退中"
const RETREAT_TEXT := "撤退成功"
const RETREAT_BUTTON_TEXT := "全體撤退"
const CANCEL_RETREAT_TEXT := "取消撤退"
const RETREAT_ZONE_TEXT := "撤退區"
## C08 全體進攻 top-right.
const ATTACK_ALL_TEXT := "全體進攻"
## C08 aggregate HP.
const FRIEND_HP_TEXT := "我方 %d%%"
const ENEMY_HP_TEXT := "敵方 %d%%"
## C08 battle groups.
const GROUP_MARKS := ["①", "②"]
const GROUP_TEXT := "群組%s"
const GROUP_DONE_TEXT := "完成%s"
const ALL_TEXT := "全體"
const GROUP_EDIT_HINT := "編輯群組%s：點頭像加入／移除，再按「完成%s」"
const GROUP_SELECTED_HINT := "再按群組%s可編輯成員"
const DEAD_TEXT := "陣亡"
## C05 result reward (minimal text, no animation).
const REWARD_TEXT := "%s 經驗 +%d"
const LEVEL_UP_TEXT := "%s 升至 %d 級"
const NO_REWARD_TEXT := "本場沒有獲得經驗"
## C03: friendly unit names and colours (Prototype presentation).
const ROLE_NAMES := {CombatUnit.Role.HERO: "主角", CombatUnit.Role.MERC_A: "傭兵A", CombatUnit.Role.MERC_B: "傭兵B"}
const ROLE_COLORS := {CombatUnit.Role.HERO: Color(0.95, 0.78, 0.3), CombatUnit.Role.MERC_A: Color(0.35, 0.65, 0.95), CombatUnit.Role.MERC_B: Color(0.55, 0.85, 0.5)}
## C06 / C07 Skills (C08 skill bar; MP is shown as 魔力).
const SKILL_NAMES := {"slow": "緩速", "guard": "守護", "aoe": "範圍攻擊", "lightning": "閃電"}
## Short identifier drawn in each skill icon (no emoji font needed).
const SKILL_MARKS := {"slow": "緩", "guard": "守", "aoe": "爆", "lightning": "雷"}
const NORMAL_SKILL_TEXT := "普通技能：%s　魔力 %d"
const SPECIAL_SKILL_TEXT := "特殊技能：%s　魔力 %d"
const SKILL_READY_STATE := "可用"
const SKILL_PREPARATION_STATE := "戰鬥開始後可用"
const SKILL_AIM_STATE := "選擇目標"
const SKILL_PENDING_STATE := "接近目標"
const SKILL_CASTING_STATE := "施法中…"
const SKILL_COOLDOWN_STATE := "冷卻 %.1f 秒"
const SKILL_NO_MP_STATE := "魔力不足"
const SKILL_UNAVAILABLE_STATE := "不可用"
const GESTURE_OPEN_STATE := "畫符中…"
const GESTURE_CASTING_STATE := "施法完成後可用"
const AIM_HINT_TEXT := "點敵人施放技能　點其他地方取消"
const SLOW_MARK_TEXT := "緩"
const AOE_TEXT := "範圍 -%d"
## How long the AoE cells stay marked (battle time).
const AOE_MARK_MS := 600
const EXIT_TEXT := "返回世界"
## C08 character info (only values the systems already have).
const INFO_TEXT := "%s\n生命 %d / %d　魔力 %d / %d\n攻擊 %d　攻擊距離 %d 格\n攻擊間隔 %.1f 秒　移動速度 %.1f 格／秒"
const INFO_PROGRESS_TEXT := "\n等級 %d　經驗 %d"
const INFO_SKILL_TEXT := "\n%s（%s）"
const INFO_GUARD_TEXT := "\n守護中 %.1f 秒"
const INFO_CLOSE_TEXT := "關閉"
const INFO_BUTTON_TEXT := "ⓘ"
## C07 Gesture / Combat Clock (functional Prototype presentation).
const CLOCK_TEXT := "戰鬥時間 %02d:%02d / 05:00"
const TIME_UP_TEXT := "時間到　強制撤退"
const FORCED_RETREAT_BUTTON_TEXT := "強制撤退中"
const GESTURE_READY_TEXT := "閃電（魔力 %d）"
const GESTURE_PREPARATION_TEXT := "閃電：戰鬥開始後可用"
const GESTURE_OPEN_TEXT := "畫符中…"
const GESTURE_CASTING_TEXT := "閃電：施法完成後可用"
const GESTURE_COOLDOWN_TEXT := "閃電：冷卻 %.1f 秒"
const GESTURE_NO_MP_TEXT := "閃電：魔力不足"
const GESTURE_TITLE_TEXT := "沿淡色閃電一筆畫出，放手即完成"
const GESTURE_COUNTDOWN_TEXT := "剩餘 %d 秒"
const GESTURE_CLOCK_TEXT := "戰鬥時間 %02d:%02d（繼續計時）"
const GESTURE_GRADE_TEXTS := ["完美", "成功", "部分", "失敗"]
const GESTURE_HIT_TEXT := "閃電 %s！%d 分　%d 傷害 × %d"
const GESTURE_FAIL_TEXT := "閃電 失敗　%d 分"
const GESTURE_TIMEOUT_TEXT := "閃電 時間到　失敗"
## How long the Gesture result stays on screen (UI time only: real seconds,
## independent of the battle and the Combat Clock).
const GESTURE_FEEDBACK_SECONDS := 1.5
## The square drawing area of the Gesture Window (screen pixels).
const GESTURE_AREA := Rect2(80.0, 360.0, 560.0, 560.0)

var _battle: CombatBattle
var _field: Field
var _status_label: Label
var _hint_label: Label
var _reward_label: Label
## C05: the session's progression (set by main.gd), read for the result's
## EXP preview and the info panel's Level / EXP; the world lifecycle applies it.
var progression: ProgressionState
var _exit_button: Button
var _retreat_button: Button
var _attack_all_button: Button
var _clock_label: Label
var _hp_bars: HpBars
var _group_buttons: Array[Button] = []
var _all_button: Button
var _group_hint: Label
var _portraits: Array[Portrait] = []
var _info_buttons: Array[Button] = []
var _info_panel: Panel
var _info_text: Label
var _info_unit: CombatUnit
var _skill_slots: Array[SkillSlot] = []
var _navigator: Navigator
var _camera := CombatCamera.new()
## C08 group editing (UI state): the group whose members portrait taps
## toggle, -1: none.
var _editing_group := -1
## C08 battlefield press (tap vs drag), owned by one pointer.
var _pressing := false
var _field_pointer := 0
## C08 navigator drag, owned by one pointer (-1: none).
var _navigator_pointer := -1
## C07 / C08: the pointer drawing the Gesture stroke.
var _stroke_pointer := 0
var _dragging := false
var _press_position := Vector2.ZERO
var _drag_last := Vector2.ZERO
var _gesture_overlay: GestureOverlay
var _gesture_result_label: Label
var _gesture_countdown_label: Label
var _gesture_clock_label: Label
## C07: the stroke being drawn (drawing-area units, see GestureMatcher).
var _stroke := PackedVector2Array()
var _drawing := false
var _feedback_left := 0.0
var _carry_ms := 0.0


func _ready() -> void:
	layer = 20
	visible = false
	var background := ColorRect.new()
	background.name = "Background"
	background.color = Color(0.07, 0.07, 0.09, 1.0)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(background)
	_camera.setup(Vector2(CombatConfig.COLUMNS * CELL_SIZE.x, CombatConfig.ROWS * CELL_SIZE.y), Vector2(SCREEN_WIDTH, FIELD_HEIGHT))
	_field = Field.new()
	_field.name = "Field"
	_field.view = self
	_field.position = Vector2(0.0, FIELD_TOP)
	_field.size = Vector2(SCREEN_WIDTH, FIELD_HEIGHT)
	_field.clip_contents = true
	add_child(_field)
	# Top row: 全體撤退 | Combat Clock | 全體進攻.
	_retreat_button = _button("RetreatButton", RETREAT_BUTTON_TEXT, Rect2(12.0, 16.0, 220.0, 68.0), 26)
	_retreat_button.pressed.connect(toggle_retreat)
	_attack_all_button = _button("AttackAllButton", ATTACK_ALL_TEXT, Rect2(488.0, 16.0, 220.0, 68.0), 26)
	_attack_all_button.pressed.connect(press_attack_all)
	_clock_label = _label("ClockLabel", 34.0, 20, Color(0.85, 0.85, 0.9))
	_status_label = _label("StatusLabel", 88.0, 34, Color(0.95, 0.8, 0.45))
	_hp_bars = HpBars.new()
	_hp_bars.name = "HpBars"
	_hp_bars.view = self
	_hp_bars.position = Vector2(12.0, 146.0)
	_hp_bars.size = Vector2(696.0, 40.0)
	_hp_bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hp_bars)
	# [群組①] [群組②] [全體]
	for index in range(2):
		var group := _button("GroupButton%d" % (index + 1), GROUP_TEXT % GROUP_MARKS[index], Rect2(12.0 + index * 238.0, 194.0, 220.0, 58.0), 26)
		group.pressed.connect(press_group.bind(index))
		_group_buttons.append(group)
	_all_button = _button("AllButton", ALL_TEXT, Rect2(488.0, 194.0, 220.0, 58.0), 26)
	_all_button.pressed.connect(press_all)
	_group_hint = _label("GroupHint", 254.0, 17, Color(0.75, 0.9, 0.75))
	for index in range(MAX_PORTRAITS):
		var portrait := Portrait.new()
		portrait.name = "Portrait%d" % index
		portrait.view = self
		portrait.index = index
		portrait.position = Vector2(12.0 + index * (PORTRAIT_SIZE.x + 7.0), PORTRAIT_TOP)
		portrait.size = PORTRAIT_SIZE
		add_child(portrait)
		_portraits.append(portrait)
		var info := _button("InfoButton%d" % index, INFO_BUTTON_TEXT, Rect2(portrait.position + Vector2(PORTRAIT_SIZE.x - 46.0, 4.0), Vector2(42.0, 42.0)), 22)
		info.pressed.connect(func() -> void: open_info(get_portrait_unit(index)))
		_info_buttons.append(info)
	for index in range(MAX_PORTRAITS * 2):
		var slot := SkillSlot.new()
		slot.name = "SkillSlot%d" % index
		slot.view = self
		slot.focus_mode = Control.FOCUS_NONE
		slot.visible = false
		slot.pressed.connect(press_skill_slot.bind(slot))
		add_child(slot)
		_skill_slots.append(slot)
	_navigator = Navigator.new()
	_navigator.name = "CameraNavigator"
	_navigator.view = self
	_navigator.position = NAVIGATOR_RECT.position
	_navigator.size = NAVIGATOR_RECT.size
	add_child(_navigator)
	_hint_label = _label("HintLabel", 1186.0, 22, Color(0.85, 0.85, 0.95))
	_reward_label = _label("RewardLabel", SKILL_BAR_TOP + 4.0, 24, Color(0.95, 0.85, 0.5))
	_reward_label.offset_bottom = _reward_label.offset_top + 76.0
	_exit_button = _button("ExitButton", EXIT_TEXT, Rect2(190.0, SKILL_BAR_TOP + 86.0, 340.0, 80.0), 30)
	_exit_button.pressed.connect(func() -> void: exit_requested.emit())
	_gesture_result_label = _label("GestureResultLabel", FIELD_TOP + 10.0, 34, Color(1.0, 0.9, 0.4))
	# Character info: a closable panel (only values the systems already have).
	_info_panel = Panel.new()
	_info_panel.name = "InfoPanel"
	_info_panel.position = Vector2(60.0, 300.0)
	_info_panel.size = Vector2(600.0, 420.0)
	_info_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_info_panel.visible = false
	var info_style := StyleBoxFlat.new()
	info_style.bg_color = Color(0.1, 0.1, 0.13)
	info_style.border_color = Color(0.6, 0.6, 0.65)
	info_style.set_border_width_all(2)
	_info_panel.add_theme_stylebox_override("panel", info_style)
	add_child(_info_panel)
	_info_text = Label.new()
	_info_text.name = "InfoText"
	_info_text.position = Vector2(24.0, 20.0)
	_info_text.size = Vector2(552.0, 300.0)
	_info_text.add_theme_font_size_override("font_size", 24)
	_info_panel.add_child(_info_text)
	var close := Button.new()
	close.name = "InfoClose"
	close.text = INFO_CLOSE_TEXT
	close.focus_mode = Control.FOCUS_NONE
	close.position = Vector2(200.0, 330.0)
	close.size = Vector2(200.0, 68.0)
	close.add_theme_font_size_override("font_size", 26)
	close.pressed.connect(close_info)
	_info_panel.add_child(close)
	# The Gesture Window: on top of everything, it takes every touch.
	_gesture_overlay = GestureOverlay.new()
	_gesture_overlay.name = "GestureOverlay"
	_gesture_overlay.view = self
	_gesture_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_gesture_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_gesture_overlay.visible = false
	add_child(_gesture_overlay)
	var title := _label("GestureTitle", 230.0, 30, Color(0.95, 0.95, 1.0))
	_gesture_countdown_label = _label("GestureCountdown", 280.0, 30, Color(1.0, 0.85, 0.4))
	_gesture_clock_label = _label("GestureClock", 940.0, 26, Color(0.85, 0.85, 0.9))
	for label in [title, _gesture_countdown_label, _gesture_clock_label]:
		remove_child(label)
		_gesture_overlay.add_child(label)
	title.text = GESTURE_TITLE_TEXT
	_refresh()


func _label(label_name: String, top: float, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.name = label_name
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	label.offset_top = top
	label.offset_bottom = top + font_size * 1.6
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	add_child(label)
	return label


func _button(button_name: String, text: String, rect: Rect2, font_size: int) -> Button:
	var button := Button.new()
	button.name = button_name
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.position = rect.position
	button.size = rect.size
	button.add_theme_font_size_override("font_size", font_size)
	add_child(button)
	return button


func open(battle: CombatBattle) -> void:
	_battle = battle
	_carry_ms = 0.0
	_stroke.clear()
	_drawing = false
	_feedback_left = 0.0
	_gesture_result_label.text = ""
	_editing_group = -1
	_info_unit = null
	_pressing = false
	_dragging = false
	_navigator_pointer = -1
	_camera.offset = Vector2.ZERO
	battle.gesture_resolved.connect(_on_gesture_resolved)
	visible = true
	_refresh()


func close() -> void:
	if _battle != null and _battle.gesture_resolved.is_connected(_on_gesture_resolved):
		_battle.gesture_resolved.disconnect(_on_gesture_resolved)
	_battle = null
	_editing_group = -1
	_info_unit = null
	visible = false


func is_open() -> bool:
	return _battle != null


func get_battle() -> CombatBattle:
	return _battle


func get_camera() -> CombatCamera:
	return _camera


func _physics_process(delta: float) -> void:
	if _battle == null:
		return
	_carry_ms += delta * 1000.0
	var ms := int(_carry_ms)
	_carry_ms -= ms
	_battle.advance(ms)


func _process(delta: float) -> void:
	# C07: the Gesture result shows for a moment of UI time only.
	_feedback_left = maxf(_feedback_left - delta, 0.0)
	if _battle != null:
		_refresh()


## C08: the battlefield's horizontal scroll (the camera; it follows no unit).
func get_scroll_x() -> float:
	return _camera.offset.x


## Screen position -> grid cell (outside the grid or the field: (-1, -1)).
func cell_at(screen_position: Vector2) -> Vector2i:
	if screen_position.y < FIELD_TOP or screen_position.y >= FIELD_TOP + FIELD_HEIGHT:
		return Vector2i(-1, -1)
	var local := screen_position - Vector2(0.0, FIELD_TOP) + _camera.offset
	if local.x < 0.0 or local.y < 0.0:
		return Vector2i(-1, -1)
	var cell := Vector2i(int(local.x / CELL_SIZE.x), int(local.y / CELL_SIZE.y))
	return cell if CombatBattle.is_in_grid(cell) else Vector2i(-1, -1)


## Screen centre of a (fractional) grid cell.
func cell_center(cell: Vector2) -> Vector2:
	return Vector2(cell.x * CELL_SIZE.x + CELL_SIZE.x / 2.0, FIELD_TOP + cell.y * CELL_SIZE.y + CELL_SIZE.y / 2.0) - _camera.offset


## One tap / click on the battlefield.
func tap_at(screen_position: Vector2) -> bool:
	if _battle == null:
		return false
	var cell := cell_at(screen_position)
	return cell != Vector2i(-1, -1) and _battle.tap(cell)


## C08 battlefield press / drag / release (screen pixels) of one pointer. A
## release that never moved past DRAG_THRESHOLD is a tap; otherwise the press
## only pans the camera and issues no command. While one pointer presses the
## battlefield another finger landing on it is ignored (the same finger
## pressing again restarts); other pointers' drags and releases never touch
## this press.
func field_press(screen_position: Vector2, pointer := 0) -> void:
	if _pressing and pointer != _field_pointer:
		return
	_pressing = true
	_field_pointer = pointer
	_dragging = false
	_press_position = screen_position
	_drag_last = screen_position


func field_drag(screen_position: Vector2, pointer := 0) -> void:
	if not _pressing or pointer != _field_pointer:
		return
	if not _dragging and screen_position.distance_to(_press_position) > DRAG_THRESHOLD:
		_dragging = true
	if _dragging:
		_camera.drag(screen_position - _drag_last)
		_drag_last = screen_position
		_field.queue_redraw()


func field_release(screen_position: Vector2, pointer := 0) -> bool:
	if not _pressing or pointer != _field_pointer:
		return false
	_pressing = false
	if _dragging:
		_dragging = false
		return false
	return tap_at(screen_position)


## A pointer lifted or cancelled away (e.g. the system took the touch):
## its battlefield press ends with no command.
func field_cancel(pointer := 0) -> void:
	if _pressing and pointer == _field_pointer:
		_pressing = false
		_dragging = false


func is_field_pressed() -> bool:
	return _pressing


## C08 navigator: centre the camera on `ratio` of the battlefield width.
func navigate_to(ratio: float) -> void:
	_camera.center_on_ratio(ratio)
	_field.queue_redraw()


## C08 navigator press / drag / release of one pointer: it only moves the
## camera (never a command, never the battlefield press). The newest pointer
## pressing it takes over; other pointers' drags and releases are ignored.
func navigator_press(ratio: float, pointer := 0) -> void:
	_navigator_pointer = pointer
	navigate_to(ratio)


func navigator_drag(ratio: float, pointer := 0) -> void:
	if pointer == _navigator_pointer:
		navigate_to(ratio)


func navigator_release(pointer := 0) -> void:
	if pointer == _navigator_pointer:
		_navigator_pointer = -1


## The pointer dragging the navigator (-1: none).
func get_navigator_pointer() -> int:
	return _navigator_pointer


## C08 multi-touch: an input event as [kind, pointer, position]; kind is
## "press" / "move" / "release" / "cancel", "emulated" for the mouse events
## Godot emulates from a finger (dropped: that finger's own touch events
## already arrive, so it is never handled twice) or "" for anything else.
## Every finger is its own pointer (its touch index); a real mouse is
## MOUSE_POINTER.
static func pointer_event(event: InputEvent) -> Array:
	var touch := event as InputEventScreenTouch
	if touch != null:
		if touch.canceled:
			return ["cancel", touch.index, touch.position]
		return ["press" if touch.pressed else "release", touch.index, touch.position]
	var drag := event as InputEventScreenDrag
	if drag != null:
		return ["move", drag.index, drag.position]
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		return ["emulated", MOUSE_POINTER, Vector2.ZERO]
	var click := event as InputEventMouseButton
	if click != null and click.button_index == MOUSE_BUTTON_LEFT:
		return ["press" if click.pressed else "release", MOUSE_POINTER, click.position]
	var motion := event as InputEventMouseMotion
	if motion != null and motion.button_mask & MOUSE_BUTTON_MASK_LEFT:
		return ["move", MOUSE_POINTER, motion.position]
	return ["", MOUSE_POINTER, Vector2.ZERO]


## C08 全體進攻: every alive friendly unit attacks its nearest enemy.
func press_attack_all() -> bool:
	if _battle == null:
		return false
	var done := _battle.attack_all()
	_refresh()
	return done


## C08 aggregate HP as whole percents (rounded, but never 100 while damaged
## nor 0 while any HP is left).
func get_friend_hp_percent() -> int:
	return _percent(_battle.get_friend_hp_ratio()) if _battle != null else 0


func get_enemy_hp_percent() -> int:
	return _percent(_battle.get_enemy_hp_ratio()) if _battle != null else 0


static func _percent(ratio: float) -> int:
	var value := roundi(ratio * 100.0)
	if ratio < 1.0:
		value = mini(value, 99)
	if ratio > 0.0:
		value = maxi(value, 1)
	return value


# --- Groups & portraits (C08) ------------------------------------------------------------------

## [群組①] / [群組②]: an empty group starts editing; a group being edited
## finishes and selects its alive members; a group already selected starts
## editing again; any other tap selects its alive members.
func press_group(index: int) -> bool:
	if _battle == null:
		return false
	if _editing_group == index:
		_editing_group = -1
		_battle.select_group(index)
	elif _battle.get_group(index).is_empty() or is_group_selected(index):
		_editing_group = index
	else:
		_editing_group = -1
		_battle.select_group(index)
	_refresh()
	return true


## [全體]: every alive friendly unit.
func press_all() -> bool:
	if _battle == null:
		return false
	_editing_group = -1
	var done := _battle.select_all()
	_refresh()
	return done


func get_editing_group() -> int:
	return _editing_group


## Whether the selection is exactly group `index`'s alive members.
func is_group_selected(index: int) -> bool:
	if _battle == null:
		return false
	var alive := _battle.get_group(index).filter(func(u: CombatUnit) -> bool: return u.alive)
	return not alive.is_empty() and alive == _battle.get_selection()


## A portrait tap: while editing a group it toggles that member; otherwise it
## selects the unit alone (a group command was a one-time order; the unit's
## next order replaces only its own).
func press_portrait(unit: CombatUnit) -> bool:
	if _battle == null or unit == null:
		return false
	var done := false
	if _editing_group >= 0:
		_battle.toggle_group_member(_editing_group, unit)
		done = true
	else:
		done = _battle.select_unit(unit)
	_refresh()
	return done


## The friendly unit shown by portrait `index` (null: empty slot).
func get_portrait_unit(index: int) -> CombatUnit:
	if _battle == null or index >= _battle.get_friends().size():
		return null
	return _battle.get_friends()[index]


## What portrait `index` shows: {unit, selected, caster, dead, groups
## (["①", "②"] marks), editing (a member of the group being edited)}.
func get_portrait_state(index: int) -> Dictionary:
	var unit := get_portrait_unit(index)
	if unit == null:
		return {}
	var groups := []
	for group in range(2):
		if _battle.get_group(group).has(unit):
			groups.append(GROUP_MARKS[group])
	return {"unit": unit, "selected": _battle.get_selection().has(unit), "caster": unit == _battle.get_selected(), "dead": not unit.alive, "groups": groups, "editing": _editing_group >= 0 and _battle.get_group(_editing_group).has(unit)}


func get_group_hint() -> String:
	if _editing_group >= 0:
		return GROUP_EDIT_HINT % [GROUP_MARKS[_editing_group], GROUP_MARKS[_editing_group]]
	for index in range(2):
		if is_group_selected(index):
			return GROUP_SELECTED_HINT % GROUP_MARKS[index]
	return ""


# --- Character info (C08) ------------------------------------------------------------------------

func open_info(unit: CombatUnit) -> bool:
	if _battle == null or unit == null:
		return false
	_info_unit = unit
	_refresh()
	return true


func close_info() -> void:
	_info_unit = null
	_refresh()


func get_info_unit() -> CombatUnit:
	return _info_unit


func get_info_text(unit: CombatUnit) -> String:
	if _battle == null or unit == null:
		return ""
	var text: String = INFO_TEXT % [ROLE_NAMES[unit.role], unit.hp, unit.max_hp, unit.mp, unit.max_mp, unit.attack_damage, unit.attack_range, unit.attack_interval_ms / 1000.0, unit.move_speed]
	if progression != null:
		text += INFO_PROGRESS_TEXT % [progression.get_level(unit.id), progression.get_exp(unit.id)]
	for entry in _skill_entries_for(unit, false):
		text += INFO_SKILL_TEXT % [entry["title"], entry["state"]]
	if _battle.get_guard_remaining(unit) > 0:
		text += INFO_GUARD_TEXT % (_battle.get_guard_remaining(unit) / 1000.0)
	return text


# --- Skill bar (C08) ---------------------------------------------------------------------------

## The skill bar: one entry per Skill of every selected unit (the Hero's
## Normal Skill, then its Gesture). One selected unit: full text; several:
## compact (icon + owner). Each entry: owner, kind, title, state, text,
## disabled, compact.
func get_skill_bar_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	# (As the C06 Skill button: hidden while retreating and after the result.)
	if _battle == null or _battle.is_over() or _battle.is_retreating():
		return entries
	var selection := _battle.get_selection()
	var compact := selection.size() > 1
	for unit in selection:
		entries.append_array(_skill_entries_for(unit, compact))
	return entries


func _skill_entries_for(unit: CombatUnit, compact: bool) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	if unit.skill.is_empty():
		return entries
	var kind: String = unit.skill["kind"]
	var state := SKILL_READY_STATE
	var ready := false
	if _battle.get_phase() == CombatBattle.Phase.PREPARATION:
		state = SKILL_PREPARATION_STATE
	elif _battle.is_aiming() and unit == _battle.get_selected():
		state = SKILL_AIM_STATE
		ready = true
	elif unit.skill_state == CombatUnit.SkillState.PENDING:
		state = SKILL_PENDING_STATE
		ready = _battle.get_skill_readiness(unit) == CombatBattle.SkillReadiness.READY
	else:
		match _battle.get_skill_readiness(unit):
			CombatBattle.SkillReadiness.READY:
				ready = true
			CombatBattle.SkillReadiness.CASTING:
				state = SKILL_CASTING_STATE
			CombatBattle.SkillReadiness.COOLDOWN:
				state = SKILL_COOLDOWN_STATE % (_battle.get_skill_cooldown_remaining(unit) / 1000.0)
			CombatBattle.SkillReadiness.NO_MP:
				state = SKILL_NO_MP_STATE
			_:
				state = SKILL_UNAVAILABLE_STATE
	entries.append(_entry(unit, kind, NORMAL_SKILL_TEXT % [SKILL_NAMES[kind], CombatConfig.SKILL_MP_COST], state, not ready, compact))
	if unit.is_hero:
		var gesture_state := SKILL_READY_STATE
		if _battle.get_phase() == CombatBattle.Phase.PREPARATION:
			gesture_state = SKILL_PREPARATION_STATE
		else:
			match _battle.get_gesture_readiness():
				CombatBattle.GestureReadiness.OPEN:
					gesture_state = GESTURE_OPEN_STATE
				CombatBattle.GestureReadiness.CASTING:
					gesture_state = GESTURE_CASTING_STATE
				CombatBattle.GestureReadiness.COOLDOWN:
					gesture_state = SKILL_COOLDOWN_STATE % (_battle.get_gesture_cooldown_remaining() / 1000.0)
				CombatBattle.GestureReadiness.NO_MP:
					gesture_state = SKILL_NO_MP_STATE
				CombatBattle.GestureReadiness.UNAVAILABLE:
					gesture_state = SKILL_UNAVAILABLE_STATE
		var gesture_ready := _battle.get_phase() == CombatBattle.Phase.FIGHTING and _battle.get_gesture_readiness() == CombatBattle.GestureReadiness.READY
		entries.append(_entry(unit, "lightning", SPECIAL_SKILL_TEXT % [SKILL_NAMES["lightning"], CombatConfig.GESTURE_MP_COST], gesture_state, not gesture_ready, compact))
	return entries


func _entry(unit: CombatUnit, kind: String, title: String, state: String, disabled: bool, compact: bool) -> Dictionary:
	var text := title + "\n" + state
	if compact:
		text = ROLE_NAMES[unit.role] if state == SKILL_READY_STATE else ROLE_NAMES[unit.role] + "\n" + state
	return {"owner": unit, "kind": kind, "title": title, "state": state, "text": text, "disabled": disabled, "compact": compact}


## A skill bar tap: its owner becomes the Active Caster (the selection
## stays), then the existing Skill flow runs (Guard at once, Slow / AoE aim,
## Lightning opens the Gesture Window).
func press_skill_entry(entry: Dictionary) -> bool:
	if _battle == null or entry.is_empty():
		return false
	var owner: CombatUnit = entry["owner"]
	if owner != _battle.get_selected() and not _battle.set_active_caster(owner):
		return false
	if entry["kind"] == "lightning":
		return press_gesture()
	return press_skill()


func press_skill_slot(slot: SkillSlot) -> void:
	press_skill_entry(slot.entry)


## C06: the selected unit's Skill: Guard at once, Slow / AoE start aiming
## (the next tap on an enemy); pressed while aiming it cancels the aim.
func press_skill() -> bool:
	if _battle == null:
		return false
	var done := true
	if _battle.is_aiming():
		_battle.cancel_skill_aim()
	else:
		done = _battle.start_skill_aim()
	_refresh()
	return done


## C05: the result screen's EXP line(s): what each survivor gets and who
## reaches a new Level (preview of the commit), or that nothing was earned.
func get_reward_text() -> String:
	if _battle == null or _battle.get_result() == null or progression == null:
		return ""
	var shares := progression.preview(_battle.get_result())
	if shares.is_empty():
		return NO_REWARD_TEXT
	var gains := []
	var levels := []
	for unit in _battle.get_friends():
		if shares.has(unit.id):
			gains.append(REWARD_TEXT % [ROLE_NAMES[unit.role], shares[unit.id]["exp"]])
			if shares[unit.id]["leveled"]:
				levels.append(LEVEL_UP_TEXT % [ROLE_NAMES[unit.role], shares[unit.id]["level"]])
	return "　".join(gains) + ("\n" + "　".join(levels) if not levels.is_empty() else "")


## C07: the 閃電 button (selected Hero only): opens the Gesture Window.
func press_gesture() -> bool:
	if _battle == null or not _battle.open_gesture():
		return false
	_stroke.clear()
	_drawing = false
	_refresh()
	return true


## C07: the 閃電 button text ("" when it is not shown).
func get_gesture_button_text() -> String:
	if _battle == null or _battle.get_selected() == null or not _battle.get_selected().is_hero:
		return ""
	if _battle.get_phase() == CombatBattle.Phase.PREPARATION:
		return GESTURE_PREPARATION_TEXT
	match _battle.get_gesture_readiness():
		CombatBattle.GestureReadiness.OPEN:
			return GESTURE_OPEN_TEXT
		CombatBattle.GestureReadiness.CASTING:
			return GESTURE_CASTING_TEXT
		CombatBattle.GestureReadiness.COOLDOWN:
			return GESTURE_COOLDOWN_TEXT % (_battle.get_gesture_cooldown_remaining() / 1000.0)
		CombatBattle.GestureReadiness.NO_MP:
			return GESTURE_NO_MP_TEXT
	return GESTURE_READY_TEXT % CombatConfig.GESTURE_MP_COST


## C07: the Combat Clock line ("" outside FIGHTING).
func get_clock_text() -> String:
	if _battle == null or _battle.get_phase() != CombatBattle.Phase.FIGHTING:
		return ""
	if _battle.is_time_up():
		return TIME_UP_TEXT
	var seconds := _battle.get_combat_clock_ms() / 1000
	return CLOCK_TEXT % [seconds / 60, seconds % 60]


## C07: the Gesture Window's stroke, in screen pixels (one stroke; lifting
## the finger submits it — a too-short touch is ignored and the window stays).
func begin_stroke(screen_position: Vector2, pointer := 0) -> void:
	if _battle == null or not _battle.is_gesture_open():
		return
	# One stroke at a time: another finger landing meanwhile is ignored.
	if _drawing and pointer != _stroke_pointer:
		return
	_stroke_pointer = pointer
	_stroke.clear()
	_stroke.append(_to_area(screen_position))
	_drawing = true


func extend_stroke(screen_position: Vector2, pointer := 0) -> void:
	if _drawing and pointer == _stroke_pointer:
		_stroke.append(_to_area(screen_position))


func end_stroke(pointer := 0) -> Dictionary:
	if not _drawing or _battle == null or pointer != _stroke_pointer:
		return {}
	_drawing = false
	var result := _battle.submit_gesture(_stroke)
	if result.is_empty():
		_stroke.clear()
	_refresh()
	return result


func get_stroke() -> PackedVector2Array:
	return _stroke


func _to_area(screen_position: Vector2) -> Vector2:
	return (screen_position - GESTURE_AREA.position) / GESTURE_AREA.size.x


func _on_gesture_resolved(result: Dictionary) -> void:
	_stroke.clear()
	_drawing = false
	var grade: int = result["grade"]
	if result["timeout"]:
		_gesture_result_label.text = GESTURE_TIMEOUT_TEXT
	elif grade == GestureMatcher.Grade.FAIL:
		_gesture_result_label.text = GESTURE_FAIL_TEXT % result["score"]
	else:
		_gesture_result_label.text = GESTURE_HIT_TEXT % [GESTURE_GRADE_TEXTS[grade], result["score"], result["damage"], result["targets"].size()]
	_feedback_left = GESTURE_FEEDBACK_SECONDS


func get_gesture_result_text() -> String:
	return _gesture_result_label.text if _feedback_left > 0.0 else ""


## C04: the 全體撤退 / 取消撤退 button: starts or cancels the party retreat.
func toggle_retreat() -> bool:
	if _battle == null:
		return false
	var done := _battle.cancel_retreat() if _battle.is_retreating() else _battle.start_retreat()
	_refresh()
	return done


func _refresh() -> void:
	if _status_label == null:
		return
	var active := _battle != null and not _battle.is_over()
	_exit_button.visible = _battle != null and _battle.is_over()
	if _battle == null:
		_gesture_overlay.visible = false
		_clock_label.visible = false
		for slot in _skill_slots:
			slot.visible = false
		return
	var phase := _battle.get_phase()
	_retreat_button.visible = phase == CombatBattle.Phase.FIGHTING
	_retreat_button.text = CANCEL_RETREAT_TEXT if _battle.is_retreating() else RETREAT_BUTTON_TEXT
	# C07: a forced retreat cannot be cancelled.
	_retreat_button.disabled = _battle.is_forced_retreat()
	if _battle.is_forced_retreat():
		_retreat_button.text = FORCED_RETREAT_BUTTON_TEXT
	_attack_all_button.visible = active
	_attack_all_button.disabled = phase != CombatBattle.Phase.FIGHTING or _battle.is_retreating() or _battle.is_gesture_open()
	_clock_label.text = get_clock_text()
	_clock_label.visible = _clock_label.text != ""
	match phase:
		CombatBattle.Phase.PREPARATION:
			_status_label.text = PREPARATION_TEXT % ceili(_battle.get_preparation_remaining_ms() / 1000.0)
		CombatBattle.Phase.FIGHTING:
			_status_label.text = RETREATING_TEXT if _battle.is_retreating() else FIGHTING_TEXT
		CombatBattle.Phase.VICTORY:
			_status_label.text = VICTORY_TEXT
		CombatBattle.Phase.DEFEAT:
			_status_label.text = DEFEAT_TEXT
		CombatBattle.Phase.RETREAT:
			_status_label.text = RETREAT_TEXT
	_hp_bars.queue_redraw()
	for index in range(2):
		_group_buttons[index].visible = active
		_group_buttons[index].text = (GROUP_DONE_TEXT if _editing_group == index else GROUP_TEXT) % GROUP_MARKS[index]
		_group_buttons[index].modulate = Color(1.0, 0.9, 0.5) if _editing_group == index or is_group_selected(index) else Color.WHITE
	_all_button.visible = active
	_group_hint.text = get_group_hint() if active else ""
	for index in range(MAX_PORTRAITS):
		var unit := get_portrait_unit(index)
		_portraits[index].visible = unit != null
		_info_buttons[index].visible = unit != null
		_portraits[index].queue_redraw()
	_info_panel.visible = _info_unit != null
	if _info_unit != null:
		_info_text.text = get_info_text(_info_unit)
	_refresh_skill_bar()
	_hint_label.text = AIM_HINT_TEXT if _battle.is_aiming() else ""
	_hint_label.visible = _hint_label.text != ""
	_gesture_overlay.visible = _battle.is_gesture_open()
	if _gesture_overlay.visible:
		var seconds := _battle.get_combat_clock_ms() / 1000
		_gesture_countdown_label.text = GESTURE_COUNTDOWN_TEXT % ceili(_battle.get_gesture_remaining_ms() / 1000.0)
		_gesture_clock_label.text = GESTURE_CLOCK_TEXT % [seconds / 60, seconds % 60]
		_gesture_overlay.queue_redraw()
	_gesture_result_label.visible = get_gesture_result_text() != ""
	_reward_label.visible = _battle.is_over()
	_reward_label.text = get_reward_text() if _battle.is_over() else ""
	_field.queue_redraw()
	_navigator.queue_redraw()


func _refresh_skill_bar() -> void:
	var entries := get_skill_bar_entries()
	var compact: bool = not entries.is_empty() and entries[0]["compact"]
	for index in range(_skill_slots.size()):
		var slot := _skill_slots[index]
		slot.visible = index < entries.size()
		if not slot.visible:
			slot.entry = {}
			continue
		var entry: Dictionary = entries[index]
		slot.entry = entry
		slot.text = entry["text"]
		slot.disabled = entry["disabled"]
		slot.add_theme_font_size_override("font_size", 18 if compact else 22)
		if compact:
			slot.position = Vector2(12.0 + index * 88.0, SKILL_BAR_TOP)
			slot.size = Vector2(82.0, 150.0)
		else:
			slot.position = Vector2(12.0, SKILL_BAR_TOP + index * 80.0)
			slot.size = Vector2(696.0, 74.0)
		slot.queue_redraw()


## The battlefield drawing; press / drag / release go to the view (tap vs
## camera drag). Drawn in the field's own coordinates (its top-left is the
## screen point (0, FIELD_TOP)).
class Field extends Control:
	var view: CombatView

	func _gui_input(event: InputEvent) -> void:
		# Each finger (touch index) or the desktop mouse is its own pointer.
		var pointer_event := CombatView.pointer_event(event)
		var kind: String = pointer_event[0]
		var pointer: int = pointer_event[1]
		var at: Vector2 = pointer_event[2] + position
		match kind:
			"press":
				view.field_press(at, pointer)
			"move":
				view.field_drag(at, pointer)
			"release":
				view.field_release(at, pointer)
			"cancel":
				view.field_cancel(pointer)
		if kind != "":
			accept_event()

	## Screen point -> this control's local point.
	func _p(screen: Vector2) -> Vector2:
		return screen - position

	func _draw() -> void:
		var battle := view.get_battle()
		if battle == null:
			return
		var cell_size := CombatView.CELL_SIZE
		var origin := _p(view.cell_center(Vector2.ZERO)) - cell_size / 2.0
		var width := CombatConfig.COLUMNS * cell_size.x
		var height := CombatConfig.ROWS * cell_size.y
		draw_rect(Rect2(origin, Vector2(width, height)), Color(0.16, 0.2, 0.17))
		if battle.get_phase() == CombatBattle.Phase.PREPARATION:
			var start := origin.x + CombatConfig.PREPARATION_FIRST_COLUMN * cell_size.x
			draw_rect(Rect2(start, origin.y, CombatConfig.PREPARATION_COLUMNS * cell_size.x, height), Color(0.3, 0.7, 0.4, 0.35))
			draw_line(Vector2(start, origin.y), Vector2(start, origin.y + height), Color(0.5, 1.0, 0.6), 4.0)
			var edge := start + CombatConfig.PREPARATION_COLUMNS * cell_size.x
			draw_line(Vector2(edge, origin.y), Vector2(edge, origin.y + height), Color(0.5, 1.0, 0.6), 4.0)
		elif battle.get_phase() == CombatBattle.Phase.FIGHTING:
			# C04: the Retreat Zone (column 0), brighter while retreating.
			draw_rect(Rect2(origin, Vector2(cell_size.x, height)), Color(0.95, 0.6, 0.2, 0.45 if battle.is_retreating() else 0.2))
			draw_string(get_theme_default_font(), origin + Vector2(2.0, 18.0), CombatView.RETREAT_ZONE_TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 16, Color(0.95, 0.7, 0.35))
		for column in range(CombatConfig.COLUMNS + 1):
			var x := origin.x + column * cell_size.x
			draw_line(Vector2(x, origin.y), Vector2(x, origin.y + height), Color(1, 1, 1, 0.08), 1.0)
		for row in range(CombatConfig.ROWS + 1):
			var y := origin.y + row * cell_size.y
			draw_line(Vector2(origin.x, y), Vector2(origin.x + width, y), Color(1, 1, 1, 0.08), 1.0)
		# C06: the last AoE's cells, briefly.
		var aoe := battle.get_last_aoe()
		if not aoe.is_empty() and battle.get_elapsed_ms() - int(aoe["at_ms"]) < CombatView.AOE_MARK_MS:
			for cell: Vector2i in aoe["cells"]:
				draw_rect(Rect2(origin + Vector2(cell) * cell_size, cell_size), Color(1.0, 0.55, 0.15, 0.5))
			var center: Vector2i = aoe["cells"][0]
			draw_string(get_theme_default_font(), _p(view.cell_center(Vector2(center))) + Vector2(-40.0, -40.0), CombatView.AOE_TEXT % CombatConfig.AOE_DAMAGE, HORIZONTAL_ALIGNMENT_CENTER, 80.0, 18, Color(1.0, 0.85, 0.4))
		# C07: the last Gesture's targets, while its result shows.
		if view.get_gesture_result_text() != "" and battle.get_last_gesture().has("targets"):
			for unit: CombatUnit in battle.get_last_gesture()["targets"]:
				draw_arc(_p(view.cell_center(unit.visual_cell())), 24.0, 0.0, TAU, 32, Color(1.0, 0.95, 0.3), 4.0)
		for unit in battle.get_enemies():
			_draw_unit(unit, Color(0.55, 0.3, 0.85) if battle.get_slow_remaining(unit) > 0 else Color(0.85, 0.25, 0.2))
			if battle.get_slow_remaining(unit) > 0:
				draw_string(get_theme_default_font(), _p(view.cell_center(unit.visual_cell())) + Vector2(-10.0, 8.0), CombatView.SLOW_MARK_TEXT, HORIZONTAL_ALIGNMENT_CENTER, 20.0, 18, Color.WHITE)
		var selection := battle.get_selection()
		for unit in battle.get_friends():
			_draw_unit(unit, CombatView.ROLE_COLORS[unit.role])
			_draw_name(unit)
			var at := _p(view.cell_center(unit.visual_cell()))
			# C06: Guard ring, cast progress, the pending Skill's target.
			if battle.get_guard_remaining(unit) > 0:
				draw_arc(at, 27.0, 0.0, TAU, 32, Color(0.4, 0.75, 1.0), 4.0)
			if unit.skill_state == CombatUnit.SkillState.CASTING:
				var done := 1.0 - float(battle.get_cast_remaining(unit)) / CombatConfig.SKILL_CAST_MS
				draw_arc(at, 31.0, -PI / 2.0, -PI / 2.0 + TAU * done, 32, Color(1.0, 0.95, 0.5), 4.0)
			elif unit.skill_state == CombatUnit.SkillState.PENDING and unit.skill_target != unit:
				draw_arc(_p(view.cell_center(unit.skill_target.visual_cell())), 26.0, 0.0, TAU, 32, Color(0.75, 0.45, 1.0), 3.0)
			# C08: every selected unit ringed; the Active Caster in gold.
			if selection.has(unit):
				var caster := unit == battle.get_selected()
				draw_arc(at, 22.0, 0.0, TAU, 32, Color(1.0, 0.85, 0.3) if caster else Color.WHITE, 4.0 if caster else 2.0)
				if unit.target != null and unit.target.alive:
					draw_arc(_p(view.cell_center(unit.target.visual_cell())), 22.0, 0.0, TAU, 32, Color(1.0, 0.9, 0.2), 2.0)
				elif unit.has_goal:
					var goal := _p(view.cell_center(Vector2(unit.goal)))
					draw_rect(Rect2(goal - Vector2(10, 10), Vector2(20, 20)), Color(1, 1, 1, 0.6), false, 2.0)

	func _draw_name(unit: CombatUnit) -> void:
		var center := _p(view.cell_center(unit.visual_cell()))
		var color := Color(0.9, 0.9, 0.9) if unit.alive else Color(0.5, 0.5, 0.5)
		draw_string(get_theme_default_font(), center + Vector2(-30.0, 38.0), CombatView.ROLE_NAMES[unit.role], HORIZONTAL_ALIGNMENT_CENTER, 60.0, 16, color)

	func _draw_unit(unit: CombatUnit, color: Color) -> void:
		var center := _p(view.cell_center(unit.visual_cell()))
		if not unit.alive:
			draw_circle(center, 8.0, Color(0.3, 0.3, 0.3))
			return
		draw_circle(center, 17.0, color)
		var bar := Rect2(center + Vector2(-20.0, -34.0), Vector2(40.0, 6.0))
		draw_rect(bar, Color(0.2, 0.05, 0.05))
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * unit.hp / unit.max_hp, bar.size.y)), Color(0.3, 0.9, 0.35))


## C08: friendly and enemy aggregate HP. Both start full at the centre; the
## friendly fill shrinks towards the left, the enemy fill towards the right.
## Two independent bars (not a tug-of-war).
class HpBars extends Control:
	var view: CombatView

	func _draw() -> void:
		var half := size.x / 2.0 - 4.0
		var battle := view.get_battle()
		var friend := battle.get_friend_hp_ratio() if battle != null else 1.0
		var enemy := battle.get_enemy_hp_ratio() if battle != null else 1.0
		var center := size.x / 2.0
		draw_rect(Rect2(0.0, 0.0, half, size.y), Color(0.15, 0.15, 0.18))
		draw_rect(Rect2(center + 4.0, 0.0, half, size.y), Color(0.15, 0.15, 0.18))
		draw_rect(Rect2(center - 4.0 - half * friend, 0.0, half * friend, size.y), Color(0.3, 0.75, 0.4))
		draw_rect(Rect2(center + 4.0, 0.0, half * enemy, size.y), Color(0.85, 0.3, 0.25))
		var font := get_theme_default_font()
		draw_string(font, Vector2(8.0, size.y - 10.0), CombatView.FRIEND_HP_TEXT % view.get_friend_hp_percent(), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 22, Color.WHITE)
		draw_string(font, Vector2(center + 8.0, size.y - 10.0), CombatView.ENEMY_HP_TEXT % view.get_enemy_hp_percent(), HORIZONTAL_ALIGNMENT_RIGHT, half - 8.0, 22, Color.WHITE)


## C08: one friendly unit's portrait (tap: select alone / group edit). Shows selected, Active Caster, dead and group ① / ② marks.
class Portrait extends Control:
	var view: CombatView
	var index := 0

	func _gui_input(event: InputEvent) -> void:
		# Any finger (or the mouse) taps it on release over the portrait.
		var pointer_event := CombatView.pointer_event(event)
		var kind: String = pointer_event[0]
		if kind == "release" and Rect2(Vector2.ZERO, size).has_point(pointer_event[2]):
			view.press_portrait(view.get_portrait_unit(index))
		if kind != "":
			accept_event()

	func _draw() -> void:
		var unit := view.get_portrait_unit(index)
		var battle := view.get_battle()
		if unit == null or battle == null:
			return
		var color: Color = CombatView.ROLE_COLORS[unit.role]
		var font := get_theme_default_font()
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.13, 0.13, 0.16) if unit.alive else Color(0.08, 0.08, 0.09))
		draw_circle(Vector2(30.0, 34.0), 20.0, color if unit.alive else Color(0.3, 0.3, 0.3))
		draw_string(font, Vector2(58.0, 34.0), CombatView.ROLE_NAMES[unit.role], HORIZONTAL_ALIGNMENT_LEFT, -1.0, 20, Color.WHITE if unit.alive else Color(0.5, 0.5, 0.5))
		if unit.alive:
			draw_rect(Rect2(10.0, 64.0, size.x - 20.0, 10.0), Color(0.2, 0.05, 0.05))
			draw_rect(Rect2(10.0, 64.0, (size.x - 20.0) * unit.hp / unit.max_hp, 10.0), Color(0.3, 0.9, 0.35))
			if unit.max_mp > 0:
				draw_rect(Rect2(10.0, 80.0, size.x - 20.0, 8.0), Color(0.05, 0.05, 0.2))
				draw_rect(Rect2(10.0, 80.0, (size.x - 20.0) * unit.mp / unit.max_mp, 8.0), Color(0.35, 0.55, 1.0))
		else:
			draw_string(font, Vector2(10.0, 84.0), CombatView.DEAD_TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 20, Color(0.75, 0.35, 0.35))
		var marks := ""
		for group in range(2):
			if battle.get_group(group).has(unit):
				marks += CombatView.GROUP_MARKS[group]
		draw_string(font, Vector2(10.0, size.y - 4.0), marks, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 18, Color(0.75, 0.95, 0.75))
		if view.get_editing_group() >= 0:
			draw_rect(Rect2(Vector2.ZERO, size), Color(0.5, 1.0, 0.6, 0.15 if battle.get_group(view.get_editing_group()).has(unit) else 0.0))
		var caster := unit == battle.get_selected()
		if battle.get_selection().has(unit):
			draw_rect(Rect2(Vector2(2.0, 2.0), size - Vector2(4.0, 4.0)), Color(1.0, 0.85, 0.3) if caster else Color.WHITE, false, 5.0 if caster else 2.0)
		if caster:
			# Active Caster: a gold diamond in the corner.
			draw_colored_polygon(PackedVector2Array([Vector2(size.x - 18.0, size.y - 22.0), Vector2(size.x - 10.0, size.y - 14.0), Vector2(size.x - 18.0, size.y - 6.0), Vector2(size.x - 26.0, size.y - 14.0)]), Color(1.0, 0.85, 0.3))


## C08: a skill bar button with a drawn icon (no emoji font): Lightning a
## zigzag, Slow a spiral, Guard a shield, AoE a burst, each with its short
## identifier (雷 / 緩 / 守 / 爆).
class SkillSlot extends Button:
	var view: CombatView
	var entry := {}

	func _draw() -> void:
		if entry.is_empty():
			return
		var compact: bool = entry["compact"]
		var center := Vector2(size.x / 2.0, 34.0) if compact else Vector2(size.y / 2.0, size.y / 2.0)
		var color := Color(1.0, 0.9, 0.35) if not entry["disabled"] else Color(0.5, 0.5, 0.5)
		match entry["kind"]:
			"lightning":
				draw_polyline(PackedVector2Array([center + Vector2(8, -22), center + Vector2(-8, -2), center + Vector2(8, -2), center + Vector2(-8, 22)]), color, 5.0)
			"slow":
				for ring in range(3):
					draw_arc(center, 8.0 + ring * 6.0, ring * 1.2, ring * 1.2 + PI * 1.4, 16, color, 3.0)
			"guard":
				draw_polyline(PackedVector2Array([center + Vector2(-16, -18), center + Vector2(16, -18), center + Vector2(14, 4), center + Vector2(0, 22), center + Vector2(-14, 4), center + Vector2(-16, -18)]), color, 4.0)
			"aoe":
				for ray in range(8):
					var angle := ray * TAU / 8.0
					draw_line(center + Vector2.from_angle(angle) * 6.0, center + Vector2.from_angle(angle) * 22.0, color, 4.0)
		draw_string(get_theme_default_font(), center + Vector2(-9.0, 7.0), CombatView.SKILL_MARKS[entry["kind"]], HORIZONTAL_ALIGNMENT_CENTER, 18.0, 18, Color(0.1, 0.1, 0.12))


## C08: the bottom camera navigator — the whole battlefield width as a strip
## (unit dots) with the visible range; press / drag centres the camera there
## (horizontal only).
class Navigator extends Control:
	var view: CombatView

	func _gui_input(event: InputEvent) -> void:
		# Only the pointer that pressed it moves the camera; other fingers
		# keep working on the rest of the HUD at the same time.
		var pointer_event := CombatView.pointer_event(event)
		var kind: String = pointer_event[0]
		var pointer: int = pointer_event[1]
		var ratio: float = (pointer_event[2] as Vector2).x / size.x
		match kind:
			"press":
				view.navigator_press(ratio, pointer)
			"move":
				view.navigator_drag(ratio, pointer)
			"release", "cancel":
				view.navigator_release(pointer)
		if kind != "":
			accept_event()

	func _draw() -> void:
		var battle := view.get_battle()
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.12, 0.14, 0.13))
		if battle == null:
			return
		for unit in battle.get_enemies() + battle.get_friends():
			if unit.alive:
				var x := (unit.visual_cell().x + 0.5) / CombatConfig.COLUMNS * size.x
				var y := (unit.visual_cell().y + 0.5) / CombatConfig.ROWS * size.y
				draw_circle(Vector2(x, y), 4.0, CombatView.ROLE_COLORS[unit.role] if unit.team == CombatUnit.Team.FRIEND else Color(0.85, 0.25, 0.2))
		var visible_range := view.get_camera().get_view_range()
		draw_rect(Rect2(visible_range.x * size.x, 0.0, (visible_range.y - visible_range.x) * size.x, size.y), Color(1, 1, 1, 0.8), false, 3.0)


## C07: the Gesture Window — a dimmed screen over the battle with the drawing
## area, the faint ⚡ guide and the player's stroke. It takes every touch, so
## nothing reaches the battlefield while it is open (no close button).
class GestureOverlay extends Control:
	var view: CombatView

	func _gui_input(event: InputEvent) -> void:
		# One finger (or the mouse) draws the stroke; lifting it submits.
		var pointer_event := CombatView.pointer_event(event)
		var pointer: int = pointer_event[1]
		match pointer_event[0]:
			"press":
				view.begin_stroke(pointer_event[2], pointer)
			"move":
				view.extend_stroke(pointer_event[2], pointer)
			"release", "cancel":
				view.end_stroke(pointer)
		accept_event()

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.0, 0.05, 0.82))
		var area := CombatView.GESTURE_AREA
		draw_rect(area, Color(0.12, 0.12, 0.18, 0.95))
		draw_rect(area, Color(1, 1, 1, 0.25), false, 2.0)
		var guide := PackedVector2Array()
		for point in GestureMatcher.GUIDE:
			guide.append(area.position + point * area.size.x)
		draw_polyline(guide, Color(1.0, 0.95, 0.5, 0.28), 26.0)
		var stroke := view.get_stroke()
		if stroke.size() >= 2:
			var screen := PackedVector2Array()
			for point in stroke:
				screen.append(area.position + point * area.size.x)
			draw_polyline(screen, Color(0.6, 0.85, 1.0), 8.0)
