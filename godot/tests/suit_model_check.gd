extends SceneTree
## Prints SuitModel results as JSON so tests/test_godot_suit.py can compare them with server/eva.py.
##   godot --headless --path godot --script res://tests/suit_model_check.gd


func _init() -> void:
	var out := []
	for met in [0.0, 150.0, 300.0, 520.0]:
		for load in [0.0, 50.0, 70.0, 85.0, 100.0]:
			var pc := SuitModel.ppco2_mmhg(met, load)
			out.append({"met": met, "load": load, "ppco2": pc, "ppo2": SuitModel.ppo2_kpa(SuitModel.SUIT_P_KPA, pc)})
	var consts := {"p": SuitModel.SUIT_P_KPA, "caution": SuitModel.PPCO2_CAUTION, "warning": SuitModel.PPCO2_WARNING, "limit": SuitModel.PPCO2_LIMIT,
		"leak_60s": SuitModel.pressure_kpa("leak", 60.0, 0.0), "co2_10s": SuitModel.scrubber_load(20.0, "co2", 10.0)}
	print("JSON:" + JSON.stringify({"rows": out, "consts": consts}))
	quit()
