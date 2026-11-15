extends "res://scripts/app/demo30_tour.gd"
## --tour=fulltour: the console shots for the long walkthrough video that the 30-second take does not have: the
## console with its panels, layer drapes, the console's own guided tour and help, the helmet tools (ghost pacer, data
## flashlight, Earth light, tags), the cuff menu, an ABORT walk home, and a ride in PR-2. Marks as in demo30_tour.gd.


func run() -> void:
	m.alerts.muted = true
	if m.fps_label:
		m.fps_label.visible = false
	await m._await_plan()
	var waited := 0.0
	while not m.tower.load_sheets_ready() and waited < 300.0:
		await m._wait(0.5)
		waited += 0.5
	await hold(2.0)
	m._quiet_alerts()
	mark("start", "take")
	await _orbit_ui()
	await _drapes()
	await _coach_and_help()
	await _helmet_tools_full()
	await _cuff()
	await _abort()
	await _rover_ride()
	await _play_ui()
	mark("end", "take")
	await hold(0.5)


## The whole console: the plan panels, the timeline and the 3D view; a stop selected and flown to.
func _orbit_ui() -> void:
	await _orbit()
	m.ui_hidden = false
	m.world.set_layer_visible("labels", true)
	m._fade_plan_ui(true)
	m.world.home_view()
	m.world.orbit.auto_rotate = true
	await hold(2.2)
	m._quiet_alerts()
	mark("in", "orbit_ui")
	await hold(3.0)
	var sid := ""
	for s in Mission.stops:
		if str(s.get("name", "")).contains("Wildcat"):
			sid = str(s["id"])
	if sid == "" and not Mission.stops.is_empty():
		sid = str(Mission.stops[0]["id"])
	if sid != "":
		m._select_stop(sid)
	await hold(4.0)
	mark("out", "orbit_ui")
	m.world.home_view()
	await hold(1.6)


## Layers draped on the 3D terrain: the combined hazard class, then the ways-home network with its pulses.
func _drapes() -> void:
	m.world.orbit.auto_rotate = true
	for id in ["hazard", "ways_home"]:
		var L := _layer(id)
		if L.is_empty():
			continue
		m._on_overlay(L)
		m._set_flow_for(L)
		await hold(2.5)   # the drape is fetched and revealed
		m._quiet_alerts()
		mark("in", "drape_" + id)
		await hold(3.6)
		mark("out", "drape_" + id)
	m._on_overlay({"id": ""})
	await hold(1.0)


## The console's own first-run guided tour, and the help with every key and gamepad button.
func _coach_and_help() -> void:
	m._start_coach()
	await hold(1.0)
	mark("in", "coach")
	await hold(2.4)
	for i in [1, 2]:
		if m.coach.active():
			m.coach._go(i)
		await hold(2.2)
	mark("out", "coach")
	if m.coach.active():
		m.coach.stop(true)
	await hold(0.8)
	m._toggle_help()
	await hold(0.6)
	mark("in", "help")
	await hold(3.2)
	mark("out", "help")
	m._toggle_help()
	await hold(0.6)


## The helmet tools, as tools_tour.gd stages them: ghost pacer, data flashlight, Earth light, a hazard and a find tag.
func _helmet_tools_full() -> void:
	m.ui_hidden = true
	m._fade_plan_ui(false)
	var walks := _walks()
	var tw := 0.0
	if not walks.is_empty():
		var e: Dictionary = walks[mini(1, walks.size() - 1)]
		tw = float(e["t0"]) + (float(e["t1"]) - float(e["t0"])) * 0.3
	Mission.set_playing(false)
	Mission.set_time(tw)
	m._set_mode("walk")
	await hold(2.4)
	m.world.walker.autopilot = false
	var d0 := float(Mission.state_at(tw)["d"])
	_place_on_route(d0)
	m.world.walker.pitch = -0.10
	await hold(1.0)
	# the ghost walks the plan at the planned pace; the HUD says ahead or behind
	m.tools.set_ghost(true)
	await hold(1.2)
	mark("in", "ghost")
	await hold(4.0)
	mark("out", "ghost")
	m.tools.set_ghost(false)
	Mission.set_playing(false)
	_place_on_route(d0)
	m.world.walker.pitch = -0.12
	await hold(0.8)
	# the data flashlight shows a layer only where you look
	m.tools.set_flashlight(true)
	var waited := 0.0
	while m.world._param("overlay_opacity") < 0.05 and waited < 30.0:
		await hold(0.25)
		waited += 0.25
	await hold(1.0)
	mark("in", "flashlight")
	await hold(3.4)
	mark("out", "flashlight")
	m.tools.set_flashlight(false)
	m._flashlight_layer("")
	m._on_overlay({"id": ""})
	await hold(0.6)
	# Earth light: the ground and sky in Earth-like light (the geologist's white balance)
	m.tools.set_earth_light(true)
	await hold(0.6)
	mark("in", "earthlight")
	await hold(2.6)
	mark("out", "earthlight")
	m.tools.set_earth_light(false)
	await hold(0.6)
	# tags where you look: a hazard closes the ground and the route is planned again; a find is a candidate stop
	m.world.walker.pitch = -0.30
	await hold(0.5)
	mark("in", "tags")
	m.tools.tag("hazard")
	await hold(2.0)
	m.world.walker.pitch = -0.22
	await hold(0.3)
	m.tools.tag("find")
	await hold(2.0)
	mark("out", "tags")
	await hold(0.5)


