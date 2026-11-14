"""Loads a built site into memory and caches per-request computations."""

from __future__ import annotations

import json
import math
import threading
from datetime import datetime, timedelta
from functools import cached_property
from pathlib import Path

import numpy as np
from PIL import Image

from marsgeo import mars24
from marsgeo.grid import SiteGrid, sample_bilinear

from . import tags as tagslib
from . import viewshed as vs
from . import walkback as wb
from .routing import Router
from .walkmodel import WalkParams, cell_multiplier

ROOT = Path(__file__).resolve().parents[1]
CONFIG_DIR = ROOT / "config" / "sites"
DATA_DIR = ROOT / "data"


def site_ids() -> list[str]:
    return sorted(p.stem for p in CONFIG_DIR.glob("*.json"))


def is_built(site_id: str) -> bool:
    """Built = the pipeline's final `meta` step ran (it writes the grids); not just the first files."""
    d = DATA_DIR / "sites" / site_id
    if not all((d / n).exists() for n in ("build_meta.json", "analysis_2m.npz", "dem_1m.tif")):
        return False
    try:
        return "grid_1m" in json.loads((d / "build_meta.json").read_text())
    except (OSError, ValueError):
        return False


def load_config(site_id: str) -> dict:
    return json.loads((CONFIG_DIR / f"{site_id}.json").read_text(encoding="utf-8"))


def hazard_classes(slope, rough, sand, p: WalkParams, boulder=None) -> np.ndarray:
    """0 easy, 1 moderate, 2 difficult, 3 hazardous, 4 no-go (for the given limits)."""
    mid = (p.caution_slope + p.max_slope) / 2
    c = np.zeros(np.shape(slope), np.uint8)
    c = np.maximum(c, np.select([slope > p.max_slope, slope >= mid, slope >= p.caution_slope, slope >= 10], [4, 3, 2, 1], 0))
    c = np.maximum(c, np.select([rough > p.max_rough, rough >= 0.40, rough >= 0.30, rough >= 0.20], [4, 3, 2, 1], 0))
    c = np.maximum(c, np.select([sand >= 0.72, sand >= 0.58], [2, 1], 0))
    if boulder is not None:
        c = np.maximum(c, np.select([boulder >= 2.0, boulder >= 1.2, boulder >= 0.75], [4, 3, 2], 0))
    return c.astype(np.uint8)


class _KeyedOnce:
    """Compute-once cache with a lock per key (many tiles may ask at the same moment)."""

    def __init__(self, maxsize=8):
        self.maxsize = maxsize
        self.data: dict = {}
        self.locks: dict = {}
        self.glock = threading.Lock()

    def get(self, key, fn):
        with self.glock:
            if key in self.data:
                v = self.data.pop(key)
                self.data[key] = v
                return v
            lock = self.locks.setdefault(key, threading.Lock())
        with lock:
            with self.glock:
                if key in self.data:
                    return self.data[key]
            v = fn()
            with self.glock:
                self.data[key] = v
                while len(self.data) > self.maxsize:
                    old = next(iter(self.data))
                    self.data.pop(old)
                    self.locks.pop(old, None)
            return v


