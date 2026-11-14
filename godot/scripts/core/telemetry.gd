class_name Telemetry
extends RefCounted
## EV1's state as the suit and the console know it, in both views: in the helmet from the walker, in orbit
## view from the plan at the EVA clock. The helmet HUD shows it, CwMonitor raises alarms from it, and the
## voice "status" report reads it. Updated ~8 times a second by main.gd.
##
## Data freshness (NASA-STD-3001 [V2 10020]): the radio-shadow timer (loss of signal), the server link and
## the age of each downloaded feed are tracked, so the interface can mark stale or missing data.

var world: MarsWorld
var route := PackedVector2Array()   # the planned walking route (site metres), for the off-route distance
var demo := false                   # the director is flying the camera
var abort_active := false
var abort_target := Vector2.ZERO
var d := {}                         # the latest state (see update)
var hr := 78.0
var _press: Array = []              # [msec, kPa] over the last 10 s, for the rate of change
var _los_since := -1
var _link_down_since := -1
var _met_high_since := -1


func update() -> Dictionary:
	if world == null or not world.ready_terrain:
		return d
	var now := Time.get_ticks_msec()
	var walk := world.mode == "walk"
	var has := Mission.has_plan()
	var t := Mission.eva_t
	var st := Mission.state_at(t)
	var wk := world.walker
	var td := world.td
	var cabin := has and Mission.in_cabin(t)
	var abort_walk := abort_active and world.abort_active()
	var xy: Vector2 = wk.xy() if walk else (world.abort_xy(world.abort_s) if abort_walk else (st["xy"] as Vector2))
	var manual := walk and not wk.autopilot and not wk.riding
	var live := walk or (has and Mission.playing)
	var out := {"t": t, "walk": walk, "has": has, "live": live, "manual": manual, "cabin": cabin or (walk and wk.riding),
		"xy": xy, "suited": has and not cabin}
	# ---- crew mode (annunciated on every change)
	var mode := ""
	if demo:
		mode = "DEMO"
	elif walk and wk.riding:
		mode = "RIDING"
	elif walk:
		mode = ("ABORT" if abort_walk else "AUTOPILOT") if wk.autopilot else "MANUAL"
	out["mode"] = mode
	# ---- suit
	var met := float(st.get("met_w", 200.0)) if has else 200.0
	if manual:
		met = lerpf(140.0, 420.0, clampf(wk.speed_now / 2.5, 0.0, 1.0)) + maxf(0.0, wk.slope_ahead) * 6.0
	if out["cabin"]:
		met = 120.0
	out["met_w"] = met
	var wobble := 1.2 * sin(now / 1700.0) + 0.6 * sin(now / 530.0)
	hr = lerpf(hr, 58.0 + met / 6.0 + wobble, 0.2)
	out["hr"] = hr
	var fault := Mission.suit_fault
	var fault_s := (now - Mission.suit_fault_ms) / 1000.0 if fault != "" else 0.0
	out["fault"] = fault
	for k in ["o2_pct", "battery_pct", "co2_pct", "water_pct", "dose_usv", "margin_min", "sun_elev"]:
		out[k] = float(st.get(k, NAN)) if has else NAN
	var load := SuitModel.scrubber_load(float(out["co2_pct"]) if has else 0.0, fault, fault_s)
	out["scrubber_pct"] = load
	var p := SuitModel.pressure_kpa(fault, fault_s, now / 1000.0)
	out["p_suit"] = p
	_press.append([now, p])
	while _press.size() > 2 and now - int(_press[0][0]) > 10000:
		_press.pop_front()
	var dt_min := (now - int(_press[0][0])) / 60000.0
	out["p_drop_rate"] = (float(_press[0][1]) - p) / dt_min if dt_min > 0.03 else 0.0   # kPa a minute, + = falling
	var ppco2 := SuitModel.ppco2_mmhg(met, load)
	out["ppco2"] = ppco2
	out["ppo2"] = SuitModel.ppo2_kpa(p, ppco2)
	out["suit_c"] = 21.4 + met / 400.0
	if met > 520.0:
		if _met_high_since < 0:
			_met_high_since = now
	else:
		_met_high_since = -1
	out["met_high_s"] = (now - _met_high_since) / 1000.0 if _met_high_since >= 0 else 0.0
	# ---- where you are
	var wb := td.layer_value("walkback", xy.x, xy.y, -2.0) if walk else (float(st.get("walkback_min", -1.0)) * 60.0 if has else -2.0)
	out["walkback_s"] = wb
	out["slope"] = wk.slope_ahead if walk else float(st.get("slope", 0.0))
	out["hazard"] = int(td.layer_value("hazard", xy.x, xy.y, 0.0)) if walk else int(st.get("hazard", 0))
	var comms := int(td.layer_value("comms", xy.x, xy.y, 2.0)) if walk else int(st.get("comms", 2))
	if out["cabin"]:
		comms = 2   # the rover's own radio
	out["comms"] = comms
	if comms == 0 and live:
		if _los_since < 0:
			_los_since = now
	else:
		_los_since = -1
	out["los_s"] = (now - _los_since) / 1000.0 if _los_since >= 0 else 0.0
	var shield := td.layer_value("shield", xy.x, xy.y, 0.0) if walk else float(st.get("shield", 0.0))
	var base := float(Mission.conditions.get("radiation", {}).get("gcr_usv_h", 22.7))
	var rate := base * (1.0 - shield)
	if Mission.sep_active:
		rate += 600.0 * (1.0 - minf(0.95, shield * 2.5))
	if out["cabin"]:
		rate *= 0.7
	out["dose_rate"] = rate
	out["sun_elev"] = world.sun_elev
	var tt: Dictionary = Mission.plan.get("totals", {}) if has else {}
	var sunset_t: Variant = tt.get("sunset_t")
	out["sunset_in_s"] = (float(sunset_t) - t) if sunset_t != null else INF
	# ---- turn-back time: when the margin above the walk-back reserve runs out
	var margin := float(out["margin_min"])
	out["turn_in_min"] = margin if has else NAN
	if has and is_finite(margin):
		var unix := Mission.unix_at(t) + maxf(margin, 0.0) * 60.0
		out["turn_by"] = MarsTime.hms(MarsTime.ltst(MarsTime.at(unix), Mission.site_lon()), false)
	else:
		out["turn_by"] = ""
	# ---- buddy and route
	out["ev2_sep"] = world.buddy_xy().distance_to(xy) if walk and world.buddy_xy().is_finite() else 0.0
	if manual and abort_walk:   # walking home by hand: how far from the red route, not from the plan
		out["off_route"] = world.abort_xy(world.abort_nearest_s(xy)).distance_to(xy)
	else:
		out["off_route"] = _route_distance(xy) if manual else 0.0
	# ---- abort guidance
	out["abort"] = abort_active
	out["abort_done"] = abort_walk and world.abort_done
	# ---- links and data age
	if Api.online:
		_link_down_since = -1
	elif _link_down_since < 0:
		_link_down_since = now
	out["link_down_s"] = (now - _link_down_since) / 1000.0 if _link_down_since >= 0 else 0.0
	out["age_conditions"] = Mission.age_s("conditions")
	out["age_space_weather"] = Mission.age_s("space_weather")
	out["phase"] = str(st.get("phase", "")) if has else ""
	out["event"] = st.get("event", {})
	if abort_walk:   # the plan's stations no longer apply: the crew is walking home
		out["phase"] = "stop" if world.abort_done else "walk"
		out["event"] = {"kind": "walk", "name": ("Abort complete at %s" if world.abort_done else "Abort → %s") % Mission.haven_name(), "tasks": []}
	d = out
	return out


