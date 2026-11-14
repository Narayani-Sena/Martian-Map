class_name Walker
extends RefCounted
## First-person astronaut. Autopilot follows the planned route at the timeline clock;
## any movement key takes manual control (WASD, Shift to lope, Space to jump in 0.38 g).

const EYE := 1.62
const MARS_G := 3.721
const MAX_CLIMB_DEG := 32.0
const WALK_SPEED := 1.25      # m/s on the flat; Shift lopes at 2.4x
const ACCEL := 2.6            # m/s² speeding up: a suited astronaut with a backpack takes a moment
const DECEL := 4.5            # m/s² slowing down
const AIR_CONTROL := 0.25     # share of that control left while airborne in 0.38 g
const BODY_R := 0.35          # suit radius for boulder contact (m)
const STEP_OVER := 0.4        # boulders lower than this (m) are stepped over

var td: TerrainData
var structures: Array = []   # MarsWorld.obstacles: the habitat, its solar field and the rovers, walked round by hand too
var x := 0.0
var y := 0.0
var feet := 0.0
var yaw := 0.0          # radians; 0 = facing north, +pi/2 = east
var pitch := -0.06
var vz := 0.0
var grounded := true
var autopilot := true
var speed_now := 0.0
var distance_walked := 0.0
var blocked := false
var slope_ahead := 0.0
var _bob := 0.0
var _look_t := 99.0
var _step_acc := 0.0
var _jumped := false
var stepped := false    # true on frames where a footstep lands (for sound)
var riding := false     # in PR-2's cab on a rover-assisted EVA (chase view)
var _ride_yaw := 0.0
var vel := Vector2.ZERO # walking velocity by hand (m/s, x east, y north)
var bumped := false     # true on frames where you walked into a boulder
var lope_latched := false  # Settings "lope_toggle": Shift / LB switches loping on and off
var slid := false       # true on frames where too-steep ground turned the step along the slope
var _rocks := {}        # boulder chunk -> Array[Vector3(x, y, contact radius)], built on first visit


## Loping: held (the default) or toggled (Settings "lope_toggle").
func lope_on() -> bool:
	return lope_latched if Settings.lope_toggle else Input.is_action_pressed("lope")


func place(xy: Vector2, heading_deg: float) -> void:
	x = xy.x
	y = xy.y
	yaw = deg_to_rad(heading_deg)
	feet = td.h(x, y) if td else 0.0
	vz = 0.0


func xy() -> Vector2:
	return Vector2(x, y)


func heading_deg() -> float:
	return fposmod(rad_to_deg(yaw), 360.0)


## Turn the head by a mouse move (or the right stick), scaled by the Settings look sensitivity.
func look(rel: Vector2) -> void:
	var k := Settings.mouse_sens
	yaw += rel.x * 0.0024 * k
	pitch = clampf(pitch - rel.y * 0.002 * k * (-1.0 if Settings.invert_y else 1.0), -1.3, 1.25)
	_look_t = 0.0


func jump() -> void:
	if grounded:
		vz = 2.3   # ~0.7 m hop on Mars, a few cm on Earth
		grounded = false
		_jumped = true


