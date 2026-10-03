class_name CombatCamera
extends RefCounted

## Combat C08: the battlefield camera — presentation state only (never saved,
## no combat truth). It no longer follows any unit: the player pans it by
## dragging the battlefield (both axes) or the bottom navigator (horizontal
## only). The offset is the top-left of the visible part of the battlefield,
## in battlefield pixels, kept inside [0, content - view] on each axis; an
## axis whose content fits the view does not move.

var content_size := Vector2.ZERO
var view_size := Vector2.ZERO
var offset := Vector2.ZERO


func setup(content: Vector2, view: Vector2) -> void:
	content_size = content
	view_size = view
	offset = offset.clamp(Vector2.ZERO, max_offset())


func max_offset() -> Vector2:
	return Vector2(maxf(content_size.x - view_size.x, 0.0), maxf(content_size.y - view_size.y, 0.0))


## Drag the battlefield by `delta` screen pixels: the content follows the
## finger, so the camera moves the other way.
func drag(delta: Vector2) -> void:
	offset = (offset - delta).clamp(Vector2.ZERO, max_offset())


## Navigator: centre the view on `ratio` (0 = left edge, 1 = right edge).
func center_on_ratio(ratio: float) -> void:
	offset.x = clampf(clampf(ratio, 0.0, 1.0) * content_size.x - view_size.x / 2.0, 0.0, max_offset().x)


## The visible horizontal range as fractions of the battlefield width.
func get_view_range() -> Vector2:
	if content_size.x <= 0.0:
		return Vector2(0.0, 1.0)
	return Vector2(offset.x / content_size.x, minf((offset.x + view_size.x) / content_size.x, 1.0))