## The cuff menu: every crew action on big buttons for gloved hands.
func _cuff() -> void:
	m._quiet_alerts()
	m.cuff_menu.open(m.ui.size)
	await hold(0.7)
	mark("in", "cuff")
	await hold(3.0)
	mark("out", "cuff")
	m.cuff_menu.close()
	await hold(0.6)


## ABORT: the crew turns for home on the fastest way back (a red route), first in the helmet, then from above.
func _abort() -> void:
	if m.world.mode != "walk":
		m._set_mode("walk")
		await hold(1.8)
	var walks := _walks()
	if walks.size() > 1:
		Mission.set_time(float(walks[1]["t0"]) + (float(walks[1]["t1"]) - float(walks[1]["t0"])) * 0.5)
	await hold(0.6)
	m._start_abort()
	await hold(0.8)
	mark("in", "abort_helmet")
	await hold(3.6)
	mark("out", "abort_helmet")
	m._set_mode("orbit")
	await hold(1.4)
	m.ui_hidden = true
	m._fade_plan_ui(false)
	m.world.focus_xy(m.world.walker.xy(), 420.0)
	await hold(1.6)
	mark("in", "abort_orbit")
	await hold(3.6)
	mark("out", "abort_orbit")
	m._toggle_abort()
	m._quiet_alerts()
	await hold(1.0)


## Rover-assisted EVA: PR-2 drives on its own route, and the view from inside its cab.
func _rover_ride() -> void:
	await m._await_plan()
	var was_rover: bool = Mission.rover_enabled
	Mission.rover_dropoff = {}
	Mission.set_rover(true)
	Mission.request_plan()
	await m._await_plan()
	await hold(1.0)
	if Mission.has_rover():
		var drive_t := float(Mission.plan["events"][0]["t1"])
		Mission.set_time(drive_t * 0.5)
		await _orbit()
		m.world.focus_xy(Mission.rover_state(Mission.eva_t)["xy"], 90.0)
		await hold(2.2)
		Mission.speed_index = 1
		Mission.set_playing(true)
		m.follow_crew = true
		await hold(0.4)
		mark("in", "rover_drive")
		await hold(3.2)
		mark("out", "rover_drive")
		Mission.set_playing(false)
		m.follow_crew = false
		Mission.set_time(drive_t * 0.6)
		m._set_mode("walk")
		await hold(2.6)
		Mission.speed_index = 1
		Mission.set_playing(true)
		await hold(0.5)
		mark("in", "rover_cab")
		await hold(3.4)
		mark("out", "rover_cab")
		Mission.set_playing(false)
		m._set_mode("orbit")
		await hold(1.3)
	Mission.set_rover(was_rover)
	Mission.request_plan()
	await m._await_plan()
	await hold(1.0)


## The EVA playing in the console with its panels: the timeline runs, the consumables drain, the crew walks.
func _play_ui() -> void:
	await _orbit()
	m.ui_hidden = false
	m._fade_plan_ui(true)
	m.world.set_layer_visible("labels", true)
	var walks := _walks()
	if not walks.is_empty():
		Mission.set_time(float(walks[0]["t0"]) + 200.0)
	m.follow_crew = true
	m.dock.set_follow(true)
	Mission.speed_index = 2
	Mission.set_playing(true)
	m.world.orbit.auto_rotate = false
	m.world.focus_xy(Mission.state_at(Mission.eva_t)["xy"], 260.0)
	await hold(2.0)
	m._quiet_alerts()
	mark("in", "play_ui")
	await hold(4.5)
	mark("out", "play_ui")
	Mission.set_playing(false)
	m.follow_crew = false
	m.dock.set_follow(false)
