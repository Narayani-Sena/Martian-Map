class_name MarsTime
extends RefCounted
## Mars24 sun clock (Allison & McEwen 2000).
## GDScript twin of marsgeo/mars24.py and web/src/lib/mars24.js, so all three clients agree.
## Longitudes are east-positive; azimuth is clockwise from north.

const TT_MINUS_UTC := 69.184
const SOL_DAYS := 1.0274912517
const SOL_SECONDS := SOL_DAYS * 86400.0
const PBS := [
	[0.0071, 2.2353, 49.409], [0.0057, 2.7543, 168.173], [0.0039, 1.1177, 191.837], [0.0037, 15.7866, 21.736],
	[0.0021, 2.1354, 15.704], [0.002, 2.4694, 95.528], [0.0018, 32.8493, 49.095],
]


## Mars time quantities for a Unix timestamp (seconds, UTC).
static func at(unix: float) -> Dictionary:
	var jd_ut := 2440587.5 + unix / 86400.0
	var jd_tt := jd_ut + TT_MINUS_UTC / 86400.0
	var d := jd_tt - 2451545.0
	var m := fposmod(19.3871 + 0.52402073 * d, 360.0)
	var a_fms := fposmod(270.3871 + 0.524038496 * d, 360.0)
	var pbs := 0.0
	for p in PBS:
		pbs += float(p[0]) * cos(deg_to_rad(0.985626 * d / float(p[1]) + float(p[2])))
	var mr := deg_to_rad(m)
	var nu_m := (10.691 + 3e-7 * d) * sin(mr) + 0.623 * sin(2.0 * mr) + 0.05 * sin(3.0 * mr) \
		+ 0.005 * sin(4.0 * mr) + 0.0005 * sin(5.0 * mr) + pbs
	var ls := fposmod(a_fms + nu_m, 360.0)
	var lsr := deg_to_rad(ls)
	var eot := 2.861 * sin(2.0 * lsr) - 0.071 * sin(4.0 * lsr) + 0.002 * sin(6.0 * lsr) - nu_m
	var msd := (jd_tt - 2451549.5) / SOL_DAYS + 44796.0 - 0.0009626
	var mtc := fposmod(24.0 * msd, 24.0)
	var decl := rad_to_deg(asin(0.42565 * sin(lsr))) + 0.25 * sin(lsr)
	var helio := 1.5236 * (1.00436 - 0.09309 * cos(mr) - 0.004336 * cos(2.0 * mr) - 0.00031 * cos(3.0 * mr) - 0.00003 * cos(4.0 * mr))
	var frac := fposmod((jd_tt - 2435208.5) / 686.9725, 1.0)
	var my := int(floor((jd_tt - 2435208.5) / 686.9725 + 1.0))
	if ls > 300.0 and frac < 0.1:
		my -= 1
	if ls < 60.0 and frac > 0.9:
		my += 1
	return {"jd_ut": jd_ut, "msd": msd, "mtc": mtc, "ls": ls, "eot": eot, "decl": decl, "helio": helio, "mars_year": my}


static func lmst(mt: Dictionary, lon: float) -> float:
	return fposmod(float(mt["mtc"]) + lon / 15.0, 24.0)


static func ltst(mt: Dictionary, lon: float) -> float:
	return fposmod(float(mt["mtc"]) + lon / 15.0 + float(mt["eot"]) / 15.0, 24.0)


## Returns Vector2(elevation_deg, azimuth_deg).
static func sun_position(mt: Dictionary, lat: float, lon: float) -> Vector2:
	var h := deg_to_rad((ltst(mt, lon) - 12.0) * 15.0)
	var phi := deg_to_rad(lat)
	var dec := deg_to_rad(float(mt["decl"]))
	var sin_alt := sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(h)
	var alt := rad_to_deg(asin(clampf(sin_alt, -1.0, 1.0)))
	var az := rad_to_deg(atan2(-cos(dec) * sin(h), sin(dec) * cos(phi) - cos(dec) * sin(phi) * cos(h)))
	return Vector2(alt, fposmod(az, 360.0))


