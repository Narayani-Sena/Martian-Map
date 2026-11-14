class_name LineChart
extends Control
## Small custom chart: gradient-filled series, background bands, reference lines,
## a glowing playhead, hover crosshair with tooltip, and click/drag scrubbing.

signal scrubbed(x: float)

var series: Array = []      # {xs: PackedFloat32Array, ys: PackedFloat32Array, color, width, fill}
var bands: Array = []       # {x0, x1, color, pattern: "" | "hatch" | "dots"}
var hlines: Array = []      # {y, color, text}
var x_min := 0.0
var x_max := 1.0
var y_min := 0.0
var y_max := 1.0
var playhead := NAN
var marker := Vector2(NAN, NAN)   # highlighted point (x, y)
var hover_x := NAN
var pad := Vector4(36, 8, 8, 16)  # left, top, right, bottom
var y_ticks := 4
var x_fmt: Callable = func(x: float) -> String: return "%.0f" % x
var y_fmt: Callable = func(y: float) -> String: return "%.0f" % y
var tip_fmt: Callable = Callable()   # (x) -> String
var title := ""
var interactive := true
var _drag := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(120, 80)


func plot_rect() -> Rect2:
	return Rect2(pad.x, pad.y, maxf(1.0, size.x - pad.x - pad.z), maxf(1.0, size.y - pad.y - pad.w))


func to_px(x: float, y: float) -> Vector2:
	var r := plot_rect()
	var fx := (x - x_min) / maxf(1e-9, x_max - x_min)
	var fy := (y - y_min) / maxf(1e-9, y_max - y_min)
	return Vector2(r.position.x + fx * r.size.x, r.position.y + (1.0 - fy) * r.size.y)


func to_x(px: float) -> float:
	var r := plot_rect()
	return x_min + clampf((px - r.position.x) / r.size.x, 0.0, 1.0) * (x_max - x_min)


func set_series(list: Array) -> void:
	series = list
	queue_redraw()


func auto_y(margin := 0.08) -> void:
	var lo := INF
	var hi := -INF
	for s in series:
		for v in (s["ys"] as PackedFloat32Array):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	if lo == INF:
		return
	var m := (hi - lo) * margin + 0.001
	y_min = lo - m
	y_max = hi + m


