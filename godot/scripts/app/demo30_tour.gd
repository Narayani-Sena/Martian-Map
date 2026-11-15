extends RefCounted
## --tour=demo30: one take of every console shot the 30-second demo video uses, recorded by Godot's movie writer
## (godot --path godot --write-movie <file>.avi --fixed-fps 30 -- --capture=<dir> --tour=demo30 [--site=<id>]).
## Each shot is framed by "in <label> <frame>" and "out <label> <frame>" lines in
## demo30_marks.txt (in the capture folder), so the video build cuts the take by label; nothing between shots is kept.
## In-app captions and toasts stay off and the panels stay hidden, except where a shot is about the interface.

var m   # main.gd
var _marks := ""


func _init(main_node) -> void:
	m = main_node


func mark(kind: String, label: String) -> void:
	if m.capture_dir == "":
		return
	var path: String = m.capture_dir.path_join("demo30_marks.txt")
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_line("%s %s %d" % [kind, label, Engine.get_frames_drawn()])
		f.close()
	print("DEMO30 %s %s %d" % [kind, label, Engine.get_frames_drawn()])


## Waits s seconds of frame time (the movie writer runs slower than the wall clock).
func hold(s: float) -> void:
	var left := s
	while left > 0.0:
		await m.get_tree().process_frame
		left -= m.get_process_delta_time()


func _walks() -> Array:
	var out: Array = []
	for e in Mission.plan["events"]:
		if str(e.get("kind", "")) == "walk":
			out.append(e)
	return out


func _layer(id: String) -> Dictionary:
	for L in Mission.site.get("layers", []):
		if str(L.get("id", "")) == id:
			return L
	return {}


func _orbit() -> void:
	if m.world.mode != "orbit":
		m._set_mode("orbit")
		await hold(1.3)


func _place_on_route(d: float, look_ahead := 12.0) -> void:
	var p: Vector2 = Mission.route_xy(d)
	var q: Vector2 = Mission.route_xy(d + look_ahead)
	m.world.walker.place(p, rad_to_deg(atan2(q.x - p.x, q.y - p.y)))


func run() -> void:
	m.alerts.muted = true
	m.ui_hidden = true
	if m.fps_label:
		m.fps_label.visible = false
	await m._await_plan()
	var waited := 0.0
	while not m.tower.load_sheets_ready() and waited < 300.0:
		await m._wait(0.5)
		waited += 0.5
	await m.radar_viewpoint()   # fetch the radar runs before the camera rolls
	m._fade_plan_ui(false)
	m.world.set_layer_visible("labels", false)
	await hold(2.0)
	m._quiet_alerts()
	mark("start", "take")
	await _tower()
	await _chase()
	await _helmet()
	await _helmet_tools()
	await _lake()
	await _radar()
	await _then_now()
	await _cw()
	await _rover()
	await _end()
	await _danger()
	mark("end", "take")
	await hold(0.5)


## The app's layer tower (the IN THE APP inset of S3, and S3's fallback), a little faster than real time.
func _tower() -> void:
	await _orbit()
	m._quiet_alerts()
	mark("in", "tower")
	Engine.time_scale = 1.6
	await m.play_tower(1.2, false)
	Engine.time_scale = 1.0
	mark("out", "tower")
	m._fade_plan_ui(false)
	await hold(0.6)


## Behind EV1 and EV2 on the route (director.gd's chase shot), without the plan panels.
func _chase() -> void:
	var walks := _walks()
	var t0 := float(walks[0]["t0"]) + 45.0 if not walks.is_empty() else 0.0
	Mission.set_time(t0)
	var st := Mission.state_at(t0)
	var p0: Vector2 = st["xy"]
	var dir0: Vector2 = (st.get("xy_ahead", p0) as Vector2) - p0
	var yaw0: float = -atan2(dir0.x, dir0.y) if dir0.length() > 0.5 else m.world.orbit.yaw
	m.world.orbit.auto_rotate = false
	m.world.orbit.fly_to(m.world.td.world_at(p0), Director.CHASE_DIST, yaw0, deg_to_rad(Director.CHASE_PITCH), 1.2)
	await hold(1.5)
	m.follow_crew = true
	m.dock.set_follow(true)
	Mission.speed_index = 1
	Mission.set_playing(true)
	await _chase_for(0.8)
	mark("in", "chase")
	await _chase_for(3.2)
	mark("out", "chase")
	Mission.set_playing(false)
	m.follow_crew = false
	m.dock.set_follow(false)


