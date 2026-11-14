class_name OrbitRig
extends RefCounted
## Orbit camera with damped motion, cinematic fly-to arcs and an idle auto-orbit.
## yaw = 0 puts the camera south of the target looking north; pitch is the elevation angle.
## The wheel zooms toward the ground under the cursor, and right/middle-drag keeps the ground you
## grabbed under the cursor, with a little fling when you let go while moving.

var td: TerrainData
var picker: Callable      # screen point -> ground hit (Vector3.INF if the ray misses); set by MarsWorld
var ray_fn: Callable      # screen point -> [origin, direction] of the camera as last drawn
var target := Vector3.ZERO
var yaw := 0.5
var pitch := 0.55
var dist := 2600.0
var min_dist := 10.0
var max_dist := 160000.0
var auto_rotate := true
var idle_time := 0.0

var _target := Vector3.ZERO
var _yaw := 0.5
var _pitch := 0.55
var _dist := 2600.0
var _flight := {}
var _grab := Vector3.INF          # ground point held under the cursor during a right/middle drag
var _pan_offset := Vector3.ZERO   # camera shift applied since the camera node was last placed
var _fling := Vector3.ZERO        # m/s, carried on after a pan drag is let go while moving
var _drag_hist: Array = []        # [[time_s, Vector3 shift], ...] of the latest drag moves


func snap() -> void:
	_target = target
	_yaw = yaw
	_pitch = pitch
	_dist = dist


func flying() -> bool:
	return not _flight.is_empty()


func transform() -> Transform3D:
	var dir := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch))
	var pos := _target + dir * _dist
	if td:
		var g := td.h(pos.x, -pos.z)
		if pos.y < g + 3.0:
			pos.y = g + 3.0
	return Transform3D(Basis(), pos).looking_at(_target, Vector3.UP)


func update(delta: float) -> Transform3D:
	idle_time += delta
	_pan_offset = Vector3.ZERO   # the camera is placed from the state below: drag rays start over
	if _fling != Vector3.ZERO and _flight.is_empty():
		var step := _fling * delta
		target += step
		_target += step
		if td:
			target.y = td.h(target.x, -target.z)
		_fling *= exp(-delta * 3.5)
		if _fling.length() < maxf(dist, 40.0) * 0.02:
			_fling = Vector3.ZERO
	if not _flight.is_empty():
		var f: Dictionary = _flight
		f["e"] = float(f["e"]) + delta
		var u := clampf(float(f["e"]) / float(f["dur"]), 0.0, 1.0)
		var s := u * u * (3.0 - 2.0 * u)
		s = s * s * (3.0 - 2.0 * s)
		var a: Vector3 = f["t0"]
		var b: Vector3 = f["t1"]
		target = a.lerp(b, s)
		var bump := float(f["bump"]) * sin(PI * u)
		dist = exp(lerpf(log(float(f["d0"])), log(float(f["d1"])), s)) * (1.0 + bump)
		yaw = lerp_angle(float(f["y0"]), float(f["y1"]), s)
		pitch = lerpf(float(f["p0"]), float(f["p1"]), s)
		snap()
		if u >= 1.0:
			_flight = {}
	else:
		if auto_rotate and idle_time > 40.0:
			yaw += delta * 0.02
		var k := 1.0 - exp(-delta * 7.5)
		_target = _target.lerp(target, k)
		_yaw = lerp_angle(_yaw, yaw, k)
		_pitch = lerpf(_pitch, pitch, k)
		_dist = exp(lerpf(log(_dist), log(dist), k))
	return transform()


## Cinematic flight: travels along a gentle arc (zooms out mid-way for long hops).
func fly_to(t1: Vector3, d1: float, yaw1 := NAN, pitch1 := NAN, dur := -1.0) -> void:
	var travel := Vector2(t1.x - _target.x, t1.z - _target.z).length()
	if dur < 0.0:
		dur = clampf(1.2 + log(1.0 + travel / 150.0) * 0.55 + absf(log(d1 / maxf(_dist, 1.0))) * 0.25, 1.2, 4.5)
	_flight = {"t0": _target, "t1": t1, "d0": _dist, "d1": d1, "y0": _yaw, "p0": _pitch,
		"y1": _yaw if is_nan(yaw1) else yaw1, "p1": _pitch if is_nan(pitch1) else pitch1,
		"bump": clampf(travel / maxf(_dist + d1, 1.0) * 1.4, 0.0, 1.6), "dur": dur, "e": 0.0}
	_fling = Vector3.ZERO
	idle_time = 0.0


func cancel_flight() -> void:
	_flight = {}


