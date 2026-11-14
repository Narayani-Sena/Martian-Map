class_name Coach
extends Control
## The guided first run: a short tour of the real controls. Each step dims the screen except the
## control it is about, rings it, and explains it in a bubble beside it. The highlighted control
## stays live (clicks inside the ring go through to it). Shown once on the first run; SHOW ME AROUND
## (settings or help) plays it again. Enter / → next, ← back, Esc skips; gamepad A next, B skips.

signal finished(skipped: bool)

const DIM := Color(0.0, 0.012, 0.024, 0.64)

var _steps: Array = []     # {title, text, rect: Callable -> Rect2 in UI coordinates (missing = no ring)}
var _i := -1
var _bubble: PanelContainer
var _title: Label
var _text: Label
var _count: Label
var _next: Button
var _back: Button
var _hole := Rect2()       # the ring as drawn (eases toward _hole_to)
var _hole_to := Rect2()
var _t := 0.0
var _ring: StyleBoxFlat
var _halo: StyleBoxFlat
var _placed_for := Rect2()   # the ring the bubble was last placed beside
var _bubble_tw: Tween


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   # the console waits while the tour talks (except the ringed control)
	visible = false
	_ring = UiKit.box(Color(0, 0, 0, 0), UiKit.ACCENT, 10, 2, 0)
	_halo = UiKit.box(Color(0, 0, 0, 0), UiKit.ACCENT, 14, 2, 0)
	_bubble = PanelContainer.new()
	_bubble.add_theme_stylebox_override("panel", UiKit.box(UiKit.PANEL_SOLID, Color(UiKit.ACCENT, 0.7), 10, 1, 16))
	_bubble.custom_minimum_size = Vector2(390, 0)
	add_child(_bubble)
	var v := UiKit.vbox(9)
	_bubble.add_child(v)
	var head := UiKit.hbox(8)
	_title = UiKit.label("", 18, UiKit.TEXT, 700)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	_count = UiKit.caps("", UiKit.FAINT, 11)
	head.add_child(_count)
	v.add_child(head)
	_text = UiKit.wrap("", 14, UiKit.DIM)
	_text.custom_minimum_size = Vector2(358, 0)
	v.add_child(_text)
	var row := UiKit.hbox(8)
	row.add_child(UiKit.button("SKIP TOUR", func(): stop(true), "Esc"))
	row.add_child(UiKit.spacer(0.0, true))
	_back = UiKit.button("◀", func(): _go(_i - 1), "Back  [←]")
	_back.add_theme_font_override("font", UiKit.symbols())
	row.add_child(_back)
	_next = UiKit.button("NEXT  ▶", func(): _go(_i + 1), "Next  [Enter / →]")
	_next.add_theme_font_override("font", UiKit.symbols())
	row.add_child(_next)
	v.add_child(row)


func start(steps: Array) -> void:
	_steps = steps
	visible = true
	modulate.a = 1.0
	UiKit.appear(self, 0.0, 0.3)
	_hole = Rect2(size * 0.5, Vector2.ZERO)
	_go(0)


func active() -> bool:
	return visible and _i >= 0


func step() -> int:
	return _i


func stop(skipped := false) -> void:
	if not active():
		return
	_i = -1
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, 0.25)
	tw.tween_callback(func():
		visible = false
		modulate.a = 1.0)
	Sfx.play("toggle", -8.0)
	finished.emit(skipped)


func _go(i: int) -> void:
	if i >= _steps.size():
		stop(false)
		return
	_i = clampi(i, 0, _steps.size() - 1)
	var s: Dictionary = _steps[_i]
	_title.text = str(s.get("title", ""))
	_text.text = str(s.get("text", ""))
	_count.text = "%d / %d" % [_i + 1, _steps.size()]
	_back.disabled = _i == 0
	_next.text = "DONE  ✓" if _i == _steps.size() - 1 else "NEXT  ▶"
	var enter: Variant = s.get("enter")   # e.g. scroll a panel so the control is in view
	if enter is Callable and (enter as Callable).is_valid():
		(enter as Callable).call()
	_hole_to = _target_rect(s)
	if _hole.size == Vector2.ZERO:
		_hole = Rect2(_hole_to.get_center(), Vector2.ZERO)
	_place_bubble.call_deferred()   # once the bubble has its size for the new text
	Sfx.play("toggle", -10.0)


