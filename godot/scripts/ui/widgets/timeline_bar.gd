class_name TimelineBar
extends Control
## EVA timeline: egress, walking legs, stops, ingress as coloured blocks; a draggable playhead,
## 15-minute ticks, the sunset marker, predicted CME arrival windows (DONKI) and a hover tooltip.

signal scrubbed(t: float)

var events: Array = []
var total := 1.0
var t := 0.0
var sunset_t := NAN
var cme: Array = []   # DONKI arrivals: t_rel_s (forecast), t0_rel_s / t1_rel_s (uncertainty window), glancing, level
var shade: Array = []  # stretches walked in terrain shadow: t0, t1 (seconds after the start)
var _hover := NAN
var _drag := false
var _head: Control      # the playhead and the hover tip, drawn on their own layer: moving them never redraws the bar
var _active := -2       # the event under the playhead (the bar is redrawn only when this changes)
var _tip_box := UiKit.box(UiKit.PANEL_SOLID, Color(UiKit.ACCENT, 0.5), 4, 1, 4)

const KIND_COLORS := {"egress": Color("b48cff"), "ingress": Color("b48cff"), "walk": Color("4fd1ff"), "stop": Color("ffb03b"), "drive": Color("4ade80")}


func _init() -> void:
	custom_minimum_size = Vector2(200, 46)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_head = Control.new()
	_head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_head.set_anchors_preset(Control.PRESET_FULL_RECT)
	_head.draw.connect(_draw_head)
	add_child(_head)


func set_plan(evs: Array, total_s: float, sunset := NAN, arrivals: Array = [], shaded: Array = []) -> void:
	events = evs
	total = maxf(total_s, 1.0)
	sunset_t = sunset
	cme = arrivals
	shade = shaded
	_active = _active_index(t)
	queue_redraw()
	_head.queue_redraw()


func set_time(v: float) -> void:
	if v == t:
		return
	t = v
	var ai := _active_index(v)
	if ai != _active:   # the highlighted block changes only at event boundaries
		_active = ai
		queue_redraw()
	_head.queue_redraw()


func _active_index(tt: float) -> int:
	for i in events.size():
		if tt >= float(events[i]["t0"]) and tt < float(events[i]["t1"]):
			return i
	return -1


func _x(tt: float) -> float:
	return clampf(tt / total, 0.0, 1.0) * size.x


func _draw() -> void:
	var y0 := 4.0
	var h := 20.0
	draw_rect(Rect2(0, y0, size.x, h), Color(1, 1, 1, 0.04))
	if events.is_empty():
		draw_string(UiKit.font(500), Vector2(8, y0 + 15), "No plan yet", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UiKit.FAINT)
		return
	var f := UiKit.font(600)
	for e in events:
		var kind := str(e["kind"])
		var col: Color = KIND_COLORS.get(kind, UiKit.DIM)
		var x0 := _x(float(e["t0"]))
		var x1 := _x(float(e["t1"]))
		var active := t >= float(e["t0"]) and t < float(e["t1"])
		var a := 0.85 if active else 0.42
		draw_rect(Rect2(x0 + 1, y0, maxf(1.0, x1 - x0 - 2), h), Color(col, a))
		if active:
			draw_rect(Rect2(x0 + 1, y0, maxf(1.0, x1 - x0 - 2), h), Color(1, 1, 1, 0.5), false, 1.0)
		var label := str(e.get("name", kind))
		if kind == "walk":
			label = "→ " + label.get_slice("→ ", 1) if label.contains("→ ") else label
		elif kind == "egress" or kind == "ingress":
			label = "SUITPORT" if label.begins_with("Suitport") else "AIRLOCK"
		elif kind == "drive":
			label = "PR-2 DRIVE"
		var room := x1 - x0 - 8
		if room > 30:
			var tw := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
			if tw > room:
				label = label.substr(0, maxi(2, int(label.length() * room / tw) - 1)) + "…"
			draw_string(f, Vector2(x0 + 5, y0 + 14), label, HORIZONTAL_ALIGNMENT_LEFT, room, UiKit.MIN_FONT, Color(0.02, 0.03, 0.05) if active else Color.WHITE)
	for sh in shade:   # terrain shadow: a dark blue bar under the blocks
		var s0 := _x(float((sh as Dictionary).get("t0", 0.0)))
		var s1 := _x(float((sh as Dictionary).get("t1", 0.0)))
		draw_rect(Rect2(s0, y0 + h - 5.0, maxf(2.0, s1 - s0), 5.0), Color(0.23, 0.31, 0.62, 0.95))
	for a in cme:   # CME arrival windows: hatched band over the blocks, a tick at the forecast time
		var a0 := float(a.get("t0_rel_s", 0.0))
		var a1 := float(a.get("t1_rel_s", 0.0))
		if a1 <= 0.0 or a0 >= total:
			continue
		var ccol: Color = UiKit.AMBER if bool(a.get("glancing", false)) else UiKit.BAD
		var bx0 := _x(maxf(a0, 0.0))
		var bx1 := _x(minf(a1, total))
		draw_rect(Rect2(bx0, y0 - 3, maxf(2.0, bx1 - bx0), h + 6), Color(ccol, 0.16))
		var sx0 := bx0 - fmod(bx0, 8.0)
		while sx0 < bx1:   # diagonal hatching: the band reads without relying on colour alone
			var xa := maxf(sx0, bx0)
			draw_line(Vector2(xa, y0 + h + 2), Vector2(minf(xa + 6.0, bx1), y0 - 2), Color(ccol, 0.45), 1.0)
			sx0 += 8.0
		draw_rect(Rect2(bx0, y0 - 3, maxf(2.0, bx1 - bx0), h + 6), Color(ccol, 0.8), false, 1.0)
		var tf := float(a.get("t_rel_s", 0.0))
		if tf >= 0.0 and tf <= total:
			var fx := _x(tf)
			draw_line(Vector2(fx, 0), Vector2(fx, y0 + h + 4), ccol, 2.0)
		draw_string(f, Vector2(bx0 + 3, y0 + h + 15), "CME ±%dh" % int(round((a1 - a0) / 7200.0)), HORIZONTAL_ALIGNMENT_LEFT, -1, UiKit.MIN_FONT, ccol)
	var m := UiKit.mono(400)
	var step := 900.0 if total < 4.0 * 3600.0 else 1800.0
	var k := 0.0
	while k <= total:
		var x := _x(k)
		draw_line(Vector2(x, y0 + h + 1), Vector2(x, y0 + h + (6 if int(k) % 3600 == 0 else 3)), Color(1, 1, 1, 0.25))
		if int(k) % 1800 == 0:
			draw_string(m, Vector2(x + 2, y0 + h + 15), "%d:%02d" % [int(k / 3600.0), int(k / 60.0) % 60], HORIZONTAL_ALIGNMENT_LEFT, -1, UiKit.MIN_FONT, UiKit.FAINT)
		k += step
	if not is_nan(sunset_t) and sunset_t < total * 1.05:
		var sx := _x(sunset_t)
		draw_line(Vector2(sx, 0), Vector2(sx, y0 + h + 4), UiKit.BAD, 2.0)
		draw_string(f, Vector2(sx - 52, y0 + h + 15), "SUNSET", HORIZONTAL_ALIGNMENT_RIGHT, 48, UiKit.MIN_FONT, UiKit.BAD)   # over the real terrain


