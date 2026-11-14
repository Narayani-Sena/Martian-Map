class_name TerrainData
extends RefCounted
## CPU copies of the elevation models plus the safety grids used by the helmet HUD.
## The same arrays are uploaded as R32F textures and displaced on the GPU (see terrain.gdshader),
## so what the walker stands on here is exactly what is drawn.

var grid: Geo                     # 1 m site grid
var dem := PackedFloat32Array()   # absolute elevation (m), row 0 = north
var reg_grid: Geo                 # 200 m regional grid (Mount Sharp, crater floor)
var reg := PackedFloat32Array()
var reg_offset := 0.0             # regional datum shift onto the HiRISE DTM
var elev_ref := 0.0               # world Y = elevation - elev_ref
var edge_blend := 90.0

var dem_tex: ImageTexture
var reg_tex: ImageTexture

# Safety grids (filled after a plan): name -> {"g": Geo, "data": Packed*Array, "kind": "f32"|"u8"}
var layers := {}

# Boulders detected from HiRISE shadows: rows of (x, y, diameter, height); bucketed by 32 m chunk.
const BOULDER_CHUNK := 32.0
var boulders := PackedFloat32Array()
var boulder_chunks := {}


func set_boulders(bytes: PackedByteArray) -> void:
	boulders = bytes.to_float32_array()
	boulder_chunks.clear()
	var n := boulders.size() / 4
	for i in n:
		var key := Vector2i(int(floor(boulders[i * 4] / BOULDER_CHUNK)), int(floor(boulders[i * 4 + 1] / BOULDER_CHUNK)))
		if not boulder_chunks.has(key):
			boulder_chunks[key] = PackedInt32Array()
		var arr: PackedInt32Array = boulder_chunks[key]
		arr.append(i)
		boulder_chunks[key] = arr


## Boulders whose centre lies in a 32 m chunk: Array of Vector4(x, y, diameter, height).
func boulders_in(key: Vector2i) -> Array:
	var out := []
	if boulder_chunks.has(key):
		for i in (boulder_chunks[key] as PackedInt32Array):
			out.append(Vector4(boulders[i * 4], boulders[i * 4 + 1], boulders[i * 4 + 2], boulders[i * 4 + 3]))
	return out


## The height models go to the GPU with mipmaps (averaged heights): coarse clipmap vertices sample the
## level that matches their spacing, so distant terrain is a smoothed surface instead of point samples
## of 1 m detail that shimmer as the grid slides (see terrain.gdshader height_lod).
var dem_levels := 0
var reg_levels := 0


## The heavy part (float copy, image, mipmaps: ~300 ms for Gale) is thread-safe and runs on a worker
## (Mission.load_terrain); only the texture upload in finish_*() happens on the main thread.
func prepare_dem(bytes: PackedByteArray, g: Geo) -> Image:
	grid = g
	dem = bytes.to_float32_array()
	var img := Image.create_from_data(g.width, g.height, false, Image.FORMAT_RF, bytes)
	img.generate_mipmaps()
	dem_levels = img.get_mipmap_count()
	return img


func finish_dem(img: Image) -> void:
	dem_tex = ImageTexture.create_from_image(img)


func prepare_regional(bytes: PackedByteArray, g: Geo, offset: float) -> Image:
	reg_grid = g
	reg = bytes.to_float32_array()
	reg_offset = offset
	var img := Image.create_from_data(g.width, g.height, false, Image.FORMAT_RF, bytes)
	img.generate_mipmaps()
	reg_levels = img.get_mipmap_count()
	return img


func finish_regional(img: Image) -> void:
	reg_tex = ImageTexture.create_from_image(img)


func set_dem(bytes: PackedByteArray, g: Geo) -> void:
	finish_dem(prepare_dem(bytes, g))


func set_regional(bytes: PackedByteArray, g: Geo, offset: float) -> void:
	finish_regional(prepare_regional(bytes, g, offset))


func has_regional() -> bool:
	return reg.size() > 0


