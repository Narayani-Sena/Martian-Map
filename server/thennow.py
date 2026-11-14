"""Then and now (feature E3): the rover's own photos placed in the 3D world at the pose they were taken from.

Both rovers' raw-image feeds carry, for each frame, the rover's site and drive (which waypoint it stood on), its
attitude quaternion (rover frame to the local north-east-down frame, scalar first) and the camera's CAHV model in
the rover frame. So the camera's position, the direction through the middle of the frame, the frame's "up" and its
field of view can all be worked out, and the 3D console can stand a camera exactly there and wipe between the photo
and the terrain model. That shows what the crew will see at a place, and how well the terrain model matches it.

The quaternion convention is checked against each waypoint's own heading when the waypoint carries one; distortion
terms (O, R, E) are ignored, so the frame's edges are good to a degree or two.
"""

from __future__ import annotations

import json
import math
import numpy as np

from marsgeo.net import DaemonPool

SOLS_TO_TRY = 10      # sols spread over the rover's time inside the site
PER_SOL = 2           # frames kept per sol (the feed ranks them: looking out over the terrain, widest first)


def _vecs(s) -> list[np.ndarray]:
    if not s:
        return []
    out = []
    for part in str(s).split(";"):
        part = part.strip().strip("()")
        if not part:
            continue
        try:
            out.append(np.array([float(x) for x in part.split(",")], float))
        except ValueError:
            continue
    return out


def quat_matrix(q) -> np.ndarray:
    """Rotation matrix of a unit quaternion (w, x, y, z)."""
    w, x, y, z = (float(v) for v in q)
    n = math.sqrt(w * w + x * x + y * y + z * z) or 1.0
    w, x, y, z = w / n, x / n, y / n, z / n
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
                     [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
                     [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)]])


def ray(A, H, V, x: float, y: float) -> np.ndarray:
    """Unit direction (camera-model frame) through image pixel (x = sample, y = line) of a CAHV model."""
    r = np.cross(V - y * A, H - x * A)
    if np.dot(r, A) < 0:
        r = -r
    return r / (np.linalg.norm(r) or 1.0)


def heading_deg(R: np.ndarray) -> float:
    """Compass heading of the rover's forward (+x) axis in the north-east-down frame."""
    f = R @ np.array([1.0, 0.0, 0.0])
    return math.degrees(math.atan2(f[1], f[0])) % 360.0


def frame_pose(item: dict) -> dict | None:
    """Camera pose in north-east-down metres relative to the rover's origin: position, view direction through the
    middle of the frame, the frame's up, and its fields of view. None if the feed lacks the camera model."""
    vs = _vecs(item.get("cahv"))
    q = _vecs(item.get("attitude"))
    if len(vs) < 4 or not q or len(q[0]) != 4:
        return None
    C, A, H, V = vs[:4]
    R = quat_matrix(q[0])
    # the feeds give the model in the delivered image's pixels (after subframing and downsampling)
    w, h = float(item.get("w") or 0), float(item.get("h") or 0)
    if w <= 0 or h <= 0:
        return None
    x0, y0 = 0.0, 0.0
    xc, yc = w / 2.0, h / 2.0
    d = R @ ray(A, H, V, xc, yc)
    up = R @ (ray(A, H, V, xc, yc - h * 0.25) - ray(A, H, V, xc, yc + h * 0.25))
    up = up - np.dot(up, d) * d
    up /= np.linalg.norm(up) or 1.0
    ang = lambda a, b: math.degrees(math.acos(max(-1.0, min(1.0, float(np.dot(a, b))))))
    hfov = ang(ray(A, H, V, x0, yc), ray(A, H, V, x0 + w, yc))
    vfov = ang(ray(A, H, V, xc, y0), ray(A, H, V, xc, y0 + h))
    pos = R @ C
    return {"pos_ned": pos, "dir_ned": d, "up_ned": up, "hfov": hfov, "vfov": vfov, "heading": heading_deg(R)}


