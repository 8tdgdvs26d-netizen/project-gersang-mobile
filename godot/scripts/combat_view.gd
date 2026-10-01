class_name CombatView
extends CanvasLayer

## Combat C01: Prototype presentation of one CombatBattle. It draws the grid,
## units, HP, countdown and result, feeds the battle physics time and turns
## taps into CombatBattle.tap(cell). It owns no combat truth.
##
## Portrait app: the 5 x 60 grid scrolls horizontally with the Hero (the
## final Combat orientation is not decided here). One tap / click = one
## command, no right click, modifier keys or hotkeys.
##
## The result screen's 「返回世界」 only asks main.gd to commit the battle's
## BattleResult (C02 world lifecycle); it never decides the outcome.

## Pressed 「返回世界」 on the result screen.
signal exit_requested

const CELL_SIZE := Vector2(48.0, 100.0)
const FIELD_TOP := 400.0
## Where the followed unit sits on screen while the grid scrolls (C03: the
## selected friendly unit, else the first alive one).
const FOCUS_SCREEN_X := 200.0
const PREPARATION_TEXT := "備戰 %d"
const FIGHTING_TEXT := "戰鬥"
const VICTORY_TEXT := "勝利"
const DEFEAT_TEXT := "戰敗"
## C04 Retreat (Prototype presentation).
const RETREATING_TEXT := "撤退中"
const RETREAT_TEXT := "撤退成功"
const RETREAT_BUTTON_TEXT := "撤退"
const CANCEL_RETREAT_TEXT := "取消撤退"
const RETREAT_ZONE_TEXT := "撤退區"
## C05 result reward (minimal text, no animation).
const REWARD_TEXT := "%s 經驗 +%d"
const LEVEL_UP_TEXT := "%s 升至 %d 級"
const NO_REWARD_TEXT := "本場沒有獲得經驗"
## C03: friendly unit names and colours (Prototype presentation).
const ROLE_NAMES := {CombatUnit.Role.HERO: "主角", CombatUnit.Role.MERC_A: "傭兵A", CombatUnit.Role.MERC_B: "傭兵B"}
const ROLE_COLORS := {CombatUnit.Role.HERO: Color(0.95, 0.78, 0.3), CombatUnit.Role.MERC_A: Color(0.35, 0.65, 0.95), CombatUnit.Role.MERC_B: Color(0.55, 0.85, 0.5)}
const FRIEND_TEXT := "%s %d / %d"
const FRIEND_DEAD_TEXT := "%s 陣亡"
const ENEMIES_TEXT := "敵人 %d / %d"
const HINT_TEXT := "點隊員選取　點空格移動　點敵人攻擊"
## C06 Normal Skill (functional Prototype presentation; MP is shown as 魔力).
const SKILL_NAMES := {"slow": "緩速", "guard": "守護", "aoe": "範圍攻擊"}
const SKILL_READY_TEXT := "%s（魔力 %d）"
const SKILL_AIM_TEXT := "%s：選擇目標"
const SKILL_PENDING_TEXT := "%s：接近目標"
const SKILL_CASTING_TEXT := "%s：施法中…"
const SKILL_COOLDOWN_TEXT := "%s：冷卻 %.1f 秒"
const SKILL_NO_MP_TEXT := "%s：魔力不足"
## C06 fix: PREPARATION shows the selected unit's Skill, not usable yet.
const SKILL_PREPARATION_TEXT := "%s：戰鬥開始後可用"
const AIM_HINT_TEXT := "點敵人施放技能　點其他地方取消"
const UNIT_MP_TEXT := "%s 魔力 %d / %d"
const CASTING_STATUS_TEXT := "施法中"
const PENDING_STATUS_TEXT := "接近中"
const GUARD_STATUS_TEXT := "守護 %.1f 秒"
const SLOWED_ENEMIES_TEXT := "緩速中敵人 %d"
const SLOW_MARK_TEXT := "緩"
const AOE_TEXT := "範圍 -%d"
## How long the AoE cells stay marked (battle time).
const AOE_MARK_MS := 600
const EXIT_TEXT := "返回世界"

