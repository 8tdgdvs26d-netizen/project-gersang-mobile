class_name NoticeModal
extends CanvasLayer

## Stage 8 P05: a full-screen notice (functional Prototype, 720 x 1280): a
## dim layer that takes every touch, a panel with a title and wrapping lines
## and one 知道了 button that closes it. Used for the legacy Mercenary
## migration result and the unreadable-save warning. It decides nothing.

signal acknowledged

const OK_TEXT := "知道了"
const PANEL_RECT := Rect2(40.0, 260.0, 640.0, 760.0)

var _dim: ColorRect
var _title: Label
var _body: Label
var _ok_button: Button


func _ready() -> void:
	layer = 30
	_dim = ColorRect.new()
	_dim.name = "Dim"
	_dim.color = Color(0.0, 0.0, 0.0, 0.75)
	_dim.position = Vector2.ZERO
	_dim.size = Vector2(720.0, 1280.0)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)
	var panel := ColorRect.new()
	panel.name = "NoticePanel"
	panel.color = Color(0.1, 0.11, 0.14)
	panel.position = PANEL_RECT.position
	panel.size = PANEL_RECT.size
	_dim.add_child(panel)
	_title = Label.new()
	_title.name = "NoticeTitle"
	_title.position = Vector2(24.0, 24.0)
	_title.size = Vector2(PANEL_RECT.size.x - 48.0, 64.0)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 36)
	_title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	panel.add_child(_title)
	_body = Label.new()
	_body.name = "NoticeBody"
	_body.position = Vector2(32.0, 104.0)
	_body.size = Vector2(PANEL_RECT.size.x - 64.0, PANEL_RECT.size.y - 104.0 - 136.0)
	_body.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_body.add_theme_font_size_override("font_size", 26)
	panel.add_child(_body)
	_ok_button = Button.new()
	_ok_button.name = "OkButton"
	_ok_button.text = OK_TEXT
	_ok_button.focus_mode = Control.FOCUS_NONE
	_ok_button.position = Vector2((PANEL_RECT.size.x - 320.0) / 2.0, PANEL_RECT.size.y - 120.0)
	_ok_button.size = Vector2(320.0, 96.0)
	_ok_button.add_theme_font_size_override("font_size", 32)
	_ok_button.pressed.connect(acknowledge)
	panel.add_child(_ok_button)
	visible = false


func show_notice(title: String, lines: Array) -> void:
	_title.text = title
	_body.text = "\n".join(lines)
	visible = true


func acknowledge() -> void:
	if not visible:
		return
	visible = false
	acknowledged.emit()


func is_showing() -> bool:
	return visible


func get_title() -> String:
	return _title.text


func get_lines() -> PackedStringArray:
	return _body.text.split("\n")
