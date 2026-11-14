class_name Models
extends RefCounted
## Procedural low-poly models built from primitive meshes: no asset files needed.
## Every model faces -Z (Godot's "forward"); sizes are in metres.


static func mat(c: Color, rough := 0.65, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


static func glow(c: Color, energy := 2.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	return m


static func part(parent: Node3D, mesh: Mesh, material: Material, pos: Vector3, rot_deg := Vector3.ZERO, scl := Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.scale = scl
	parent.add_child(mi)
	return mi


static func box(x: float, y: float, z: float) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = Vector3(x, y, z)
	return b


static func cyl(r_top: float, r_bot: float, h: float, seg := 24) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bot
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c


static func sphere(r: float, hemi := false, seg := 32) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r if hemi else r * 2.0
	s.is_hemisphere = hemi
	s.radial_segments = seg
	s.rings = maxi(8, seg / 2)
	return s


static func capsule(r: float, h: float, seg := 16, rings := 6) -> CapsuleMesh:
	var c := CapsuleMesh.new()
	c.radius = r
	c.height = h
	c.radial_segments = seg
	c.rings = rings
	return c


static func torus(inner: float, outer: float, rings := 48, segs := 10) -> TorusMesh:
	var t := TorusMesh.new()
	t.inner_radius = inner
	t.outer_radius = outer
	t.rings = rings
	t.ring_segments = segs
	return t


## Merge a group's plain mesh parts into one mesh per material, so a detailed model costs a few draw calls instead
## of one per part. Parts with metadata (the blinking beacon), with children or with a non-uniform scale (whose
## normals a merge would bend), and every other kind of node, stay as they are.
static func merge_parts(group: Node3D) -> void:
	var tools := {}
	var order: Array = []
	for c in group.get_children():
		var mi := c as MeshInstance3D
		if mi == null or mi.mesh == null or mi.get_child_count() > 0 or not mi.get_meta_list().is_empty():
			continue
		var sc := mi.scale
		if absf(sc.x - sc.y) > 1e-3 or absf(sc.y - sc.z) > 1e-3:
			continue
		var m: Material = mi.material_override
		if not tools.has(m):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			tools[m] = st
			order.append(m)
		(tools[m] as SurfaceTool).append_from(mi.mesh, 0, mi.transform)
		group.remove_child(mi)
		mi.free()
	for m in order:
		var merged := MeshInstance3D.new()
		merged.mesh = (tools[m] as SurfaceTool).commit()
		merged.material_override = m
		group.add_child(merged)


## A thin rod from a to b (railings, antennas, stays).
static func strut(parent: Node3D, a: Vector3, b: Vector3, r: float, material: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = cyl(r, r, a.distance_to(b), 8)
	mi.material_override = material
	var y := (b - a).normalized()
	var x := y.cross(Vector3.UP if absf(y.y) < 0.99 else Vector3.RIGHT).normalized()
	mi.transform = Transform3D(Basis(x, y, x.cross(y)), (a + b) * 0.5)
	parent.add_child(mi)
	return mi


## A round window with a metal frame in a wall facing `a` (radians in the model's x/z), lit from inside.
static func _porthole(parent: Node3D, at: Vector3, a: float, r: float, light: Material, frame: Material) -> void:
	var rot := Vector3(0, -rad_to_deg(a), 90)
	part(parent, cyl(r, r, 0.08, 20), light, at, rot)
	part(parent, torus(r * 0.95, r * 1.25, 24, 6), frame, at, rot)


## Vertical ribs over a dome of radius r flattened to `squash` (their lower halves are under ground).
static func _ribs(parent: Node3D, centre: Vector3, r: float, squash: float, n: int, material: Material) -> void:
	var g := Node3D.new()
	g.position = centre
	g.scale = Vector3(1, squash, 1)
	parent.add_child(g)
	var ring := torus(r - 0.07, r + 0.07)
	for k in n:
		part(g, ring, material, Vector3.ZERO, Vector3(90, 180.0 * k / n, 0))
	merge_parts(g)


## A ring of regolith-filled bags (radiation shielding) round `centre`, each a little off line like hand-placed
## bags, skipping any that would sit in `avoid`: circles [Vector2 centre, radius] and segments [Vector2 a,
## Vector2 b, half-width] in the model's x/z.
static func _bag_ring(parent: Node3D, centre: Vector3, radius: float, y: float, stagger: float, mat_a: Material, mat_b: Material, avoid: Array) -> void:
	var bag := capsule(0.3, 1.25, 10, 3)
	var n := int(TAU * radius / 1.3)
	for k in n:
		var a := TAU * (k + stagger) / n
		var h := sin(k * 12.9898 + radius * 78.233) * 43758.5453   # a fixed scatter per bag
		h -= floorf(h)
		var r := radius + (h - 0.5) * 0.16
		var p := centre + Vector3(cos(a) * r, y, sin(a) * r)
		var p2 := Vector2(p.x, p.z)
		var skip := false
		for av in avoid:
			if av.size() == 2 and p2.distance_to(av[0]) < float(av[1]):
				skip = true
			elif av.size() == 3 and p2.distance_to(Geometry2D.get_closest_point_to_segment(p2, av[0], av[1])) < float(av[2]):
				skip = true
		if not skip:
			part(parent, bag, mat_a if h > 0.33 else mat_b, p, Vector3(0, 90.0 - rad_to_deg(a) + (h - 0.5) * 8.0, 90))


# ------------------------------------------------------------------ habitat
## A surface habitat after some sols on Mars: the main module (a ribbed dome on a short wall, with portholes and a
## glass cupola) behind a regolith berm and two rows of regolith-filled bags for radiation shielding; the airlock
## tunnel to the east with its hatch, landing and ramp; the science module to the west on a bellows tunnel; the
## solar field to the south; the radio mast, tanks, radiators, a weather station, crates and a rover charging post.
## Everything stays inside the crew's keep-out shapes (MarsWorld.add_habitat_obstacles: the main and science
## modules' capsule, r 13.2, and the solar field's), and the hatch stays at x 12.66 for the door stand point.
static func habitat() -> Node3D:
	var root := Node3D.new()
	root.name = "Habitat"
	var white := mat(Color(0.9, 0.88, 0.84), 0.55)
	var shell := mat(Color(0.8, 0.78, 0.74), 0.75)
	var berm := mat(Color(0.6, 0.44, 0.32), 0.95)
	var bag_a := mat(Color(0.63, 0.46, 0.33), 0.92)
	var bag_b := mat(Color(0.53, 0.38, 0.27), 0.92)
	var dark := mat(Color(0.17, 0.18, 0.2), 0.5, 0.3)
	var metal := mat(Color(0.62, 0.64, 0.68), 0.35, 0.8)
	var glass := mat(Color(0.05, 0.09, 0.14), 0.04, 0.9)
	var solar := mat(Color(0.06, 0.1, 0.24), 0.22, 0.6)
	var hazard := mat(Color(0.95, 0.74, 0.12), 0.6)
	var crate := mat(Color(0.78, 0.43, 0.18), 0.7)
	var blue := mat(Color(0.2, 0.42, 0.85), 0.5)
	var warm := glow(Color(1.0, 0.78, 0.48), 2.0)
	var lab := glow(Color(0.72, 1.0, 0.84), 1.8)
	var green := glow(Color(0.3, 1.0, 0.6), 3.0)
	var red := glow(Color(1.0, 0.15, 0.1), 4.0)
	var sci := Vector3(-15.0, 0.0, 6.0)
	var tun_a := Vector2(-6.26, 4.18)    # the bellows tunnel to the science module, end to end (x, z)
	var tun_b := Vector2(-11.34, 1.82)
	# --- main module: short wall, dome, seam, ribs, portholes and a glass cupola with an antenna
	part(root, cyl(8.0, 8.0, 2.0, 48), shell, Vector3(0, 0.0, 0))   # (reaching 1 m down: uneven ground never shows a gap)
	part(root, sphere(8.0, true, 48), white, Vector3(0, 0.95, 0), Vector3.ZERO, Vector3(1, 0.85, 1))
	part(root, torus(7.95, 8.2), dark, Vector3(0, 1.0, 0), Vector3.ZERO, Vector3(1, 0.6, 1))
	_ribs(root, Vector3(0, 0.95, 0), 8.06, 0.85, 4, metal)
	for k in 8:
		var pa := deg_to_rad(22.5 + 45.0 * k)
		if absf(wrapf(rad_to_deg(pa) - 158.0, -180.0, 180.0)) < 18.0:
			continue   # the bellows tunnel leaves the dome there
		_porthole(root, Vector3(cos(pa) * 7.82, 2.6, sin(pa) * 7.82), pa, 0.42, warm, metal)
	part(root, cyl(1.5, 1.65, 0.3, 32), metal, Vector3(0, 7.62, 0))
	part(root, sphere(1.4, true, 24), glass, Vector3(0, 7.72, 0))
	part(root, cyl(0.05, 0.05, 2.0, 8), metal, Vector3(0.7, 8.9, 0.4))
	part(root, sphere(0.09, false, 12), red, Vector3(0.7, 9.92, 0.4))
	# --- shielding: a regolith berm against the wall, then two staggered rows of filled bags
	part(root, cyl(8.3, 11.4, 1.6, 48), berm, Vector3(0, -0.25, 0))
	var main_avoid := [[Vector2(sci.x, sci.z), 6.9], [Vector2(6.4, 0.0), Vector2(13.2, 0.0), 2.1], [tun_a, tun_b, 1.9]]
	_bag_ring(root, Vector3.ZERO, 11.85, 0.3, 0.0, bag_a, bag_b, main_avoid)
	_bag_ring(root, Vector3.ZERO, 11.55, 0.84, 0.5, bag_b, bag_a, main_avoid)
	_bag_ring(root, Vector3.ZERO, 12.0, -0.26, 0.25, bag_b, bag_a, main_avoid)   # half buried: shows where the ground dips
	# --- airlock to the east: ringed tunnel, hatch with a lit window and status lights, landing, ramp and rails
	part(root, cyl(1.5, 1.5, 6.0), white, Vector3(9.6, 2.0, 0), Vector3(0, 0, 90))
	for x in [7.4, 9.6, 11.8]:
		part(root, torus(1.47, 1.62), metal, Vector3(x, 2.0, 0), Vector3(0, 0, 90))
	part(root, torus(1.3, 1.65), dark, Vector3(12.6, 2.0, 0), Vector3(0, 0, 90))
	part(root, cyl(1.26, 1.26, 0.1, 32), metal, Vector3(12.64, 2.0, 0), Vector3(0, 0, 90))
	part(root, cyl(0.3, 0.3, 0.04, 20), warm, Vector3(12.7, 2.35, 0), Vector3(0, 0, 90))
	part(root, box(0.06, 0.55, 0.07), dark, Vector3(12.71, 1.85, 0.62))
	for z in [-0.95, 0.95]:
		part(root, box(0.1, 0.1, 0.1), green, Vector3(12.7, 3.42, z))
	part(root, box(0.12, 0.1, 1.2), warm, Vector3(12.75, 3.82, 0))
	part(root, box(1.0, 0.2, 2.6), metal, Vector3(12.95, 0.6, 0))
	part(root, box(0.96, 1.2, 2.5), dark, Vector3(12.95, -0.1, 0))
	part(root, box(0.12, 0.21, 2.6), hazard, Vector3(13.45, 0.6, 0))
	part(root, box(2.33, 0.1, 2.0), metal, Vector3(14.55, 0.15, 0), Vector3(0, 0, -25.5))
	for z in [-1.25, 1.25]:
		strut(root, Vector3(12.55, 0.7, z), Vector3(12.55, 1.65, z), 0.03, metal)
		strut(root, Vector3(13.35, 0.7, z), Vector3(13.35, 1.65, z), 0.03, metal)
		strut(root, Vector3(12.5, 1.62, z), Vector3(13.4, 1.62, z), 0.03, metal)
	# --- science module to the west: wall, dome, ribs, lab-lit portholes, its own bag ring; the bellows tunnel
	part(root, cyl(5.2, 5.2, 1.7, 40), shell, sci + Vector3(0, -0.15, 0))
	part(root, sphere(5.2, true, 40), white, sci + Vector3(0, 0.7, 0), Vector3.ZERO, Vector3(1, 0.82, 1))
	part(root, torus(5.15, 5.35), dark, sci + Vector3(0, 0.75, 0), Vector3.ZERO, Vector3(1, 0.6, 1))
	_ribs(root, sci + Vector3(0, 0.7, 0), 5.26, 0.82, 3, metal)
	for deg in [60.0, 130.0, 200.0, 270.0]:
		var sa := deg_to_rad(deg)
		_porthole(root, sci + Vector3(cos(sa) * 5.06, 1.9, sin(sa) * 5.06), sa, 0.34, lab, metal)
	_bag_ring(root, sci, 5.85, 0.3, 0.0, bag_b, bag_a, [[Vector2.ZERO, 12.6], [tun_a, tun_b, 1.9]])
	part(root, cyl(1.2, 1.2, 5.6), white, Vector3(-8.8, 1.6, 3.0), Vector3(0, -25, 90))
	for f in [-0.9, 0.9]:
		part(root, torus(1.17, 1.32), metal, Vector3(-8.8, 1.6, 3.0) + Vector3(-0.906, 0, -0.423) * f, Vector3(0, -25, 90))
	# --- solar field: framed panels on posts, cable trays back to the habitat
	for row in 2:
		for k in 6:
			var px := -14.0 + k * 5.2
			var pz := 19.0 + row * 4.6
			part(root, cyl(0.07, 0.07, 2.0, 8), metal, Vector3(px, 0.4, pz))
			part(root, box(4.72, 0.05, 2.72), metal, Vector3(px, 1.42, pz), Vector3(-28, 0, 0))
			part(root, box(4.6, 0.08, 2.6), solar, Vector3(px, 1.45, pz), Vector3(-28, 0, 0))
	for x in [-2.0, 4.0]:
		part(root, box(0.35, 0.06, 5.6), dark, Vector3(x, 0.03, 15.2))
	# --- radio mast (12 m) with service collars, dish and blinking beacon
	part(root, cyl(0.14, 0.22, 12.6, 12), metal, Vector3(5.0, 5.7, -9.0))
	for hgt in [3.0, 6.0, 9.0]:
		part(root, cyl(0.34, 0.34, 0.06, 12), metal, Vector3(5.0, hgt, -9.0))
	part(root, sphere(1.6, true, 24), white, Vector3(5.0, 10.4, -9.0), Vector3(-62, 35, 0), Vector3(1, 0.35, 1))
	var bea := part(root, sphere(0.25), glow(Color(1, 0.12, 0.08), 8.0), Vector3(5.0, 12.2, -9.0))
	bea.set_meta("blink", true)
	# --- consumables: two tanks on cradles (oxygen with a blue band, water), beside the science module
	for t in [[Vector3(-13.0, 0.9, -4.5), blue], [Vector3(-16.2, 0.9, -4.5), metal]]:
		var tc: Vector3 = t[0]
		part(root, cyl(0.6, 0.6, 1.6, 20), white, tc, Vector3(0, 0, 90))
		part(root, sphere(0.6, false, 20), white, tc + Vector3(0.8, 0, 0))
		part(root, sphere(0.6, false, 20), white, tc - Vector3(0.8, 0, 0))
		part(root, cyl(0.62, 0.62, 0.3, 20), t[1], tc, Vector3(0, 0, 90))
		for dx in [-0.6, 0.6]:
			part(root, box(0.25, 0.9, 1.0), dark, tc + Vector3(dx, -0.95, 0))
	# --- heat rejection: two radiator panels on posts between the modules
	var rc := Vector3(-8.8, 0, 11.0)
	var rx := Vector3(cos(deg_to_rad(30.0)), 0, sin(deg_to_rad(30.0)))
	for dy in [1.0, 2.25]:
		part(root, box(2.6, 1.0, 0.06), white, rc + Vector3(0, dy, 0), Vector3(0, -30, 0))
	for sgn in [-1.0, 1.0]:
		strut(root, rc + rx * 1.3 * sgn + Vector3(0, -0.5, 0), rc + rx * 1.3 * sgn + Vector3(0, 2.85, 0), 0.05, metal)
	# --- weather station
	var ws := Vector3(9.0, 0, -9.3)
	strut(root, ws + Vector3(0, -0.5, 0), ws + Vector3(0, 2.4, 0), 0.04, metal)
	part(root, box(0.7, 0.03, 0.03), metal, ws + Vector3(0, 2.3, 0))
	for sgn in [-1.0, 1.0]:
		part(root, sphere(0.06, false, 10), white, ws + Vector3(0.35 * sgn, 2.36, 0))
	part(root, box(0.45, 0.02, 0.32), solar, ws + Vector3(0, 1.5, 0.12), Vector3(-35, 0, 0))
	part(root, box(0.18, 0.22, 0.14), white, ws + Vector3(0, 1.0, 0))
	# --- crates and a rover charging post
	for c in [Vector3(-11.8, 0.35, -8.3), Vector3(-13.2, 0.35, -7.5), Vector3(-12.4, 1.25, -7.9)]:
		part(root, box(1.4, 0.9, 1.0), crate, c, Vector3(0, fmod(absf(c.x) * 37.0, 25.0), 0))
	part(root, box(0.5, 2.1, 0.5), dark, Vector3(11.6, 0.55, 5.2))
	part(root, box(0.52, 0.2, 0.52), green, Vector3(11.6, 1.5, 5.2))
	var flood := OmniLight3D.new()
	flood.name = "Flood"
	flood.light_color = Color(1.0, 0.82, 0.6)
	flood.omni_range = 45.0
	flood.light_energy = 0.0
	flood.position = Vector3(14.0, 5.0, 0.0)
	root.add_child(flood)
	root.set_meta("lights", [flood])
	merge_parts(root)
	return root


static func pressurized_rover() -> Node3D:
	var root := Node3D.new()
	root.name = "PressurizedRover"
	var white := mat(Color(0.9, 0.89, 0.86), 0.5)
	var dark := mat(Color(0.11, 0.11, 0.12), 0.75)
	var glass := mat(Color(0.04, 0.1, 0.18), 0.06, 0.5)
	var orange := mat(Color(1.0, 0.45, 0.15), 0.5)
	var metal := mat(Color(0.62, 0.62, 0.65), 0.35, 0.8)
	part(root, box(7.0, 0.5, 3.0), dark, Vector3(0, 1.05, 0))
	part(root, box(6.2, 2.4, 2.8), white, Vector3(-0.3, 2.5, 0))
	part(root, box(1.5, 1.7, 2.6), white, Vector3(3.15, 2.15, 0), Vector3(0, 0, -18))
	part(root, box(0.1, 1.0, 2.3), glass, Vector3(3.92, 2.55, 0), Vector3(0, 0, -18))
	for s in [-1.0, 1.0]:
		part(root, box(1.3, 0.55, 0.06), glass, Vector3(1.4, 2.95, s * 1.42))
		part(root, box(0.8, 0.55, 0.06), glass, Vector3(-0.6, 2.95, s * 1.42))
	part(root, box(6.25, 0.18, 2.86), orange, Vector3(-0.3, 1.9, 0))
	part(root, box(4.2, 0.12, 2.4), metal, Vector3(-0.9, 3.78, 0))
	for s in [-0.65, 0.65]:
		part(root, torus(0.33, 0.5), dark, Vector3(-3.42, 2.45, s), Vector3(0, 0, 90))
	for x in [-2.4, 0.0, 2.4]:
		for s in [-1.0, 1.0]:
			part(root, cyl(0.64, 0.64, 0.5, 24), dark, Vector3(x, 0.64, s * 1.62), Vector3(90, 0, 0))
			part(root, cyl(0.32, 0.32, 0.52, 12), metal, Vector3(x, 0.64, s * 1.62), Vector3(90, 0, 0))
	for s in [-0.9, 0.9]:
		part(root, box(0.08, 0.22, 0.46), glow(Color(1, 0.95, 0.85), 5.0), Vector3(3.58, 1.5, s))
	var head := SpotLight3D.new()
	head.position = Vector3(3.9, 1.6, 0)
	head.rotation_degrees = Vector3(-6, -90, 0)
	head.spot_range = 45.0
	head.spot_angle = 32.0
	head.light_energy = 0.0
	root.add_child(head)
	root.set_meta("lights", [head])
	return root


static func curiosity() -> Node3D:
	var root := Node3D.new()
	root.name = "Curiosity"
	var body := mat(Color(0.83, 0.8, 0.75), 0.55, 0.1)
	var dark := mat(Color(0.14, 0.14, 0.15), 0.6, 0.3)
	var gold := mat(Color(0.78, 0.62, 0.32), 0.3, 0.9)
	var metal := mat(Color(0.6, 0.6, 0.62), 0.35, 0.85)
	part(root, box(1.7, 0.55, 1.15), body, Vector3(0, 1.0, 0))
	part(root, box(1.8, 0.07, 1.25), gold, Vector3(0, 1.3, 0))
	part(root, cyl(0.2, 0.2, 0.8, 16), dark, Vector3(-1.1, 1.2, 0), Vector3(0, 0, 55))
	for i in 4:
		part(root, box(0.62, 0.02, 0.5), dark, Vector3(-1.1, 1.2, 0), Vector3(i * 45.0, 0, 55))
	part(root, cyl(0.05, 0.06, 1.15, 10), body, Vector3(0.6, 1.9, 0.38))
	part(root, box(0.24, 0.3, 0.46), body, Vector3(0.63, 2.5, 0.38))
	part(root, box(0.04, 0.09, 0.32), mat(Color(0.03, 0.03, 0.05), 0.15, 0.3), Vector3(0.76, 2.5, 0.38))
	part(root, cyl(0.27, 0.27, 0.04, 20), body, Vector3(-0.3, 1.47, -0.45), Vector3(60, 0, 0))
	part(root, box(0.75, 0.07, 0.07), body, Vector3(1.15, 0.95, 0.3), Vector3(0, 30, -20))
	part(root, box(0.22, 0.22, 0.22), metal, Vector3(1.52, 0.72, 0.46))
	for s in [-1.0, 1.0]:
		part(root, box(1.95, 0.07, 0.07), body, Vector3(0, 0.75, s * 0.75), Vector3(0, 0, 8))
		for x in [-0.82, 0.0, 0.86]:
			part(root, cyl(0.26, 0.26, 0.4, 20), metal, Vector3(x, 0.26, s * 0.86), Vector3(90, 0, 0))
			part(root, box(0.06, 0.46, 0.06), body, Vector3(x, 0.56, s * 0.8))
	return root


## A Mars surface suit: soft fabric with metal bearings at the waist, shoulders, elbows, wrists, knees and ankles; a hard
## upper torso with the display and control module on the chest; the life-support backpack with its oxygen pack,
## vents and antenna; a helmet with a gold sun visor, lamps and a camera; gloves, dusty boots, a cuff checklist on
## the left forearm, and crew ID stripes on the arms and legs in the crew member's colour (EV1, EV2). Faces -Z.
## Joints for animate_astronaut: Body > HipL/HipR > Knee, Body > ShoulderL/ShoulderR > Elbow.
static func astronaut(accent: Color) -> Node3D:
	var root := Node3D.new()
	root.name = "Astronaut"
	var suit := mat(Color(0.93, 0.92, 0.89), 0.85)
	var hard := mat(Color(0.96, 0.96, 0.94), 0.4)
	var dust := mat(Color(0.74, 0.6, 0.5), 0.95)
	var dark := mat(Color(0.2, 0.21, 0.23), 0.7)
	var metal := mat(Color(0.66, 0.68, 0.72), 0.3, 0.85)
	var visor := mat(Color(0.95, 0.7, 0.25), 0.06, 1.0)
	var band := glow(accent, 0.9)
	var lamp_glow := glow(Color(1, 1, 0.92), 6.0)
	var screen := glow(Color(0.35, 0.95, 0.75), 1.6)
	var body := Node3D.new()
	body.name = "Body"
	root.add_child(body)
	# pelvis, waist bearing, torso and hard upper torso, chest display and control module
	part(body, capsule(0.17, 0.52, 12, 4), suit, Vector3(0, 0.95, 0), Vector3(0, 0, 90))
	part(body, torus(0.21, 0.27, 20, 6), metal, Vector3(0, 1.06, 0))
	part(body, capsule(0.27, 0.66, 16, 5), suit, Vector3(0, 1.34, 0))
	part(body, box(0.46, 0.42, 0.08), hard, Vector3(0, 1.4, -0.235), Vector3(-6, 0, 0))
	part(body, box(0.3, 0.15, 0.11), dark, Vector3(0, 1.27, -0.31))
	part(body, box(0.15, 0.06, 0.01), screen, Vector3(0, 1.295, -0.367))
	for kx in [-0.09, 0.0, 0.09]:
		part(body, cyl(0.018, 0.018, 0.03, 10), metal, Vector3(kx, 1.225, -0.37), Vector3(90, 0, 0))
	for sx in [-1.0, 1.0]:
		part(body, torus(0.085, 0.125, 20, 6), metal, Vector3(0.33 * sx, 1.52, 0), Vector3(0, 0, 90))
	# helmet: neck ring, shell, gold visor, lamps and a camera
	part(body, torus(0.17, 0.21, 20, 6), metal, Vector3(0, 1.62, 0))
	part(body, sphere(0.21, false, 24), hard, Vector3(0, 1.8, 0))
	part(body, sphere(0.214, true, 24), visor, Vector3(0, 1.81, -0.01), Vector3(-90, 0, 0))
	for sx in [-1.0, 1.0]:
		part(body, box(0.07, 0.06, 0.12), hard, Vector3(0.2 * sx, 1.88, -0.04))
		part(body, box(0.05, 0.04, 0.012), lamp_glow, Vector3(0.2 * sx, 1.88, -0.105))
	part(body, box(0.03, 0.03, 0.06), dark, Vector3(0.2, 1.925, -0.06))
	# life-support backpack with its oxygen pack, ID band, vents, handles and antenna
	part(body, box(0.5, 0.62, 0.24), hard, Vector3(0, 1.33, 0.27))
	part(body, cyl(0.12, 0.12, 0.5, 16), hard, Vector3(0, 1.64, 0.27), Vector3(0, 0, 90))
	part(body, box(0.51, 0.07, 0.25), band, Vector3(0, 1.5, 0.27))
	part(body, box(0.4, 0.14, 0.2), hard, Vector3(0, 0.96, 0.25))
	for vy in [1.15, 1.21]:
		part(body, box(0.3, 0.03, 0.012), dark, Vector3(0, vy, 0.396))
	for sx in [-1.0, 1.0]:
		part(body, cyl(0.012, 0.012, 0.36, 8), metal, Vector3(0.265 * sx, 1.33, 0.27))
	part(body, cyl(0.008, 0.008, 0.3, 6), metal, Vector3(-0.19, 1.83, 0.33))
	part(body, sphere(0.018, false, 8), band, Vector3(-0.19, 1.99, 0.33))
	for sx in [-1.0, 1.0]:
		# legs: thigh with the ID stripe, knee bearing; below the knee the shin, ankle bearing and a dusty boot
		var hip := Node3D.new()
		hip.name = "HipL" if sx < 0 else "HipR"
		hip.position = Vector3(0.12 * sx, 0.93, 0)
		body.add_child(hip)
		part(hip, capsule(0.105, 0.5, 12, 4), suit, Vector3(0, -0.22, 0))
		part(hip, cyl(0.112, 0.112, 0.08, 16), band, Vector3(0, -0.2, 0))
		part(hip, torus(0.085, 0.118, 20, 6), metal, Vector3(0, -0.44, 0))
		var knee := Node3D.new()
		knee.name = "Knee"
		knee.position = Vector3(0, -0.44, 0)
		hip.add_child(knee)
		part(knee, capsule(0.095, 0.44, 12, 4), suit, Vector3(0, -0.19, 0))
		part(knee, cyl(0.1, 0.1, 0.12, 16), dust, Vector3(0, -0.33, 0))
		part(knee, torus(0.075, 0.105, 20, 6), metal, Vector3(0, -0.4, 0))
		part(knee, box(0.17, 0.13, 0.27), dust, Vector3(0, -0.44, -0.04))
		part(knee, box(0.18, 0.04, 0.29), dark, Vector3(0, -0.49, -0.045))
		merge_parts(knee)
		merge_parts(hip)
		# arms: upper arm with the ID stripe, elbow bearing; the forearm, wrist bearing and glove (cuff on the left)
		var sh := Node3D.new()
		sh.name = "ShoulderL" if sx < 0 else "ShoulderR"
		sh.position = Vector3(0.35 * sx, 1.5, 0)
		body.add_child(sh)
		part(sh, capsule(0.085, 0.36, 12, 4), suit, Vector3(0.015 * sx, -0.15, 0), Vector3(0, 0, 6.0 * sx))
		part(sh, cyl(0.092, 0.092, 0.06, 16), band, Vector3(0.011 * sx, -0.1, 0), Vector3(0, 0, 6.0 * sx))
		part(sh, torus(0.07, 0.1, 20, 6), metal, Vector3(0.03 * sx, -0.32, 0))
		var elbow := Node3D.new()
		elbow.name = "Elbow"
		elbow.position = Vector3(0.03 * sx, -0.32, 0)
		sh.add_child(elbow)
		part(elbow, capsule(0.075, 0.32, 12, 4), suit, Vector3(0, -0.14, 0))
		part(elbow, torus(0.06, 0.088, 20, 6), metal, Vector3(0, -0.29, 0))
		part(elbow, box(0.085, 0.14, 0.1), dark, Vector3(0, -0.37, 0))
		part(elbow, box(0.03, 0.06, 0.035), dark, Vector3(-0.05 * sx, -0.34, -0.04))
		if sx < 0:
			part(elbow, box(0.11, 0.14, 0.012), hard, Vector3(0, -0.17, -0.078))
		merge_parts(elbow)
		merge_parts(sh)
	var lamp := SpotLight3D.new()
	lamp.position = Vector3(0, 1.95, -0.2)
	lamp.spot_range = 25.0
	lamp.spot_angle = 30.0
	lamp.light_energy = 0.0
	lamp.shadow_enabled = false
	body.add_child(lamp)
	root.set_meta("lights", [lamp])
	merge_parts(body)
	return root


## Walk cycle: legs swing from the hips with the knee bending as each leg comes forward (a little bend always: a
## suited stance), arms swing against the legs with the elbows bent, and the body bobs.
static func animate_astronaut(a: Node3D, phase: float, moving: float) -> void:
	var body := a.get_node("Body") as Node3D
	var sw := sin(phase) * 0.5 * moving
	var fwd := cos(phase) * moving   # > 0 while the left leg swings forward
	var hl := body.get_node("HipL") as Node3D
	var hr := body.get_node("HipR") as Node3D
	hl.rotation.x = sw
	hr.rotation.x = -sw
	(hl.get_node("Knee") as Node3D).rotation.x = -(0.08 + 0.6 * maxf(0.0, fwd))
	(hr.get_node("Knee") as Node3D).rotation.x = -(0.08 + 0.6 * maxf(0.0, -fwd))
	var sl := body.get_node("ShoulderL") as Node3D
	var sr := body.get_node("ShoulderR") as Node3D
	sl.rotation.x = -sw * 0.8
	sr.rotation.x = sw * 0.8
	(sl.get_node("Elbow") as Node3D).rotation.x = 0.3 + 0.25 * maxf(0.0, -sw)
	(sr.get_node("Elbow") as Node3D).rotation.x = 0.3 + 0.25 * maxf(0.0, sw)
	body.position.y = absf(sin(phase)) * 0.05 * moving


static func relay_mast(h := 3.0) -> Node3D:
	var root := Node3D.new()
	root.name = "Relay"
	var metal := mat(Color(0.7, 0.7, 0.72), 0.35, 0.8)
	part(root, cyl(0.06, 0.1, h, 10), metal, Vector3(0, h * 0.5, 0))
	for a in 3:
		part(root, box(0.04, 0.04, 1.4), metal, Vector3(0, 0.45, 0), Vector3(-35, a * 120.0, 0))
	part(root, sphere(0.45, true, 16), mat(Color(0.9, 0.9, 0.88), 0.4), Vector3(0, h - 0.2, 0), Vector3(-70, 0, 0), Vector3(1, 0.3, 1))
	var tip := part(root, sphere(0.1), glow(Color(0.4, 1.0, 0.7), 6.0), Vector3(0, h + 0.1, 0))
	tip.set_meta("blink", true)
	return root


static func octahedron(r: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var top := Vector3(0, r * 1.45, 0)
	var bot := Vector3(0, -r * 1.45, 0)
	var ring := [Vector3(r, 0, 0), Vector3(0, 0, r), Vector3(-r, 0, 0), Vector3(0, 0, -r)]
	for i in 4:
		var a: Vector3 = ring[i]
		var b: Vector3 = ring[(i + 1) % 4]
		st.add_vertex(top)
		st.add_vertex(b)
		st.add_vertex(a)
		st.add_vertex(bot)
		st.add_vertex(a)
		st.add_vertex(b)
	st.generate_normals()
	return st.commit()


static func chevron(size := 0.75) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var p := [Vector3(0, 0, -size), Vector3(size * 0.8, 0, size * 0.55), Vector3(0, 0, size * 0.05), Vector3(-size * 0.8, 0, size * 0.55)]
	for t in [[0, 1, 2], [0, 2, 3]]:
		for k in t:
			st.set_normal(Vector3.UP)
			st.add_vertex(p[k])
	return st.commit()


## Light column + floating hologram diamond over a stop.
static func beacon(color: Color, height := 60.0) -> Node3D:
	var root := Node3D.new()
	root.name = "Beacon"
	var col := MeshInstance3D.new()
	var cm := cyl(0.55, 1.25, height, 24)
	cm.cap_top = false
	cm.cap_bottom = false
	col.mesh = cm
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/beacon.gdshader")
	sm.set_shader_parameter("color", color)
	sm.set_shader_parameter("column_height", height)
	sm.set_shader_parameter("intensity", 3.2)
	col.material_override = sm
	col.position.y = height * 0.5
	col.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(col)
	var dia := MeshInstance3D.new()
	dia.name = "Diamond"
	dia.mesh = octahedron(1.5)
	var hm := ShaderMaterial.new()
	hm.shader = load("res://shaders/hologram.gdshader")
	hm.set_shader_parameter("color", color)
	dia.material_override = hm
	dia.position.y = 9.0
	dia.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(dia)
	root.set_meta("column_mat", sm)
	return root


static func soft_dot(size := 64) -> GradientTexture2D:
	var gt := GradientTexture2D.new()
	var gr := Gradient.new()
	gr.set_color(0, Color(1, 1, 1, 1))
	gr.set_color(1, Color(1, 1, 1, 0))
	gt.gradient = gr
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	gt.width = size
	gt.height = size
	return gt
