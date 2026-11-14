class_name EcgTrace
extends Control
## Scrolling ECG trace driven by a heart rate (synthetic P-QRS-T waveform).

var bpm := 78.0
var color := Color("3ddc84")
var _buf := PackedFloat32Array()
var _phase := 0.0
var _acc := 0.0
const SAMPLES := 160
const RATE := 60.0


func _init() -> void:
	custom_minimum_size = Vector2(150, 34)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_buf.resize(SAMPLES)


func _wave(p: float) -> float:
	var v := 0.12 * exp(-pow((p - 0.18) / 0.035, 2.0))
	v += -0.15 * exp(-pow((p - 0.32) / 0.012, 2.0))
	v += 1.0 * exp(-pow((p - 0.35) / 0.012, 2.0))
	v += -0.3 * exp(-pow((p - 0.38) / 0.014, 2.0))
	v += 0.25 * exp(-pow((p - 0.6) / 0.06, 2.0))
	return v


func _process(delta: float) -> void:
	_acc += delta
	var step := 1.0 / RATE
	while _acc >= step:
		_acc -= step
		_phase = fmod(_phase + step * bpm / 60.0, 1.0)
		var s := _buf.slice(1)
		s.append(_wave(_phase) + randf_range(-0.02, 0.02))
		_buf = s
	queue_redraw()


func _draw() -> void:
	var pts := PackedVector2Array()
	var h := size.y
	for i in SAMPLES:
		pts.append(Vector2(size.x * i / (SAMPLES - 1.0), h * 0.68 - _buf[i] * h * 0.55))
	draw_polyline(pts, Color(color, 0.25), 4.0, true)
	draw_polyline(pts, color, 1.5, true)
	var last := pts[pts.size() - 1]
	draw_circle(last, 2.5, Color.WHITE)
