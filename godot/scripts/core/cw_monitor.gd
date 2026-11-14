class_name CwMonitor
extends RefCounted
## Turns telemetry into caution and warning conditions (NASA-STD-3001 Vol 2 [V2 10115] parameter
## notifications, [V2 11036] suit atmosphere alarms, [V2 11010] radiation alarms). Every limit is here, and
## the catalogue in cw.gd says the same in words. Suit and walking checks run only while the EVA is live
## (walking in the helmet or playing); mission-wide ones (storm, server link, NO-GO, abort) always.

var _last_phase := ""
var _last_target := ""
var _last_mode := ""
var _primed := false
var _stale_said := {}


func check(tel: Dictionary) -> void:
	if tel.is_empty():
		return
	_mission(tel)
	if bool(tel["live"]) and bool(tel["suited"]) and not bool(tel["cabin"]):
		_suit(tel)
		_where(tel)
	_events(tel)


## Storm, space weather, server link, plan, abort, stale feeds: checked whatever the view.
func _mission(tel: Dictionary) -> void:
	CW.set_condition("sep", Mission.sep_active, "Proton flux rising%s. Stop work and get to the pressurized rover's water-wall shelter now." % (" (drill)" if Mission.sep_active else ""))
	CW.set_condition("swx", str(Mission.space_weather.get("status", "")) == "RED",
		"NASA DONKI: %s" % "; ".join(PackedStringArray(Mission.space_weather.get("reasons", []))))
	CW.set_condition("link", float(tel["link_down_s"]) > 20.0,
		"No answer from the mission server for %s. Panels show their last copy, marked STALE." % UiKit.fmt_age(float(tel["link_down_s"])))
	var nogo := Mission.has_plan() and not bool(Mission.plan["totals"].get("go", true))
	var why := ""
	if nogo:
		var issues: Array = Mission.plan.get("issues", [])
		why = str(issues[0]["text"]) if not issues.is_empty() else ""
	CW.set_condition("plan_nogo", nogo, why)
	CW.set_condition("abort", bool(tel["abort"]) and not bool(tel.get("abort_done", false)), "Abort under way: follow the red chevrons to %s." % Mission.haven_name())
	for feed in [["conditions", "Sun, weather and radiation", 1800.0], ["space_weather", "Space weather (DONKI)", 6.0 * 3600.0]]:
		var age := float(tel.get("age_" + str(feed[0]), INF))
		var stale := is_finite(age) and age > float(feed[2])
		if stale and not _stale_said.get(feed[0], false):
			CW.raise("stale", "%s data is %s old." % [str(feed[1]), UiKit.fmt_age(age)])
		_stale_said[feed[0]] = stale


func _suit(tel: Dictionary) -> void:
	var p := float(tel["p_suit"])
	var drop := float(tel["p_drop_rate"])
	CW.set_condition("suit_depress", drop > SuitModel.P_DROP_RATE or p < SuitModel.P_EMERGENCY,
		"Suit pressure %s and falling %.1f kPa a minute." % [SuitModel.fmt_pressure(p, Settings.pressure_unit), drop])
	CW.set_condition("suit_p_low", p < SuitModel.P_CAUTION, "Suit pressure %s." % SuitModel.fmt_pressure(p, Settings.pressure_unit),
		"warning" if p < SuitModel.P_WARNING else "caution")
	var ppo2 := float(tel["ppo2"])
	CW.set_condition("ppo2_low", ppo2 < SuitModel.PPO2_CAUTION, "ppO2 %s." % SuitModel.fmt_pressure(ppo2, Settings.pressure_unit),
		"warning" if ppo2 < SuitModel.PPO2_WARNING else "caution")
	var pc := float(tel["ppco2"])
	var lv := "caution"
	if pc >= SuitModel.PPCO2_LIMIT:
		lv = "emergency"
	elif pc >= SuitModel.PPCO2_WARNING:
		lv = "warning"
	CW.set_condition("ppco2_high", pc >= SuitModel.PPCO2_CAUTION, "Inspired CO2 %.1f mmHg (NASA contingency limit %d)." % [pc, int(SuitModel.PPCO2_LIMIT)], lv)
	_level("o2_low", float(tel["o2_pct"]), 25.0, 12.0, "Primary oxygen %d %%.")
	_level("batt_low", float(tel["battery_pct"]), 25.0, 12.0, "Battery %d %%.")
	_level("water_low", float(tel["water_pct"]), 25.0, 12.0, "Cooling feedwater %d %%.")
	var load := float(tel["scrubber_pct"])
	CW.set_condition("scrubber", load > 80.0, "Scrubber %d %% full." % int(load), "warning" if load > 92.0 else "caution")
	var hr := float(tel["hr"])
	CW.set_condition("hr_high", hr > 160.0, "Heart rate %d bpm." % int(hr), "warning" if hr > 180.0 else "caution")
	CW.set_condition("met_high", float(tel["met_high_s"]) > 60.0, "Working at %d W for over a minute." % int(float(tel["met_w"])))
	var m := float(tel["margin_min"])
	if is_finite(m):
		CW.set_condition("turn_back", m <= 0.0, "No margin left above the walk-back reserve: head for %s now." % Mission.haven_name())
		CW.set_condition("margin_low", m > 0.0 and m < 45.0, "%d min above the walk-back reserve. Turn back by %s LTST." % [int(m), str(tel["turn_by"])],
			"warning" if m < 25.0 else "caution")
	var rate := float(tel["dose_rate"])
	CW.set_condition("dose_rate", rate > 60.0, "%.0f µSv/h here." % rate, "warning" if rate > 150.0 else "caution")
	var dose := float(tel["dose_usv"])
	CW.set_condition("dose_eva", is_finite(dose) and dose > 500.0, "%.0f µSv so far this EVA." % dose)
	var sun := float(tel["sun_elev"])
	CW.set_condition("sunset", sun < 8.0, "Sun %.0f° above the horizon." % sun, "warning" if sun < 2.0 else "caution")


