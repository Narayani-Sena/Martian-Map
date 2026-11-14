class_name Callouts
extends Control
## Labels anchored to 3D positions (habitat, stops, shelter, Curiosity): a leader line from the
## ground, a glass tag with title + subtitle, faded with distance and de-overlapped.

var world: MarsWorld
var selected := ""
var _hits: Array = []      # labels drawn this frame, nearest first: {id, kind, title, sub, pos, rect}


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _process(_d: float) -> void:
	queue_redraw()


## The label under a screen point (in this layer's coordinates, which are the 3D viewport's), or {}.
## The tags are drawn rather than built from Controls, so clicks are tested here against what was drawn.
func hit(screen: Vector2) -> Dictionary:
	for h in _hits:
		if (h["rect"] as Rect2).has_point(screen):
			return h
	return {}


func _draw() -> void:
	_hits.clear()
	if world == null or not world.ready_terrain:
		return
	var cam := world.camera
	var items := world.callouts()
	var cp := cam.global_position
	items.sort_custom(func(a, b): return cp.distance_squared_to(a["pos"]) < cp.distance_squared_to(b["pos"]))
	var placed: Array[Rect2] = []
	var ft := UiKit.font(600)
	var fs := UiKit.caps_font()
	var walk := world.mode == "walk"
	for it in items:
		var pos: Vector3 = it["pos"]
		if cam.is_position_behind(pos):
			continue
		var d := cp.distance_to(pos)
		if walk and (d < 6.0 or d > 2500.0):
			continue
		if not walk and d > 30000.0:
			continue
		var ground := Vector3(pos.x, world.td.h(pos.x, -pos.z), pos.z)
		var sp := cam.unproject_position(pos)
		var gp := cam.unproject_position(ground)
		var col: Color = it["color"]
		var sel := str(it["id"]) == selected
		var title := str(it["title"])
		var sub := str(it["sub"])
		var tsz := 13 if sel else 12
		var w := maxf(ft.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, tsz).x, fs.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, UiKit.MIN_FONT).x) + 22.0
		var h := 37.0
		var lift := 26.0
		var rect := Rect2(sp.x - w * 0.5, sp.y - lift - h, w, h)
		var tries := 0
		while tries < 6 and _overlaps(rect, placed):
			rect.position.y -= h + 4.0
			tries += 1
		if tries >= 6 and not sel:
			continue
		if rect.end.x < 0 or rect.position.x > size.x or rect.end.y < 0 or rect.position.y > size.y:
			continue
		rect.position.x = clampf(rect.position.x, 6.0, size.x - rect.size.x - 6.0)
		if walk and (rect.position.x < 330.0 or rect.end.x > size.x - 360.0 or rect.position.y < 90.0 or rect.end.y > size.y - 250.0):
			continue
		placed.append(rect.grow(2.0))
		_hits.append({"id": str(it["id"]), "kind": str(it["kind"]), "title": title, "sub": sub, "pos": pos, "rect": rect.grow(3.0)})
		var hov := str(it["id"]) == world.hover_id   # under the mouse: drawn brighter
		var fade := clampf(1.0 - (d - 6000.0) / 20000.0, 0.35, 1.0) if not walk else clampf(1.0 - (d - 600.0) / 1900.0, 0.35, 1.0)
		var a := fade * (1.0 if sel or hov else 0.92)
		var anchor := Vector2(sp.x, rect.end.y)
		draw_line(gp, anchor, Color(col, 0.55 * a), 1.5, true)
		draw_circle(gp, 3.0, Color(col, 0.9 * a))
		var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 260.0)
		if sel:
			draw_arc(gp, 8.0 + pulse * 6.0, 0, TAU, 32, Color(col, 0.7 * (1.0 - pulse)), 2.0, true)
		var bg := UiKit.box(Color(0.02, 0.03, 0.045, 0.78 * a) if not hov else Color(col.darkened(0.7), 0.9 * a), Color(col, (0.95 if sel or hov else 0.55) * a), 5, 2 if sel or hov else 1, 4)
		draw_style_box(bg, rect)
		draw_rect(Rect2(rect.position.x, rect.position.y + 4, 3, h - 8), Color(col, a))
		draw_string(ft, rect.position + Vector2(11, 15), title, HORIZONTAL_ALIGNMENT_LEFT, w - 14, tsz, Color(UiKit.TEXT, a))
		var dist_txt := "  ·  " + Geo.fmt_dist(Vector2(pos.x - cp.x, pos.z - cp.z).length()) if walk else ""
		draw_string(fs, rect.position + Vector2(11, 30), sub + dist_txt, HORIZONTAL_ALIGNMENT_LEFT, w + 60, UiKit.MIN_FONT, Color(col, a))


func _overlaps(r: Rect2, list: Array[Rect2]) -> bool:
	for o in list:
		if r.intersects(o):
			return true
	return false