func handle_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(pow(0.86, Settings.zoom_speed), mb.position)
			return true
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(pow(1.16, Settings.zoom_speed), mb.position)
			return true
		if mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				_fling = Vector3.ZERO
				_drag_hist.clear()
				_grab = picker.call(mb.position) if picker.is_valid() else Vector3.INF
			else:
				_grab = Vector3.INF
				_release_fling()
			return true
		if mb.pressed:
			_fling = Vector3.ZERO
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			cancel_flight()
			_fling = Vector3.ZERO
			yaw -= mm.relative.x * 0.0055 * Settings.mouse_sens
			pitch = clampf(pitch + mm.relative.y * 0.0042 * Settings.mouse_sens * (-1.0 if Settings.invert_orbit else 1.0), deg_to_rad(3.0), deg_to_rad(89.0))
			idle_time = 0.0
			return true
		if mm.button_mask & (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE):
			cancel_flight()
			if _grab.is_finite() and ray_fn.is_valid():
				_drag_ground(mm.position)
			else:
				pan(mm.relative)   # grabbed the sky: fall back to a plain pan
			return true
	elif event is InputEventMagnifyGesture:
		var mg := event as InputEventMagnifyGesture
		_zoom(1.0 / mg.factor, mg.position)
		return true
	elif event is InputEventPanGesture:
		pan((event as InputEventPanGesture).delta * 8.0)
		return true
	return false


## Zoom by factor f. With a screen point, zoom toward the ground under it: the camera moves along the
## ray through that point, so the point stays under the cursor (target' = target + (P - target)(1 - d'/d)).
func _zoom(f: float, at := Vector2(-1.0, -1.0)) -> void:
	cancel_flight()
	_fling = Vector3.ZERO
	var nd := clampf(dist * f, min_dist, max_dist)
	if at.x >= 0.0 and picker.is_valid() and not is_equal_approx(nd, dist):
		var hit: Vector3 = picker.call(at)
		if hit.is_finite():
			var shift := (hit - target) * (1.0 - nd / dist)
			var flat := Vector2(shift.x, shift.z).length()
			var lim := dist * 0.5   # a point near the horizon must not throw the view kilometres away
			if flat > lim:
				shift *= lim / flat
			target += shift
	dist = nd
	idle_time = 0.0


## Right/middle-drag: move the camera so the grabbed ground point sits under the cursor again.
func _drag_ground(screen: Vector2) -> void:
	var ray: Array = ray_fn.call(screen)
	var o: Vector3 = ray[0]
	o += _pan_offset
	var d: Vector3 = ray[1]
	if absf(d.y) < 0.02:
		return
	var t := (_grab.y - o.y) / d.y
	if t <= 0.0:
		return
	var q := o + d * t
	var shift := Vector3(_grab.x - q.x, 0.0, _grab.z - q.z)
	var lim := maxf(dist, 50.0) * 0.6
	if shift.length() > lim:
		shift = shift.normalized() * lim
	target += shift
	_target += shift   # 1:1 with the cursor, no damping lag
	_pan_offset += shift
	if td:
		target.y = td.h(target.x, -target.z)
	_drag_hist.append([Time.get_ticks_msec() / 1000.0, shift])
	if _drag_hist.size() > 10:
		_drag_hist.pop_front()
	idle_time = 0.0


## Let go of a pan drag: if the cursor was still moving, the view glides on and slows down.
func _release_fling() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var sum := Vector3.ZERO
	var first := now
	# Mouse events arrive once per frame: at 10 FPS the last move is ~100 ms old when the button comes
	# up, so look back over the last few frames rather than a fixed 80 ms.
	var win := clampf(3.0 / maxf(Engine.get_frames_per_second(), 1.0), 0.08, 0.35)
	for h in _drag_hist:
		var ht := float(h[0])
		if now - ht <= win:
			var s: Vector3 = h[1]
			sum += s
			first = minf(first, ht)
	_drag_hist.clear()
	var v := sum / maxf(now - first, 1.0 / 60.0)
	var scale := maxf(dist, 40.0)
	if v.length() < scale * 0.3:
		return
	_fling = v.limit_length(scale * 2.0)


func pan(rel: Vector2) -> void:
	var s := dist * 0.0017
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	target += (-right * rel.x + fwd * rel.y) * s
	if td:
		target.y = td.h(target.x, -target.z)
	idle_time = 0.0


## Keys and gamepad (input actions from Controls): WASD / arrows / left stick pan, Q E / right stick
## turn, R F / right stick tilt, PageUp PageDown = - / triggers zoom.
func keyboard(delta: float) -> void:
	var move := Vector2(Input.get_axis("move_left", "move_right") + Input.get_axis("turn_left", "turn_right"),
		Input.get_axis("move_forward", "move_back"))
	if move != Vector2.ZERO:
		_fling = Vector3.ZERO
		pan(-move.limit_length(1.0) * delta * 600.0 * Settings.pan_speed)
	var look := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	var turn := Input.get_axis("rotate_right", "rotate_left") * 0.9 - look.x * 1.4
	if turn != 0.0:
		yaw += delta * turn
		idle_time = 0.0
	var tilt := (Input.get_axis("tilt_down", "tilt_up") * 0.7 + look.y * 0.9) * (-1.0 if Settings.invert_orbit else 1.0)
	if tilt != 0.0:
		pitch = clampf(pitch + delta * tilt, deg_to_rad(3.0), deg_to_rad(89.0))
		idle_time = 0.0
	var z := Input.get_action_strength("zoom_out") - Input.get_action_strength("zoom_in")
	if z != 0.0:
		_zoom(1.0 + z * delta * 1.5 * Settings.zoom_speed)
