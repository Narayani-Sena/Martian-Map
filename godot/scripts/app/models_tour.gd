class_name ModelsTour
extends RefCounted
## Close-ups of the procedural models for checking them by eye (the habitat, the suit), run with
##   godot --path . --resolution 1600x900 -- --capture=<dir> --tour=models --mute [--site=jezero_threeforks]
## Saves m01-m08 screenshots; the view, time and interface are put back.

var m   # main.gd


func _init(main_node) -> void:
	m = main_node


## Orbit yaw that puts the camera on the side of `target` that `from` lies on (site x/y; see OrbitRig.transform).
func _yaw_from(from: Vector2, target: Vector2) -> float:
	var d := (from - target).normalized()
	return atan2(d.x, -d.y)


func run() -> void:
	var boot := 0.0
	while not Mission.has_plan() and boot < 240.0:
		await m._wait(0.5)
		boot += 0.5
	await m._await_plan()
	await m._wait(1.0)
	var w: MarsWorld = m.world
	var t0 := Mission.eva_t
	var ui_was: bool = m.ui.visible
	m.ui.visible = false
	w.orbit.auto_rotate = false
	var hab_xy: Vector2 = Mission.hab_xy()
	var hab: Vector3 = w.td.world_at(hab_xy)
	var door: Vector2 = w.haven_door()
	var out_yaw := _yaw_from(door, hab_xy)   # looking at the airlock from outside
	for v in [["m01_habitat_airlock_side.png", out_yaw, 70.0, 0.32], ["m02_habitat_far_side.png", out_yaw + PI, 70.0, 0.32],
			["m03_habitat_above.png", out_yaw + 0.9, 95.0, 0.85]]:
		w.orbit.fly_to(hab + Vector3(0, 3, 0), float(v[2]), float(v[1]), float(v[3]), 0.2)
		await m._wait(2.5)
		await m._shot(str(v[0]))
	w.orbit.fly_to(w.td.world_at(door) + Vector3(0, 2.5, 0), 16.0, out_yaw + 0.5, 0.22, 0.2)
	await m._wait(2.5)
	await m._shot("m04_airlock.png")
	# the helmet view at the airlock door, facing it
	Mission.set_playing(false)
	Mission.set_time(0.0)
	m._set_mode("walk")
	await m._wait(2.5)
	var wk: Walker = w.walker
	wk.autopilot = false
	m.hud.visible = false
	var face := (hab_xy - door).normalized()
	wk.place(door, rad_to_deg(atan2(face.x, face.y)))
	wk.pitch = 0.05
	await m._wait(1.5)
	await m._shot("m05_helmet_at_airlock.png")
	# the suit: a stand-in crew member 3.2 m in front of you in an open spot, from the front, the back and mid-stride
	var ds: Array = Mission.plan["profile"]["d"]
	var spot: Vector2 = Mission.route_xy(minf(160.0, float(ds[ds.size() - 1]) * 0.3))
	wk.place(spot, 20.0)
	wk.pitch = -0.08
	await m._wait(1.0)
	var fwd := Vector2(sin(wk.yaw), cos(wk.yaw))
	var fig: Node3D = Models.astronaut(Color("ff7a3d"))
	w.add_child(fig)
	fig.position = w.td.world_at(spot + fwd * 3.2)
	var base_rot := -atan2(-fwd.x, -fwd.y)   # facing you (crew figures face their walking direction this way)
	for v in [["m06_suit_front.png", 0.0, 0.0], ["m07_suit_back.png", PI, 0.0], ["m08_suit_walking.png", PI * 0.5, 1.0]]:
		fig.rotation.y = base_rot + float(v[1])
		Models.animate_astronaut(fig, 1.2, float(v[2]))
		await m._wait(0.8)
		await m._shot(str(v[0]))
	fig.queue_free()
	wk.autopilot = true
	m.hud.visible = true
	m._set_mode("orbit")
	await m._wait(1.0)
	m.ui.visible = ui_was
	Mission.set_time(t0)
	print("models tour: done")
