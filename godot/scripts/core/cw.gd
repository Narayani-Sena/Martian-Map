extends Node
## Caution and warning system (autoload "CW"), built to NASA-STD-3001 Vol 2 section 10.3 and Table 10.3-1.
##
## * Four classes, each with a fixed colour, tone and priority [V2 10114, 10175]: emergency (flashing red,
##   priority 1), warning (red, 3), caution (yellow, 4), advisory (blue, 5).
## * Latched: an alert keeps annunciating (tone, banner, master alarm) until the crew acknowledges it, even
##   when its condition clears first; the highest-priority unacknowledged alert is the one annunciated.
## * Silence stops the sound and keeps the alert on screen [V2 10116]; acknowledge ends the annunciation.
##   Shelving suppresses an alert for a while: still listed and logged, no banner or tone [V2 10177].
##   Inhibiting takes an alert out of service [V2 10155]; inhibited alerts are reported every 5 min [V2 10156].
## * The first tone of a new alarm is 10 dB quieter, against startle [V2 10176]; tones per Table 10.3-1 (Sfx).
## * Warnings and emergencies are also spoken ("Warning. Suit pressure low."), cautions too if chosen.
## * Every raise, clear, acknowledgement, silence, shelve and inhibit is logged; test_annunciators() runs
##   each class for the crew's annunciator test [V2 10117].
##
## Monitors call set_condition(id, on) every check; one-off events call raise(id). Thresholds: CwMonitor.

signal changed                        # the active list, a state or the inhibit list changed
signal annunciate(alert: Dictionary)  # a new (or escalated) alert to put in front of the crew
signal logged(entry: Dictionary)
signal audit(titles: Array)           # periodic reminder of inhibited alerts

const PRIORITY := {"emergency": 1, "warning": 3, "caution": 4, "advisory": 5}
const TONE := {"emergency": "cw_emergency", "warning": "cw_warning", "caution": "cw_caution", "advisory": "cw_advisory"}
const GAP_S := {"emergency": 2.0, "warning": 3.0, "caution": 4.0}   # silence between bursts: longer for lower priority
const AUDIT_S := 300.0
const RAISE_HOLD_MS := 600     # a condition must hold this long before it raises (no flicker on noisy values)
const CLEAR_HOLD_MS := 2000    # and be gone this long before it counts as cleared
const ADVISORY_MS := 6000      # advisories end by themselves
const SAY_AGAIN_MS := 30000
const LOG_MAX := 400

