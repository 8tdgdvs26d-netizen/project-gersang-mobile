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
## C03: friendly unit names and colours (Prototype presentation).
const ROLE_NAMES := {CombatUnit.Role.HERO: "主角", CombatUnit.Role.MERC_A: "傭兵A", CombatUnit.Role.MERC_B: "傭兵B"}
const ROLE_COLORS := {CombatUnit.Role.HERO: Color(0.95, 0.78, 0.3), CombatUnit.Role.MERC_A: Color(0.35, 0.65, 0.95), CombatUnit.Role.MERC_B: Color(0.55, 0.85, 0.5)}
const FRIEND_TEXT := "%s %d / %d"
const FRIEND_DEAD_TEXT := "%s 陣亡"
const ENEMIES_TEXT := "敵人 %d / %d"
const HINT_TEXT := "點隊員選取　點空格移動　點敵人攻擊"
const EXIT_TEXT := "返回世界"

var _battle: CombatBattle
var _field: Field
var _status_label: Label
var _info_label: Label
var _hint_label: Label
var _exit_button: Button
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


func _refresh() -> void:
	if _status_label == null:
		return
	_exit_button.visible = _battle != null and _battle.is_over()
	if _battle == null:
		return
	match _battle.get_phase():
		CombatBattle.Phase.PREPARATION:
			_status_label.text = PREPARATION_TEXT % ceili(_battle.get_preparation_remaining_ms() / 1000.0)
		CombatBattle.Phase.FIGHTING:
			_status_label.text = FIGHTING_TEXT
		CombatBattle.Phase.VICTORY:
			_status_label.text = VICTORY_TEXT
		CombatBattle.Phase.DEFEAT:
			_status_label.text = DEFEAT_TEXT
	var friends := []
	for unit in _battle.get_friends():
		friends.append(FRIEND_TEXT % [ROLE_NAMES[unit.role], unit.hp, unit.max_hp] if unit.alive else FRIEND_DEAD_TEXT % ROLE_NAMES[unit.role])
	_info_label.text = "　".join(friends) + "\n" + (ENEMIES_TEXT % [_battle.get_alive_enemy_count(), _battle.get_enemies().size()])
	_hint_label.visible = not _battle.is_over()
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
			draw_rect(Rect2(left, CombatView.FIELD_TOP, CombatConfig.PREPARATION_COLUMNS * cell_size.x, height), Color(0.3, 0.7, 0.4, 0.35))
			var edge := left + CombatConfig.PREPARATION_COLUMNS * cell_size.x
			draw_line(Vector2(edge, CombatView.FIELD_TOP), Vector2(edge, CombatView.FIELD_TOP + height), Color(0.5, 1.0, 0.6), 4.0)
		for column in range(CombatConfig.COLUMNS + 1):
			var x := left + column * cell_size.x
			draw_line(Vector2(x, CombatView.FIELD_TOP), Vector2(x, CombatView.FIELD_TOP + height), Color(1, 1, 1, 0.08), 1.0)
		for row in range(CombatConfig.ROWS + 1):
			var y := CombatView.FIELD_TOP + row * cell_size.y
			draw_line(Vector2(left, y), Vector2(left + CombatConfig.COLUMNS * cell_size.x, y), Color(1, 1, 1, 0.08), 1.0)
		for unit in battle.get_enemies():
			_draw_unit(unit, Color(0.85, 0.25, 0.2))
		for unit in battle.get_friends():
			_draw_unit(unit, CombatView.ROLE_COLORS[unit.role])
			_draw_name(unit)
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
