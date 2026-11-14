"""Build every data product for one site.

    python -m pipeline.build_site gale_boxwork            # build what's missing
    python -m pipeline.build_site gale_boxwork --force    # rebuild everything
    python -m pipeline.build_site gale_boxwork --only derive skyview

Outputs go to data/sites/<site_id>/ and are read by the FastAPI server.
"""

from __future__ import annotations

import argparse
import json
import logging
import math
import time
from pathlib import Path

import numpy as np
from PIL import Image
from rasterio.warp import Resampling
from scipy import ndimage

from marsgeo import stac
from marsgeo.constants import METERS_PER_DEG
from marsgeo.grid import SiteGrid, sample_bilinear

from . import contours, derive, imagery, rover, skyview, terrain
from .rasterio_io import read_tif, write_tif

ROOT = Path(__file__).resolve().parents[1]
CONFIG_DIR = ROOT / "config" / "sites"
DATA_DIR = ROOT / "data"

log = logging.getLogger("pipeline")

STEPS = ["dem", "regional", "derive", "team_dem", "skyview", "imagery", "thermal", "thermal_day", "crism", "geology", "boulders",
         "sand", "confidence", "rover", "ingenuity", "chemistry", "radar", "science", "contours", "meta"]

ANALYSIS_FACTOR = 2  # analysis grid = 2 m
HORIZON_FACTOR = 4  # horizon / shielding grid = 4 m
HORIZON_MARGIN_M = 1000.0
# Stored horizon: uint8 (n_az, H, W), value = (elevation deg - HORIZON_MIN_DEG) / HORIZON_STEP_DEG -> -10 .. 66.5 deg
HORIZON_STEP_DEG = 0.3
HORIZON_MIN_DEG = -10.0


def load_config(site_id: str) -> dict:
    return json.loads((CONFIG_DIR / f"{site_id}.json").read_text(encoding="utf-8"))