## Unit vector toward the sun in world space (x east, y up, z south — Godot's -Z is north).
static func sun_vector(elev_deg: float, az_deg: float) -> Vector3:
	var el := deg_to_rad(elev_deg)
	var az := deg_to_rad(az_deg)
	return Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el)).normalized()


## Vector2(sunrise_ltst, sunset_ltst) in hours, or Vector2(-1, -1) during polar day/night.
static func sunrise_sunset(mt: Dictionary, lat: float, horizon_deg := -0.25) -> Vector2:
	var phi := deg_to_rad(lat)
	var dec := deg_to_rad(float(mt["decl"]))
	var c := (sin(deg_to_rad(horizon_deg)) - sin(phi) * sin(dec)) / (cos(phi) * cos(dec))
	if c <= -1.0 or c >= 1.0:
		return Vector2(-1.0, -1.0)
	var h0 := rad_to_deg(acos(c)) / 15.0
	return Vector2(12.0 - h0, 12.0 + h0)


## The UTC (unix) nearest to `unix` at which local true solar time equals target_h.
static func utc_for_ltst(unix: float, lon: float, target_h: float) -> float:
	var t := unix
	for i in 8:
		var cur := ltst(at(t), lon)
		var diff := fposmod(target_h - cur + 12.0, 24.0) - 12.0
		if absf(diff) < 1e-5:
			break
		t += diff * 3600.0 * SOL_DAYS
	return t


static func mission_sol(mt: Dictionary, lon: float, landing_msd: float) -> int:
	return int(floor(float(mt["msd"]) + lon / 360.0) - landing_msd)


static func season(ls: float, lat: float) -> String:
	var north := ["spring", "summer", "autumn", "winter"]
	var south := ["autumn", "winter", "spring", "summer"]
	var i := int(floor(ls / 90.0)) % 4
	return str(north[i]) if lat >= 0.0 else str(south[i])


static func hms(hours: float, with_seconds := true) -> String:
	var s := int(round(fposmod(hours, 24.0) * 3600.0))
	var h := int(s / 3600.0)
	s -= h * 3600
	var m := int(s / 60.0)
	s -= m * 60
	if with_seconds:
		return "%02d:%02d:%02d" % [h % 24, m, s]
	return "%02d:%02d" % [h % 24, m]


## Duration in seconds -> "1 h 05 min" / "12 min" / "45 s".
static func dur(seconds: float) -> String:
	var s := absf(seconds)
	if s < 60.0:
		return "%d s" % int(round(s))
	var m := int(round(s / 60.0))
	if m < 60:
		return "%d min" % m
	return "%d h %02d min" % [int(m / 60.0), m % 60]


## Seconds -> "T+01:23:45".
static func clock(seconds: float, prefix := "T+") -> String:
	var s := int(maxf(0.0, seconds))
	return "%s%02d:%02d:%02d" % [prefix, int(s / 3600.0), int(s / 60.0) % 60, s % 60]


## ISO-8601 (as the API returns it) -> unix seconds. Handles fractions and +hh:mm / Z.
static func parse_iso(s: String) -> float:
	if s.length() < 19:
		return 0.0
	var dt := {
		"year": s.substr(0, 4).to_int(), "month": s.substr(5, 2).to_int(), "day": s.substr(8, 2).to_int(),
		"hour": s.substr(11, 2).to_int(), "minute": s.substr(14, 2).to_int(), "second": s.substr(17, 2).to_int(),
	}
	var t := float(Time.get_unix_time_from_datetime_dict(dt))
	var rest := s.substr(19)
	if rest.begins_with("."):
		var j := 1
		while j < rest.length() and rest[j] >= "0" and rest[j] <= "9":
			j += 1
		t += ("0" + rest.substr(0, j)).to_float()
		rest = rest.substr(j)
	if rest.length() >= 6 and (rest[0] == "+" or rest[0] == "-"):
		var off := rest.substr(1, 2).to_int() * 3600 + rest.substr(4, 2).to_int() * 60
		t -= off if rest[0] == "+" else -off
	return t


static func to_iso(unix: float) -> String:
	return Time.get_datetime_string_from_unix_time(int(unix), false) + "Z"
