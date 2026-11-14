class_name BarGauge
extends Control
## Segmented consumable bar (O2, battery, CO2, water). Animates toward its level and
## blinks when it crosses the warning thresholds. `invert` = higher is worse (CO2 load).

var title := "O2"
var text := ""
var level := 1.0
var target := 1.0
var warn := 0.3
var bad := 0.15
var invert := false
var segments := 24
var compact := false


func _init(t := "", inv := false, height := 30.0) -> void:
	title = t
	invert = inv
	custom_minimum_size = Vector2(60, height)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_level(v: float, txt: String) -> void:
	target = clampf(v, 0.0, 1.0)
	text = txt
	queue_redraw()


func _health() -> float:
	return 1.0 - level if invert else level


func _process(delta: float) -> void:
	if absf(level - target) > 0.0005:
		level = lerpf(level, target, 1.0 - exp(-delta * 5.0))
		queue_redraw()
	elif _health() <= warn:
		queue_redraw()


func _draw() -> void:
	var hp := _health()
	var col := UiKit.level_color(hp, warn, bad)
	if hp <= bad and fmod(Time.get_ticks_msec() / 1000.0, 0.8) < 0.35:
		col = col.lightened(0.45)
	var top := 0.0
	if not compact:
		draw_string(UiKit.caps_font(), Vector2(0, 11), title, HORIZONTAL_ALIGNMENT_LEFT, -1, UiKit.MIN_FONT, UiKit.DIM)
		draw_string(UiKit.mono(600), Vector2(0, 12), text, HORIZONTAL_ALIGNMENT_RIGHT, size.x, 12, col)
		top = 16.0
	var h := size.y - top
	var gap := 2.0
	var w := (size.x - gap * (segments - 1)) / segments
	for i in segments:
		var x := i * (w + gap)
		var frac := (i + 0.5) / segments
		var on := frac <= level
		var c := col if on else Color(1, 1, 1, 0.07)
		if on and i == int(level * segments):
			c = c.lightened(0.35)
		draw_rect(Rect2(x, top, w, h), c)
	if level > 0.0:
		var x2 := level * size.x
		draw_rect(Rect2(0, top + h - 1, x2, 1), Color(col, 0.9))
