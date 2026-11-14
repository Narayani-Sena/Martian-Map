"""Crew-tagged map (feature C2): look at a spot and press once, "hazard" or "find".

A hazard tag closes a small disc of ground for routing (radius 6 m by default): the route is planned again, EV2
sees the tag, and the next EVA inherits it because tags are kept per site on disk. A find tag is a place worth a
stop: Plan it for me (C3) offers it as a candidate.
"""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path

import numpy as np

KINDS = ("hazard", "find")
DEFAULT_RADIUS = {"hazard": 6.0, "find": 0.0}
_lock = threading.Lock()


def path_for(data_dir: Path, site_id: str) -> Path:
    return data_dir / "tags" / f"{site_id}.json"


def load(data_dir: Path, site_id: str) -> list[dict]:
    p = path_for(data_dir, site_id)
    if not p.exists():
        return []
    try:
        return json.loads(p.read_text(encoding="utf-8")).get("tags", [])
    except (OSError, ValueError):
        return []


def save(data_dir: Path, site_id: str, tags: list[dict]) -> None:
    p = path_for(data_dir, site_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps({"tags": tags}, indent=1), encoding="utf-8")
    tmp.replace(p)


def add(data_dir: Path, site_id: str, kind: str, lon: float, lat: float, note: str = "", by: str = "EV1",
        radius_m: float | None = None) -> dict:
    if kind not in KINDS:
        raise ValueError("kind: hazard | find")
    with _lock:
        tags = load(data_dir, site_id)
        n = max([int(t["id"][1:]) for t in tags if t["id"][1:].isdigit()] + [0]) + 1
        tag = {"id": f"T{n}", "kind": kind, "lon": float(lon), "lat": float(lat), "note": str(note)[:120], "by": str(by)[:20],
               "radius_m": float(DEFAULT_RADIUS[kind] if radius_m is None else min(max(radius_m, 2.0), 40.0)), "t": time.time()}
        tags.append(tag)
        save(data_dir, site_id, tags)
    return tag


def delete(data_dir: Path, site_id: str, tag_id: str | None) -> int:
    with _lock:
        tags = load(data_dir, site_id)
        keep = [] if tag_id is None else [t for t in tags if t["id"] != tag_id]
        save(data_dir, site_id, keep)
        return len(tags) - len(keep)


def hazard_mask(grid2, tags: list[dict]) -> np.ndarray | None:
    """True on the 2 m cells inside a hazard tag's disc (None if there are none)."""
    hz = [t for t in tags if t["kind"] == "hazard"]
    if not hz:
        return None
    H, W = grid2.height, grid2.width
    m = np.zeros((H, W), bool)
    for t in hz:
        r, c = grid2.lonlat_to_rowcol(t["lon"], t["lat"])
        rad = t["radius_m"] / grid2.res
        r0, r1 = int(max(0, np.floor(r - rad))), int(min(H, np.ceil(r + rad) + 1))
        c0, c1 = int(max(0, np.floor(c - rad))), int(min(W, np.ceil(c + rad) + 1))
        if r0 >= r1 or c0 >= c1:
            continue
        yy, xx = np.ogrid[r0:r1, c0:c1]
        m[r0:r1, c0:c1] |= (yy - r) ** 2 + (xx - c) ** 2 <= rad ** 2
    return m


def version(tags: list[dict]) -> str:
    return "|".join(f"{t['id']}:{t['kind']}:{t['lon']:.6f}:{t['lat']:.6f}:{t['radius_m']:g}" for t in tags if t["kind"] == "hazard")
