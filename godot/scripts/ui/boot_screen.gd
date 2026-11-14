class_name BootScreen
extends Control
## Start-up sequence: rotating rings and a radar sweep, a glitching title, a typed boot log
## with status tags and a progress bar; finish() wipes it away to reveal the 3D scene.

var _lines: Array = []       # {text, status, t}
var _progress := 0.0
var _shown := 0.0
var _t := 0.0
var _closing := 0.0
var _title := "MARTIAN MAP"
var _subtitle := "EVA CONSOLE · MARS SURFACE OPERATIONS"
var failed := false


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP


func set_subtitle(text: String) -> void:
	_subtitle = text.to_upper()
	queue_redraw()


func step(text: String) -> void:
	if not _lines.is_empty() and str(_lines[-1]["status"]) == "..":
		_lines[-1]["status"] = "OK"
	_lines.append({"text": text, "status": "..", "t": _t})
	if _lines.size() > 11:
		_lines.pop_front()
	Sfx.play("type", -12.0)


func done(status := "OK") -> void:
	if not _lines.is_empty():
		_lines[-1]["status"] = status
	if status != "OK":
		failed = true


func progress(p: float) -> void:
	_progress = clampf(p, 0.0, 1.0)


func finish() -> void:
	done("OK")
	_progress = 1.0
	Sfx.play("ready", -4.0)
	var tw := create_tween()
	tw.tween_interval(0.5)
	tw.tween_property(self, "_closing", 1.0, 1.1).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(queue_free)


func _process(delta: float) -> void:
	_t += delta
	_shown = lerpf(_shown, _progress, 1.0 - exp(-delta * 4.0))
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	var c := Vector2(w * 0.5, h * 0.42)
	var wipe := _closing * (h * 0.5 + 40.0)
	draw_rect(Rect2(0, 0, w, h * 0.5 - wipe), Color(0.012, 0.016, 0.024))
	draw_rect(Rect2(0, h * 0.5 + wipe, w, h * 0.5 - wipe + 1), Color(0.012, 0.016, 0.024))
	if _closing > 0.0:
		draw_rect(Rect2(0, h * 0.5 - wipe - 2, w, 2), Color(UiKit.ACCENT, 1.0 - _closing))
		draw_rect(Rect2(0, h * 0.5 + wipe, w, 2), Color(UiKit.ACCENT, 1.0 - _closing))
	var a := 1.0 - clampf(_closing * 2.0, 0.0, 1.0)
	if a <= 0.01:
		return
	for i in 26:
		var y := fmod(i * 41.0 + _t * 18.0, h)
		draw_line(Vector2(0, y), Vector2(w, y), Color(UiKit.ACCENT, 0.025 * a), 1.0)
	var planet := Color(0.82, 0.38, 0.17, a)
	draw_circle(c, 92, Color(planet, 0.12 * a))
	draw_circle(c, 70, Color(0.5, 0.2, 0.09, a))
	draw_circle(c + Vector2(-14, -16), 52, Color(0.72, 0.33, 0.15, a))
	draw_circle(c + Vector2(-24, -26), 26, Color(0.85, 0.45, 0.22, 0.6 * a))
	for k in 3:
		var r := 110.0 + k * 26.0
		var rot := _t * (0.6 - k * 0.25) * (1.0 if k % 2 == 0 else -1.0)
		for s in 6:
			var a0 := rot + s * TAU / 6.0
			draw_arc(c, r, a0, a0 + TAU / 6.0 * 0.62, 24, Color(UiKit.ACCENT, (0.55 - k * 0.14) * a), 2.0 - k * 0.4, true)
	var sweep := fmod(_t * 1.6, TAU)
	for j in 18:
		var aa := sweep - j * 0.03
		draw_line(c, c + Vector2(cos(aa), sin(aa)) * 150.0, Color(UiKit.ACCENT, (0.22 - j * 0.012) * a), 2.0)
	var blip := c + Vector2(cos(1.1), sin(1.1)) * 46.0
	draw_circle(blip, 3.0 + 2.0 * sin(_t * 6.0), Color(UiKit.MARS, a))
	var ft := UiKit.font(700)
	var gl := 0.0
	if fmod(_t, 2.7) < 0.12:
		gl = randf_range(-6.0, 6.0)
	var ty := c.y + 205.0
	draw_string(ft, Vector2(gl - 2, ty), _title, HORIZONTAL_ALIGNMENT_CENTER, w, 46, Color(1.0, 0.2, 0.3, 0.55 * a * absf(gl) / 6.0))
	draw_string(ft, Vector2(-gl + 2, ty), _title, HORIZONTAL_ALIGNMENT_CENTER, w, 46, Color(0.2, 0.9, 1.0, 0.55 * a * absf(gl) / 6.0))
	draw_string(ft, Vector2(0, ty), _title, HORIZONTAL_ALIGNMENT_CENTER, w, 46, Color(UiKit.TEXT, a))
	draw_string(UiKit.caps_font(), Vector2(0, ty + 28), _subtitle, HORIZONTAL_ALIGNMENT_CENTER, w, 12, Color(UiKit.ACCENT, a))
	var bx := w * 0.5 - 260.0
	var by := ty + 56.0
	draw_rect(Rect2(bx, by, 520, 4), Color(1, 1, 1, 0.08 * a))
	draw_rect(Rect2(bx, by, 520 * _shown, 4), Color(UiKit.ACCENT, a))
	draw_rect(Rect2(bx + 520 * _shown - 14, by - 2, 14, 8), Color(1, 1, 1, 0.6 * a))
	draw_string(UiKit.mono(500), Vector2(bx, by + 22), "%3d%%" % int(_shown * 100.0), HORIZONTAL_ALIGNMENT_RIGHT, 520, 11, Color(UiKit.DIM, a))
	var m := UiKit.mono(400)
	var y2 := by + 44.0
	for i in _lines.size():
		var L: Dictionary = _lines[i]
		var age := _t - float(L["t"])
		var txt := str(L["text"])
		var n := mini(txt.length(), int(age * 70.0))
		var status := str(L["status"])
		var scol := UiKit.GOOD if status == "OK" else (UiKit.BAD if status == "FAIL" else (UiKit.AMBER if status == "WARN" else UiKit.DIM))
		var tag := "[ %s ]" % (status if status != ".." else ["·  ", " · ", "  ·"][int(_t * 6.0) % 3])
		var fade := clampf(1.0 - (_lines.size() - 1 - i) * 0.07, 0.3, 1.0) * a
		draw_string(m, Vector2(bx, y2), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(scol, fade))
		draw_string(m, Vector2(bx + 64, y2), txt.substr(0, n), HORIZONTAL_ALIGNMENT_LEFT, 460, 12, Color(UiKit.TEXT, fade))
		y2 += 18.0
	if failed:
		draw_string(UiKit.font(600), Vector2(0, h - 40), "Start the API:  .venv\\Scripts\\python -m uvicorn server.main:app --port 8000   (then restart)", HORIZONTAL_ALIGNMENT_CENTER, w, 13, Color(UiKit.AMBER, a))