## Low-is-bad levels: caution under `caution` %, warning under `warning` %.
func _level(id: String, v: float, caution: float, warning: float, fmt: String) -> void:
	if not is_finite(v):
		return
	CW.set_condition(id, v < caution, fmt % int(v), "warning" if v < warning else "caution")


## Radio, ground and route: the walking ones only count when you walk by hand (the autopilot keeps to the plan).
func _where(tel: Dictionary) -> void:
	CW.set_condition("comms", int(tel["comms"]) == 0, "No line of sight to the hab mast here (loss of signal %s). Walk back into coverage." % UiKit.fmt_age(float(tel["los_s"])))
	var manual := bool(tel["manual"])
	CW.set_condition("slope", manual and absf(float(tel["slope"])) > 26.0, "%.0f° slope in front of you." % absf(float(tel["slope"])))
	CW.set_condition("hazard", manual and int(tel["hazard"]) >= 4, "Roughness or slope here exceeds the EVA limits.")
	CW.set_condition("off_route", manual and float(tel["off_route"]) > 60.0, "%d m from the planned route." % int(float(tel["off_route"])))
	CW.set_condition("ev2_sep", bool(tel["walk"]) and float(tel["ev2_sep"]) > 120.0, "EV2 is %d m away." % int(float(tel["ev2_sep"])))


## Advisories for events: arriving on station, and every change of who is in control.
func _events(tel: Dictionary) -> void:
	var phase := str(tel["phase"])
	var ev: Dictionary = tel["event"] if tel["event"] is Dictionary else {}
	var name := str(ev.get("name", ""))
	if bool(tel["live"]) and phase == "stop" and not bool(tel["abort"]) and (phase != _last_phase or name != _last_target):
		var tasks: Array = ev.get("tasks", [])
		CW.raise("on_station", "%s: %d task%s on the cuff checklist." % [name, tasks.size(), "" if tasks.size() == 1 else "s"])
	_last_phase = phase
	_last_target = name
	var mode := str(tel["mode"])
	if mode != _last_mode:
		if _primed and mode != "":
			var words := {"AUTOPILOT": "AUTOPILOT: following the plan", "ABORT": "AUTOPILOT: walking the abort route to %s" % Mission.haven_name(),
				"MANUAL": "MANUAL: walking by hand, the EVA clock is paused",
				"RIDING": "RIDING in %s: suits on the suitports" % Mission.haven_name(), "DEMO": "DEMO: the console is flying itself; any input takes over"}
			CW.raise("mode", str(words.get(mode, mode)))
		elif _primed and _last_mode == "DEMO":
			CW.raise("mode", "You have control (demo ended).")
		_last_mode = mode
	_primed = true
