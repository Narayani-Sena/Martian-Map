class_name Director
extends Node
## Demo mode (▶ DEMO in the top bar, or the help panel): a hands-free fly-through of the EVA.
## Orbit overview → a chase camera behind the crew at x30 → the first station → the helmet view on
## autopilot → back out. Any key, click, drag, wheel or gamepad input hands the controls straight back
## (that first press is swallowed, so it doesn't also do something).

signal ended(by_user: bool)

const CHASE_DIST := 34.0     # m behind the crew: an astronaut is ~40 px tall at this range
const CHASE_PITCH := 15.0    # degrees above the horizontal

var shell            # the application shell (main.gd); untyped because it has no class_name
var world: MarsWorld
var running := false
var shot := ""       # current shot, for the checks: overview | chase | station | helmet | outro
var _chase := false
var _saved := {}
var _ignore_until := 0
var _caption: PanelContainer
var _cap_title: Label
var _cap_text: Label
var _run_id := 0


func setup(app, ui: Control) -> void:
	shell = app
	world = app.world
	_caption = PanelContainer.new()
	_caption.add_theme_stylebox_override("panel", UiKit.box(Color(0.01, 0.02, 0.03, 0.82), Color(UiKit.MARS, 0.6), 8, 1, 14))
	_caption.custom_minimum_size = Vector2(560, 0)
	_caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_caption.visible = false
	var v := UiKit.vbox(4)
	_caption.add_child(v)
	_cap_title = UiKit.caps("", UiKit.MARS, 13)
	v.add_child(_cap_title)
	_cap_text = UiKit.wrap("", 14, UiKit.TEXT)
	_cap_text.custom_minimum_size = Vector2(530, 0)
	v.add_child(_cap_text)
	ui.add_child(_caption)


func play() -> void:
	if running or not Mission.has_plan() or not world.ready_terrain:
		return
	running = true
	_run_id += 1
	var me := _run_id
	_ignore_until = Time.get_ticks_msec() + 500   # the click on DEMO itself
	_saved = {"speed": Mission.speed_index, "t": Mission.eva_t, "follow": shell.follow_crew, "auto_rotate": world.orbit.auto_rotate}
	shell.alerts.toast("Demo: sit back. Any key, click or stick hands the controls back.", "info")
	var stops: Array = []
	var walks: Array = []
	for e in Mission.plan["events"]:
		match str(e.get("kind", "")):
			"stop":
				stops.append(e)
			"walk":
				walks.append(e)

	# 1. the plan from above
	shot = "overview"
	if world.mode == "walk":
		shell._set_mode("orbit")
		if not await _hold(me, 1.6):
			return
	Mission.set_playing(false)
	world.home_view()
	world.orbit.auto_rotate = true
	_say("1 / 5 · The plan", "Gale crater's boxwork ridges on HiRISE 1 m terrain. The cyan route links the science stations; the rings show how long the walk back to the habitat takes from anywhere.")
	if not await _hold(me, 6.5):
		return

	# 2. a chase camera a few tens of metres behind the crew, at x10
	shot = "chase"
	var t0 := 0.0
	if not walks.is_empty():
		t0 = float(walks[0]["t0"]) + 45.0   # already clear of the habitat
	Mission.set_time(t0)
	var st := Mission.state_at(t0)
	var p0: Vector2 = st["xy"]
	var dir0: Vector2 = (st.get("xy_ahead", p0) as Vector2) - p0
	var yaw0: float = -atan2(dir0.x, dir0.y) if dir0.length() > 0.5 else world.orbit.yaw
	world.orbit.auto_rotate = false
	world.orbit.fly_to(world.td.world_at(p0), CHASE_DIST, yaw0, deg_to_rad(CHASE_PITCH), 2.4)
	_say("2 / 5 · Out on foot", "Riding along behind EV1 and EV2 at x10 on the planned route. The timeline below plays the whole EVA, and the suit consumables drain as they walk.")
	if not await _hold(me, 2.5):
		return
	shell.follow_crew = true
	shell.dock.set_follow(true)
	Mission.speed_index = 1
	Mission.set_playing(true)
	_chase = true
	if not await _hold(me, 10.0):
		return
	_chase = false

	# 3. at the first station
	shot = "station"
	if not stops.is_empty():
		var ev: Dictionary = stops[0]
		Mission.speed_index = 1
		Mission.set_time(float(ev["t0"]) + 30.0)
		shell.follow_crew = false
		shell.dock.set_follow(false)
		var stop_id := _stop_id_named(str(ev.get("name", "")))
		if stop_id != "":
			shell._select_stop(stop_id)
		_say("3 / 5 · On station", "%s: the crew works the station's tasks. The panels show conditions, space weather, the rover's camera and every safety layer." % str(ev.get("name", "")))
		if not await _hold(me, 7.0):
			return

	# 4. into the helmet, on autopilot at x10
	shot = "helmet"
	Mission.set_playing(false)
	var walk_ev: Dictionary = walks[mini(1, walks.size() - 1)] if not walks.is_empty() else {}
	if not walk_ev.is_empty():
		Mission.set_time(maxf(float(walk_ev["t0"]), float(walk_ev["t1"]) - 130.0))
	shell._set_mode("walk")
	if not await _hold(me, 1.4):
		return
	Mission.speed_index = 1
	Mission.set_playing(true)
	_say("4 / 5 · In the helmet", "EV1's visor: suit consumables, the next waypoint, walk-back time, radio link and dose. WASD would take over and walk by hand.")
	if not await _hold(me, 13.0):
		return

	# 5. back out
	shot = "outro"
	Mission.set_playing(false)
	shell._set_mode("orbit")
	if not await _hold(me, 1.2):
		return
	world.home_view()
	_say("5 / 5 · Your turn", "Plan the stops, check the safety layers, then walk it. F1 lists every key; the guided tour is under the gear.")
	if not await _hold(me, 5.0):
		return
	stop(false)