func update(delta: float, auto_target: Dictionary, manual_keys := true) -> Transform3D:
	_look_t += delta
	stepped = false
	var move := Vector2.ZERO
	if manual_keys:
		# input actions (Controls): WASD / arrows / left stick; the stick walks slower when only tilted a little
		move = Input.get_vector("move_left", "move_right", "move_back", "move_forward")
		yaw += Input.get_axis("turn_left", "turn_right") * delta * 1.3
	if move != Vector2.ZERO:
		autopilot = false
	var px := x
	var py := y
	blocked = false
	bumped = false
	slid = false
	riding = autopilot and bool(auto_target.get("ride", false))
	if riding:
		vel = Vector2.ZERO
		return _ride(delta, auto_target)
	if autopilot and not auto_target.is_empty():
		vel = Vector2.ZERO
		var t: Vector2 = auto_target["xy"]
		var gap := Vector2(x, y).distance_to(t)
		if gap > 250.0:
			x = t.x
			y = t.y
		elif gap > 2.0:
			# catch up with the plan at a brisk lope rather than teleporting
			var step := (t - Vector2(x, y)).normalized() * minf(gap, maxf(3.0, gap * 0.8) * delta)
			x += step.x
			y += step.y
		else:
			var k := 1.0 - exp(-delta * 10.0)
			x = lerpf(x, t.x, k)
			y = lerpf(y, t.y, k)
		var ahead: Vector2 = auto_target.get("xy_ahead", t)
		if ahead.distance_to(t) > 0.5 and _look_t > 2.5:
			var want := atan2(ahead.x - t.x, ahead.y - t.y)
			yaw = lerp_angle(yaw, want, minf(1.0, delta * 2.2))
			pitch = lerpf(pitch, -0.08, minf(1.0, delta * 1.5))
	else:
		# by hand: the speed ramps up and down instead of jumping, with little control in the air
		var want := Vector2.ZERO
		if move != Vector2.ZERO:
			var mv := move.limit_length(1.0)
			var run := 2.4 if lope_on() else 1.0
			want = Vector2(sin(yaw) * mv.y + cos(yaw) * mv.x, cos(yaw) * mv.y - sin(yaw) * mv.x) * WALK_SPEED * run
		var rate := (ACCEL if want.length() > vel.length() else DECEL) * (1.0 if grounded else AIR_CONTROL)
		vel = vel.move_toward(want, rate * delta)
		if vel.length_squared() > 1e-6:
			_step(vel * delta)
	var moved := Vector2(x - px, y - py).length()
	if moved < 20.0:
		distance_walked += moved
		speed_now = lerpf(speed_now, moved / maxf(delta, 1e-4), minf(1.0, delta * 6.0))
		_bob += moved * 2.1
		_step_acc += moved
		var stride := clampf(0.7 + speed_now * 0.3, 0.95, 1.8)   # longer bounds when loping
		if _step_acc > stride and grounded:
			_step_acc = 0.0
			stepped = true
	else:
		speed_now = 0.0
	var ground := td.h(x, y) if td else 0.0
	vz -= MARS_G * delta
	feet += vz * delta
	if feet <= ground:
		feet = ground
		vz = 0.0
		grounded = true
	if td:
		var hx := x + sin(yaw) * 5.0
		var hy := y + cos(yaw) * 5.0
		slope_ahead = rad_to_deg(atan2(td.h(hx, hy) - ground, 5.0))
	var breathe := sin(Time.get_ticks_msec() * 0.0016) * 0.006
	var bob := sin(_bob) * 0.035 * clampf(speed_now, 0.0, 1.5)
	var pos := Vector3(x, feet + EYE + bob, -y)
	var p := pitch + breathe
	var fwd := Vector3(sin(yaw) * cos(p), sin(p), -cos(yaw) * cos(p))
	return Transform3D(Basis(), pos).looking_at(pos + fwd, Vector3.UP)


## One step by hand. Ground steeper than MAX_CLIMB_DEG turns the step along the slope (you slide
## round the shoulder of a ridge instead of stopping dead); boulders taller than STEP_OVER push you
## round them.
func _step(step: Vector2) -> void:
	var p := Vector2(x, y)
	var q := p + step
	if td == null or not td.grid.contains_xy(q.x, q.y, 3.0):
		vel = Vector2.ZERO
		blocked = true
		return
	if grounded and _too_steep(p, q):
		var up := _uphill(p)
		var climb := step.dot(up)
		var along := step - up * climb if climb > 0.0 else Vector2.ZERO
		if along.length() > 1e-4 and not _too_steep(p, p + along):
			q = p + along
			vel -= up * maxf(0.0, vel.dot(up))
			slid = true
		else:
			vel = Vector2.ZERO
			blocked = true
			return
	q = _clear_of_boulders(q)
	x = q.x
	y = q.y


