class_name Ribbon
extends RefCounted
## Builds ribbon meshes for draped polylines. Each centre-line point becomes two vertices at the
## same position; ribbon.gdshader pushes them apart along the side vector (stored in NORMAL),
## with UV.x = metres along the line and UV.y = 0/1 across it.


static var _xray: Shader


## The faint "x-ray" pass behind ridges: the same shader (it tests depth itself), drawn with hidden_alpha = 1.
static func xray_shader() -> Shader:
	if _xray == null:
		_xray = load("res://shaders/ribbon.gdshader") as Shader
	return _xray


## points: world-space centre line. Returns null for fewer than two points.
static func build(lines: Array, colors: Array = []) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var li := 0
	for line in lines:
		var pts: PackedVector3Array = line
		var n := pts.size()
		if n < 2:
			li += 1
			continue
		var col: Color = colors[li] if li < colors.size() else Color.WHITE
		var base := verts.size()
		var dist := 0.0
		for i in n:
			if i > 0:
				var dd := pts[i] - pts[i - 1]
				dist += Vector2(dd.x, dd.z).length()
			var a := pts[maxi(i - 1, 0)]
			var b := pts[mini(i + 1, n - 1)]
			var tg := Vector3(b.x - a.x, 0.0, b.z - a.z)
			if tg.length_squared() < 1e-8:
				tg = Vector3(1, 0, 0)
			tg = tg.normalized()
			var side := Vector3(-tg.z, 0.0, tg.x)
			for s in 2:
				verts.append(pts[i])
				normals.append(side)
				uvs.append(Vector2(dist, float(s)))
				cols.append(col)
		for i in n - 1:
			var v := base + i * 2
			idx.append_array(PackedInt32Array([v, v + 2, v + 1, v + 1, v + 2, v + 3]))
		li += 1
	if idx.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


## Densify a site-space polyline (Vector2 xy) so no segment is longer than `step` metres,
## then drape it on the terrain.
static func drape(td: TerrainData, xy: PackedVector2Array, step := 3.0) -> PackedVector3Array:
	var out := PackedVector3Array()
	var n := xy.size()
	for i in n:
		var p := xy[i]
		if i > 0:
			var q := xy[i - 1]
			var L := q.distance_to(p)
			var k := int(ceil(L / step))
			for j in range(1, k):
				var r := q.lerp(p, float(j) / k)
				out.append(Vector3(r.x, td.h(r.x, r.y), -r.y))
		out.append(Vector3(p.x, td.h(p.x, p.y), -p.y))
	return out


static func material(color: Color, width_m := 1.2, min_px := 3.0, glow := 1.8, flow := 0.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/ribbon.gdshader")
	m.set_shader_parameter("color", color)
	m.set_shader_parameter("width_m", width_m)
	m.set_shader_parameter("min_px", min_px)
	m.set_shader_parameter("glow", glow)
	m.set_shader_parameter("flow_speed", flow)
	return m
