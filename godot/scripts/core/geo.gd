class_name Geo
extends RefCounted
## Local metric grid for a small Mars site — the same projection as marsgeo/grid.py:
##     x = R cos(lat0) (lon - lon0)    (metres east of the site centre)
##     y = R (lat - lat0)              (metres north of the site centre)
## World space in Godot: X = x (east), Z = -y (north is -Z), Y = elevation - elev_ref.

const MARS_R := 3396190.0

var lon0 := 0.0
var lat0 := 0.0
var x_min := 0.0
var y_max := 0.0
var res := 1.0
var width := 1
var height := 1
var kx := 1.0
var ky := 1.0


static func from_dict(d: Dictionary) -> Geo:
	var g := Geo.new()
	g.lon0 = float(d["lon0"])
	g.lat0 = float(d["lat0"])
	g.x_min = float(d["x_min"])
	g.y_max = float(d["y_max"])
	g.res = float(d["res"])
	g.width = int(d["width"])
	g.height = int(d["height"])
	g.kx = MARS_R * cos(deg_to_rad(g.lat0)) * PI / 180.0
	g.ky = MARS_R * PI / 180.0
	return g


func x_max() -> float:
	return x_min + width * res


func y_min() -> float:
	return y_max - height * res


func size_m() -> Vector2:
	return Vector2(width * res, height * res)


func center_xy() -> Vector2:
	return Vector2(x_min + width * res * 0.5, y_max - height * res * 0.5)


func to_xy(lon: float, lat: float) -> Vector2:
	return Vector2((lon - lon0) * kx, (lat - lat0) * ky)


func to_lonlat(x: float, y: float) -> Vector2:
	return Vector2(lon0 + x / kx, lat0 + y / ky)


## Fractional (col, row) where integers are pixel centres.
func xy_to_cr(x: float, y: float) -> Vector2:
	return Vector2((x - x_min) / res - 0.5, (y_max - y) / res - 0.5)


func contains_xy(x: float, y: float, margin := 0.0) -> bool:
	return x >= x_min + margin and x <= x_max() - margin and y <= y_max - margin and y >= y_min() + margin


## Texture UV (0..1, v down = south) of a site point.
func uv(x: float, y: float) -> Vector2:
	return Vector2((x - x_min) / (width * res), (y_max - y) / (height * res))


static func world(xy: Vector2, h: float) -> Vector3:
	return Vector3(xy.x, h, -xy.y)


static func xy_of(p: Vector3) -> Vector2:
	return Vector2(p.x, -p.z)


static func bearing_deg(from_xy: Vector2, to_xy: Vector2) -> float:
	var d := to_xy - from_xy
	return fposmod(rad_to_deg(atan2(d.x, d.y)), 360.0)


static func compass(b: float) -> String:
	var names := ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
	return str(names[int(round(fposmod(b, 360.0) / 22.5)) % 16])


static func fmt_dist(m: float) -> String:
	if absf(m) >= 1000.0:
		return "%.2f km" % (m / 1000.0)
	return "%d m" % int(round(m))


## Linear interpolation in sorted xs -> ys (clamped). Arrays are plain Arrays from JSON.
static func interp(xs: Array, ys: Array, x: float) -> float:
	var n := xs.size()
	if n == 0:
		return 0.0
	if x <= float(xs[0]):
		return _num(ys[0])
	if x >= float(xs[n - 1]):
		return _num(ys[n - 1])
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if float(xs[mid]) <= x:
			lo = mid
		else:
			hi = mid
	var x0 := float(xs[lo])
	var x1 := float(xs[hi])
	var f := 0.0 if x1 == x0 else (x - x0) / (x1 - x0)
	if ys[lo] == null:
		return _num(ys[hi])
	if ys[hi] == null:
		return _num(ys[lo])
	return lerpf(float(ys[lo]), float(ys[hi]), f)


## Index of the last xs[i] <= x.
static func bisect(xs: Array, x: float) -> int:
	var n := xs.size()
	if n == 0 or x < float(xs[0]):
		return 0
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if float(xs[mid]) <= x:
			lo = mid
		else:
			hi = mid
	return hi if x >= float(xs[hi]) else lo


static func _num(v) -> float:
	return 0.0 if v == null else float(v)