def ned_to_world(v) -> list[float]:
    """North-east-down -> the 3D console's world axes (x east, y up, z south)."""
    n, e, dn = (float(c) for c in v)
    return [round(e, 5), round(-dn, 5), round(-n, 5)]


def _waypoints(site) -> dict:
    p = site.dir / "rover_waypoints.geojson"
    if not p.exists():
        return {}
    out = {}
    for f in json.loads(p.read_text(encoding="utf-8")).get("features", []):
        pr = f.get("properties") or {}
        c = (f.get("geometry") or {}).get("coordinates") or []
        if pr.get("site") is None or pr.get("drive") is None or len(c) < 2:
            continue
        out[(int(pr["site"]), int(pr["drive"]))] = {"lon": float(c[0]), "lat": float(c[1]), "sol": int(pr.get("sol") or 0)}
    return out


def pick_sols(sols: list[int], k: int = SOLS_TO_TRY) -> list[int]:
    s = sorted(set(sols))
    if len(s) <= k:
        return s
    return [s[round(i * (len(s) - 1) / (k - 1))] for i in range(k)]


def photos(site, k_sols: int = SOLS_TO_TRY, per_sol: int = PER_SOL) -> dict:
    """The rover's navigation-camera views inside the site, each with the pose it was taken from."""
    from . import rover_images
    mission = (site.cfg.get("rover") or {}).get("raw_images_mission")
    rover = site.cfg.get("rover_name") or (site.cfg.get("rover") or {}).get("name") or "the rover"
    wps = _waypoints(site)
    if not mission or not wps:
        return {"photos": [], "note": "No rover waypoints for this site."}
    sols = pick_sols([w["sol"] for w in wps.values()], k_sols)

    def fetch(sol):
        try:
            return sol, rover_images.landscapes(mission, sol, sol)
        except Exception:
            return sol, []

    found = _pool.map(fetch, sols)
    out = []
    for sol, items in found:
        kept = []
        for it in items:
            try:
                key = (int(it.get("site")), int(it.get("drive")))
            except (TypeError, ValueError):
                continue
            wp = wps.get(key)
            pose = frame_pose(it) if wp else None
            if pose is None:
                continue
            az = math.degrees(math.atan2(pose["dir_ned"][1], pose["dir_ned"][0])) % 360.0
            if any(abs((az - k["az"] + 180.0) % 360.0 - 180.0) < 25.0 for k in kept):
                continue   # another view in nearly the same direction
            x, y = site.grid.lonlat_to_xy(wp["lon"], wp["lat"])
            cx, cy = float(x) + float(pose["pos_ned"][1]), float(y) + float(pose["pos_ned"][0])
            clon, clat = site.grid.xy_to_lonlat(cx, cy)
            el = math.degrees(math.asin(max(-1.0, min(1.0, -float(pose["dir_ned"][2])))))
            kept.append({"id": it.get("id"), "sol": it.get("sol"), "camera": it.get("camera"), "title": it.get("title"),
                         "url": it.get("url"), "thumb": it.get("thumb"), "date_taken": it.get("date_taken"),
                         "w": it.get("w"), "h": it.get("h"), "rmc": f"{key[0]}_{key[1]}",
                         "lon": round(float(clon), 7), "lat": round(float(clat), 7),
                         "cam_h_m": round(-float(pose["pos_ned"][2]), 2), "az": round(az, 1), "el": round(el, 1),
                         "dir": ned_to_world(pose["dir_ned"]), "up": ned_to_world(pose["up_ned"]),
                         "hfov": round(pose["hfov"], 2), "vfov": round(pose["vfov"], 2),
                         "rover_heading": round(pose["heading"], 1)})
            if len(kept) >= per_sol:
                break
        out.extend(kept)
    out.sort(key=lambda p: (p["sol"], p["az"]))
    return {"rover": rover, "mission": mission, "sols_tried": sols, "photos": out,
            "note": "Each photo is placed where the rover's camera stood, pointing where it pointed (from the "
                    "raw-image feed's camera model and rover attitude); distortion is ignored at the edges."}


_pool = DaemonPool(4, "thennow")