## Every alert the console can raise: class, title, the spoken words, what to do, and what is watched.
const CATALOG := {
	"suit_depress": {"level": "emergency", "group": "Suit", "title": "SUIT PRESSURE DROPPING", "say": "suit pressure dropping",
		"do": "Open the purge valve for secondary oxygen, stop work and head for the nearest haven now.",
		"watch": "Suit pressure falling faster than 0.7 kPa a minute, or under 20.7 kPa (3.0 psi)"},
	"suit_p_low": {"level": "warning", "group": "Suit", "title": "SUIT PRESSURE LOW", "say": "suit pressure low",
		"do": "Check the pressure regulator and the purge valve; end the EVA.",
		"watch": "Suit pressure under 27.6 kPa (4.0 psi): caution; under 25.5 kPa (3.7 psi): warning"},
	"ppo2_low": {"level": "warning", "group": "Suit", "title": "OXYGEN PRESSURE LOW", "say": "oxygen pressure low",
		"do": "Open the purge valve; return to the haven.",
		"watch": "ppO2 under 22 kPa: caution; under 18 kPa (hypoxia risk): warning"},
	"ppco2_high": {"level": "caution", "group": "Suit", "title": "CO₂ HIGH IN THE HELMET", "say": "carbon dioxide high",
		"do": "Slow down to breathe out less CO2; if it keeps rising, purge and return.",
		"watch": "Inspired CO2 over 8 mmHg: caution; 15: warning; 20 (NASA contingency limit): emergency"},
	"o2_low": {"level": "caution", "group": "Consumables", "title": "OXYGEN SUPPLY LOW", "say": "oxygen supply low",
		"do": "Turn back: the margin calculation already counts the walk home.",
		"watch": "Primary O2 under 25 %: caution; under 12 %: warning"},
	"batt_low": {"level": "caution", "group": "Consumables", "title": "BATTERY LOW", "say": "battery low",
		"do": "Turn back; switch off the helmet lights you do not need.",
		"watch": "Battery under 25 %: caution; under 12 %: warning"},
	"water_low": {"level": "caution", "group": "Consumables", "title": "FEEDWATER LOW", "say": "cooling water low",
		"do": "Slow down to sweat less and turn back.",
		"watch": "Cooling feedwater under 25 %: caution; under 12 %: warning"},
	"scrubber": {"level": "caution", "group": "Consumables", "title": "CO₂ SCRUBBER NEAR CAPACITY", "say": "scrubber near capacity",
		"do": "Plan the return now; the cartridge is nearly full.",
		"watch": "Scrubber load over 80 %: caution; over 92 %: warning"},
	"hr_high": {"level": "caution", "group": "Crew", "title": "HEART RATE HIGH", "say": "heart rate high",
		"do": "Stop and rest until the heart rate settles.",
		"watch": "Heart rate over 160 bpm: caution; over 180 bpm: warning"},
	"met_high": {"level": "caution", "group": "Crew", "title": "WORK RATE HIGH", "say": "work rate high",
		"do": "Slow the pace: hard work uses oxygen and water faster and raises CO2.",
		"watch": "Metabolic rate over 520 W for a minute"},
	"margin_low": {"level": "caution", "group": "Consumables", "title": "CONSUMABLES MARGIN LOW", "say": "consumables margin low",
		"do": "Finish the current task and turn back.",
		"watch": "Margin above the walk-back reserve under 45 min: caution; under 25 min: warning"},
	"turn_back": {"level": "warning", "group": "Consumables", "title": "TURN BACK NOW", "say": "turn back now",
		"do": "Head for the haven: the walk back now uses the whole reserve.",
		"watch": "Margin above the walk-back reserve at zero"},
	"dose_rate": {"level": "caution", "group": "Environment", "title": "RADIATION DOSE RATE HIGH", "say": "radiation dose rate high",
		"do": "Get under rock cover or into the rover; cut the time in the open.",
		"watch": "Dose rate over 60 µSv/h: caution; over 150 µSv/h: warning"},
	"dose_eva": {"level": "caution", "group": "Environment", "title": "EVA DOSE ABOVE BUDGET", "say": "radiation dose above budget",
		"do": "End the EVA when the current task is done.",
		"watch": "Dose this EVA over 500 µSv (planning budget)"},
	"sunset": {"level": "caution", "group": "Environment", "title": "SUNSET APPROACHING", "say": "sunset approaching",
		"do": "Head back while there is light.",
		"watch": "Sun under 8° and still outside: caution; under 2°: warning"},
	"sep": {"level": "warning", "group": "Environment", "title": "SOLAR PARTICLE EVENT", "say": "solar particle event, take shelter",
		"do": "Stop work and get to the pressurized rover's water-wall shelter now.",
		"watch": "Storm drill, or NASA DONKI reporting particles arriving at Mars"},
	"swx": {"level": "caution", "group": "Environment", "title": "SPACE WEATHER ALERT", "say": "space weather alert",
		"do": "Keep the EVA short and near shelter; watch the dose rate.",
		"watch": "NASA DONKI status RED for Mars"},
	"comms": {"level": "caution", "group": "Comms", "title": "RADIO SHADOW", "say": "loss of signal",
		"do": "Voice and telemetry to the hab are cut; walk back into coverage or place a relay.",
		"watch": "No radio line of sight to the hab mast, a relay or the rover"},
	"link": {"level": "caution", "group": "Comms", "title": "MISSION SERVER LINK LOST", "say": "mission server link lost",
		"do": "Data shown is the last received copy (marked STALE); the suit's own sensors keep working.",
		"watch": "No answer from the mission server for 20 s"},
	"slope": {"level": "caution", "group": "Navigation", "title": "STEEP GROUND AHEAD", "say": "steep ground ahead",
		"do": "Go round: the slope is beyond the suit's safe walking limit.",
		"watch": "Slope ahead over 26° while walking by hand"},
	"hazard": {"level": "warning", "group": "Navigation", "title": "NO-GO TERRAIN", "say": "no go terrain",
		"do": "Step back the way you came; roughness or slope here exceeds the EVA limits.",
		"watch": "Standing on hazard class 4 ground while walking by hand"},
	"off_route": {"level": "caution", "group": "Navigation", "title": "OFF THE PLANNED ROUTE", "say": "off route",
		"do": "The safety numbers assume the planned route; rejoin it (Tab).",
		"watch": "More than 60 m from the planned route while walking by hand"},
	"ev2_sep": {"level": "caution", "group": "Crew", "title": "EV2 SEPARATION", "say": "crew separation",
		"do": "Close up with EV2: crews walk in pairs within sight of each other.",
		"watch": "EV1 and EV2 more than 120 m apart"},
	"plan_nogo": {"level": "caution", "group": "Mission", "title": "EVA PLAN NO-GO", "say": "plan no go",
		"do": "See the plan panel's checks; shorten the EVA, move a stop or start earlier.",
		"watch": "The latest plan fails a GO/NO-GO check"},
	"abort": {"level": "warning", "group": "Mission", "title": "EVA ABORT", "say": "abort, return to the haven",
		"do": "Follow the red chevrons back to the haven. CANCEL ABORT (hold End again) resumes the plan.",
		"watch": "Crew-initiated abort (hold End or R3, or the ABORT button)"},
	"on_station": {"level": "advisory", "group": "Mission", "title": "ON STATION", "say": "on station",
		"do": "Work site reached: the tasks are on the cuff checklist.", "watch": "Arriving at a science stop"},
	"mode": {"level": "advisory", "group": "Mission", "title": "MODE CHANGE", "say": "mode change",
		"do": "", "watch": "Autopilot, manual walking, riding in the rover or the demo taking or giving back control"},
	"stale": {"level": "advisory", "group": "Comms", "title": "DATA STALE", "say": "data stale",
		"do": "The panel shows its last copy; it refreshes when the link is back.", "watch": "A data feed older than its refresh time"},
	"test_advisory": {"level": "advisory", "group": "Test", "title": "TEST · ADVISORY", "say": "test, advisory", "do": "", "watch": "Annunciator test"},
	"test_caution": {"level": "caution", "group": "Test", "title": "TEST · CAUTION", "say": "test, caution", "do": "", "watch": "Annunciator test"},
	"test_warning": {"level": "warning", "group": "Test", "title": "TEST · WARNING", "say": "test, warning", "do": "", "watch": "Annunciator test"},
	"test_emergency": {"level": "emergency", "group": "Test", "title": "TEST · EMERGENCY", "say": "test, emergency", "do": "", "watch": "Annunciator test"},
}

