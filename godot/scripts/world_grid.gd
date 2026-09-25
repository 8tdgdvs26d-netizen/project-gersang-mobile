class_name WorldGrid
extends Node2D

## Lightweight orientation grid for the empty prototype world. It only draws
## lines once; no textures or collision objects are created.

const SPACING := 400.0
const MAJOR_EVERY := 10
const MINOR_COLOR := Color(0.1, 0.16, 0.17, 1)
const MAJOR_COLOR := Color(0.18, 0.28, 0.27, 1)


func _draw() -> void:
	var size := WorldLayout.WORLD_SIZE
	for column in range(int(size.x / SPACING) + 1):
		var x := column * SPACING
		draw_line(Vector2(x, 0.0), Vector2(x, size.y), _color(column), _width(column))
	for row in range(int(size.y / SPACING) + 1):
		var y := row * SPACING
		draw_line(Vector2(0.0, y), Vector2(size.x, y), _color(row), _width(row))


func _color(index: int) -> Color:
	return MAJOR_COLOR if index % MAJOR_EVERY == 0 else MINOR_COLOR


func _width(index: int) -> float:
	return 4.0 if index % MAJOR_EVERY == 0 else 2.0