static func _bilinear(arr: PackedFloat32Array, w: int, h: int, c: float, r: float) -> float:
	var c0 := clampi(int(floor(c)), 0, w - 1)
	var r0 := clampi(int(floor(r)), 0, h - 1)
	var c1 := mini(c0 + 1, w - 1)
	var r1 := mini(r0 + 1, h - 1)
	var fc := clampf(c - floor(c), 0.0, 1.0)
	var fr := clampf(r - floor(r), 0.0, 1.0)
	var a := arr[r0 * w + c0]
	var b := arr[r0 * w + c1]
	var cc := arr[r1 * w + c0]
	var d := arr[r1 * w + c1]
	return lerpf(lerpf(a, b, fc), lerpf(cc, d, fc), fr)


func dem_h(x: float, y: float) -> float:
	var cr := grid.xy_to_cr(x, y)
	return _bilinear(dem, grid.width, grid.height, cr.x, cr.y)


func reg_h(x: float, y: float) -> float:
	var cr := reg_grid.xy_to_cr(x, y)
	return _bilinear(reg, reg_grid.width, reg_grid.height, cr.x, cr.y) + reg_offset


func inside_w(x: float, y: float) -> float:
	var dx := minf(x - grid.x_min, grid.x_max() - x)
	var dy := minf(grid.y_max - y, y - grid.y_min())
	return clampf(minf(dx, dy) / edge_blend, 0.0, 1.0)


## Absolute elevation (m) — HiRISE inside the site, blended into the regional model outside.
func height_abs(x: float, y: float) -> float:
	if dem.is_empty():
		return elev_ref
	var w := inside_w(x, y)
	if w >= 1.0 or not has_regional():
		return dem_h(x, y)
	var r := reg_h(x, y)
	if w <= 0.0:
		return r
	return lerpf(r, dem_h(x, y), smoothstep(0.0, 1.0, w))


## World-space height (Y) at a site point.
func h(x: float, y: float) -> float:
	return height_abs(x, y) - elev_ref


func world_at(xy: Vector2, lift := 0.0) -> Vector3:
	return Vector3(xy.x, h(xy.x, xy.y) + lift, -xy.y)


## Surface slope (deg) from a centred difference over `e` metres.
func slope_deg(x: float, y: float, e := 1.5) -> float:
	var dx := (height_abs(x + e, y) - height_abs(x - e, y)) / (2.0 * e)
	var dy := (height_abs(x, y + e) - height_abs(x, y - e)) / (2.0 * e)
	return rad_to_deg(atan(sqrt(dx * dx + dy * dy)))


## March a ray against the height field. Returns the hit (world space) or Vector3.INF.
func raycast(origin: Vector3, dir: Vector3, max_dist := 120000.0) -> Vector3:
	if dem.is_empty():
		return Vector3.INF
	var t := 0.0
	var prev_t := 0.0
	var p := origin
	var above := p.y - h(p.x, -p.z)
	if above < 0.0:
		return Vector3.INF
	while t < max_dist:
		var step := clampf(above * 0.5, 0.5, 400.0)
		prev_t = t
		t += step
		p = origin + dir * t
		above = p.y - h(p.x, -p.z)
		if above <= 0.0:
			var lo := prev_t
			var hi := t
			for i in 18:
				var mid := (lo + hi) * 0.5
				var q := origin + dir * mid
				if q.y - h(q.x, -q.z) > 0.0:
					lo = mid
				else:
					hi = mid
			var hit := origin + dir * hi
			hit.y = h(hit.x, -hit.z)
			return hit
	return Vector3.INF


# ------------------------------------------------------------------ safety grids
func set_layer(name: String, bytes: PackedByteArray, g: Geo, kind: String) -> void:
	var data: Variant = bytes.to_float32_array() if kind == "f32" else bytes
	layers[name] = {"g": g, "data": data, "kind": kind}


func has_layer(name: String) -> bool:
	return layers.has(name)


## Nearest-cell value of a safety grid; `fallback` outside the site or when not loaded.
func layer_value(name: String, x: float, y: float, fallback := -1.0) -> float:
	if not layers.has(name):
		return fallback
	var L: Dictionary = layers[name]
	var g: Geo = L["g"]
	var cr := g.xy_to_cr(x, y)
	var c := int(round(cr.x))
	var r := int(round(cr.y))
	if c < 0 or r < 0 or c >= g.width or r >= g.height:
		return fallback
	var i := r * g.width + c
	if L["kind"] == "f32":
		var a: PackedFloat32Array = L["data"]
		return a[i]
	var b: PackedByteArray = L["data"]
	return float(b[i])