var _battle: CombatBattle
var _field: Field
var _status_label: Label
var _info_label: Label
var _hint_label: Label
var _reward_label: Label
## C05: the session's progression (set by main.gd), read only to preview the
## result's EXP shares; the world lifecycle applies them.
var progression: ProgressionState
var _exit_button: Button
var _retreat_button: Button
var _skill_button: Button
var _skill_label: Label
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
	_field = Field.new()
	_field.name = "Field"
	_field.view = self
	_field.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_field)
	_status_label = _label("StatusLabel", 150.0, 56, Color(0.95, 0.8, 0.45))
	_info_label = _label("InfoLabel", 240.0, 24, Color(0.9, 0.9, 0.9))
	_info_label.offset_bottom = _info_label.offset_top + 80.0
	_hint_label = _label("HintLabel", FIELD_TOP + CombatConfig.ROWS * CELL_SIZE.y + 30.0, 24, Color(0.7, 0.7, 0.75))
	_reward_label = _label("RewardLabel", FIELD_TOP + CombatConfig.ROWS * CELL_SIZE.y + 8.0, 24, Color(0.95, 0.85, 0.5))
	_reward_label.offset_bottom = _reward_label.offset_top + 76.0
	_hint_label.text = HINT_TEXT
	_exit_button = Button.new()
	_exit_button.name = "ExitButton"
	_exit_button.text = EXIT_TEXT
	_exit_button.focus_mode = Control.FOCUS_NONE
	_exit_button.add_theme_font_size_override("font_size", 30)
	_exit_button.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_exit_button.offset_left = -170.0
	_exit_button.offset_right = 170.0
	_exit_button.offset_top = FIELD_TOP + CombatConfig.ROWS * CELL_SIZE.y + 90.0
	_exit_button.offset_bottom = _exit_button.offset_top + 80.0
	_exit_button.pressed.connect(func() -> void: exit_requested.emit())
	add_child(_exit_button)
	# C04: 撤退 / 取消撤退, FIGHTING only (same spot; the exit only shows after a result).
	_retreat_button = Button.new()
	_retreat_button.name = "RetreatButton"
	_retreat_button.text = RETREAT_BUTTON_TEXT
	_retreat_button.focus_mode = Control.FOCUS_NONE
	_retreat_button.add_theme_font_size_override("font_size", 30)
	_retreat_button.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_retreat_button.offset_left = -150.0
	_retreat_button.offset_right = 150.0
	_retreat_button.offset_top = _exit_button.offset_top
	_retreat_button.offset_bottom = _exit_button.offset_bottom
	_retreat_button.pressed.connect(toggle_retreat)
	add_child(_retreat_button)
	# C06: the selected unit's Normal Skill (shown from PREPARATION, usable while FIGHTING; below 撤退).
	_skill_button = Button.new()
	_skill_button.name = "SkillButton"
	_skill_button.focus_mode = Control.FOCUS_NONE
	_skill_button.add_theme_font_size_override("font_size", 30)
	_skill_button.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_skill_button.offset_left = -220.0
	_skill_button.offset_right = 220.0
	_skill_button.offset_top = _exit_button.offset_bottom + 20.0
	_skill_button.offset_bottom = _skill_button.offset_top + 80.0
	_skill_button.pressed.connect(press_skill)
	add_child(_skill_button)
	_skill_label = _label("SkillLabel", 330.0, 20, Color(0.7, 0.85, 1.0))
	_skill_label.offset_bottom = _skill_label.offset_top + 64.0
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


func open(battle: CombatBattle) -> void:
	_battle = battle
	_carry_ms = 0.0
	visible = true
	_refresh()


func close() -> void:
	_battle = null
	visible = false


func is_open() -> bool:
	return _battle != null


func get_battle() -> CombatBattle:
	return _battle


func _physics_process(delta: float) -> void:
	if _battle == null:
		return
	_carry_ms += delta * 1000.0
	var ms := int(_carry_ms)
	_carry_ms -= ms
	_battle.advance(ms)


func _process(_delta: float) -> void:
	if _battle != null:
		_refresh()


## Horizontal scroll (grid pixels) that keeps the focus unit in view.
func get_scroll_x() -> float:
	var focus := get_focus_unit()
	if focus == null:
		return 0.0
	var width := _field.size.x if _field.size.x > 0.0 else 720.0
	var limit := maxf(CombatConfig.COLUMNS * CELL_SIZE.x - width, 0.0)
	return clampf(focus.visual_cell().x * CELL_SIZE.x - FOCUS_SCREEN_X, 0.0, limit)


