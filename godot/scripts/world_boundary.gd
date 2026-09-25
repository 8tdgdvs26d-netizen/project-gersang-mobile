class_name WorldBoundary
extends Node2D

const BOUNDS := Rect2(Vector2.ZERO, WorldLayout.WORLD_SIZE)
const BORDER_COLOR := Color(0.88, 0.75, 0.36, 0.7)
const BORDER_WIDTH := 8.0


func _draw() -> void:
	draw_rect(BOUNDS, BORDER_COLOR, false, BORDER_WIDTH)
