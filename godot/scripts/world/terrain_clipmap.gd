class_name TerrainClipmap
extends MeshInstance3D
## One grid mesh that follows the camera: 1 m spacing near the middle, growing geometrically outward
## to ~64 km, so the same mesh shows boxwork ridges at your feet and Mount Sharp on the horizon.
## Heights come from textures in the vertex shader; the mesh itself is flat.

const CORE := 48        # 1 m steps out to here, then each step grows geometrically
const REACH := 64000.0  # metres from the centre to the edge of the grid

var n_half := 256       # vertices from centre to edge (set from the quality preset)

var material: ShaderMaterial
var lod_scale := 1.0
var walk_mode := false
var _lod_k := -1.0


func build(td: TerrainData, albedo: Texture2D, albedo_reg: Texture2D, normal_map: Texture2D = null) -> void:
	n_half = int(Quality.get_value("clip_n"))
	mesh = _make_mesh()
	material = ShaderMaterial.new()
	material.shader = load("res://shaders/terrain.gdshader")
	var g := td.grid
	material.set_shader_parameter("dem_tex", td.dem_tex)
	material.set_shader_parameter("dem_lin", td.dem_tex)   # same texture, trilinear sampler (far vertices)
	material.set_shader_parameter("site_rect", Vector4(g.x_min, g.y_max, g.width * g.res, g.height * g.res))
	material.set_shader_parameter("site_res", g.res)
	material.set_shader_parameter("dem_dims", Vector2i(g.width, g.height))
	material.set_shader_parameter("elev_ref", td.elev_ref)
	material.set_shader_parameter("edge_blend", td.edge_blend)
	material.set_shader_parameter("dem_max_lod", td.dem_levels)
	material.set_shader_parameter("reg_max_lod", td.reg_levels)
	if td.has_regional():
		var r := td.reg_grid
		material.set_shader_parameter("reg_tex", td.reg_tex)
		material.set_shader_parameter("reg_lin", td.reg_tex)
		material.set_shader_parameter("reg_rect", Vector4(r.x_min, r.y_max, r.width * r.res, r.height * r.res))
		material.set_shader_parameter("reg_res", r.res)
		material.set_shader_parameter("reg_dims", Vector2i(r.width, r.height))
		material.set_shader_parameter("reg_offset", td.reg_offset)
		material.set_shader_parameter("has_regional", true)
	else:
		material.set_shader_parameter("reg_tex", td.dem_tex)
		material.set_shader_parameter("reg_lin", td.dem_tex)
		material.set_shader_parameter("has_regional", false)
	if normal_map:
		material.set_shader_parameter("normal_tex", normal_map)
		material.set_shader_parameter("has_normal_map", true)
	if albedo:
		material.set_shader_parameter("albedo_tex", albedo)
	if albedo_reg:
		material.set_shader_parameter("albedo_reg_tex", albedo_reg)
	elif albedo:
		material.set_shader_parameter("albedo_reg_tex", albedo)
	if albedo and albedo_reg and td.has_regional():
		var tint := match_reg_tint(albedo, albedo_reg, td)
		if tint != Vector3.ZERO:
			material.set_shader_parameter("reg_tint", tint)
	var detail := detail_textures()
	material.set_shader_parameter("detail_nrm", detail[0])
	material.set_shader_parameter("detail_val", detail[1])
	material_override = material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	custom_aabb = AABB(Vector3(-70000, -8000, -70000), Vector3(140000, 20000, 140000))
	extra_cull_margin = 16384.0


## The regional imagery is greyscale CTX coloured with reg_tint. One fixed tint suits Gale but leaves Jezero's pale
## HiRISE site as a square pasted on orange ground, so match it to each site: the mean HiRISE colour in a band just
## inside the site's edge (colour swath only, no grey strips or holes) over the mean CTX brightness of the same
## ground, both in linear light as the shader sees them. Vector3.ZERO if it cannot be measured.
static func match_reg_tint(albedo: Texture2D, albedo_reg: Texture2D, td: TerrainData) -> Vector3:
	var si := albedo.get_image()
	var ri := albedo_reg.get_image()
	if si == null or ri == null or si.is_empty() or ri.is_empty():
		return Vector3.ZERO
	if si.is_compressed():
		si.decompress()
	if ri.is_compressed():
		ri.decompress()
	var g := td.grid
	var r := td.reg_grid
	var w := g.width * g.res
	var h := g.height * g.res
	var sum_s := Vector3.ZERO
	var sum_r := 0.0
	var n := 0
	var count := 800
	for k in count:
		var t := float(k) / float(count)
		var inset := lerpf(0.03, 0.09, fposmod(k * 0.618034, 1.0))   # spread across the band
		var uv := Vector2(t, inset)
		match k % 4:
			1:
				uv = Vector2(1.0 - inset, t)
			2:
				uv = Vector2(t, 1.0 - inset)
			3:
				uv = Vector2(inset, t)
		var cs := si.get_pixel(int(uv.x * (si.get_width() - 1)), int(uv.y * (si.get_height() - 1))).srgb_to_linear()
		var lum := cs.r * 0.2126 + cs.g * 0.7152 + cs.b * 0.0722
		var sat := maxf(cs.r, maxf(cs.g, cs.b)) - minf(cs.r, minf(cs.g, cs.b))
		if lum < 0.004 or sat < 0.01:
			continue   # a no-data hole, or a grey strip the shader recolours with site_tint
		var x := g.x_min + uv.x * w
		var y := g.y_max - uv.y * h
		var ru := (x - r.x_min) / (r.width * r.res)
		var rv := (r.y_max - y) / (r.height * r.res)
		if ru < 0.0 or ru > 1.0 or rv < 0.0 or rv > 1.0:
			continue
		var cr := ri.get_pixel(int(ru * (ri.get_width() - 1)), int(rv * (ri.get_height() - 1))).srgb_to_linear()
		var l := (cr.r + cr.g + cr.b) / 3.0
		if l < 0.004:
			continue
		sum_s += Vector3(cs.r, cs.g, cs.b)
		sum_r += l
		n += 1
	if n < 80 or sum_r <= 0.0:
		return Vector3.ZERO
	var m := sum_s / sum_r
	# most of the way to the match (the seam goes), not all of it: a pale site would otherwise wash out the whole
	# crater round it. 30 % of the hand-set tint that suits Gale, in log space, keeps the colours warm.
	var base := Vector3(1.5, 0.8, 0.52)
	var tint := Vector3(pow(base.x, 0.3) * pow(m.x, 0.7), pow(base.y, 0.3) * pow(m.y, 0.7), pow(base.z, 0.3) * pow(m.z, 0.7))
	var top := maxf(tint.x, maxf(tint.y, tint.z))
	if top > 3.0:
		tint *= 3.0 / top   # keep the hue when it is too bright
	print("terrain: regional tint matched to the site edge (%d samples): measured %s, used %s" % [n, str(m), str(tint)])
	return Vector3(maxf(tint.x, 0.3), maxf(tint.y, 0.3), maxf(tint.z, 0.3))