## The unit the camera follows: the selected friendly unit, else the first
## alive friendly unit, else the first friendly unit.
func get_focus_unit() -> CombatUnit:
	if _battle == null or _battle.get_friends().is_empty():
		return null
	if _battle.get_selected() != null:
		return _battle.get_selected()
	for unit in _battle.get_friends():
		if unit.alive:
			return unit
	return _battle.get_friends()[0]


## Screen position -> grid cell (outside the grid: (-1, -1)).
func cell_at(screen_position: Vector2) -> Vector2i:
	var local := screen_position - Vector2(-get_scroll_x(), FIELD_TOP)
	if local.x < 0.0 or local.y < 0.0:
		return Vector2i(-1, -1)
	var cell := Vector2i(int(local.x / CELL_SIZE.x), int(local.y / CELL_SIZE.y))
	return cell if CombatBattle.is_in_grid(cell) else Vector2i(-1, -1)


## Screen centre of a (fractional) grid cell.
func cell_center(cell: Vector2) -> Vector2:
	return Vector2(cell.x * CELL_SIZE.x - get_scroll_x() + CELL_SIZE.x / 2.0, FIELD_TOP + cell.y * CELL_SIZE.y + CELL_SIZE.y / 2.0)


## One tap / click on the screen.
func tap_at(screen_position: Vector2) -> bool:
	if _battle == null:
		return false
	var cell := cell_at(screen_position)
	return cell != Vector2i(-1, -1) and _battle.tap(cell)


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


## C06: the Skill button: Guard at once, Slow / AoE start aiming (the next
## tap on an enemy); pressed while aiming it cancels the aim.
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


## C06: the Skill button text for the selected unit ("" when it has none).
func get_skill_button_text() -> String:
	var unit := _battle.get_selected() if _battle != null else null
	if unit == null or unit.skill.is_empty():
		return ""
	var skill_name: String = SKILL_NAMES[unit.skill["kind"]]
	if _battle.get_phase() == CombatBattle.Phase.PREPARATION:
		return SKILL_PREPARATION_TEXT % skill_name
	if _battle.is_aiming():
		return SKILL_AIM_TEXT % skill_name
	if unit.skill_state == CombatUnit.SkillState.PENDING:
		return SKILL_PENDING_TEXT % skill_name
	match _battle.get_skill_readiness(unit):
		CombatBattle.SkillReadiness.CASTING:
			return SKILL_CASTING_TEXT % skill_name
		CombatBattle.SkillReadiness.COOLDOWN:
			return SKILL_COOLDOWN_TEXT % [skill_name, _battle.get_skill_cooldown_remaining(unit) / 1000.0]
		CombatBattle.SkillReadiness.NO_MP:
			return SKILL_NO_MP_TEXT % skill_name
	return SKILL_READY_TEXT % [skill_name, CombatConfig.SKILL_MP_COST]


## C06: every friendly unit's MP and Skill / Guard state, and how many
## enemies are slowed.
func get_skill_status_text() -> String:
	if _battle == null:
		return ""
	var parts := []
	for unit in _battle.get_friends():
		if not unit.alive or unit.skill.is_empty():
			continue
		var text: String = UNIT_MP_TEXT % [ROLE_NAMES[unit.role], unit.mp, unit.max_mp]
		if unit.skill_state == CombatUnit.SkillState.CASTING:
			text += " " + CASTING_STATUS_TEXT
		elif unit.skill_state == CombatUnit.SkillState.PENDING:
			text += " " + PENDING_STATUS_TEXT
		if _battle.get_guard_remaining(unit) > 0:
			text += " " + GUARD_STATUS_TEXT % (_battle.get_guard_remaining(unit) / 1000.0)
		parts.append(text)
	var slowed := 0
	for enemy in _battle.get_enemies():
		if _battle.get_slow_remaining(enemy) > 0:
			slowed += 1
	return "　".join(parts) + "\n" + (SLOWED_ENEMIES_TEXT % slowed)


## C04: the 撤退 / 取消撤退 button: starts or cancels the party retreat.
func toggle_retreat() -> bool:
	if _battle == null:
		return false
	var done := _battle.cancel_retreat() if _battle.is_retreating() else _battle.start_retreat()
	_refresh()
	return done