## The ringed rectangle in this control's coordinates (it covers the whole UI layer from its origin).
func _target_rect(s: Dictionary) -> Rect2:
	var cb: Variant = s.get("rect")
	if not (cb is Callable) or not (cb as Callable).is_valid():
		return Rect2(size * 0.5, Vector2.ZERO)
	var r: Rect2 = (cb as Callable).call()
	return Rect2(r.position - global_position, r.size).grow(8.0)


## Beside the ring where there is room (right, left, below, above), else in the middle of the screen.
func _place_bubble() -> void:
	_placed_for = _hole_to
	_bubble.reset_size()
	var b := _bubble.size
	var h := _hole_to
	var m := 20.0
	var screen := Rect2(Vector2(16, 16), size - Vector2(32, 32))
	var pos := (size - b) * 0.5
	if h.size != Vector2.ZERO:
		var cands := [
			Vector2(h.end.x + m, h.get_center().y - b.y * 0.5),
			Vector2(h.position.x - m - b.x, h.get_center().y - b.y * 0.5),
			Vector2(h.get_center().x - b.x * 0.5, h.end.y + m),
			Vector2(h.get_center().x - b.x * 0.5, h.position.y - m - b.y)]
		for c in cands:
			var p: Vector2 = c
			p.y = clampf(p.y, screen.position.y, screen.end.y - b.y)
			p.x = clampf(p.x, screen.position.x, screen.end.x - b.x)
			if not Rect2(p, b).intersects(h) and screen.encloses(Rect2(p, b)):
				pos = p
				break
	if _bubble_tw and _bubble_tw.is_valid():
		_bubble_tw.kill()
	_bubble_tw = create_tween()
	_bubble_tw.tween_property(_bubble, "position", pos, 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _process(delta: float) -> void:
	if not visible:
		return
	if active():   # the ring follows its control (panels slide, lists scroll)
		_hole_to = _target_rect(_steps[_i])
		if _hole_to.position.distance_to(_placed_for.position) > 3.0 or _hole_to.size.distance_to(_placed_for.size) > 3.0:
			_place_bubble()
	_t += delta
	var k := 1.0 - exp(-delta * 9.0)
	_hole = Rect2(_hole.position.lerp(_hole_to.position, k), _hole.size.lerp(_hole_to.size, k))
	queue_redraw()


func _draw() -> void:
	var r := _hole
	draw_rect(Rect2(0, 0, size.x, maxf(r.position.y, 0.0)), DIM)
	draw_rect(Rect2(0, r.end.y, size.x, size.y - r.end.y), DIM)
	draw_rect(Rect2(0, r.position.y, maxf(r.position.x, 0.0), r.size.y), DIM)
	draw_rect(Rect2(r.end.x, r.position.y, size.x - r.end.x, r.size.y), DIM)
	if r.size.x > 4.0 and r.size.y > 4.0:
		var pulse := 0.5 + 0.5 * sin(_t * 4.0)
		_ring.border_color = Color(UiKit.ACCENT, 0.65 + 0.35 * pulse)
		draw_style_box(_ring, r)
		_halo.border_color = Color(UiKit.ACCENT, 0.3 * (1.0 - pulse))
		draw_style_box(_halo, r.grow(4.0 + 7.0 * pulse))


## Clicks inside the ring reach the control underneath, so you can try it while the tour points at it.
func _has_point(point: Vector2) -> bool:
	return not (_hole.size.x > 4.0 and _hole.has_point(point))


func _input(event: InputEvent) -> void:
	if not active() or not event.is_pressed() or event.is_echo():
		return
	var handled := true
	if event.is_action_pressed("back"):
		stop(true)
	elif event is InputEventKey and ((event as InputEventKey).keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_RIGHT]):
		_go(_i + 1)
	elif event is InputEventKey and (event as InputEventKey).keycode == KEY_LEFT:
		_go(_i - 1)
	elif event is InputEventJoypadButton and (event as InputEventJoypadButton).button_index == JOY_BUTTON_A:
		_go(_i + 1)
	else:
		handled = false
	if handled:
		get_viewport().set_input_as_handled()
