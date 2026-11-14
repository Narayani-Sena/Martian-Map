class_name MiniMap
extends Control
## Circular, heading-up minimap for the helmet: HiRISE imagery, the route, stops, the hab and
## the walker. A child "disc" clips the map layer to a circle (clip_children); a second child
## draws the rim, ticks and the sweeping range ring on top.

var tex: Texture2D
var grid: Geo
var center := Vector2.ZERO
var heading := 0.0
var range_m := 350.0
var route := PackedVector2Array()
var alt_route := PackedVector2Array()   # the abort route home, drawn in red over the plan
var markers: Array = []   # {xy, color}
var _disc: Control
var _layer: Control
var _overlay: Control


func _init() -> void:
	custom_minimum_size = Vector2(210, 210)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_disc = Control.new()
	_disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_disc.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	_disc.set_anchors_preset(Control.PRESET_FULL_RECT)
	_disc.draw.connect(func():
		var r := minf(_disc.size.x, _disc.size.y) * 0.5
		_disc.draw_circle(_disc.size * 0.5, r, Color(0.02, 0.03, 0.04, 0.85)))
	add_child(_disc)
	_layer = Control.new()
	_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_layer.draw.connect(_draw_map)
	_disc.add_child(_layer)
	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)


func _process(_d: float) -> void:
	if is_visible_in_tree():
		_layer.queue_redraw()
		_overlay.queue_redraw()


func _to_map(xy: Vector2, s: float) -> Vector2:
	return Vector2(xy.x - center.x, -(xy.y - center.y)) * s


func _draw_map() -> void:
	if grid == null:
		return
	var sz := _layer.size
	var r := minf(sz.x, sz.y) * 0.5
	var s := r / range_m
	_layer.draw_set_transform(sz * 0.5, -deg_to_rad(heading), Vector2.ONE)
	if tex:
		var tl := _to_map(Vector2(grid.x_min, grid.y_max), s)
		_layer.draw_texture_rect(tex, Rect2(tl, Vector2(grid.width * grid.res, grid.height * grid.res) * s), false, Color(0.82, 0.82, 0.82))
	var ring := 100.0
	while ring < range_m * 1.5:
		_layer.draw_arc(Vector2.ZERO, ring * s, 0, TAU, 64, Color(UiKit.ACCENT, 0.14), 1.0, true)
		ring += 100.0
	if route.size() > 1:
		var pts := PackedVector2Array()
		for p in route:
			pts.append(_to_map(p, s))
		_layer.draw_polyline(pts, Color(0, 0, 0, 0.55), 4.5, true)
		_layer.draw_polyline(pts, Color(UiKit.ACCENT, 0.95), 2.2, true)
	if alt_route.size() > 1:
		var ap := PackedVector2Array()
		for p in alt_route:
			ap.append(_to_map(p, s))
		_layer.draw_polyline(ap, Color(0, 0, 0, 0.6), 5.0, true)
		_layer.draw_polyline(ap, UiKit.BAD, 2.8, true)
	for mk in markers:
		var p2 := _to_map(mk["xy"], s)
		var col: Color = mk.get("color", UiKit.AMBER)
		_layer.draw_circle(p2, 7.0, Color(col, 0.3))
		_layer.draw_circle(p2, 4.0, col)
	_layer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_overlay() -> void:
	var sz := _overlay.size
	var c := sz * 0.5
	var r := minf(sz.x, sz.y) * 0.5
	_overlay.draw_arc(c, r - 1, 0, TAU, 96, Color(UiKit.ACCENT, 0.6), 2.0, true)
	for i in 72:
		var a := TAU * i / 72.0 - deg_to_rad(heading) - PI * 0.5
		var l := 8.0 if i % 18 == 0 else 3.0
		var dir := Vector2(cos(a), sin(a))
		_overlay.draw_line(c + dir * (r - 2), c + dir * (r - 2 - l), Color(UiKit.ACCENT, 0.7 if i % 18 == 0 else 0.25), 1.0)
	var na := -deg_to_rad(heading) - PI * 0.5
	var np := c + Vector2(cos(na), sin(na)) * (r - 17)
	_overlay.draw_string(UiKit.font(700), np + Vector2(-10, 5), "N", HORIZONTAL_ALIGNMENT_CENTER, 20, 13, UiKit.MARS)
	var t := fmod(Time.get_ticks_msec() / 1000.0, 2.4) / 2.4
	_overlay.draw_arc(c, r * t, 0, TAU, 64, Color(UiKit.ACCENT, 0.35 * (1.0 - t)), 1.5, true)
	_overlay.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -10), c + Vector2(7, 8), c + Vector2(0, 4), c + Vector2(-7, 8)]), Color.WHITE)
	_overlay.draw_string(UiKit.mono(400), Vector2(c.x - 40, sz.y - 10), "%d m" % int(range_m), HORIZONTAL_ALIGNMENT_CENTER, 80, UiKit.MIN_FONT, UiKit.DIM)