## Two small tiling noise textures for the close-up ground detail (sand ripples, grain, knobbly
## bedrock). The shader used to compute value noise and its gradient per pixel (about 50 hashes); a
## texture fetch at each scale gives the same kind of detail for a fraction of the cost on an iGPU.
## [0] normal map of Perlin noise (xy = slope of the bumps), [1] value noise. 32 noise cells per tile.
static func detail_textures() -> Array:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_PERLIN
	n.seed = 7
	n.frequency = 1.0 / 8.0          # 8 px per noise cell -> 32 cells across 256 px
	n.fractal_type = FastNoiseLite.FRACTAL_NONE
	var bump := n.get_seamless_image(256, 256)
	bump.convert(Image.FORMAT_RGBA8)
	bump.bump_map_to_normal_map(6.0)
	bump.generate_mipmaps()
	var v := FastNoiseLite.new()
	v.noise_type = FastNoiseLite.TYPE_VALUE_CUBIC
	v.seed = 11
	v.frequency = 1.0 / 8.0
	v.fractal_type = FastNoiseLite.FRACTAL_NONE
	var val := v.get_seamless_image(256, 256)
	val.generate_mipmaps()
	return [ImageTexture.create_from_image(bump), ImageTexture.create_from_image(val)]


static func growth_for(n: int) -> float:
	var m := n - CORE
	var lo := 1.0001
	var hi := 1.5
	for i in 60:
		var r := (lo + hi) * 0.5
		var total := CORE + r * (pow(r, m) - 1.0) / (r - 1.0)
		if total > REACH:
			hi = r
		else:
			lo = r
	return (lo + hi) * 0.5


static func offsets(n: int) -> PackedFloat32Array:
	var g := growth_for(n)
	var o := PackedFloat32Array()
	o.resize(n + 1)
	var s := 0.0
	for i in range(1, n + 1):
		s += 1.0 if i <= CORE else pow(g, i - CORE)
		o[i] = s
	return o


func _make_mesh() -> ArrayMesh:
	var N := n_half
	var off := offsets(N)
	var side := 2 * N + 1
	var coords := PackedFloat32Array()
	var spacing := PackedFloat32Array()
	coords.resize(side)
	spacing.resize(side)
	for i in side:
		var k := i - N
		var a := absi(k)
		coords[i] = signf(k) * off[a]
		spacing[i] = (off[a + 1] - off[a]) if a < N else (off[N] - off[N - 1])
	var count := side * side
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	verts.resize(count)
	uvs.resize(count)
	normals.resize(count)
	var idx := 0
	for j in side:
		var z := coords[j]
		var sz := spacing[j]
		for i in side:
			verts[idx] = Vector3(coords[i], 0.0, z)
			uvs[idx] = Vector2(maxf(spacing[i], sz), 0.0)
			normals[idx] = Vector3.UP
			idx += 1
	var tris := PackedInt32Array()
	tris.resize((side - 1) * (side - 1) * 6)
	var t := 0
	for j in side - 1:
		var row := j * side
		for i in side - 1:
			var a := row + i
			var c := a + side
			tris[t] = a
			tris[t + 1] = a + 1
			tris[t + 2] = c
			tris[t + 3] = a + 1
			tris[t + 4] = c + 1
			tris[t + 5] = c
			t += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = tris
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


## Re-centre under the camera. In orbit view the whole grid is scaled by a power of two
## that follows the camera's height, so vertex density tracks pixel size.
func follow(cam_pos: Vector3, ground_y: float) -> void:
	var k := 1.0
	var kc := 1.0
	if not walk_mode:
		var above := maxf(1.0, cam_pos.y - ground_y)
		k = clampf(pow(2.0, floor(log(above / 260.0) / log(2.0))), 1.0, 64.0)
		kc = clampf(above / 260.0, 1.0, 64.0)
	lod_scale = k
	# the height filter follows the camera height smoothly, so the x2 mesh steps don't pop
	if material and absf(kc - _lod_k) > _lod_k * 0.01:
		_lod_k = kc
		material.set_shader_parameter("lod_k", kc)
	var snap := k
	var p := Vector3(snappedf(cam_pos.x, snap), 0.0, snappedf(cam_pos.z, snap))
	transform = Transform3D(Basis.from_scale(Vector3(k, 1.0, k)), p)


func set_param(name: String, value: Variant) -> void:
	if material:
		material.set_shader_parameter(name, value)
