extends SceneTree
## Prints MarsTime results as JSON so tests/test_godot_mars24.py can compare them with Python.
##   godot --headless --path godot --script res://tests/mars_time_check.gd


func _init() -> void:
	var out := []
	for unix in [946771200.0, 1600000000.0, 1762873200.0, 1800000000.0]:
		var mt := MarsTime.at(unix)
		var sp := MarsTime.sun_position(mt, -4.815, 137.385)
		var rs := MarsTime.sunrise_sunset(mt, -4.815)
		out.append({"unix": unix, "ls": mt["ls"], "msd": mt["msd"], "mtc": mt["mtc"], "eot": mt["eot"], "decl": mt["decl"],
			"ltst": MarsTime.ltst(mt, 137.385), "lmst": MarsTime.lmst(mt, 137.385), "elev": sp.x, "az": sp.y,
			"sunrise": rs.x, "sunset": rs.y, "iso": MarsTime.parse_iso("2026-11-12T10:00:07.250+00:00")})
	print("JSON:" + JSON.stringify(out))
	quit()