## Shortest distance (m) from p to the planned route polyline (every other profile point).
func _route_distance(p: Vector2) -> float:
	var best := INF
	for i in range(1, route.size()):
		var a := route[i - 1]
		var b := route[i]
		var ab := b - a
		var l2 := ab.length_squared()
		var f := 0.0 if l2 < 1e-6 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * f))
	return best if best < INF else 0.0


## A spoken status report (voice "status"): the numbers a crewmember would ask the IV for.
func status_report() -> String:
	if d.is_empty() or not bool(d["has"]):
		return "No plan yet."
	var parts := []
	parts.append("Suit %s, ppCO2 %.0f millimetres" % [SuitModel.fmt_pressure(float(d["p_suit"]), Settings.pressure_unit).replace("kPa", "kilopascal").replace("psi", "P S I"), float(d["ppco2"])])
	parts.append("oxygen %d percent, battery %d percent" % [int(float(d["o2_pct"])), int(float(d["battery_pct"]))])
	if is_finite(float(d["turn_in_min"])):
		parts.append("turn back in %d minutes" % int(maxf(0.0, float(d["turn_in_min"]))))
	if float(d["walkback_s"]) >= 0.0:
		parts.append("walk back %d minutes" % int(float(d["walkback_s"]) / 60.0))
	return ". ".join(PackedStringArray(parts)) + "."
