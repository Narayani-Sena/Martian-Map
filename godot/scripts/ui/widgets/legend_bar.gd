class_name LegendBar
extends Control
## Legend for a draped layer, from the API's legend block:
##   {unit, stops: [[value, "#hex"], ...]}  -> a colour ramp with ticks
##   {classes: [[label, "#hex"], ...]}      -> labelled swatches (hazard, walk-back, radio, geologic units)
## Every class carries its name as text, so no colour has to be told apart on its own (NASA-STD-3001 [V2 10045]).

var stops: Array = []
var classes: Array = []
var unit := ""
const SW := 12.0      # swatch size
const ROW := 18.0     # class row height


func _init() -> void:
	custom_minimum_size = Vector2(120, 34)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_fit)


func set_legend(legend: Variant) -> void:
	stops = []
	classes = []
	unit = ""
	if legend is Dictionary:
		stops = (legend as Dictionary).get("stops", [])
		classes = (legend as Dictionary).get("classes", [])
		unit = str((legend as Dictionary).get("unit", ""))
	elif legend is Array:
		stops = legend
	_fit()
	queue_redraw()


## Height for the class list: one row per class, two columns when the panel is wide enough.
func _fit() -> void:
	var h := 34.0
	if not classes.is_empty():
		var cols := 2 if size.x >= 300.0 and classes.size() > 3 else 1
		h = ceilf(classes.size() / float(cols)) * ROW + 4.0
	elif stops.size() < 2:
		h = 0.0
	if absf(custom_minimum_size.y - h) > 0.5:
		custom_minimum_size.y = h
	queue_redraw()


func _draw() -> void:
	if not classes.is_empty():
		_draw_classes()
		return
	if stops.size() < 2:
		return
	var h := 10.0
	var w := size.x
	var lo := float(stops[0][0])
	var hi := float(stops[stops.size() - 1][0])
	var n := 64
	for i in n:
		var v := lerpf(lo, hi, (i + 0.5) / n)
		draw_rect(Rect2(w * i / n, 4, w / n + 1, h), _color_at(v))
	draw_rect(Rect2(0, 4, w, h), Color(1, 1, 1, 0.25), false, 1.0)
	var f := UiKit.mono(400)
	var shown := 0
	for s in stops:
		var x := (float(s[0]) - lo) / maxf(1e-9, hi - lo) * w
		draw_line(Vector2(x, 14), Vector2(x, 18), Color(1, 1, 1, 0.4))
		if shown % maxi(1, stops.size() / 4) == 0 or shown == stops.size() - 1:
			var txt := _fmt(float(s[0]))
			draw_string(f, Vector2(clampf(x - 20, 0, w - 40), 30), txt, HORIZONTAL_ALIGNMENT_CENTER, 40, UiKit.MIN_FONT, UiKit.DIM)
		shown += 1


func _draw_classes() -> void:
	var cols := 2 if size.x >= 300.0 and classes.size() > 3 else 1
	var cw := size.x / cols
	var rows := int(ceil(classes.size() / float(cols)))
	var f := UiKit.font(500)
	for i in classes.size():
		var c: Array = classes[i]
		var col := i / rows
		var row := i % rows
		var p := Vector2(col * cw, row * ROW + 2.0)
		var colr := Color(str(c[1]))
		if colr.a < 0.05:   # a transparent class ("Easy" ground) gets an outline swatch
			draw_rect(Rect2(p + Vector2(0, 2), Vector2(SW, SW)), Color(1, 1, 1, 0.5), false, 1.0)
		else:
			draw_rect(Rect2(p + Vector2(0, 2), Vector2(SW, SW)), Color(colr, 1.0))
			draw_rect(Rect2(p + Vector2(0, 2), Vector2(SW, SW)), Color(1, 1, 1, 0.3), false, 1.0)
		draw_string(f, p + Vector2(SW + 6.0, 13.0), str(c[0]), HORIZONTAL_ALIGNMENT_LEFT, cw - SW - 10.0, UiKit.MIN_FONT, UiKit.TEXT)


func _fmt(v: float) -> String:
	if absf(v) >= 100.0 or v == floor(v):
		return "%d" % int(round(v))
	return "%.2f" % v


func _color_at(v: float) -> Color:
	for i in range(1, stops.size()):
		var a := float(stops[i - 1][0])
		var b := float(stops[i][0])
		if v <= b:
			var f := clampf((v - a) / maxf(1e-9, b - a), 0.0, 1.0)
			return Color(str(stops[i - 1][1])).lerp(Color(str(stops[i][1])), f)
	return Color(str(stops[stops.size() - 1][1]))
