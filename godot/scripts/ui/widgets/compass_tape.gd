class_name CompassTape
extends Control
## Helmet compass: a heading tape showing ±65° with markers for the next waypoint, the hab,
## the storm shelter, the sun and Curiosity.

var heading := 0.0
var markers: Array = []   # {bearing, label, color, sub}
const SPAN := 130.0
var _hb_box := UiKit.box(Color(0.02, 0.03, 0.04, 0.7), Color(UiKit.ACCENT, 0.7), 4, 1, 2)   # the heading readout's box (built once)


func _init() -> void:
	custom_minimum_size = Vector2(560, 58)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_d: float) -> void:
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var cx := w * 0.5
	var ppd := w / SPAN
	var base := 30.0
	var f := UiKit.font(600)
	var m := UiKit.mono(500)
	var fade := func(x: float) -> float: return clampf(1.0 - absf(x - cx) / (cx * 0.98), 0.0, 1.0)
	draw_line(Vector2(0, base), Vector2(w, base), Color(UiKit.ACCENT, 0.18), 1.0)
	var start := int(floor(heading - SPAN * 0.5))
	for deg in range(start, start + int(SPAN) + 2):
		if posmod(deg, 5) != 0:
			continue
		var x := cx + (deg - heading) * ppd
		var a: float = fade.call(x)
		var major := posmod(deg, 15) == 0
		draw_line(Vector2(x, base), Vector2(x, base - (11.0 if major else 5.0)), Color(UiKit.ACCENT, 0.75 * a), 1.5 if major else 1.0)
		if posmod(deg, 45) == 0:
			var names := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
			var name: String = names[int(posmod(deg, 360) / 45.0)]
			draw_string(f, Vector2(x - 20, base - 14), name, HORIZONTAL_ALIGNMENT_CENTER, 40, 15 if name.length() == 1 else 12, Color(UiKit.TEXT, a))
		elif major:
			draw_string(m, Vector2(x - 20, base - 14), "%d" % posmod(deg, 360), HORIZONTAL_ALIGNMENT_CENTER, 40, UiKit.MIN_FONT, Color(UiKit.DIM, a))
	for mk in markers:
		var rel := fposmod(float(mk["bearing"]) - heading + 180.0, 360.0) - 180.0
		var col: Color = mk.get("color", UiKit.AMBER)
		var clamped := absf(rel) > SPAN * 0.5 - 3.0
		var x2 := cx + clampf(rel, -SPAN * 0.5 + 3.0, SPAN * 0.5 - 3.0) * ppd
		var y := base + 6.0
		if clamped:
			var dir := signf(rel)
			draw_colored_polygon(PackedVector2Array([Vector2(x2 + dir * 8, y + 6), Vector2(x2 - dir * 2, y), Vector2(x2 - dir * 2, y + 12)]), Color(col, 0.8))
		else:
			draw_colored_polygon(PackedVector2Array([Vector2(x2, y), Vector2(x2 + 6, y + 6), Vector2(x2, y + 12), Vector2(x2 - 6, y + 6)]), col)
			draw_string(f, Vector2(x2 - 70, y + 24), str(mk.get("label", "")), HORIZONTAL_ALIGNMENT_CENTER, 140, UiKit.MIN_FONT, Color(col, 0.95))
	var hb := Rect2(cx - 38, base + 4, 76, 22)
	draw_style_box(_hb_box, hb)
	draw_string(m, Vector2(hb.position.x, hb.position.y + 16), "%03d° %s" % [int(round(fposmod(heading, 360.0))) % 360, Geo.compass(heading)], HORIZONTAL_ALIGNMENT_CENTER, hb.size.x, 13, UiKit.TEXT)
	draw_colored_polygon(PackedVector2Array([Vector2(cx - 6, base - 1), Vector2(cx + 6, base - 1), Vector2(cx, base + 5)]), UiKit.ACCENT)