class Site:
    def __init__(self, site_id: str):
        self.id = site_id
        self.cfg = load_config(site_id)
        self.dir = DATA_DIR / "sites" / site_id
        self.meta = json.loads((self.dir / "build_meta.json").read_text())
        self.grid = SiteGrid.from_dict(self.meta["grid_1m"])
        self.grid2 = SiteGrid.from_dict(self.meta["grid_2m"])
        self.grid4 = SiteGrid.from_dict(self.meta["grid_4m"])
        a = np.load(self.dir / "analysis_2m.npz")
        self.z2 = a["z"].astype(np.float32)
        self.slope2 = a["slope"].astype(np.float32)
        self.rough2 = a["rough"].astype(np.float32)
        self.tpi2 = a["tpi"].astype(np.float32)
        self.sand2 = self._load_npy("sand_2m.npy", np.zeros_like(self.z2))
        self.shield4 = self._load_npy("shield_4m.npy", np.zeros(self.z4.shape, np.float32))
        self.svf4 = self._load_npy("skyview_4m.npy", np.ones(self.z4.shape, np.float32))
        self.thermal4 = self._load_npy("thermal_4m.npy", None)
        self.thermal_day4 = self._load_npy("thermal_day_4m.npy", None)  # THEMIS day IR via NASA Mars Trek
        self.boulder2 = self._load_npy("boulders_2m.npy", None)  # largest boulder diameter touching each 2 m cell
        from pipeline import geology as _geology
        self.geology2, self.geology_meta = _geology.load(self.dir)  # USGS geologic units (uint8 index), or None
        self.sand_conf2 = self._load_npy("sand_conf_2m.npy", None)        # do the sand clues agree? 0..1
        self.terrain_conf2 = self._load_npy("terrain_conf_2m.npy", None)  # do our DTM and the team's agree? 0..1 (NaN: no second model)
        self.slope_unc2 = self._load_npy("slope_unc_2m.npy", None)        # |our slope - team slope|, deg
        self.scouted4 = np.load(self.dir / "scouted_4m.npy") if (self.dir / "scouted_4m.npy").exists() else None  # latest Ingenuity flight that saw each cell
        self.router = Router(self.z2, self.grid2.res)
        self._lock = threading.Lock()
        self.walkbacks = _KeyedOnce(8)
        self.viewsheds = _KeyedOnce(8)
        self.hazards = _KeyedOnce(4)
        self.flows = _KeyedOnce(4)      # ways-home trees (server/flow.py), per set of havens and walking limits
        self.fields = _KeyedOnce(6)     # forward walking-time fields from a start cell (server/envelope.py)
        self.tags = tagslib.load(DATA_DIR, site_id)   # crew tags (feature C2): hazard tags close ground for routing
        self.tag_key = tagslib.version(self.tags)
        self.on_change: list = []      # callbacks when the cost grids change (the API clears its caches)

    def _load_npy(self, name, default):
        p = self.dir / name
        return np.load(p).astype(np.float32) if p.exists() else default

    @cached_property
    def z4(self) -> np.ndarray:
        h, w = (self.z2.shape[0] // 2) * 2, (self.z2.shape[1] // 2) * 2
        return self.z2[:h, :w].reshape(h // 2, 2, w // 2, 2).mean(axis=(1, 3)).astype(np.float32)

    @cached_property
    def dem1(self) -> np.ndarray:
        import rasterio
        with rasterio.open(self.dir / "dem_1m.tif") as src:
            return src.read(1).astype(np.float32)

    @cached_property
    def hillshade1(self) -> np.ndarray:
        return np.asarray(Image.open(self.dir / "hillshade_1m.png"))

    @cached_property
    def boulders(self) -> np.ndarray:
        """Detected boulders as an (N, 4) float32 array: x, y (site metres), diameter, height."""
        p = self.dir / "boulders.json"
        if not p.exists():
            return np.zeros((0, 4), np.float32)
        b = json.loads(p.read_text()).get("boulders", [])
        return np.array([[r["x"], r["y"], r["d"], r["h"]] for r in b], np.float32).reshape(-1, 4)

    @cached_property
    def crism(self) -> dict:
        """CRISM composites on the 4 m grid: {kind: {"rgba": HxWx4 uint8, "meta": {...}}}."""
        p = self.dir / "crism_meta.json"
        if not p.exists():
            return {}
        meta = json.loads(p.read_text())
        out = {}
        for kind, m in meta.get("layers", {}).items():
            f = self.dir / f"crism_{kind}.png"
            if f.exists():
                out[kind] = {"rgba": np.asarray(Image.open(f).convert("RGBA")), "meta": m}
        return out

    @cached_property
    def sand_parts(self) -> dict:
        """The sand clues' logit contributions on the 2 m grid (pipeline/sand.py), for Inspect's explanation."""
        p = self.dir / "sand_parts_2m.npz"
        if not p.exists():
            return {}
        z = np.load(p)
        sc = float(z["scale"])
        return {k: z[k].astype(np.float32) * sc for k in z.files if k != "scale"}

    @cached_property
    def science(self) -> dict:
        """Science-opportunity score and its parts on the 2 m grid (pipeline/science.py); {} if not built."""
        p = self.dir / "science_2m.npz"
        if not p.exists():
            return {}
        z = np.load(p)
        return {k: (z[k].astype(np.float32) if z[k].dtype == np.float16 else z[k]) for k in z.files}

    @cached_property
    def ingenuity(self) -> list[dict]:
        """Ingenuity flights near the site (properties of the flight lines in ingenuity.geojson)."""
        p = self.dir / "ingenuity.geojson"
        if not p.exists():
            return []
        out = []
        for f in json.loads(p.read_text(encoding="utf-8")).get("features", []):
            if (f.get("properties") or {}).get("kind") == "flight":
                out.append({**f["properties"], "path": f["geometry"]["coordinates"]})
        return out

    def flight(self, n: int) -> dict | None:
        return next((f for f in self.ingenuity if int(f["flight"]) == int(n)), None)

    def scouted_at(self, lon: float, lat: float) -> dict | None:
        """The latest Ingenuity flight whose navigation camera saw this point, or None."""
        if self.scouted4 is None:
            return None
        r, c = (int(round(float(v))) for v in self.grid4.lonlat_to_rowcol(lon, lat))
        if not (0 <= r < self.grid4.height and 0 <= c < self.grid4.width):
            return None
        n = int(self.scouted4[r, c])
        f = self.flight(n) if n else None
        return {k: f[k] for k in ("flight", "sol", "earth_date", "max_alt_m", "length_m")} if f else None

    # ------------------------------------------------------------ horizon / sunlight
    @cached_property
    def horizon(self):
        """(uint8 array (n_az, H, W) on the 4 m grid, step deg, min deg) or None for a site built before D4."""
        p = self.dir / "horizon_4m.npz"
        if not p.exists():
            return None
        z = np.load(p)
        return z["h"], float(z["step_deg"]), float(z["min_deg"])

    def horizon_deg(self, r4, c4, az_deg) -> np.ndarray:
        """Terrain horizon elevation (deg) seen from 4 m cells (r4, c4) towards azimuth az_deg (clockwise from north).

        Nearest cell, linear between the stored azimuth slices. Arrays broadcast together.
        """
        h, step, lo = self.horizon
        n = h.shape[0]
        ri = np.clip(np.rint(np.asarray(r4, float)).astype(int), 0, h.shape[1] - 1)
        ci = np.clip(np.rint(np.asarray(c4, float)).astype(int), 0, h.shape[2] - 1)
        f = (np.asarray(az_deg, float) % 360.0) / (360.0 / n)
        k0 = np.floor(f).astype(int) % n
        k1 = (k0 + 1) % n
        w = f - np.floor(f)
        v = (1.0 - w) * h[k0, ri, ci] + w * h[k1, ri, ci]
        return lo + step * v

    def sunlit(self, lon, lat, sun_elev, sun_az) -> np.ndarray:
        """True where the sun's centre is above both the true horizon and the terrain horizon at (lon, lat)."""
        sun_elev = np.asarray(sun_elev, float)
        if self.horizon is None:
            return sun_elev > -0.25
        r4, c4 = self.grid4.lonlat_to_rowcol(np.asarray(lon, float), np.asarray(lat, float))
        return (sun_elev > -0.25) & (sun_elev > self.horizon_deg(r4, c4, sun_az))

    def sun_times(self, lon: float, lat: float, day_utc: datetime, step_min: float = 1.0) -> dict:
        """Sunrise and sunset over the real terrain at (lon, lat) on the sol containing day_utc, and the flat-horizon times.

        Scans the sol from 04:00 to 20:00 local true solar time; the crossings are interpolated to well under a minute.
        """
        lon0 = self.grid.lon0
        mt0 = mars24.mars_time(day_utc)
        flat = mars24.sunrise_sunset_ltst(mt0, self.grid.lat0)
        t0 = mars24.utc_for_ltst(day_utc, lon0, 4.0)
        n = int(16 * 60 / step_min) + 1
        ts = [t0 + timedelta(seconds=i * step_min * 60 * mars24.MARS_SOL_DAYS) for i in range(n)]
        el = np.empty(n)
        az = np.empty(n)
        for i, t in enumerate(ts):
            e, a, _ = mars24.sun_position(mars24.mars_time(t), self.grid.lat0, lon0)
            el[i], az[i] = e, a
        hz = np.full(n, -0.25)
        if self.horizon is not None:
            r4, c4 = self.grid4.lonlat_to_rowcol(lon, lat)
            hz = np.maximum(hz, self.horizon_deg(np.full(n, r4), np.full(n, c4), az))
        up = el - hz
        out = {"flat_sunrise_ltst": flat[0] if flat else None, "flat_sunset_ltst": flat[1] if flat else None,
               "sunrise_ltst": None, "sunset_ltst": None, "sunrise_utc": None, "sunset_utc": None}
        above = np.flatnonzero(up > 0)
        if above.size:
            i, j = int(above[0]), int(above[-1])

            def cross(a, b):  # time where `up` crosses 0 between samples a and b
                if a < 0 or b >= n or up[a] == up[b]:
                    return ts[max(0, min(n - 1, a))]
                f = up[a] / (up[a] - up[b])
                return ts[a] + (ts[b] - ts[a]) * float(f)
            rise = cross(i - 1, i) if i > 0 else ts[0]
            sset = cross(j, j + 1) if j < n - 1 else ts[-1]
            for key, t in (("sunrise", rise), ("sunset", sset)):
                out[key + "_utc"] = t.isoformat()
                out[key + "_ltst"] = round(mars24.local_true_solar_time(mars24.mars_time(t), lon0), 4)
        if self.horizon is not None:
            r4, c4 = self.grid4.lonlat_to_rowcol(lon, lat)
            h, _, _ = self.horizon
            out["horizon_deg"] = [round(float(v), 2) for v in self.horizon_deg(np.full(h.shape[0], r4), np.full(h.shape[0], c4),
                                                                                np.arange(h.shape[0]) * 360.0 / h.shape[0])]
        return out

    def shadow_grid(self, sun_elev: float, sun_az: float) -> np.ndarray:
        """uint8 on the 4 m grid: 0 sunlit, 1 terrain shadow, 2 sun below the true horizon (night)."""
        if sun_elev <= -0.25:
            return np.full((self.grid4.height, self.grid4.width), 2, np.uint8)
        if self.horizon is None:
            return np.zeros((self.grid4.height, self.grid4.width), np.uint8)
        h, step, lo = self.horizon
        n = h.shape[0]
        f = (sun_az % 360.0) / (360.0 / n)
        k0 = int(np.floor(f)) % n
        w = f - np.floor(f)
        hz = lo + step * ((1.0 - w) * h[k0].astype(np.float32) + w * h[(k0 + 1) % n].astype(np.float32))
        return (hz >= sun_elev).astype(np.uint8)

    @cached_property
    def regional(self):
        p = self.dir / "regional_200m.tif"
        if not p.exists():
            return None, None
        import rasterio
        with rasterio.open(p) as src:
            arr = src.read(1).astype(np.float32)
        return arr, SiteGrid.from_dict(self.meta["regional_grid"])

    # ------------------------------------------------------------ cost grids
    def multiplier(self, p: WalkParams) -> np.ndarray:
        key = p.key()
        with self._lock:
            if not self.router.has_multiplier(key):
                m = cell_multiplier(p, self.slope2, self.rough2, self.sand2, self.boulder2)
                mask = tagslib.hazard_mask(self.grid2, self.tags)
                if mask is not None:  # crew hazard tags are no-go
                    m = m.copy()
                    m[mask] = np.inf
                self.router.set_multiplier(key, m, p)
            return self.router.multiplier(key)

    def hazard(self, p: WalkParams) -> np.ndarray:
        def build():
            c = hazard_classes(self.slope2, self.rough2, self.sand2, p, self.boulder2)
            mask = tagslib.hazard_mask(self.grid2, self.tags)
            if mask is not None:
                c = c.copy()
                c[mask] = 4
            return c
        return self.hazards.get(p.key(), build)

    def set_tags(self, tags: list[dict]) -> None:
        """New crew tags: every cost grid and field that depends on them is computed again."""
        new_key = tagslib.version(tags)
        self.tags = tags
        if new_key == self.tag_key:
            return  # only finds changed: routing is unaffected
        self.tag_key = new_key
        with self._lock:
            self.router._mult.clear()
        self.walkbacks = _KeyedOnce(8)
        self.hazards = _KeyedOnce(4)
        self.flows = _KeyedOnce(4)
        self.fields = _KeyedOnce(6)
        self._graphs = None
        for fn in self.on_change:
            fn(self)

    def walkback(self, hab_lonlat, p: WalkParams) -> dict:
        key = f"{hab_lonlat[0]:.6f},{hab_lonlat[1]:.6f}|{p.key()}"
        return self.walkbacks.get(key, lambda: wb.compute(self, hab_lonlat, p))

    @cached_property
    def skyline(self):
        """Every 4 m cell's stored skyline as a matrix, for the skyline fix (server/skyline.py), or None."""
        if self.horizon is None:
            return None
        from . import skyline as sk
        return sk.SkylineIndex(self)

    @cached_property
    def fix_quality(self):
        """Expected 95 % skyline-fix radius (m) on a 16 m grid, and that grid (cached on disk per build)."""
        if self.skyline is None:
            return None, None
        import re
        from . import skyline as sk
        stamp = re.sub(r"\W", "", str(self.meta.get("built_utc", "")))
        p = DATA_DIR / "cache" / "skyline" / f"{self.id}_fix_{stamp}.npy"
        if p.exists():
            m = np.load(p)
        else:
            m = sk.fix_quality_map(self.skyline)
            p.parent.mkdir(parents=True, exist_ok=True)
            np.save(p, m)
        g4 = self.grid4
        g = SiteGrid(g4.lon0, g4.lat0, g4.x_min, g4.y_max, g4.res * 4, m.shape[1], m.shape[0])
        return m, g

    def flow(self, havens: list[dict], p: WalkParams):
        """The ways-home tree (server/flow.py) for these havens: every cell's fastest walk to the nearest one."""
        from . import flow as fl
        return self.flows.get(fl.havens_key(havens) + "|" + p.key(), lambda: fl.FlowTree(self, havens, p))

    def habitat_haven(self) -> dict:
        h = self.cfg.get("habitat") or {"lon": self.grid.lon0, "lat": self.grid.lat0}
        return {"lon": float(h["lon"]), "lat": float(h["lat"]), "name": "Hab"}

    def comms(self, observers, target_h: float) -> dict:
        key = ";".join(f"{a:.6f},{b:.6f},{h:g}" for a, b, h in observers) + f"|{target_h:g}"
        return self.viewsheds.get(key, lambda: vs.combined(self.z2, self.grid2, observers, target_h))

    # --------------------------------------------------------------- sampling
    def sample(self, lon, lat):
        """Everything we know about a point (arrays OK)."""
        r1, c1 = self.grid.lonlat_to_rowcol(lon, lat)
        r2, c2 = self.grid2.lonlat_to_rowcol(lon, lat)
        r4, c4 = self.grid4.lonlat_to_rowcol(lon, lat)
        out = {
            "elev": sample_bilinear(self.dem1, r1, c1),
            "slope": sample_bilinear(self.slope2, r2, c2),
            "rough": sample_bilinear(self.rough2, r2, c2),
            "sand": sample_bilinear(self.sand2, r2, c2),
            "tpi": sample_bilinear(self.tpi2, r2, c2),
            "shield": sample_bilinear(self.shield4, r4, c4),
            "skyview": sample_bilinear(self.svf4, r4, c4),
        }
        if self.thermal4 is not None:
            out["thermal"] = sample_bilinear(self.thermal4, r4, c4)
        if self.thermal_day4 is not None:
            out["thermal_day"] = sample_bilinear(self.thermal_day4, r4, c4)
        for key, arr in (("sand_conf", self.sand_conf2), ("terrain_conf", self.terrain_conf2), ("slope_unc", self.slope_unc2)):
            if arr is not None:
                out[key] = sample_bilinear(arr, r2, c2)
        if self.science:
            out["science"] = sample_bilinear(self.science["score"], r2, c2)
        return out

    def geology_at(self, lon: float, lat: float) -> dict | None:
        """The USGS map unit at a point: code, name, description, interpretation, map and citation."""
        if self.geology2 is None:
            return None
        r, c = (int(round(float(v))) for v in self.grid2.lonlat_to_rowcol(lon, lat))
        r = min(max(r, 0), self.grid2.height - 1)
        c = min(max(c, 0), self.grid2.width - 1)
        k = int(self.geology2[r, c])
        units = self.geology_meta.get("units", [])
        if k <= 0 or k > len(units):
            return None
        u = units[k - 1]
        return {"code": u["code"], "name": u["name"], "color": u["color"], "description": u.get("description", ""),
                "interpretation": u.get("interpretation", ""), "map": self.geology_meta.get("map", ""),
                "scale": self.geology_meta.get("scale", ""), "url": self.geology_meta.get("url", "")}

    def refuges(self, n: int = 5, min_sep_m: float = 250.0):
        """Spots where terrain blocks the most sky (partial radiation shelter), on walkable ground."""
        s = self.shield4.copy()
        slope4 = self.slope2[: s.shape[0] * 2: 2, : s.shape[1] * 2: 2]
        s[slope4[: s.shape[0], : s.shape[1]] > 18] = 0
        out = []
        for _ in range(n):
            i = np.unravel_index(int(np.argmax(s)), s.shape)
            if s[i] <= 0:
                break
            lon, lat = self.grid4.rowcol_to_lonlat(*i)
            out.append({"lon": float(lon), "lat": float(lat), "shield": float(self.shield4[i])})
            rr, cc = np.ogrid[: s.shape[0], : s.shape[1]]
            s[(rr - i[0]) ** 2 + (cc - i[1]) ** 2 < (min_sep_m / self.grid4.res) ** 2] = 0
        return out


_sites: dict[str, Site] = {}
_sites_lock = threading.Lock()


def get_site(site_id: str) -> Site:
    with _sites_lock:
        if site_id not in _sites:
            if site_id not in site_ids() or not is_built(site_id):
                raise KeyError(site_id)
            _sites[site_id] = Site(site_id)
        return _sites[site_id]