func _draw() -> void:
	var r := plot_rect()
	var f := UiKit.mono(400)
	for i in y_ticks + 1:
		var fy := float(i) / y_ticks
		var y := r.position.y + r.size.y * (1.0 - fy)
		draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), Color(1, 1, 1, 0.05 if i > 0 else 0.12), 1.0)
		draw_string(f, Vector2(0, y + 4), y_fmt.call(lerpf(y_min, y_max, fy)), HORIZONTAL_ALIGNMENT_RIGHT, pad.x - 5, UiKit.MIN_FONT, UiKit.FAINT)
	for b in bands:
		var a := to_px(float(b["x0"]), y_max)
		var c := to_px(float(b["x1"]), y_min)
		var rect := Rect2(a.x, r.position.y, maxf(1.0, c.x - a.x), r.size.y)
		draw_rect(rect, b["color"])
		_pattern(rect, str(b.get("pattern", "")), Color(b["color"] as Color, 0.85))
	for s in series:
		var xs: PackedFloat32Array = s["xs"]
		var ys: PackedFloat32Array = s["ys"]
		var col: Color = s.get("color", UiKit.ACCENT)
		var n := mini(xs.size(), ys.size())
		if n < 2:
			continue
		var step := maxi(1, n / int(maxf(r.size.x, 2.0)))
		var pts := PackedVector2Array()
		var last_x := -INF
		for i in range(0, n, step):
			var p := to_px(xs[i], ys[i])
			if p.x <= last_x:
				continue
			last_x = p.x
			pts.append(p)
		var lp := to_px(xs[n - 1], ys[n - 1])
		if lp.x > last_x:
			pts.append(lp)
		if pts.size() < 2:
			continue
		if bool(s.get("fill", false)):
			var stride := maxi(1, pts.size() / 160)
			var i := 0
			while i < pts.size() - 1:
				var j := mini(i + stride, pts.size() - 1)
				var a := pts[i]
				var b := pts[j]
				var top_a := Color(col, 0.05 + 0.22 * (1.0 - (a.y - r.position.y) / r.size.y))
				var top_b := Color(col, 0.05 + 0.22 * (1.0 - (b.y - r.position.y) / r.size.y))
				draw_polygon(PackedVector2Array([a, b, Vector2(b.x, r.end.y), Vector2(a.x, r.end.y)]),
					PackedColorArray([top_a, top_b, Color(col, 0.0), Color(col, 0.0)]))
				i = j
		draw_polyline(pts, Color(col, 0.25), float(s.get("width", 1.6)) + 3.0, true)
		draw_polyline(pts, col, float(s.get("width", 1.6)), true)
	for hl in hlines:
		var y2 := to_px(x_min, float(hl["y"])).y
		if y2 < r.position.y or y2 > r.end.y:
			continue
		var c2: Color = hl.get("color", UiKit.AMBER)
		var x := r.position.x
		while x < r.end.x:
			draw_line(Vector2(x, y2), Vector2(minf(x + 5, r.end.x), y2), c2, 1.0)
			x += 9.0
		if str(hl.get("text", "")) != "":
			draw_string(UiKit.font(600), Vector2(r.end.x - 160, y2 - 3), str(hl["text"]), HORIZONTAL_ALIGNMENT_RIGHT, 158, UiKit.MIN_FONT, c2)
	if not is_nan(marker.x):
		var mp := to_px(marker.x, marker.y)
		draw_circle(mp, 7.0, Color(UiKit.AMBER, 0.25))
		draw_circle(mp, 3.5, UiKit.AMBER)
	if not is_nan(playhead) and playhead >= x_min and playhead <= x_max:
		var px := to_px(playhead, y_min).x
		draw_rect(Rect2(px - 3, r.position.y, 6, r.size.y), Color(UiKit.ACCENT, 0.12))
		draw_line(Vector2(px, r.position.y), Vector2(px, r.end.y), UiKit.ACCENT, 1.5)
		draw_colored_polygon(PackedVector2Array([Vector2(px - 5, r.position.y - 1), Vector2(px + 5, r.position.y - 1), Vector2(px, r.position.y + 6)]), UiKit.ACCENT)
	if title != "":
		draw_string(UiKit.caps_font(), Vector2(r.position.x + 4, r.position.y + 11), title, HORIZONTAL_ALIGNMENT_LEFT, -1, UiKit.MIN_FONT, UiKit.DIM)
	draw_string(f, Vector2(r.position.x, size.y - 2), x_fmt.call(x_min), HORIZONTAL_ALIGNMENT_LEFT, -1, UiKit.MIN_FONT, UiKit.FAINT)
	draw_string(f, Vector2(r.end.x - 80, size.y - 2), x_fmt.call(x_max), HORIZONTAL_ALIGNMENT_RIGHT, 80, UiKit.MIN_FONT, UiKit.FAINT)
	if interactive and not is_nan(hover_x):
		var hx := to_px(hover_x, y_min).x
		draw_line(Vector2(hx, r.position.y), Vector2(hx, r.end.y), Color(1, 1, 1, 0.35), 1.0)
		var lines := PackedStringArray([x_fmt.call(hover_x)])
		if tip_fmt.is_valid():
			lines = PackedStringArray(str(tip_fmt.call(hover_x)).split("\n"))
		else:
			for s in series:
				lines.append("%s %s" % [str(s.get("name", "")), y_fmt.call(_sample(s, hover_x))])
		var tw := 10.0
		for l in lines:
			tw = maxf(tw, UiKit.font(500).get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x)
		var bw := tw + 16.0
		var bh := lines.size() * 15.0 + 8.0
		var bx := hx + 10.0 if hx + 10.0 + bw < size.x else hx - 10.0 - bw
		var box_r := Rect2(bx, r.position.y + 2, bw, bh)
		draw_style_box(UiKit.box(UiKit.PANEL_SOLID, Color(UiKit.ACCENT, 0.5), 5, 1, 4), box_r)
		for i in lines.size():
			draw_string(UiKit.font(500), Vector2(bx + 8, r.position.y + 17 + i * 15), lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UiKit.TEXT if i > 0 else UiKit.ACCENT)
		for s in series:
			var sp := to_px(hover_x, _sample(s, hover_x))
			draw_circle(sp, 3.5, s.get("color", UiKit.ACCENT))


## A texture inside a band, so the bands differ by shape as well as colour: diagonal hatching or dots.
func _pattern(rect: Rect2, kind: String, col: Color) -> void:
	if kind == "":
		return
	var step := 7.0
	var y := rect.position.y + 2.0
	while y < rect.end.y - 2.0:
		var x := rect.position.x + fmod(y, step * 2.0) * 0.5
		while x < rect.end.x - 1.0:
			if kind == "hatch":
				var e := minf(x + 5.0, rect.end.x)
				draw_line(Vector2(x, y + (e - x)), Vector2(e, y), col, 1.0)
			else:
				draw_circle(Vector2(x + 1.0, y + 1.0), 1.0, col)
			x += step
		y += step


func _sample(s: Dictionary, x: float) -> float:
	var xs: PackedFloat32Array = s["xs"]
	var ys: PackedFloat32Array = s["ys"]
	var n := xs.size()
	if n == 0:
		return 0.0
	if x <= xs[0]:
		return ys[0]
	if x >= xs[n - 1]:
		return ys[n - 1]
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if xs[mid] <= x:
			lo = mid
		else:
			hi = mid
	var f := (x - xs[lo]) / maxf(1e-9, xs[hi] - xs[lo])
	return lerpf(ys[lo], ys[hi], f)


func _gui_input(event: InputEvent) -> void:
	if not interactive:
		return
	if event is InputEventMouseMotion:
		hover_x = to_x((event as InputEventMouseMotion).position.x)
		if _drag:
			scrubbed.emit(hover_x)
		queue_redraw()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_drag = (event as InputEventMouseButton).pressed
		if _drag:
			scrubbed.emit(to_x((event as InputEventMouseButton).position.x))
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		hover_x = NAN
		_drag = false
		queue_redraw()
	elif what == NOTIFICATION_RESIZED:
		queue_redraw()
