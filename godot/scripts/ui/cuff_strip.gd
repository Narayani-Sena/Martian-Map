class_name CuffStrip
extends Control
## The route unrolled on the cuff (feature D3): the next 250 m as a straight strip, the way a rally co-driver reads
## a roadbook. Bands above the line mark radio shadow, terrain shade and hazardous ground at their distance; on the
## line, the co-driver's pace notes (boulders on their side, turns, climbs and descents) and the next station.
## You are the triangle at the left; the strip scrolls as you walk.

const SPAN_M := 250.0
const BEHIND_M := 15.0

var tools: HelmetTools


func _init() -> void:
	custom_minimum_size = Vector2(286, 74)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		queue_redraw()


func _x(d: float, me: float) -> float:
	return (d - (me - BEHIND_M)) / SPAN_M * size.x


func _draw() -> void:
	var w := size.x
	var hud := Color(0.55, 0.95, 1.0)
	var dim := Color(0.55, 0.95, 1.0, 0.45)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.03, 0.05, 0.55))
	var font := UiKit.symbols()
	if tools == null or not is_finite(tools.along) or not Mission.has_plan():
		draw_string(font, Vector2(8, 40), "STRIP MAP · walk the route to see what is ahead", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, dim)
		return
	var me := tools.along
	var prof: Dictionary = Mission.plan.get("profile", {})
	var pd: Array = prof.get("d", [])
	var haz: Array = prof.get("hazard", [])
	var comms: Array = prof.get("comms", [])
	var sun: Array = prof.get("sunlit", [])
	var working: Array = prof.get("working", [])
	var rows := [["RADIO", 4.0, Color(0.62, 0.66, 0.72, 0.85)], ["SHADE", 13.0, Color(0.25, 0.4, 0.95, 0.85)],
		["HAZARD", 22.0, Color(1.0, 0.62, 0.2, 0.9)]]
	for r in rows:
		draw_string(font, Vector2(4, float(r[1]) + 7.0), str(r[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, 8, dim)
	var x_lo := 46.0
	# bands: one segment per profile step inside the window
	for k in range(1, pd.size()):
		var d0 := float(pd[k - 1])
		var d1 := float(pd[k])
		if d1 < me - BEHIND_M or d1 <= d0:
			continue
		if d0 > me - BEHIND_M + SPAN_M:
			break
		var x0 := maxf(_x(d0, me), x_lo)
		var x1 := minf(_x(d1, me), w)
		if x1 <= x0:
			continue
		if k < comms.size() and comms[k] != null and int(comms[k]) == 0:
			draw_rect(Rect2(x0, 4.0, x1 - x0, 7.0), rows[0][2])
		if k < sun.size() and sun[k] != null and int(sun[k]) == 0:
			draw_rect(Rect2(x0, 13.0, x1 - x0, 7.0), rows[1][2])
		if k < haz.size() and haz[k] != null and int(haz[k]) >= 2:
			draw_rect(Rect2(x0, 22.0, x1 - x0, 7.0), rows[2][2] if int(haz[k]) == 2 else Color(1.0, 0.3, 0.35, 0.95))
	# the route line and a tick every 50 m
	var y := 46.0
	draw_line(Vector2(x_lo, y), Vector2(w - 2.0, y), hud, 2.0)
	var t := ceilf((me - BEHIND_M) / 50.0) * 50.0
	while t <= me - BEHIND_M + SPAN_M:
		var x := _x(t, me)
		if x >= x_lo:
			draw_line(Vector2(x, y - 3.0), Vector2(x, y + 3.0), dim, 1.0)
			var lab := "+%d" % int(round(t - me))
			if absf(t - me) > 12.0:
				draw_string(font, Vector2(x - 10.0, y + 26.0), lab, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, dim)
		t += 50.0
	# the next station: where the profile starts working
	for k in range(1, pd.size()):
		if k < working.size() and bool(working[k]) and not bool(working[k - 1]):
			var ds := float(pd[k])
			if ds > me - 2.0 and ds < me - BEHIND_M + SPAN_M:
				var xs := _x(ds, me)
				if xs >= x_lo:
					draw_line(Vector2(xs, y - 12.0), Vector2(xs, y + 2.0), Color(1.0, 0.86, 0.5), 2.0)
					draw_string(font, Vector2(xs + 2.0, y - 4.0), "⚑ STA", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1.0, 0.86, 0.5))
				break
	# pace notes on the line: boulders on their side, turns, climbs and descents
	for n in tools.notes():
		var dn := float(n["d"])
		if dn < me - BEHIND_M:
			continue
		if dn > me - BEHIND_M + SPAN_M:
			break
		var xn := _x(dn, me)
		if xn < x_lo:
			continue
		var txt := str(n["text"]).to_lower()
		var glyph := "•"
		var col := hud
		var dy := 0.0
		if txt.contains("boulder"):
			glyph = "◆"
			col = Color(1.0, 0.72, 0.35)
			dy = -8.0 if txt.contains(" left") else 8.0
		elif txt.contains("turn") or txt.contains("bear") or txt.contains("hairpin"):
			glyph = "↰" if txt.contains("left") else "↱"
		elif txt.contains("up") or txt.contains("climb"):
			glyph = "▲"
			col = Color(1.0, 0.86, 0.5)
		elif txt.contains("down") or txt.contains("descen"):
			glyph = "▼"
			col = Color(0.6, 0.85, 1.0)
		elif txt.contains("sand"):
			glyph = "≈"
			col = Color(1.0, 0.8, 0.45)
		draw_string(font, Vector2(xn - 5.0, y + 5.0 + dy), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)
	# you
	var xm := _x(me, me)
	draw_colored_polygon(PackedVector2Array([Vector2(xm - 6, y + 9), Vector2(xm + 6, y + 9), Vector2(xm, y + 1)]), Color.WHITE)
	draw_string(font, Vector2(4, y + 26.0), "STRIP", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, dim)