func _draw_head() -> void:
	if events.is_empty():
		return
	var y0 := 4.0
	var h := 20.0
	var f := UiKit.font(600)
	var px := _x(t)
	_head.draw_rect(Rect2(px - 4, 0, 8, y0 + h + 4), Color(1, 1, 1, 0.1))
	_head.draw_line(Vector2(px, 0), Vector2(px, y0 + h + 4), Color.WHITE, 2.0)
	_head.draw_colored_polygon(PackedVector2Array([Vector2(px - 6, 0), Vector2(px + 6, 0), Vector2(px, 7)]), Color.WHITE)
	if not is_nan(_hover):
		var hx := _x(_hover)
		_head.draw_line(Vector2(hx, y0), Vector2(hx, y0 + h), Color(1, 1, 1, 0.5), 1.0)
		var txt := "%s  %s" % [MarsTime.clock(_hover), _event_name(_hover)]
		var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 14
		var bx := clampf(hx - w * 0.5, 0, size.x - w)
		_head.draw_style_box(_tip_box, Rect2(bx, y0 + h + 2, w, 18))
		_head.draw_string(f, Vector2(bx + 7, y0 + h + 15), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UiKit.TEXT)


func _event_name(tt: float) -> String:
	for sh in shade:
		if tt >= float((sh as Dictionary).get("t0", 0.0)) and tt <= float((sh as Dictionary).get("t1", 0.0)):
			for e in events:
				if tt >= float(e["t0"]) and tt < float(e["t1"]):
					return "%s · in terrain shadow" % str(e.get("name", e["kind"]))
	for a in cme:
		if tt >= float(a.get("t0_rel_s", 0.0)) and tt <= float(a.get("t1_rel_s", 0.0)):
			for e in events:
				if tt >= float(e["t0"]) and tt < float(e["t1"]):
					return "%s · CME window" % str(e.get("name", e["kind"]))
	for e in events:
		if tt >= float(e["t0"]) and tt < float(e["t1"]):
			return str(e.get("name", e["kind"]))
	return ""


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover = clampf((event as InputEventMouseMotion).position.x / maxf(size.x, 1.0), 0.0, 1.0) * total
		if _drag:
			scrubbed.emit(_hover)
		_head.queue_redraw()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_drag = (event as InputEventMouseButton).pressed
		if _drag:
			scrubbed.emit(clampf((event as InputEventMouseButton).position.x / maxf(size.x, 1.0), 0.0, 1.0) * total)
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_hover = NAN
		_drag = false
		_head.queue_redraw()