var _active := {}        # id -> alert dictionary (see _make)
var _on_since := {}      # id -> msec the condition was first seen (debounce)
var _off_since := {}
var _shelved := {}       # id -> msec until which it is suppressed
var log_entries: Array = []
var testing := false
var _sounding := ""      # id whose tone sequence is playing
var _burst := 0
var _next_burst := 0
var _say_at := -1
var _say_id := ""
var _audit_at := 0
var _voice := ""
var speech_ok := false


func _ready() -> void:
	_audit_at = Time.get_ticks_msec() + 15000   # remind about inhibited alerts shortly after start-up
	if DisplayServer.has_feature(DisplayServer.FEATURE_TEXT_TO_SPEECH):
		var vs := DisplayServer.tts_get_voices_for_language("en")
		if not vs.is_empty():
			_voice = vs[0]
			speech_ok = true


# ------------------------------------------------------------------ queries
func is_inhibited(id: String) -> bool:
	return (Settings.get_value("cw_inhibited") as Array).has(id)


func inhibited() -> Array:
	return (Settings.get_value("cw_inhibited") as Array).duplicate()


func is_shelved(id: String) -> bool:
	return _shelved.has(id) and Time.get_ticks_msec() < int(_shelved[id])


## Active alerts, most important first: unacknowledged before acknowledged, then by priority, newest first.
func active() -> Array:
	var out := _active.values()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a["acked"]) != bool(b["acked"]):
			return not bool(a["acked"])
		var pa := int(PRIORITY[a["level"]])
		var pb := int(PRIORITY[b["level"]])
		if pa != pb:
			return pa < pb
		return int(a["raised_ms"]) > int(b["raised_ms"]))
	return out


