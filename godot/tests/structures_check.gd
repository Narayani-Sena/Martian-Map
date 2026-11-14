extends SceneTree
## Walking round the habitat and its solar field (MarsWorld.outside_structures), without the app: a crew member
## starts all round the habitat and heads for points all round beyond it, moving each frame by the autopilot's
## rule (walker.gd); every walk must stay out of the models and get there. A target inside the habitat or a rover
## must end at its door (the airlock, the suitports), one inside the solar field at its edge; abort routes built by
## route_around_structures must stay out of the models and end at the airlock door. Prints one line per failure and a summary; exit code 1 on any failure.
##   godot --headless --path godot --script res://tests/structures_check.gd [-- --case=<start deg>,<target deg>]
## --case traces one walk (start and target directions from the habitat's centre, degrees).

const DT := 1.0 / 30.0


var W: GDScript   # world.gd, loaded once the autoloads it uses exist


func _initialize() -> void:
	W = load("res://scripts/world/world.gd")
	var w = W.new()
	w.obstacles.clear()
	w.add_habitat_obstacles(Vector2.ZERO)
	# PR-2 parked to the north (as at a drop-off: an abort to it ends at its centre) and Curiosity to the north-west
	var pr := Vector2(0.0, 45.0)
	w._rover_capsule(w._add_obstacle("PR-2", pr, pr, 2.3, Vector2.RIGHT), pr, deg_to_rad(35.0))
	w._add_obstacle("Curiosity", Vector2(-40.0, 30.0), Vector2(-40.0, 30.0), 2.1, Vector2.RIGHT)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--case="):
			var ab := arg.trim_prefix("--case=").split(",")
			var st := _free_spot(w, Vector2.from_angle(deg_to_rad(float(ab[0]))))
			_walk(w, st, Vector2.from_angle(deg_to_rad(float(ab[1]))) * 70.0, 20.0, true)
			w.free()
			quit(0)
			return
	var bad := 0
	var stuck := 0
	var walks := 0
	var worst := INF
	var longest := 0.0
	for i in 24:
		var a0 := TAU * i / 24.0
		var start := _free_spot(w, Vector2.from_angle(a0))
		for j in 24:
			var a1 := TAU * j / 24.0
			var target := Vector2.from_angle(a1) * 70.0
			var r := _walk(w, start, target, 240.0)
			walks += 1
			worst = minf(worst, r["min_clear"])
			longest = maxf(longest, r["t"])
			if not r["arrived"] or r["min_clear"] < -0.1:
				bad += 1
				if not r["arrived"]:
					stuck += 1
				if bad <= 6 or (not r["arrived"] and stuck <= 6):
					print("FAIL start %3d deg -> target %3d deg: arrived %s after %.0f s, ended %.1f m away, least clearance %.2f m" % [
						int(rad_to_deg(a0)), int(rad_to_deg(a1)), r["arrived"], r["t"], r["left"], r["min_clear"]])
	# from far out (an abort, or catching up with the plan at high speed) to the habitat's centre and beyond it
	var far_bad := 0
	var far_longest := 0.0
	for i in 24:
		var start := Vector2.from_angle(TAU * i / 24.0) * 150.0
		for target in [Vector2.ZERO, -start * 0.5]:
			var r := _walk(w, start, target, 300.0)
			var home: bool = target == Vector2.ZERO
			var c: float = w.structure_clearance(r["end"])
			far_longest = maxf(far_longest, r["t"])
			# a lope straight in (3 m/s and up) and a walk round the habitat (~45 s): not a slow spiral from far out
			if r["min_clear"] < -0.1 or (home and r["end"].distance_to(_door_of(w, target)) > 0.3) or (not home and not r["arrived"]) or r["t"] > 75.0:
				far_bad += 1
				print("FAIL from 150 m at %3d deg to %s: least clearance %.2f m, after %.0f s %.1f m outside a wall, %.1f m from the target" % [
					int(rad_to_deg(TAU * i / 24.0)), "the habitat's centre" if home else "beyond it", r["min_clear"], r["t"], c, r["left"]])
	# abort routes: straight from 150 m all round to the habitat's centre, kept out of the models; every metre of the
	# ribbon must be outside them and it must end at the airlock door
	var route_bad := 0
	var route_longest := 0.0
	for i in 24:
		var start := Vector2.from_angle(TAU * i / 24.0) * 150.0
		var rt: PackedVector2Array = w.route_around_structures(PackedVector2Array([start, start * 0.5, Vector2.ZERO]))
		var worst_r := INF
		var length := 0.0
		for k in range(1, rt.size()):
			length += rt[k - 1].distance_to(rt[k])
			for f in 6:
				worst_r = minf(worst_r, w.structure_clearance(rt[k - 1].lerp(rt[k], f / 5.0)))
		route_longest = maxf(route_longest, length)
		var end_d: float = rt[rt.size() - 1].distance_to(_door_of(w, Vector2.ZERO))
		if worst_r < -0.1 or end_d > 0.3 or length > 150.0 + 80.0:
			route_bad += 1
			print("FAIL abort route from 150 m at %3d deg: %d points %.0f m, least clearance %.2f m, ends %.2f m from the door" % [
				int(rad_to_deg(TAU * i / 24.0)), rt.size(), length, worst_r, end_d])
	# targets inside: the habitat's centre and the middle of the solar field
	var inside_bad := 0
	for i in 24:
		var dir := Vector2.from_angle(TAU * i / 24.0)
		var start := _free_spot(w, dir, 20.0)
		for target in [Vector2.ZERO, w.model_to_site(Vector2.ZERO, deg_to_rad(w.HAB_YAW_DEG), 0.0, 21.3), pr]:
			var r := _walk(w, start, target, 240.0)
			var c: float = w.structure_clearance(r["end"])
			var door: Vector2 = _door_of(w, target)
			var ok_end: bool = r["end"].distance_to(door) < 0.3 if door.is_finite() else c < 0.6
			if r["min_clear"] < -0.1 or not ok_end:
				inside_bad += 1
				print("FAIL inside target %s from %3d deg: least clearance %.2f m, stopped %.2f m outside a wall, %.2f m from its door" % [
					str(target.round()), int(rad_to_deg(TAU * i / 24.0)), r["min_clear"], c, r["end"].distance_to(door) if door.is_finite() else -1.0])
	print("structures_check: %d walks round the habitat, its solar field, PR-2 and Curiosity, %d failed (%d never got there; least clearance %.2f m, longest %.0f s); targets inside: %d failed; from 150 m: %d failed (longest %.0f s); abort routes: %d failed (longest %.0f m)" % [
		walks, bad, stuck, worst, longest, inside_bad, far_bad, far_longest, route_bad, route_longest])
	w.free()
	quit(1 if bad + inside_bad + far_bad + route_bad > 0 else 0)