## Ends the demo: by_user = someone took the controls. Playback stops; speed and follow go back.
func stop(by_user := true) -> void:
	if not running:
		return
	running = false
	_chase = false
	shot = ""
	_run_id += 1   # any shot still waiting gives up
	Mission.set_playing(false)
	if world.mode == "orbit":
		Mission.speed_index = int(_saved.get("speed", Mission.speed_index))
	else:
		shell._orbit_speed_index = int(_saved.get("speed", 2))   # what leaving the helmet goes back to
	Mission.playing_changed.emit(Mission.playing)
	shell.follow_crew = bool(_saved.get("follow", false))
	shell.dock.set_follow(shell.follow_crew)
	world.orbit.auto_rotate = bool(_saved.get("auto_rotate", true))
	var tw := _caption.create_tween()
	tw.tween_property(_caption, "modulate:a", 0.0, 0.3)
	tw.tween_callback(func(): _caption.visible = false)
	shell.alerts.toast("Demo stopped — you have the controls." if by_user else "Demo over — the console is yours.", "ok")
	ended.emit(by_user)


func _stop_id_named(name: String) -> String:
	for s in Mission.stops:
		if str(s.get("name", "")) == name:
			return str(s["id"])
	return str(Mission.stops[0]["id"]) if not Mission.stops.is_empty() else ""


func _say(title: String, text: String) -> void:
	_cap_title.text = title.to_upper()
	_cap_text.text = text
	_caption.visible = true
	_caption.reset_size()
	var host: Vector2 = (_caption.get_parent() as Control).size
	_caption.position = Vector2((host.x - _caption.size.x) * 0.5, 92.0)
	UiKit.appear(_caption, 0.0, 0.4)


## Waits `s` seconds of the demo. False if the demo was stopped meanwhile (the caller just returns).
func _hold(me: int, s: float) -> bool:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame
		if me != _run_id or not running:
			return false
	return me == _run_id and running


## The chase camera: behind the crew, looking along their way, a little above.
func _process(delta: float) -> void:
	if not running or not _chase or world.mode != "orbit" or world.orbit.flying():
		return
	var st := Mission.state_at(Mission.eva_t)
	var p: Vector2 = st["xy"]
	var dir: Vector2 = (st.get("xy_ahead", p) as Vector2) - p
	var k := 1.0 - exp(-delta * 1.8)
	if dir.length() > 0.5:
		world.orbit.yaw = lerp_angle(world.orbit.yaw, -atan2(dir.x, dir.y), k)   # yaw -heading = behind them
	world.orbit.dist = lerpf(world.orbit.dist, CHASE_DIST, k)
	world.orbit.pitch = lerp_angle(world.orbit.pitch, deg_to_rad(CHASE_PITCH), k)
	world.orbit.idle_time = 0.0


func _input(event: InputEvent) -> void:
	if not running or Time.get_ticks_msec() < _ignore_until:
		return
	var take := false
	if event is InputEventKey:
		take = event.is_pressed() and not event.is_echo()
	elif event is InputEventMouseButton:
		take = event.is_pressed()
	elif event is InputEventMouseMotion:
		take = (event as InputEventMouseMotion).button_mask != 0   # a drag; just moving the mouse is fine
	elif event is InputEventJoypadButton:
		take = event.is_pressed()
	elif event is InputEventJoypadMotion:
		take = absf((event as InputEventJoypadMotion).axis_value) > 0.5
	if take:
		stop(true)
		if not (event is InputEventMouseMotion or event is InputEventJoypadMotion):
			get_viewport().set_input_as_handled()