func _too_steep(a: Vector2, b: Vector2) -> bool:
	var run_len := maxf(a.distance_to(b), 1e-4)
	return rad_to_deg(atan2(td.h(b.x, b.y) - td.h(a.x, a.y), run_len)) > MAX_CLIMB_DEG


## Unit vector pointing uphill at p (site x/y).
func _uphill(p: Vector2) -> Vector2:
	var e := 0.75
	var g := Vector2(td.h(p.x + e, p.y) - td.h(p.x - e, p.y), td.h(p.x, p.y + e) - td.h(p.x, p.y - e))
	return g.normalized() if g.length_squared() > 1e-10 else Vector2.ZERO


func _clear_of_boulders(q: Vector2) -> Vector2:
	var key := Vector2i(floori(q.x / TerrainData.BOULDER_CHUNK), floori(q.y / TerrainData.BOULDER_CHUNK))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for b in _boulders(key + Vector2i(dx, dy)):
				var bv: Vector3 = b
				var c := Vector2(bv.x, bv.y)
				var r := bv.z + BODY_R
				var d := q.distance_to(c)
				if d < r:
					var n := (q - c) / d if d > 1e-4 else Vector2.RIGHT
					q = c + n * r
					vel -= n * minf(0.0, vel.dot(n))
					bumped = true
	for o in structures:
		var a: Vector2 = o["a"]
		var b: Vector2 = o["b"]
		var k := a if a.distance_squared_to(b) < 1e-6 else Geometry2D.get_closest_point_to_segment(q, a, b)
		var r: float = o["r"]
		var d := q.distance_to(k)
		if d < r:
			var n := (q - k) / d if d > 1e-4 else Vector2.RIGHT
			q = k + n * r
			vel -= n * minf(0.0, vel.dot(n))
			bumped = true
	return q


## Boulders in one 32 m chunk that you cannot step over: Vector3(x, y, contact radius), cached.
func _boulders(key: Vector2i) -> Array:
	if _rocks.has(key):
		return _rocks[key]
	var out := []
	for b in td.boulders_in(key):
		var v: Vector4 = b
		if v.w >= STEP_OVER:
			out.append(Vector3(v.x, v.y, clampf(v.z, 0.6, 4.0) * 0.45))   # the same size range RockField draws
	_rocks[key] = out
	return out


## Riding in PR-2: a chase view from behind and above the rover (drag still looks around it).
func _ride(delta: float, auto_target: Dictionary) -> Transform3D:
	var t: Vector2 = auto_target["xy"]
	var ahead: Vector2 = auto_target.get("xy_ahead", t)
	if ahead.distance_to(t) > 0.05:
		_ride_yaw = lerp_angle(_ride_yaw, atan2(ahead.x - t.x, ahead.y - t.y), minf(1.0, delta * 2.5))
	if _look_t > 2.5:
		yaw = lerp_angle(yaw, _ride_yaw, minf(1.0, delta * 2.0))
		pitch = lerpf(pitch, -0.22, minf(1.0, delta * 1.5))
	x = t.x
	y = t.y
	speed_now = 0.0
	vz = 0.0
	grounded = true
	var ground := td.h(x, y) if td else 0.0
	feet = ground
	var back := Vector2(sin(yaw), cos(yaw)) * 14.0
	var cx := x - back.x
	var cy := y - back.y
	var cam_ground := td.h(cx, cy) if td else ground
	var pos := Vector3(cx, maxf(ground, cam_ground) + 6.0, -cy)
	var fwd := Vector3(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
	return Transform3D(Basis(), pos).looking_at(pos + fwd, Vector3.UP)


func consume_jump_sound() -> bool:
	var j := _jumped
	_jumped = false
	return j
