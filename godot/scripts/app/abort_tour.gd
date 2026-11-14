class_name AbortTour
extends RefCounted
## Runtime checks for EVA ABORT, run with
##   godot --path . --resolution 1600x900 -- --capture=<dir> --tour=abort --mute [--site=jezero_threeforks]
## Prints "CHECK An PASS/FAIL  detail" lines and saves screenshots. Time, speed, view and autopilot are put back.

var m   # main.gd


func _init(main_node) -> void:
	m = main_node


func _c(n: int, ok: bool, detail: String) -> void:
	print("CHECK A%d %s  %s" % [n, "PASS" if ok else "FAIL", detail])


func _auto_text() -> String:
	return (m.hud._l["auto"] as Label).text


func run() -> void:
	var boot := 0.0
	while not Mission.has_plan() and boot < 240.0:   # the first plan of a slow site may not have started yet
		await m._wait(0.5)
		boot += 0.5
	await m._await_plan()
	await m._wait(1.0)
	var t0 := Mission.eva_t
	var speed0 := Mission.speed_index
	var tt: Dictionary = Mission.plan["totals"]
	var haven: Vector2 = Mission.haven_xy()
	var wk: Walker = m.world.walker

	# A1: helmet view, autopilot on but paused (as in the user's screenshot): ABORT must start the walk home
	Mission.set_time(float(tt["total_s"]) * 0.3)
	m._set_mode("walk")
	await m._wait(3.0)
	m.hud.visible = true
	if not wk.autopilot:
		m.world.toggle_autopilot()
	Mission.set_playing(false)
	Mission.speed_index = Mission.SPEEDS.find(30.0)
	await m._wait(0.5)
	var start: Vector2 = wk.xy()
	m._start_abort()
	await m._wait(0.3)
	var route: PackedVector2Array = m.world.abort_route
	var door: Vector2 = m.world.haven_door()
	var ends_home := route.size() >= 2 and route[route.size() - 1].distance_to(door) < 1.0 and door.distance_to(haven) > 3.0
	_c(1, m.tel.abort_active and Mission.playing and wk.autopilot and ends_home and m.world.abort_speed >= 0.3 and m.world.abort_speed <= 1.5,
		"abort from a paused autopilot: playing %s, autopilot %s, route %d points %.0f m ending at %s %s, pace %.2f m/s" % [Mission.playing, wk.autopilot,
		route.size(), m.world.abort_length(), Mission.haven_name() + "'s door", ends_home, m.world.abort_speed])

	# A2: the crew actually walks home (EV1 and EV2), and the HUD says so
	var d0 := start.distance_to(haven)
	await m._wait(4.0)
	var d1: float = wk.xy().distance_to(haven)
	var ev2: Vector2 = m.world.buddy_xy()
	var ev2_ok: bool = ev2.is_finite() and ev2.distance_to(wk.xy()) < 15.0 and ev2.distance_to(haven) < d1 + 2.0
	ev2_ok = ev2_ok and m.world.structure_clearance(ev2) > -0.6
	var auto := _auto_text()
	var mode := str(m.tel.d.get("mode", ""))
	var phase := (m.hud._l["phase"] as Label).text
	await m._shot("a02_abort_walking_home.png")
	_c(2, d1 < d0 - 30.0 and ev2_ok and auto.contains("ABORT: walking home") and mode == "ABORT" and phase.contains("ABORT"),
		"4 s at x30: %.0f m -> %.0f m from %s; EV2 %.0f m from EV1, %.0f m from home; mode %s; HUD \"%s\" / \"%s\"" % [d0, d1, Mission.haven_name(),
		ev2.distance_to(wk.xy()) if ev2.is_finite() else -1.0, ev2.distance_to(haven) if ev2.is_finite() else -1.0, mode, auto, phase])

	# A3: take over by hand (the clock stops), step off the route, TAB picks the red route up again
	m.world.toggle_autopilot()
	await m._wait(0.3)
	var manual_ok: bool = not wk.autopilot and not Mission.playing and _auto_text().contains("follow the red chevrons")
	var s_before: float = m.world.abort_s
	wk.x += 12.0   # a few steps to the side, by hand
	await m._wait(0.3)
	m.world.toggle_autopilot()
	await m._wait(0.3)
	var s_after: float = m.world.abort_s
	var rejoin_ok: bool = wk.autopilot and Mission.playing and absf(s_after - s_before) < 40.0
	await m._wait(1.5)
	var d2: float = wk.xy().distance_to(haven)
	_c(3, manual_ok and rejoin_ok and d2 < d1,
		"by hand: clock paused %s, HUD says follow the chevrons %s; TAB: autopilot %s, playing %s, picked the route up at %.0f m (was %.0f m), now %.0f m from home" % [
		not Mission.playing if not wk.autopilot else manual_ok, manual_ok, wk.autopilot, Mission.playing, s_after, s_before, d2])

	# A4: arrival: the walk stops at the haven, the HUD and the caution & warning say so
	Mission.speed_index = Mission.SPEEDS.size() - 1
	var waited := 0.0
	while not m.world.abort_done and waited < 40.0:
		await m._wait(0.5)
		waited += 0.5
	var settle := 0.0   # at high playback speeds the walker trails the route point: let it finish the last metres
	while wk.xy().distance_to(door) > 1.5 and settle < 30.0:
		await m._wait(0.5)
		settle += 0.5
	await m._wait(2.5)   # the caution & warning monitor clears a condition after 2 s
	var home_d: float = wk.xy().distance_to(haven)
	var al: Dictionary = CW.get_alert("abort")
	var cw_cleared: bool = al.is_empty()   # acknowledged on arrival: the banner no longer says "abort under way"
	var sep: Dictionary = CW.get_alert("ev2_sep")
	var ev2_home: float = m.world.buddy_xy().distance_to(wk.xy())
	await m._shot("a04_abort_complete.png")
	var wall: float = wk.xy().distance_to(door)
	var outside: bool = wall < 1.5 and m.world.structure_clearance(wk.xy()) > -0.6   # at the haven's door, not inside a model
	_c(4, m.world.abort_done and not Mission.playing and outside and _auto_text().contains("ABORT COMPLETE") and cw_cleared and sep.is_empty() and ev2_home < 20.0 and ev2_home > 1.0,
		"arrived %s after %.0f s (+%.1f s to step in), playing %s, EV1 %.1f m from the centre of %s, %.1f m from its door (there, not inside: %s), HUD \"%s\", abort condition cleared %s" % [m.world.abort_done, waited, settle, Mission.playing,
		home_d, Mission.haven_name(), wall, outside, _auto_text(), cw_cleared]
		+ "; EV2 %.0f m from EV1, EV2 separation caution %s" % [ev2_home, "none" if sep.is_empty() else str(sep.get("text", "raised"))])

	# A5: cancel: back on the plan
	m._toggle_abort()
	await m._wait(0.5)
	_c(5, not m.tel.abort_active and not m.world.abort_active() and m.world.abort_mi == null and not _auto_text().contains("ABORT"),
		"cancelled: abort %s, route %d points, HUD \"%s\"" % [m.tel.abort_active, m.world.abort_route.size(), _auto_text()])

	# A6: orbit view: the crew figures walk the red route, and FOLLOW CREW follows them
	m._set_mode("orbit")
	await m._wait(2.0)
	Mission.set_time(float(tt["total_s"]) * 0.5)
	Mission.set_playing(false)
	Mission.speed_index = Mission.SPEEDS.find(30.0)
	var was_follow: bool = m.follow_crew
	m.follow_crew = true
	m._start_abort()
	await m._wait(3.0)
	var ev1_fig: Node3D = m.world.crew[0]
	var fig_xy := Vector2(ev1_fig.position.x, -ev1_fig.position.z)
	var on_route: bool = fig_xy.distance_to(m.world.abort_xy(m.world.abort_s)) < 3.0
	var cam_xy := Vector2(m.world.orbit.target.x, -m.world.orbit.target.z)
	var followed: bool = cam_xy.distance_to(fig_xy) < 10.0
	await m._shot("a06_abort_orbit.png")
	_c(6, Mission.playing and m.world.abort_s > 20.0 and on_route and followed and ev1_fig.visible,
		"orbit: playing %s, walked %.0f m of %.0f m, EV1 figure on the red route %s, camera follows %s" % [Mission.playing, m.world.abort_s,
		m.world.abort_length(), on_route, followed])
	# ... and the helmet view puts you where the figures are: on the red route, not where the plan would be by now
	m._set_mode("walk")
	await m._wait(0.6)
	var on_red: float = wk.xy().distance_to(m.world.abort_xy(m.world.abort_s))
	var plan_xy: Vector2 = Mission.state_at(Mission.eva_t)["xy"]
	_c(6, on_red < 6.0 and wk.autopilot and Mission.playing,
		"orbit -> helmet during the abort walk: you start %.1f m from the walk's point on the red route (the plan's point is %.0f m away), autopilot %s, playing %s" % [
		on_red, wk.xy().distance_to(plan_xy), wk.autopilot, Mission.playing])
	m._toggle_abort()
	m.follow_crew = was_follow

	# A7: nobody walks through the habitat: stand behind it (the route leaves the other way) and let the autopilot
	# take you out at the start of the walk: EV1 and EV2 go round the wall, not through the model
	m._set_mode("walk")
	await m._wait(2.0)
	var prof: Dictionary = Mission.plan["profile"]
	var pt: Array = prof["t"]
	var pd: Array = prof["d"]
	var t_go := 0.0
	for i in pd.size():
		if float(pd[i]) > 0.5:
			t_go = float(pt[maxi(i - 1, 0)])
			break
	var hab: Vector2 = Mission.hab_xy()
	var out_dir: Vector2 = (Mission.route_xy(40.0) - hab).normalized()
	Mission.set_playing(false)
	Mission.speed_index = Mission.SPEEDS.find(10.0)
	Mission.set_time(maxf(t_go - 5.0, 0.0))
	wk.autopilot = true
	var behind := hab - out_dir * 14.0
	for i in 40:   # the first free spot behind the habitat (its capsule reaches further on the science module's side)
		if m.world.structure_clearance(behind) > 0.5:
			break
		behind -= out_dir * 0.5
	wk.place(behind, 0.0)
	await m._wait(1.0)
	Mission.set_playing(true)
	var min1 := INF   # the least clearance from any structure: negative is inside one
	var min2 := INF
	var went := 0.0
	var out_ok := false
	while went < 90.0:
		await m._wait(0.05)
		went += 0.05
		min1 = minf(min1, m.world.structure_clearance(wk.xy()))
		var b: Vector2 = m.world.buddy_xy()
		if b.is_finite():
			min2 = minf(min2, m.world.structure_clearance(b))
		var rel: Vector2 = wk.xy() - hab
		if rel.length() > 30.0 and rel.dot(out_dir) > 0.0 and m.world.structure_clearance(wk.xy()) > 3.0:
			out_ok = true
			break
	await m._shot("a07_round_the_habitat.png")
	_c(7, out_ok and min1 >= -0.6 and min2 >= -0.6,
		"started behind the habitat, route leaving the other way: out on the route side %s after %.1f s at x10; least clearance from the habitat, its solar field and the rovers: EV1 %.1f m, EV2 %.1f m (negative = inside one); %d structures" % [
		out_ok, went, min1, min2, m.world.obstacles.size()])
	Mission.set_playing(false)

	# A8: an abort at the very end of the plan, the crew away from home (say they walked off by hand): the clock
	# holds at the end instead of stopping there or jumping back to T+0, and the crew still walks home
	var total := float(tt["total_s"])
	Mission.speed_index = Mission.SPEEDS.find(30.0)
	Mission.set_time(total)
	wk.autopilot = true
	var away: Vector2 = Mission.route_xy(float(pd[pd.size() - 1]) * 0.5)
	wk.place(away, 0.0)
	m._start_abort()
	await m._wait(3.0)
	var held: bool = Mission.eva_t >= total - 1.0
	var d_end: float = wk.xy().distance_to(haven)
	_c(8, held and Mission.playing and d_end < away.distance_to(haven) - 20.0,
		"abort at the plan's end %.0f m from %s: clock at %s (plan ends %s, held %s), playing %s, 3 s at x30 later %.0f m from home" % [
		away.distance_to(haven), Mission.haven_name(), MarsTime.clock(Mission.eva_t), MarsTime.clock(total), held, Mission.playing, d_end])
	m._toggle_abort()
	await m._wait(0.3)
	_c(8, not Mission.hold_at_end and not Mission.playing, "after cancelling: the clock holds %s, playing %s (stopped at the end)" % [Mission.hold_at_end, Mission.playing])
	Mission.set_playing(false)
	Mission.speed_index = speed0
	Mission.set_time(t0)
	CW.reset()
	print("abort tour: done")