func get_alert(id: String) -> Dictionary:
	return _active.get(id, {})


## The alert to put in front of the crew: the highest-priority one not yet acknowledged ({} = none).
func top() -> Dictionary:
	for a in active():
		if not bool(a["acked"]) and not bool(a["shelved"]):
			return a
	return {}


## Master alarm: {"level": highest unacknowledged class or "", "n": unacknowledged count, "total": active count}.
func master() -> Dictionary:
	var lv := ""
	var n := 0
	for a in _active.values():
		if bool(a["acked"]) or bool(a["shelved"]):
			continue
		n += 1
		if lv == "" or int(PRIORITY[a["level"]]) < int(PRIORITY[lv]):
			lv = str(a["level"])
	return {"level": lv, "n": n, "total": _active.size()}


# ------------------------------------------------------------------ raising and clearing
## A monitored condition: call it on every check. It raises after RAISE_HOLD_MS of `on`, clears after
## CLEAR_HOLD_MS of off. `level` overrides the catalogue class (multi-level alerts like ppCO2); a rise in
## class re-annunciates, even if the lower one was acknowledged.
func set_condition(id: String, on: bool, text := "", level := "") -> void:
	if not CATALOG.has(id) or is_inhibited(id):
		return
	var now := Time.get_ticks_msec()
	var a: Dictionary = _active.get(id, {})
	var lv := level if level != "" else str(CATALOG[id]["level"])
	if on:
		_off_since.erase(id)
		if a.is_empty():
			if not _on_since.has(id):
				_on_since[id] = now
			if now - int(_on_since[id]) >= RAISE_HOLD_MS:
				_on_since.erase(id)
				_raise(id, text, lv)
			return
		if bool(a["cleared"]):   # back before anyone acknowledged it: active again
			a["cleared"] = false
			_log("RETURNED", a)
		if int(PRIORITY[lv]) < int(PRIORITY[a["level"]]):
			a["level"] = lv
			a["acked"] = false
			a["silenced"] = false
			a["raised_ms"] = now
			if text != "":
				a["text"] = text
			_log("ESCALATED", a)
			annunciate.emit(a)
			changed.emit()
		elif text != "" and text != str(a["text"]):
			a["text"] = text
	else:
		_on_since.erase(id)
		if a.is_empty() or bool(a["cleared"]):
			return
		if not _off_since.has(id):
			_off_since[id] = now
		if now - int(_off_since[id]) >= CLEAR_HOLD_MS:
			_off_since.erase(id)
			_clear(id)


## A one-off event (advisories, tests). Advisories end by themselves after a few seconds.
func raise(id: String, text := "", level := "") -> void:
	if not CATALOG.has(id) or is_inhibited(id):
		return
	var lv := level if level != "" else str(CATALOG[id]["level"])
	_active.erase(id)
	_raise(id, text, lv)
	if lv != "advisory":
		(_active[id] as Dictionary)["cleared"] = true   # an event: nothing to clear later, only to acknowledge
		(_active[id] as Dictionary)["event"] = true


func _raise(id: String, text: String, lv: String) -> void:
	var c: Dictionary = CATALOG[id]
	var a := {"id": id, "level": lv, "title": str(c["title"]), "text": text if text != "" else str(c["do"]), "do": str(c["do"]),
		"say": str(c["say"]), "group": str(c["group"]), "raised_ms": Time.get_ticks_msec(),
		"eva": MarsTime.clock(Mission.eva_t) if Mission.has_plan() else "—",
		"cleared": false, "acked": false, "silenced": false, "shelved": is_shelved(id)}
	_active[id] = a
	_log("RAISED" + (" (shelved)" if bool(a["shelved"]) else ""), a)
	if lv == "advisory":
		if bool(Settings.get_value("advisory_tones")) and not bool(a["shelved"]):
			Sfx.play_alert(TONE["advisory"], -6.0)
		if str(Settings.get_value("speech")) == "all":
			_speak(a)
	if not bool(a["shelved"]):
		annunciate.emit(a)
	changed.emit()