func _refresh() -> void:
	if _status_label == null:
		return
	_exit_button.visible = _battle != null and _battle.is_over()
	_retreat_button.visible = _battle != null and _battle.get_phase() == CombatBattle.Phase.FIGHTING
	# C06 fix: the Skill UI shows from PREPARATION on (the button stays
	# disabled until FIGHTING; the battle refuses Skills before that anyway).
	_skill_label.visible = _battle != null and (_battle.get_phase() == CombatBattle.Phase.PREPARATION or _battle.get_phase() == CombatBattle.Phase.FIGHTING)
	_skill_button.visible = _skill_label.visible and not _battle.is_retreating() and get_skill_button_text() != ""
	if _battle == null:
		return
	if _skill_button.visible:
		_skill_button.text = get_skill_button_text()
		_skill_button.disabled = not _battle.is_aiming() and _battle.get_skill_readiness(_battle.get_selected()) != CombatBattle.SkillReadiness.READY
	_skill_label.text = get_skill_status_text() if _skill_label.visible else ""
	_retreat_button.text = CANCEL_RETREAT_TEXT if _battle.is_retreating() else RETREAT_BUTTON_TEXT
	match _battle.get_phase():
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
	var friends := []
	for unit in _battle.get_friends():
		friends.append(FRIEND_TEXT % [ROLE_NAMES[unit.role], unit.hp, unit.max_hp] if unit.alive else FRIEND_DEAD_TEXT % ROLE_NAMES[unit.role])
	_info_label.text = "　".join(friends) + "\n" + (ENEMIES_TEXT % [_battle.get_alive_enemy_count(), _battle.get_enemies().size()])
	_hint_label.visible = not _battle.is_over()
	_hint_label.text = AIM_HINT_TEXT if _battle.is_aiming() else HINT_TEXT
	_reward_label.visible = _battle.is_over()
	_reward_label.text = get_reward_text() if _battle.is_over() else ""
	_field.queue_redraw()