func _chase_for(s: float) -> void:
	var left := s
	while left > 0.0:
		await m.get_tree().process_frame
		var delta: float = m.get_process_delta_time()
		left -= delta
		var w: MarsWorld = m.world
		if w.orbit.flying():
			continue
		var st := Mission.state_at(Mission.eva_t)
		var p: Vector2 = st["xy"]
		var dir: Vector2 = (st.get("xy_ahead", p) as Vector2) - p
		var k := 1.0 - exp(-delta * 1.8)
		if dir.length() > 0.5:
			w.orbit.yaw = lerp_angle(w.orbit.yaw, -atan2(dir.x, dir.y), k)
		w.orbit.dist = lerpf(w.orbit.dist, Director.CHASE_DIST, k)
		w.orbit.pitch = lerp_angle(w.orbit.pitch, deg_to_rad(Director.CHASE_PITCH), k)
		w.orbit.idle_time = 0.0


## Through the visor on autopilot; the ways-home line lights up along the ground toward the habitat.
func _helmet() -> void:
	var walks := _walks()
	var walk_ev: Dictionary = walks[mini(1, walks.size() - 1)] if not walks.is_empty() else {}
	if not walk_ev.is_empty():
		Mission.set_time(maxf(float(walk_ev["t0"]), float(walk_ev["t1"]) - 130.0))
	m._set_mode("walk")
	await hold(1.8)
	Mission.speed_index = 1
	Mission.set_playing(true)
	await hold(0.4)
	m._quiet_alerts()
	mark("in", "helmet")
	await hold(1.1)
	var L := _layer("ways_home")
	if not L.is_empty():
		m._on_overlay(L)
		m._set_flow_for(L)
	await hold(3.4)
	mark("out", "helmet")
	m._on_overlay({"id": ""})
	Mission.set_playing(false)


## Three helmet tools for the feature wall: synthetic vision, the skyline fix and the HUD-failure drill.
func _helmet_tools() -> void:
	if m.world.mode != "walk":
		m._set_mode("walk")
		await hold(1.8)
	var walks := _walks()
	if walks.size() > 1:
		Mission.set_time(float(walks[1]["t0"]) + (float(walks[1]["t1"]) - float(walks[1]["t0"])) * 0.4)
	Mission.speed_index = 1
	Mission.set_playing(true)
	await hold(0.5)
	m.tools.set_synthetic(true)
	await hold(0.9)
	m._quiet_alerts()
	mark("in", "t_synth")
	await hold(2.4)
	mark("out", "t_synth")
	m.tools.set_synthetic(false)
	await hold(0.5)
	m.tools.skyline_fix()
	await hold(0.3)
	mark("in", "t_skyline")
	await hold(2.6)
	mark("out", "t_skyline")
	await hold(0.8)
	Mission.set_playing(false)
	m.world.walker.autopilot = false
	m.tools.toggle_drill()
	await hold(0.9)
	mark("in", "t_hudfail")
	await hold(2.4)
	mark("out", "t_hudfail")
	if m.tools.drill_on:
		m.tools.toggle_drill()
	await hold(0.5)
	m._quiet_alerts()


## Jezero's ancient lake rises in the crater (as main.gd's _short_lake, without its caption).
func _lake() -> void:
	var L: Array = m.lake.levels()
	if L.is_empty() or not bool(L[0].get("published", false)):
		return
	await _orbit()
	m.world.set_layer_visible("labels", false)
	m._fade_plan_ui(false)
	m._quiet_alerts()
	m.world.orbit.auto_rotate = false
	m.world.orbit.fly_to(m.world.td.world_at(Mission.hab_xy()), 5600.0, m.world.orbit.yaw + 0.7, deg_to_rad(27.0), 1.0)
	await hold(1.3)
	mark("in", "lake")
	m.lake.cycle()
	await hold(LakeWater.RISE_S + 0.6)
	mark("out", "lake")
	m.lake.set_off(true)
	await hold(0.6)


## Perseverance's ground radar hung under its track (as main.gd's _short_radar, without its caption).
func _radar() -> void:
	if not m.radar.available():
		return
	var shot: Dictionary = await m.radar_viewpoint()
	if shot.is_empty():
		return
	await _orbit()
	m.world.set_layer_visible("labels", false)
	m._fade_plan_ui(false)
	m.world.orbit.auto_rotate = false
	m._quiet_alerts()
	m.world.orbit.fly_to(m.world.td.world_at(shot["xy"]), 75.0, float(shot["along_yaw"]), deg_to_rad(10.0), 1.0)
	await hold(1.3)
	await m.radar.set_on(true, true)
	mark("in", "radar")
	await hold(RadarCurtain.REVEAL_S + 2.0)
	mark("out", "radar")
	m.radar.set_on(false, true)
	await hold(0.8)