## The door of the structure `q` is inside (the habitat's airlock, PR-2's suitports), or INF.
func _door_of(w, q: Vector2) -> Vector2:
	for o in w.obstacles:
		if q.distance_to(w._core_pt(o, q)) < float(o["r"]) and (o as Dictionary).has("door"):
			return o["door"]
	return Vector2.INF


## The first spot outside every structure along a direction from the habitat's centre.
func _free_spot(w, dir: Vector2, from_m := 10.0) -> Vector2:
	var p := dir * from_m
	while w.structure_clearance(p) < 0.3:
		p += dir * 0.25
	return p


## Walk from `start` to `target` like the autopilot (walker.gd update): a brisk lope while more than 2 m behind,
## then closing in smoothly. Returns how it went.
func _walk(w, start: Vector2, target: Vector2, limit: float, trace := false) -> Dictionary:
	var p := start
	var t := 0.0
	var n := 0
	var least := INF
	while t < limit:
		var aim: Vector2 = w.outside_structures(target, p)
		var gap := p.distance_to(aim)
		if gap > 2.0:
			p += (aim - p).normalized() * minf(gap, maxf(3.0, gap * 0.8) * DT)
		else:
			p = p.lerp(aim, 1.0 - exp(-DT * 10.0))
		least = minf(least, w.structure_clearance(p))
		if trace and n % 15 == 0:
			var cl := []
			for o in w.obstacles:
				cl.append("%s %.2f" % [o["name"], p.distance_to(w._core_pt(o, p)) - float(o["r"])])
			print("t %5.1f  at %s  aim %s  clear: %s" % [t, str(p.snapped(Vector2(0.01, 0.01))), str(aim.snapped(Vector2(0.01, 0.01))), ", ".join(cl)])
		n += 1
		t += DT
		if p.distance_to(target) < 1.0 or (aim.distance_to(target) > 0.5 and p.distance_to(aim) < 0.05 and w.structure_clearance(target) < 0.0):
			break   # there, or (a target inside a model) standing still at its wall
	return {"arrived": p.distance_to(target) < 1.0 or w.structure_clearance(target) < 0.0, "t": t, "left": p.distance_to(target),
		"min_clear": least, "end": p}