## The battlefield drawing and its tap input.
class Field extends Control:
	var view: CombatView

	func _gui_input(event: InputEvent) -> void:
		# Touch arrives as emulated mouse clicks; desktop clicks the same way.
		var click := event as InputEventMouseButton
		if click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
			view.tap_at(click.position)
			accept_event()

	func _draw() -> void:
		var battle := view.get_battle()
		if battle == null:
			return
		var cell_size := CombatView.CELL_SIZE
		var left := -view.get_scroll_x()
		var height := CombatConfig.ROWS * cell_size.y
		draw_rect(Rect2(left, CombatView.FIELD_TOP, CombatConfig.COLUMNS * cell_size.x, height), Color(0.16, 0.2, 0.17))
		if battle.get_phase() == CombatBattle.Phase.PREPARATION:
			var start := left + CombatConfig.PREPARATION_FIRST_COLUMN * cell_size.x
			draw_rect(Rect2(start, CombatView.FIELD_TOP, CombatConfig.PREPARATION_COLUMNS * cell_size.x, height), Color(0.3, 0.7, 0.4, 0.35))
			draw_line(Vector2(start, CombatView.FIELD_TOP), Vector2(start, CombatView.FIELD_TOP + height), Color(0.5, 1.0, 0.6), 4.0)
			var edge := start + CombatConfig.PREPARATION_COLUMNS * cell_size.x
			draw_line(Vector2(edge, CombatView.FIELD_TOP), Vector2(edge, CombatView.FIELD_TOP + height), Color(0.5, 1.0, 0.6), 4.0)
		elif battle.get_phase() == CombatBattle.Phase.FIGHTING:
			# C04: the Retreat Zone (column 0), brighter while retreating.
			draw_rect(Rect2(left, CombatView.FIELD_TOP, cell_size.x, height), Color(0.95, 0.6, 0.2, 0.45 if battle.is_retreating() else 0.2))
			draw_string(get_theme_default_font(), Vector2(left, CombatView.FIELD_TOP - 8.0), CombatView.RETREAT_ZONE_TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 16, Color(0.95, 0.7, 0.35))
		for column in range(CombatConfig.COLUMNS + 1):
			var x := left + column * cell_size.x
			draw_line(Vector2(x, CombatView.FIELD_TOP), Vector2(x, CombatView.FIELD_TOP + height), Color(1, 1, 1, 0.08), 1.0)
		for row in range(CombatConfig.ROWS + 1):
			var y := CombatView.FIELD_TOP + row * cell_size.y
			draw_line(Vector2(left, y), Vector2(left + CombatConfig.COLUMNS * cell_size.x, y), Color(1, 1, 1, 0.08), 1.0)
		# C06: the last AoE's cells, briefly.
		var aoe := battle.get_last_aoe()
		if not aoe.is_empty() and battle.get_elapsed_ms() - int(aoe["at_ms"]) < CombatView.AOE_MARK_MS:
			for cell: Vector2i in aoe["cells"]:
				draw_rect(Rect2(left + cell.x * cell_size.x, CombatView.FIELD_TOP + cell.y * cell_size.y, cell_size.x, cell_size.y), Color(1.0, 0.55, 0.15, 0.5))
			var center: Vector2i = aoe["cells"][0]
			draw_string(get_theme_default_font(), view.cell_center(Vector2(center)) + Vector2(-40.0, -40.0), CombatView.AOE_TEXT % CombatConfig.AOE_DAMAGE, HORIZONTAL_ALIGNMENT_CENTER, 80.0, 18, Color(1.0, 0.85, 0.4))
		for unit in battle.get_enemies():
			_draw_unit(unit, Color(0.55, 0.3, 0.85) if battle.get_slow_remaining(unit) > 0 else Color(0.85, 0.25, 0.2))
			if battle.get_slow_remaining(unit) > 0:
				draw_string(get_theme_default_font(), view.cell_center(unit.visual_cell()) + Vector2(-10.0, 8.0), CombatView.SLOW_MARK_TEXT, HORIZONTAL_ALIGNMENT_CENTER, 20.0, 18, Color.WHITE)
		for unit in battle.get_friends():
			_draw_unit(unit, CombatView.ROLE_COLORS[unit.role])
			_draw_name(unit)
			# C06: Guard ring, cast progress, the pending Skill's target.
			if battle.get_guard_remaining(unit) > 0:
				draw_arc(view.cell_center(unit.visual_cell()), 27.0, 0.0, TAU, 32, Color(0.4, 0.75, 1.0), 4.0)
			if unit.skill_state == CombatUnit.SkillState.CASTING:
				var done := 1.0 - float(battle.get_cast_remaining(unit)) / CombatConfig.SKILL_CAST_MS
				draw_arc(view.cell_center(unit.visual_cell()), 31.0, -PI / 2.0, -PI / 2.0 + TAU * done, 32, Color(1.0, 0.95, 0.5), 4.0)
			elif unit.skill_state == CombatUnit.SkillState.PENDING and unit.skill_target != unit:
				draw_arc(view.cell_center(unit.skill_target.visual_cell()), 26.0, 0.0, TAU, 32, Color(0.75, 0.45, 1.0), 3.0)
		var selected := battle.get_selected()
		if selected != null:
			draw_arc(view.cell_center(selected.visual_cell()), 22.0, 0.0, TAU, 32, Color.WHITE, 3.0)
			if selected.target != null and selected.target.alive:
				draw_arc(view.cell_center(selected.target.visual_cell()), 22.0, 0.0, TAU, 32, Color(1.0, 0.9, 0.2), 3.0)
			elif selected.has_goal:
				var goal := view.cell_center(Vector2(selected.goal))
				draw_rect(Rect2(goal - Vector2(10, 10), Vector2(20, 20)), Color(1, 1, 1, 0.6), false, 2.0)

	func _draw_name(unit: CombatUnit) -> void:
		var center := view.cell_center(unit.visual_cell())
		var color := Color(0.9, 0.9, 0.9) if unit.alive else Color(0.5, 0.5, 0.5)
		draw_string(get_theme_default_font(), center + Vector2(-30.0, 36.0), CombatView.ROLE_NAMES[unit.role], HORIZONTAL_ALIGNMENT_CENTER, 60.0, 16, color)

	func _draw_unit(unit: CombatUnit, color: Color) -> void:
		var center := view.cell_center(unit.visual_cell())
		if not unit.alive:
			draw_circle(center, 8.0, Color(0.3, 0.3, 0.3))
			return
		draw_circle(center, 17.0, color)
		var bar := Rect2(center + Vector2(-20.0, -34.0), Vector2(40.0, 6.0))
		draw_rect(bar, Color(0.2, 0.05, 0.05))
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * unit.hp / unit.max_hp, bar.size.y)), Color(0.3, 0.9, 0.35))