## The rover's photo wiped against our terrain from the pose it was taken at.
func _then_now() -> void:
	m.then_now.next()
	var waited := 0.0
	while not m.then_now.active and waited < 60.0:
		await m.get_tree().process_frame
		waited += m.get_process_delta_time()
	if not m.then_now.active:
		return
	mark("in", "thennow")
	await hold(ThenNow.SWEEP_S * 0.6)
	mark("out", "thennow")
	m.then_now.stop()
	await hold(1.2)


## The caution and warning list (NASA-STD-3001 classes and colours), for the feature wall.
func _cw() -> void:
	await _orbit()
	Mission.set_playing(false)
	m.world.home_view()
	await hold(1.6)
	CW.reset()
	CW.raise("test_caution", "check")
	CW.raise("test_warning", "check")
	CW.raise("test_emergency", "check")
	m.cw_panel.toggle(m.ui.size, "ACTIVE")
	await hold(0.8)
	mark("in", "t_cw")
	await hold(2.4)
	mark("out", "t_cw")
	m.cw_panel.toggle(m.ui.size)
	CW.reset()
	m._quiet_alerts()
	await hold(0.4)


## PR-2 drives the crew out (rover-assisted EVA), for the feature wall; the walking plan is restored after.
func _rover() -> void:
	await m._await_plan()
	var was_rover: bool = Mission.rover_enabled
	Mission.rover_dropoff = {}
	Mission.set_rover(true)
	Mission.request_plan()
	await m._await_plan()
	await hold(1.0)
	if Mission.has_rover():
		var drive_t := float(Mission.plan["events"][0]["t1"])
		Mission.set_time(drive_t * 0.45)
		await _orbit()
		m.world.focus_xy(Mission.rover_state(Mission.eva_t)["xy"], 150.0)
		await hold(2.2)
		Mission.speed_index = 1
		Mission.set_playing(true)
		m.follow_crew = true
		await hold(0.5)
		mark("in", "t_rover")
		await hold(2.6)
		mark("out", "t_rover")
		Mission.set_playing(false)
		m.follow_crew = false
	Mission.set_rover(was_rover)
	Mission.request_plan()
	await m._await_plan()
	await hold(1.0)


## The whole console with its panels (S13's fallback).
func _end() -> void:
	await _orbit()
	m.ui_hidden = false
	m.world.set_layer_visible("labels", true)
	m._fade_plan_ui(true)
	m._quiet_alerts()
	m.world.home_view()
	m.world.orbit.auto_rotate = true
	await hold(2.4)
	m._quiet_alerts()
	mark("in", "end")
	await hold(4.2)
	mark("out", "end")
	m.ui_hidden = true
	m._fade_plan_ui(false)
	m.world.set_layer_visible("labels", false)
	m.world.orbit.auto_rotate = false
	await hold(0.6)


## The suit-leak drill (tools_tour.gd run_reach): in the helmet, then from above as the safe ground shrinks.
func _danger() -> void:
	m._set_mode("walk")
	await hold(1.8)
	m.world.walker.autopilot = false
	Mission.set_playing(false)
	_place_on_route(420.0)
	await hold(0.5)
	m.alerts.muted = false
	m._suit_drill("leak")
	Mission.set_playing(false)
	var re: ReachEdge = m.reach
	var waited := 0.0
	while (re._tex == null or re.havens.is_empty()) and waited < 60.0:
		await m._wait(0.25)
		waited += 0.25
	re.minutes_left = 16.0
	m.world.walker.pitch = -0.26
	await hold(1.2)
	mark("in", "danger_helmet")
	await _drain(re, 16.0, 12.0, 3.8)
	mark("out", "danger_helmet")
	m._set_mode("orbit")
	await hold(1.3)
	m.ui_hidden = true
	m._fade_plan_ui(false)
	m.world.orbit.fly_to(m.world.td.world_at(m.world.walker.xy()), 2600.0, m.world.orbit.yaw, deg_to_rad(52.0), 0.1)
	re.minutes_left = 30.0
	await hold(1.6)
	mark("in", "danger_orbit")
	m.world.orbit.auto_rotate = true
	await _drain(re, 30.0, 9.0, 4.4)
	mark("out", "danger_orbit")
	Mission.set_drill("")


## Runs the secondary oxygen down from a to b minutes over s seconds (the edge tightens as it does).
func _drain(re, a: float, b: float, s: float) -> void:
	var t := 0.0
	while t < s:
		await m.get_tree().process_frame
		t += m.get_process_delta_time()
		re.minutes_left = lerpf(a, b, clampf(t / s, 0.0, 1.0))