func _clear(id: String) -> void:
	var a: Dictionary = _active.get(id, {})
	if a.is_empty():
		return
	if bool(a["acked"]) or str(a["level"]) == "advisory":
		_active.erase(id)
		_log("CLEARED", a)
	else:
		a["cleared"] = true   # latched: stays until acknowledged
		if str(a["level"]) == "caution":
			a["silenced"] = true   # a cleared caution goes quiet; warnings keep calling until acknowledged
		_log("CLEARED (awaiting ACK)", a)
	changed.emit()


# ------------------------------------------------------------------ crew actions
## Acknowledge one alert, or the top one. Returns false if there was nothing to acknowledge.
func acknowledge(id := "") -> bool:
	var a: Dictionary = _active.get(id, {}) if id != "" else top()
	if a.is_empty() or bool(a["acked"]):
		return false
	a["acked"] = true
	a["silenced"] = true
	_log("ACK", a)
	if bool(a["cleared"]):
		_active.erase(str(a["id"]))
	changed.emit()
	return true


func acknowledge_all() -> int:
	var n := 0
	for a in active():
		if not bool(a["acked"]) and acknowledge(str(a["id"])):
			n += 1
	return n


## Stop the sound of everything annunciating now; the alerts stay on screen until acknowledged.
func silence() -> int:
	var n := 0
	for a in _active.values():
		if not bool(a["acked"]) and not bool(a["silenced"]):
			a["silenced"] = true
			n += 1
	if n > 0:
		_log("SILENCED %d" % n, {"id": "", "level": "", "title": "", "text": ""})
		Sfx.stop_alert()
		_sounding = ""
		changed.emit()
	return n


## Suppress an alert for `minutes`: listed and logged, but no banner or tone until the time is up.
func shelve(id: String, minutes := 10.0) -> void:
	_shelved[id] = Time.get_ticks_msec() + int(minutes * 60000.0)
	var a: Dictionary = _active.get(id, {"id": id, "level": str(CATALOG.get(id, {}).get("level", "")), "title": str(CATALOG.get(id, {}).get("title", id)), "text": ""})
	if _active.has(id):
		a["shelved"] = true
		a["silenced"] = true
	_log("SHELVED %d min" % int(minutes), a)
	changed.emit()


func unshelve(id: String) -> void:
	if _shelved.erase(id):
		var a: Dictionary = _active.get(id, {})
		if not a.is_empty():
			a["shelved"] = false
		_log("UNSHELVED", {"id": id, "level": str(CATALOG.get(id, {}).get("level", "")), "title": str(CATALOG.get(id, {}).get("title", id)), "text": ""})
		changed.emit()


## Out of service (not monitored, not logged) until enabled again; reported every 5 minutes meanwhile.
func set_inhibited(id: String, on: bool) -> void:
	var list := inhibited()
	if on and not list.has(id):
		list.append(id)
	elif not on:
		list.erase(id)
	Settings.set_value("cw_inhibited", list)
	var info := {"id": id, "level": str(CATALOG.get(id, {}).get("level", "")), "title": str(CATALOG.get(id, {}).get("title", id)), "text": ""}
	if on:
		_active.erase(id)
		_on_since.erase(id)
	_log("INHIBITED" if on else "ENABLED", info)
	changed.emit()


## The crew's annunciator test: each class's banner, colour, tone and voice in turn [V2 10117].
func test_annunciators() -> void:
	if testing:
		return
	testing = true
	_log("TEST STARTED", {"id": "test", "level": "", "title": "ANNUNCIATOR TEST", "text": ""})
	for lv in ["advisory", "caution", "warning", "emergency"]:
		var id: String = "test_" + lv
		raise(id, "Annunciator test: the %s banner, colour, tone%s." % [lv, " and voice" if speech_ok else ""], lv)
		await get_tree().create_timer(3.4).timeout
		acknowledge(id)
		_active.erase(id)
		changed.emit()
	_log("TEST COMPLETE", {"id": "test", "level": "", "title": "ANNUNCIATOR TEST", "text": ""})
	testing = false


## Clear the active list (site switch: the conditions are checked again from scratch). Keeps the log.
func reset() -> void:
	_active.clear()
	_on_since.clear()
	_off_since.clear()
	Sfx.stop_alert()
	_sounding = ""
	changed.emit()


