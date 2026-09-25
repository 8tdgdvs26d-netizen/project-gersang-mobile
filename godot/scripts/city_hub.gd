class_name CityHub
extends CanvasLayer

## Shared prototype City Hub overlay used by every active city. It only shows
## which city is open and requests leaving; facilities belong to later packages.

signal leave_requested

var city_id := ""

@onready var _city_label := $Center/Content/CityLabel as Label
@onready var _leave_button := $Center/Content/LeaveButton as Button
@onready var _cargo_label := $Center/Content/CargoLabel as Label


func _ready() -> void:
	visible = false
	_leave_button.pressed.connect(_on_leave_pressed)


func open(opened_city_id: String) -> void:
	city_id = opened_city_id
	_city_label.text = "[ City %s ]" % city_id
	visible = true


## Developer-only debug line; the cargo model itself lives outside the hub.
func show_cargo_summary(used: int, capacity: int) -> void:
	_cargo_label.text = "Cargo: %d / %d" % [used, capacity]


func close() -> void:
	city_id = ""
	_city_label.text = ""
	_cargo_label.text = ""
	visible = false


func is_open() -> bool:
	return visible


func get_city_label_text() -> String:
	return _city_label.text


func get_cargo_label_text() -> String:
	return _cargo_label.text


func _on_leave_pressed() -> void:
	leave_requested.emit()
