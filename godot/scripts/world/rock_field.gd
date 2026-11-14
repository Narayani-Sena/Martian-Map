class_name RockField
extends Node3D
## Scattered rocks around the walker (walk mode only). The DTM resolves metre-scale relief;
## these instanced rocks add the decimetre-scale clutter you would actually step around.
## Chunks are seeded by their grid coordinates, so the same rocks reappear when you return.

const CHUNK := 32.0
const RADIUS := 3          # chunks in each direction
const ROCKS_PER_CHUNK := 70
const BUILD_BUDGET_US := 3000   # per frame: chunks are built a few at a time, nearest first

var td: TerrainData
var _meshes: Array[Mesh] = []
var _material: StandardMaterial3D
var _chunks := {}          # Vector2i -> MultiMeshInstance3D
var _center := Vector2i(1 << 30, 0)
var _queue: Array = []     # chunk keys still to build, nearest first
var _boulder_mesh: Mesh


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 0.95
	_material.albedo_color = Color(0.42, 0.33, 0.27)
	# Fade the rocks out towards the edge of the ring (dithered, so no transparency sorting) instead of
	# letting whole 32 m chunks pop in and out. Min > max reverses the fade: gone by min, starts at max.
	var reach := float(Quality.get_value("rock_radius")) * CHUNK   # the ring always covers this far
	_material.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_DITHER
	_material.distance_fade_min_distance = reach * 0.95
	_material.distance_fade_max_distance = reach * 0.6
	var noise := FastNoiseLite.new()
	noise.seed = 3
	noise.frequency = 1.6
	for k in 4:
		_meshes.append(_make_rock(noise, k, 7, 4))   # pebbles: a few cm to 0.5 m, low poly is plenty
	_boulder_mesh = _make_rock(noise, 1, 9, 6)      # HiRISE boulders, up to 4 m


func _make_rock(noise: FastNoiseLite, k: int, radial := 9, rings := 6) -> Mesh:
	var sm := SphereMesh.new()
	sm.radius = 0.5
	sm.height = 1.0
	sm.radial_segments = radial
	sm.rings = rings
	var arr := sm.get_mesh_arrays()
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var flat: float = [0.55, 0.7, 0.45, 0.85][k]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var shaded := PackedVector3Array()
	shaded.resize(verts.size())
	for i in verts.size():
		var v := verts[i]
		var d := 1.0 + noise.get_noise_3d(v.x * 2.0 + k * 7.0, v.y * 2.0, v.z * 2.0) * 0.55
		shaded[i] = Vector3(v.x * d, v.y * d * flat, v.z * d * (0.8 + 0.1 * k))
	for i in idx.size():
		var v2 := shaded[idx[i]]
		var tone := 0.62 + 0.38 * clampf(v2.y * 2.0 + 0.5, 0.0, 1.0)
		st.set_color(Color(tone, tone * 0.93, tone * 0.88))
		st.add_vertex(v2)
	st.generate_normals()
	return st.commit()


func clear_all() -> void:
	for k in _chunks:
		(_chunks[k] as Node).queue_free()
	_chunks.clear()
	_queue.clear()
	_center = Vector2i(1 << 30, 0)


## Called every frame. Crossing into a new chunk queues the missing ones (nearest first); each frame then
## builds what fits in BUILD_BUDGET_US, so walking (or riding PR-2 at x30) never stalls on a whole row.
func update_around(xy: Vector2) -> void:
	if td == null or _meshes.is_empty():
		return
	var radius := int(Quality.get_value("rock_radius"))
	var c := Vector2i(int(floor(xy.x / CHUNK)), int(floor(xy.y / CHUNK)))
	if c != _center:
		_center = c
		var keep := {}
		var want: Array = []
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				var key := Vector2i(c.x + dx, c.y + dy)
				keep[key] = true
				if not _chunks.has(key):
					want.append(key)
		for key in _chunks.keys():
			if not keep.has(key):
				(_chunks[key] as Node).queue_free()
				_chunks.erase(key)
		want.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return (a - c).length_squared() < (b - c).length_squared())
		_queue = want
	var t0 := Time.get_ticks_usec()
	while not _queue.is_empty():
		var key: Vector2i = _queue.pop_front()
		if not _chunks.has(key):
			_chunks[key] = _build_chunk(key)
		if Time.get_ticks_usec() - t0 > BUILD_BUDGET_US:
			break


## Chunks still waiting to be built.
func pending() -> int:
	return _queue.size()


func _build_chunk(key: Vector2i) -> Node3D:
	var holder := Node3D.new()
	add_child(holder)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(key.x * 73856093, key.y * 19349663))
	var per_mesh: Array = [[], [], [], []]
	for i in ROCKS_PER_CHUNK:
		var x := (key.x + rng.randf()) * CHUNK
		var y := (key.y + rng.randf()) * CHUNK
		if not td.grid.contains_xy(x, y, 2.0):
			continue
		var slope := td.slope_deg(x, y, 1.0)
		var keep_p := 0.35 + clampf(slope / 25.0, 0.0, 0.65)
		if rng.randf() > keep_p:
			continue
		var s := lerpf(0.06, 0.5, pow(rng.randf(), 2.4))   # pebbles only: real boulders come from HiRISE below
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s) * Vector3(rng.randf_range(0.8, 1.3), 1.0, rng.randf_range(0.8, 1.3)))
		var pos := Vector3(x, td.h(x, y) - s * 0.18, -y)
		(per_mesh[rng.randi() % 4] as Array).append(Transform3D(basis, pos))
	var big: Array = []
	for b in td.boulders_in(key):
		var v: Vector4 = b
		if not td.grid.contains_xy(v.x, v.y, 1.0):
			continue
		var d := clampf(v.z, 0.6, 4.0)
		var hgt := clampf(v.w, 0.3, d * 1.2)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(d, hgt / 0.6, d * rng.randf_range(0.8, 1.15)))
		var pos := Vector3(v.x, td.h(v.x, v.y) - hgt * 0.15, -v.y)
		big.append(Transform3D(basis, pos))
	# Pebbles cast no shadow: theirs are smaller than a shadow-map texel, yet every one of them was drawn
	# into each shadow split again (rocks were ~5 ms of a helmet frame on the UHD 620). Boulders keep theirs.
	for m in 4:
		_add_multimesh(holder, _meshes[m], per_mesh[m], false)
	_add_multimesh(holder, _boulder_mesh, big, true)
	return holder


func _add_multimesh(holder: Node3D, mesh: Mesh, list: Array, shadows: bool) -> void:
	if list.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = list.size()
	for i in list.size():
		mm.set_instance_transform(i, list[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = _material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(mmi)