class Builder:
    def __init__(self, site_id: str, force: bool = False):
        self.cfg = load_config(site_id)
        self.site_id = site_id
        self.force = force
        self.out = DATA_DIR / "sites" / site_id
        self.cache = DATA_DIR / "cache"
        self.out.mkdir(parents=True, exist_ok=True)
        self.cache.mkdir(parents=True, exist_ok=True)
        self.grid = SiteGrid.from_bbox(self.cfg["bbox"], res=1.0, multiple=8)
        self.grid2 = self.grid.resampled(ANALYSIS_FACTOR)
        self.grid4 = self.grid.resampled(HORIZON_FACTOR)
        meta_path = self.out / "build_meta.json"
        self.meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}

    # ----------------------------------------------------------- helpers
    def need(self, *names: str) -> bool:
        return self.force or not all((self.out / n).exists() for n in names)

    def save_meta(self):
        (self.out / "build_meta.json").write_text(json.dumps(self.meta, indent=2))

    def dem(self) -> np.ndarray:
        return read_tif(self.out / "dem_1m.tif")

    # ----------------------------------------------------------- steps
    def step_dem(self):
        if not self.need("dem_1m.tif"):
            return
        dem, used, missing = terrain.build_dem(self.grid, self.cfg["dem"].get("preferred"),
                                               self.cfg["dem"].get("collection", "mro_hirise_socet_dtms"))
        write_tif(self.out / "dem_1m.tif", dem, self.grid)
        self.meta["dem_sources"] = used
        self.meta["dem_missing_fraction"] = missing
        log.info("DEM %dx%d  z %.1f .. %.1f m", dem.shape[1], dem.shape[0], dem.min(), dem.max())

    def regional_grid(self) -> SiteGrid:
        h = self.cfg.get("regional_half_deg", 0.8)
        g = self.grid
        bbox = (g.lon0 - h / math.cos(math.radians(g.lat0)), g.lat0 - h, g.lon0 + h / math.cos(math.radians(g.lat0)), g.lat0 + h)
        return SiteGrid.from_bbox(bbox, res=200.0, lon0=g.lon0, lat0=g.lat0)

    def step_regional(self):
        if not self.need("regional_200m.tif"):
            return
        rg = self.regional_grid()
        t = time.time()
        reg = terrain.build_regional_dem(rg)
        write_tif(self.out / "regional_200m.tif", reg, rg)
        self.meta["regional_grid"] = rg.to_dict()
        log.info("regional DEM %dx%d in %.0fs (z %.0f..%.0f)", rg.width, rg.height, time.time() - t, reg.min(), reg.max())

    def step_derive(self):
        if not self.need("analysis_2m.npz", "hillshade_1m.png"):
            return
        dem = self.dem()
        res = self.grid.res
        hs = derive.multidirectional_hillshade(dem, res, z_factor=1.0)
        Image.fromarray((hs * 255).astype(np.uint8)).save(self.out / "hillshade_1m.png", optimize=True)
        rough1 = derive.roughness(dem, res, window_m=5.0)
        slope1 = derive.slope_deg(dem, res)
        # 2 m analysis grid used for routing: average height, slope over a 4 m baseline,
        # and the *maximum* 1 m roughness/slope inside each cell (conservative).
        z2 = derive.block_reduce(dem, ANALYSIS_FACTOR, "mean")
        slope2 = derive.slope_deg(z2, self.grid2.res)
        slope1max = derive.block_reduce(slope1, ANALYSIS_FACTOR, "max")
        rough2 = derive.block_reduce(rough1, ANALYSIS_FACTOR, "max")
        tpi2 = derive.tpi(z2, self.grid2.res, radius_m=15.0)
        tpi_big = derive.tpi(z2, self.grid2.res, radius_m=60.0)
        np.savez_compressed(self.out / "analysis_2m.npz", z=z2, slope=slope2, slope1max=slope1max,
                            rough=rough2, tpi=tpi2, tpi_big=tpi_big)
        # normal maps for the 3D terrain (x east, y north, z up)
        for size in (2048, 4096):
            zz = _resize(dem, size)
            nm = derive.normal_map(zz, self.grid.width * res / size, strength=1.0)
            Image.fromarray(nm).save(self.out / f"normal_{size}.jpg", quality=92)
        stats = {}
        for name, a in (("slope2", slope2), ("slope1max", slope1max), ("rough2", rough2), ("tpi2", tpi2)):
            q = np.percentile(a, [1, 5, 25, 50, 75, 95, 99])
            stats[name] = [round(float(v), 3) for v in q]
        self.meta["derive_stats_p1_5_25_50_75_95_99"] = stats
        log.info("derive stats %s", stats)

    def step_team_dem(self):
        """The rover team's own terrain mosaic, co-registered with our DTM (shift, height offset, tilt)."""
        tcfg = self.cfg.get("team_dem")
        if not tcfg or not self.need("team_dem_2m.npy", "dem_diff_2m.npy"):
            return
        from . import team_dem
        z2 = np.load(self.out / "analysis_2m.npz")["z"]
        try:
            self.meta["team_dem"] = team_dem.build(self.out, self.grid2, z2, tcfg, self.cache / "team_dem")
        except Exception as e:  # offline or the server is down: the site still builds without it
            log.warning("team DEM step skipped: %s", e)

    def step_skyview(self):
        if not self.need("shield_4m.npy", "horizon_4m.npz"):
            return
        t = time.time()
        g4 = self.grid4
        m_px = int(HORIZON_MARGIN_M / g4.res)
        ext_grid = SiteGrid(g4.lon0, g4.lat0, g4.x_min - m_px * g4.res, g4.y_max + m_px * g4.res,
                            g4.res, g4.width + 2 * m_px, g4.height + 2 * m_px)
        ext, _, missing = terrain.build_dem(ext_grid, self.cfg["dem"].get("preferred"),
                                            resampling=Resampling.average, fill=False)
        regional = read_tif(self.out / "regional_200m.tif")
        rg = self.regional_grid()
        if missing > 0:
            # outside the HiRISE strip: use the regional DEM, shifted to the HiRISE datum
            rr, cc = np.meshgrid(np.arange(ext_grid.height), np.arange(ext_grid.width), indexing="ij")
            rx, ry = ext_grid.rowcol_to_xy(rr, cc)
            r2, c2 = rg.xy_to_rowcol(rx, ry)
            reg_on_ext = sample_bilinear(regional, r2, c2).astype(np.float32)
            ok = np.isfinite(ext)
            off = float(np.nanmedian(ext[ok] - reg_on_ext[ok]))
            ext = np.where(ok, ext, reg_on_ext + off).astype(np.float32)
            self.meta["horizon_regional_offset_m"] = off
        site4 = ext[m_px:m_px + g4.height, m_px:m_px + g4.width]
        n_az = 24
        near = skyview.near_field_tan_horizon(ext, m_px, site4.shape, g4.res, n_az=n_az, max_dist=HORIZON_MARGIN_M)
        far = skyview.far_field_tan_horizon(regional + float(self.meta.get("horizon_regional_offset_m", 0.0)),
                                            rg, g4, site4, n_az=n_az, min_dist=HORIZON_MARGIN_M)
        tan_h = np.maximum(near, far)
        shield = skyview.shielded_fraction(tan_h, n=1.0)
        svf = skyview.sky_view_factor(tan_h)
        np.save(self.out / "shield_4m.npy", shield)
        np.save(self.out / "skyview_4m.npy", svf)
        # Keep the horizon itself: the server uses it for terrain sunrise/sunset, shadows on the route and the
        # light at each stop. Azimuth k is 360 k / n_az degrees clockwise from north.
        hdeg = np.degrees(np.arctan(tan_h))
        q = np.clip(np.rint((hdeg - HORIZON_MIN_DEG) / HORIZON_STEP_DEG), 0, 255).astype(np.uint8)
        np.savez_compressed(self.out / "horizon_4m.npz", h=q, step_deg=HORIZON_STEP_DEG, min_deg=HORIZON_MIN_DEG, n_az=n_az)
        # horizon profile (deg) at the site centre, for the conditions panel / 3D sanity check
        cr, cc_ = g4.height // 2, g4.width // 2
        self.meta["centre_horizon_deg"] = [round(math.degrees(math.atan(max(0.0, float(v)))), 2) for v in tan_h[:, cr, cc_]]
        self.meta["shield_stats"] = {"min": float(shield.min()), "median": float(np.median(shield)), "max": float(shield.max())}
        log.info("skyview in %.0fs  shield min/med/max %.3f/%.3f/%.3f", time.time() - t, shield.min(), np.median(shield), shield.max())

    def team_offset(self) -> tuple[float, float]:
        """Where the rover team's products show a feature relative to our DTM (0, 0 if not measured)."""
        t = self.meta.get("team_dem")
        return (float(t["dx_m"]), float(t["dy_m"])) if t else (0.0, 0.0)

    def step_imagery(self):
        bm = self.cfg["basemap"]
        tdir = DATA_DIR / "tiles" / f"{self.cfg['mission']}_{bm['id']}"
        off = self.team_offset() if bm.get("frame", "team") == "team" else (0.0, 0.0)
        if self.need("texture_4096.jpg", "texture_2048.jpg"):
            tex = imagery.build_texture(bm["url"], bm.get("tms", True), tdir, self.grid,
                                        self.cfg.get("texture_zoom", 17), 4096, offset_m=off)
            self.meta["texture_offset_m"] = [round(off[0], 2), round(off[1], 2)]
            Image.fromarray(tex).save(self.out / "texture_4096.jpg", quality=88)
            Image.fromarray(tex).resize((2048, 2048), Image.LANCZOS).save(self.out / "texture_2048.jpg", quality=88)
            Image.fromarray(tex).resize((512, 512), Image.LANCZOS).save(self.out / "thumb.jpg", quality=85)
        # pre-warm the tile cache so the 2-D map works offline over the site
        bbox = self.grid.with_margin(400).bounds_lonlat()
        n = imagery.fetch_tiles(bm["url"], bm.get("tms", True), tdir, bbox, range(12, 18))
        log.info("basemap tiles cached: %d", n)
        cb = self.cfg.get("context_basemap")
        if cb and self.need("regional_texture.jpg"):
            rg = self.regional_grid()
            cdir = DATA_DIR / "tiles" / f"{self.cfg['mission']}_{cb['id']}"
            tex = imagery.build_texture(cb["url"], cb.get("tms", True), cdir, rg,
                                        self.cfg.get("regional_texture_zoom", 12), 2048,
                                        offset_m=self.team_offset() if cb.get("frame", "team") == "team" else (0.0, 0.0))
            Image.fromarray(tex).save(self.out / "regional_texture.jpg", quality=88)

    def step_thermal(self):
        th = self.cfg.get("thermal")
        if not th or not self.need("thermal_4m.npy"):
            return
        items = stac.search([th["collection"]], ids=[th["item"]], limit=1)
        if not items:
            log.warning("thermal item %s not found", th["item"])
            return
        it = items[0]
        href = next((a["href"] for a in it["assets"].values()
                     if "tiff" in (a.get("type") or "") and "thumb" not in a["href"]), None)
        log.info("THEMIS mosaic %s -> %s", it["id"], href)
        g = self.grid4
        arr = terrain.read_to_grid(href, g, resampling=Resampling.cubic_spline, margin_px=4)
        if not np.isfinite(arr).any():
            log.warning("thermal mosaic has no data here")
            return
        arr = derive.fill_nodata(arr)
        np.save(self.out / "thermal_4m.npy", arr.astype(np.float32))
        self.meta["thermal_source"] = {"id": it["id"], "href": href,
                                       "range": [float(np.nanmin(arr)), float(np.nanmax(arr))]}

    def step_thermal_day(self):
        """THEMIS day IR from NASA Mars Trek: with the night IR it separates rock (warm at night) from loose,
        low-thermal-inertia sand and dust (warm by day, cold at night) and shows which slopes face the sun."""
        tk = self.cfg.get("trek", {}).get("thermal_day")
        if not tk or not self.need("thermal_day_4m.npy"):
            return
        from . import trek
        arr = trek.read_to_grid(tk["layer"], self.grid4, int(tk.get("level", 9)), self.cache / "trek", tk.get("ext", "png"))
        if arr is None or not np.isfinite(arr).any():
            log.warning("Mars Trek %s has no data here", tk["layer"])
            return
        arr = derive.fill_nodata(arr)
        np.save(self.out / "thermal_day_4m.npy", arr.astype(np.float32))
        self.meta["thermal_day_source"] = {"layer": tk["layer"], "level": int(tk.get("level", 9)),
                                           "m_per_px": round(trek.deg_per_px(int(tk.get("level", 9))) * METERS_PER_DEG, 1),
                                           "range": [float(np.nanmin(arr)), float(np.nanmax(arr))]}
        log.info("THEMIS day IR via Mars Trek: %s", self.meta["thermal_day_source"])

    def step_geology(self):
        gcfg = self.cfg.get("geology")
        if not gcfg or not self.need("geology_2m.npy", "geology_meta.json"):
            return
        from . import geology
        try:
            meta = geology.build(self.out, self.grid2, self.grid2.bounds_lonlat(), gcfg, self.cache / "geology")
        except Exception as e:  # the site still builds without it
            log.warning("geology step skipped: %s", e)
            return
        if meta:
            self.meta["geology"] = {"map": meta["map"], "units": len([u for u in meta["units"] if u["share"] > 0]),
                                    "coverage": meta["coverage"]}

    def step_crism(self):
        """CRISM mineral-indicator composites (hydrated/sulfate, clay, mafic, iron) on the 4 m grid."""
        if not self.need("crism_meta.json"):
            return
        from . import crism
        try:
            meta = crism.build(self.out, self.grid4, self.cfg["bbox"], DATA_DIR / "cache" / "crism",
                               notes=self.cfg.get("crism_notes"))
            self.meta["crism"] = {k: {"coverage": v["coverage"], "products": len(v["products"])} for k, v in meta["layers"].items()}
        except Exception as e:  # offline or ODE down: the site still builds without the spectral layers
            log.warning("CRISM step skipped: %s", e)

    def step_boulders(self):
        """Boulders from shadows in the DTM's own (co-registered) HiRISE orthoimage."""
        if not self.need("boulders.json", "boulders_2m.npy"):
            return
        from . import boulders
        href = self._best_ortho()
        if href is None:
            log.warning("boulders: no orthoimage found for the site's DTM")
            return
        res = boulders.build(href, self.grid, self.grid2, self.dem())
        (self.out / "boulders.json").write_text(json.dumps({"stats": res["stats"], "ortho": href, "boulders": res["boulders"]}))
        np.save(self.out / "boulders_2m.npy", res["grid2"].astype(np.float32))
        self.meta["boulders"] = dict(res["stats"], ortho=href.rsplit("/", 1)[-1])
        log.info("boulders: %d detected (%d >= 1 m, %d >= 2 m)", res["stats"]["count"], res["stats"]["ge_1m"], res["stats"]["ge_2m"])

    def _best_ortho(self):
        """Full-resolution RED orthoimage of the first DTM; the more nadir of the stereo pair."""
        ids = [d["id"] for d in self.meta.get("dem_sources", [])] or self.cfg["dem"].get("preferred", [])
        if not ids:
            return None
        items = stac.search([self.cfg["dem"]["collection"]], ids=ids[:1], limit=1)
        if not items:
            return None
        orthos = [a["href"] for k, a in items[0]["assets"].items() if k.startswith("ortho_") and "thumbnail" not in k
                  and "label" not in k and "_RED_A_" in a["href"]]
        if not orthos:
            return None
        best, best_off = orthos[0], 1e9
        for href in orthos:
            obs = href.rsplit("/", 1)[-1].split("_RED_")[0] + "_RED"
            try:
                it = stac.search(["mro_hirise_uncontrolled_observations"], ids=[obs], limit=1)
                off = float(it[0]["properties"].get("view:off_nadir", 99)) if it else 99.0
            except Exception:
                off = 99.0
            if off < best_off:
                best, best_off = href, off
        return best

    def step_sand(self):
        """Loose-sand likelihood (0..1) on the 2 m grid, its confidence and its clues (see pipeline/sand.py)."""
        if not self.need("sand_2m.npy", "sand_conf_2m.npy", "sand_parts_2m.npz"):
            return
        from . import sand
        a = np.load(self.out / "analysis_2m.npz")
        H, W = a["z"].shape
        tex_p = self.out / "texture_2048.jpg"
        tex = np.asarray(Image.open(tex_p).convert("L").resize((W, H), Image.BILINEAR), np.float32) if tex_p.exists() else None
        th_p = self.out / "thermal_4m.npy"
        night = np.load(th_p) if th_p.exists() else None
        from . import geology as _geology
        geo, gmeta = _geology.load(self.out)
        parts = sand.clues(a["slope"], a["tpi"], night, tex, geo, gmeta)
        p, conf = sand.combine(parts)
        np.save(self.out / "sand_2m.npy", p.astype(np.float32))
        np.save(self.out / "sand_conf_2m.npy", conf.astype(np.float16))
        # the clues' logit contributions, int8 in steps of 0.05, so Inspect can say why
        np.savez_compressed(self.out / "sand_parts_2m.npz", scale=0.05,
                            **{k: np.clip(np.rint(v / 0.05), -127, 127).astype(np.int8) for k, v in parts.items()})
        self.meta["sand"] = {"model": "pipeline/sand.py (night IR + darkness + bedform unit, placed by hollows)",
                             "clues": list(parts), "share_ge_058": round(float((p >= 0.58).mean()), 4),
                             "share_ge_072": round(float((p >= 0.72).mean()), 4), "mean": round(float(p.mean()), 4),
                             "confidence_mean": round(float(conf.mean()), 3)}
        units = sand.bedform_units(gmeta)
        if units:  # how well the score finds the mapped bedforms (a check, not a fit: the map is one of the clues)
            lab = np.isin(geo, units)
            p0, _ = sand.combine({k: v for k, v in parts.items() if k != "geology"})
            self.meta["sand"]["check_bedform_unit"] = {
                "in_mean": round(float(p0[lab].mean()), 3), "out_mean": round(float(p0[~lab].mean()), 3),
                "out_flagged_ge_058": round(float((p0[~lab] >= 0.58).mean()), 4)}
        log.info("sand: %s", self.meta["sand"])

    def step_confidence(self):
        """Terrain confidence from the agreement of two independent DTMs (see pipeline/confidence.py)."""
        from . import confidence
        a = np.load(self.out / "analysis_2m.npz")
        meta = confidence.build(self.out, a["z"], self.grid2.res)
        if meta:
            self.meta["terrain_confidence"] = meta

    def step_science(self):
        """Science-opportunity score from CRISM, geologic contacts, ridges/hollows and rover data (pipeline/science.py)."""
        from . import geology as _geology
        from . import science
        a = np.load(self.out / "analysis_2m.npz")
        sand_p = self.out / "sand_2m.npy"
        sand_arr = np.load(sand_p) if sand_p.exists() else np.zeros_like(a["z"])
        geo, _ = _geology.load(self.out)
        self.meta["science"] = science.build(self.out, self.grid2, a["tpi"], sand_arr, geo)

    def step_ingenuity(self):
        """Ingenuity's flights near the site, on our terrain (sites with "ingenuity": true)."""
        if not self.cfg.get("ingenuity"):
            return
        from . import ingenuity
        try:
            meta = ingenuity.build(self.out, self.grid, self.grid4, self.cache, self.meta.get("team_dem"))
        except Exception as e:  # offline: the site still builds without it
            log.warning("ingenuity step skipped: %s", e)
            return
        if meta:
            self.meta["ingenuity"] = meta

    def step_chemistry(self):
        """What the rover measured at its targets (ChemCam oxides at Gale), placed on the rover's track."""
        if not self.need("chemistry.json") and "chemistry" in self.meta:
            return
        from . import chemistry
        try:
            meta = chemistry.build(self.out, self.cfg, self.grid, self.cache / "chemcam")
        except Exception as e:  # offline: the site still builds without it
            log.warning("chemistry step skipped: %s", e)
            return
        if meta:
            self.meta["chemistry"] = meta
            log.info("chemistry: %d targets from %s", meta["n_targets"], ", ".join(meta["files"]))

    def step_radar(self):
        """Perseverance's RIMFAX ground radar under the rover's track (geophysical data; none at Gale)."""
        if not self.need("radar.json") and "radar" in self.meta:
            return
        from . import radar
        try:
            meta = radar.build(self.out, self.cfg, self.grid, self.cache / "rimfax", team=self.meta.get("team_dem"),
                               dem=self.dem())
        except Exception as e:  # offline: the site still builds without it
            log.warning("radar step skipped: %s", e)
            return
        if meta:
            self.meta["radar"] = meta
            log.info("radar: %d sols, %.0f m of track in %d pieces (%d sols left out)", meta["sols"],
                     meta["length_m"], meta["pieces"], meta["skipped"])

    def step_rover(self):
        rv = self.cfg["rover"]
        dem = self.dem()
        wp_all = rover.load(rv["waypoints"], self.cache / f"{self.cfg['mission']}_waypoints.json")
        tr_all = rover.load(rv["traverse"], self.cache / f"{self.cfg['mission']}_traverse.json")
        team = self.meta.get("team_dem")  # the team's frame, measured against our DTM (None: use positions as published)
        raw, raw_offset, _, raw_spread = rover.process_waypoints(wp_all, self.grid, dem, rv.get("elev_key", "elev_geoid"))
        wp, offset, n, spread = rover.process_waypoints(wp_all, self.grid, dem, rv.get("elev_key", "elev_geoid"), team=team)
        (self.out / "rover_waypoints.geojson").write_text(json.dumps(wp))
        (self.out / "rover_traverse.geojson").write_text(json.dumps(rover.clip_lines(tr_all, self.grid, 300, team=team)))
        (self.out / "rover_traverse_full.geojson").write_text(json.dumps(rover.simplify_full(tr_all, grid=self.grid, team=team)))
        latest = max(wp_all["features"], key=lambda f: f["properties"].get("sol") or 0)
        lat_lon = [float(v) for v in rover.move(self.grid, *latest["geometry"]["coordinates"][:2], team)]
        self.meta["rover"] = {"waypoints_in_site": len(wp["features"]), "datum_offset_m": round(offset, 2),
                              "datum_spread_m": round(spread, 2) if spread is not None else None,
                              "offset_samples": n, "latest_sol": latest["properties"].get("sol"),
                              "latest_lonlat": [round(lat_lon[0], 7), round(lat_lon[1], 7)],
                              "aligned_with_team_dem": bool(team),
                              "unaligned_offset_m": round(raw_offset, 2),
                              "unaligned_spread_m": round(raw_spread, 2) if raw_spread is not None else None}
        for ex in rv.get("extras", []):
            fc = rover.load(ex["url"], self.cache / f"{self.cfg['mission']}_{ex['id']}.json")
            if ex["kind"] == "points":
                out = rover.generic_points(fc, self.grid, ex.get("props", []), ex.get("margin_m", 3000), team=team)
            else:
                out = rover.generic_lines(fc, self.grid, ex.get("props", []), ex.get("margin_m", 3000), team=team)
            (self.out / f"extra_{ex['id']}.geojson").write_text(json.dumps(out))
        log.info("rover: %d waypoints in site; rover heights sit %.2f m (+-%s) from our DTM (%s; unaligned %.2f m +-%s)",
                 len(wp["features"]), offset, None if spread is None else round(spread, 2),
                 "positions moved by the team-DEM shift" if team else "positions as published", raw_offset,
                 None if raw_spread is None else round(raw_spread, 2))

    def step_contours(self):
        if not self.need("contours.geojson"):
            return
        a = np.load(self.out / "analysis_2m.npz")
        fc = contours.contours_geojson(a["z"], self.grid2, interval=5.0, index_every=5, smooth_sigma_px=1.5)
        (self.out / "contours.geojson").write_text(json.dumps(fc))

    def step_meta(self):
        dem = self.dem()
        self.meta.update({
            "site_id": self.site_id,
            "built_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "grid_1m": self.grid.to_dict(),
            "grid_2m": self.grid2.to_dict(),
            "grid_4m": self.grid4.to_dict(),
            "bounds_lonlat": self.grid.bounds_lonlat(),
            "elev_min": float(dem.min()), "elev_max": float(dem.max()),
            "size_m": [self.grid.width * self.grid.res, self.grid.height * self.grid.res],
            "meters_per_deg_lat": METERS_PER_DEG,
        })
        if (self.out / "regional_200m.tif").exists():
            reg = read_tif(self.out / "regional_200m.tif")
            rg = self.regional_grid()
            self.meta["regional_grid"] = rg.to_dict()
            self.meta["regional_elev"] = [float(reg.min()), float(reg.max())]
            # vertical offset HiRISE DTM - HRSC/MOLA blend over the site (3D backdrop alignment)
            g4 = self.grid4
            rr, cc = np.meshgrid(np.arange(0, g4.height, 8), np.arange(0, g4.width, 8), indexing="ij")
            x, y = g4.rowcol_to_xy(rr, cc)
            r2, c2 = rg.xy_to_rowcol(x, y)
            reg_s = sample_bilinear(reg, r2, c2)
            dem4 = derive.block_reduce(dem, 4, "mean")[::8, ::8]
            self.meta["regional_offset_m"] = round(float(np.nanmedian(dem4 - reg_s)), 2)

    def run(self, only: list[str] | None = None):
        for name in STEPS:
            if only and name not in only:
                continue
            t = time.time()
            log.info("=== %s", name)
            getattr(self, f"step_{name}")()
            self.save_meta()
            log.info("    %s done in %.1fs", name, time.time() - t)


def _resize(a: np.ndarray, size: int) -> np.ndarray:
    return np.asarray(Image.fromarray(a.astype(np.float32)).resize((size, size), Image.BILINEAR), np.float32)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("site")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--only", nargs="*", choices=STEPS)
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s: %(message)s", datefmt="%H:%M:%S")
    Builder(args.site, force=args.force).run(args.only)


if __name__ == "__main__":
    main()