# ------------------------------------------------------------------ annunciation
func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	for id in _shelved.keys():
		if now >= int(_shelved[id]):
			unshelve(str(id))
	for id in _active.keys():
		var a: Dictionary = _active[id]
		if str(a["level"]) == "advisory" and now - int(a["raised_ms"]) > ADVISORY_MS:
			_active.erase(id)
			changed.emit()
	if now >= _audit_at:
		_audit_at = now + int(AUDIT_S * 1000.0)
		var inh := inhibited()
		if not inh.is_empty():
			var titles := []
			for id in inh:
				titles.append(str(CATALOG.get(id, {}).get("title", id)))
			_log("AUDIT: %d inhibited" % inh.size(), {"id": "", "level": "advisory", "title": ", ".join(PackedStringArray(titles)), "text": ""})
			audit.emit(titles)
	_annunciate_audio(now)


## The tone of the most important unacknowledged, unsilenced alert, repeated with a silence between bursts.
func _annunciate_audio(now: int) -> void:
	var target := {}
	for a in active():
		var lv := str(a["level"])
		if lv == "advisory" or bool(a["acked"]) or bool(a["silenced"]) or bool(a["shelved"]):
			continue
		target = a
		break
	if target.is_empty():
		if _sounding != "":
			Sfx.stop_alert()
			_sounding = ""
		return
	var id := str(target["id"])
	var lv2 := str(target["level"])
	var tone: String = TONE[lv2]
	var length := float(Sfx.ALERT_LEN.get(tone, 1.0))
	if id != _sounding:
		_sounding = id
		_burst = 0
		_next_burst = now
	if now >= _next_burst:
		Sfx.play_alert(tone, -10.0 if _burst == 0 else 0.0)   # pre-alert: the first burst 10 dB down [V2 10176]
		if _burst == 0:
			_say_id = id
			_say_at = now + int(length * 1000.0)   # the words follow the tone, as in NASA's alert waveform
		_burst += 1
		_next_burst = now + int((length + float(GAP_S.get(lv2, 3.0))) * 1000.0)
	if _say_at >= 0 and now >= _say_at and _say_id == id:
		_say_at = now + SAY_AGAIN_MS
		_speak(target)


func _speak(a: Dictionary) -> void:
	var mode := str(Settings.get_value("speech"))
	var lv := str(a["level"])
	if not speech_ok or mode == "off" or Sfx.cli_mute:
		return
	if mode == "warnings" and not (lv == "warning" or lv == "emergency"):
		return
	var words := "%s. %s." % [lv.capitalize(), str(a["say"])]
	DisplayServer.tts_speak(words, _voice, int(clampf(float(Settings.get_value("vol_alerts")), 0.3, 1.0) * 100.0), 1.0, 1.05, 0, true)


## Say something on the alert voice (status reports, voice-command answers).
func say(text: String) -> void:
	if speech_ok and str(Settings.get_value("speech")) != "off" and not Sfx.cli_mute:
		DisplayServer.tts_speak(text, _voice, int(clampf(float(Settings.get_value("vol_alerts")), 0.3, 1.0) * 100.0), 1.0, 1.05, 0, true)


# ------------------------------------------------------------------ log
func _log(what: String, a: Dictionary) -> void:
	var e := {"ms": Time.get_ticks_msec(), "clock": Time.get_time_string_from_system(), "eva": MarsTime.clock(Mission.eva_t) if Mission.has_plan() else "—",
		"what": what, "id": str(a.get("id", "")), "level": str(a.get("level", "")), "title": str(a.get("title", "")), "text": str(a.get("text", ""))}
	log_entries.append(e)
	while log_entries.size() > LOG_MAX:
		log_entries.pop_front()
	logged.emit(e)


## The log as CSV in user:// (returns the absolute path, "" on failure).
func export_log() -> String:
	var name := "alert_log_%s.csv" % Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "_")
	var path := "user://" + name
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_line("time,eva_clock,event,level,id,title,text")
	for e in log_entries:
		var cells := []
		for k in ["clock", "eva", "what", "level", "id", "title", "text"]:
			cells.append("\"%s\"" % str(e[k]).replace("\"", "'"))
		f.store_line(",".join(PackedStringArray(cells)))
	f.close()
	return ProjectSettings.globalize_path(path)
