extends SceneTree
## Builds the procedural models (models.gd) without the app and reports what each costs: mesh instances (draw calls
## per material), vertices, and that the walk animation's joints are there. Exit code 1 on a problem.
##   godot --headless --path godot --script res://tests/models_check.gd

var bad := 0


func _initialize() -> void:
	var M: GDScript = load("res://scripts/world/models.gd")
	for spec in [["habitat", M.habitat()], ["astronaut", M.astronaut(Color("ff7a3d"))], ["rover", M.pressurized_rover()]]:
		var n: Node3D = spec[1]
		var counts := _count(n)
		print("%-10s %3d mesh instances, %6d vertices, %d lights" % [spec[0], counts[0], counts[1], counts[2]])
		if spec[0] == "habitat" and (counts[0] > 40 or not _has_meta(n, "blink")):
			bad += 1
			print("FAIL habitat: too many draw calls or the blinking beacon was merged away")
		if spec[0] == "astronaut":
			for path in ["Body/HipL/Knee", "Body/HipR/Knee", "Body/ShoulderL/Elbow", "Body/ShoulderR/Elbow"]:
				if n.get_node_or_null(path) == null:
					bad += 1
					print("FAIL astronaut: no joint " + path)
			for ph in [0.0, 1.0, 2.0, 3.0, 4.0]:
				M.animate_astronaut(n, ph, 1.0)
			var knee := n.get_node("Body/HipL/Knee") as Node3D
			print("  walk cycle ran; left knee at the last phase %.2f rad" % knee.rotation.x)
		n.free()
	print("models_check: %s" % ("ok" if bad == 0 else "%d problems" % bad))
	quit(1 if bad > 0 else 0)


func _count(n: Node) -> Array:
	var meshes := 0
	var verts := 0
	var lights := 0
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		meshes += 1
		var m: Mesh = (n as MeshInstance3D).mesh
		for s in m.get_surface_count():
			verts += (m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	if n is Light3D:
		lights += 1
	for c in n.get_children():
		var sub := _count(c)
		meshes += sub[0]
		verts += sub[1]
		lights += sub[2]
	return [meshes, verts, lights]


func _has_meta(n: Node, key: String) -> bool:
	if n.has_meta(key):
		return true
	for c in n.get_children():
		if _has_meta(c, key):
			return true
	return false
