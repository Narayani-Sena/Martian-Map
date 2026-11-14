"""Skyline fix (feature B1): where am I, with no GPS? Match the horizon the helmet sees against the stored horizon
of every 4 m cell.

There is no GPS on Mars. Perseverance has localised itself operationally since February 2026 by matching its
panoramas against orbital maps (Mars Global Localization). Here the helmet's skyline (horizon elevation in 24
directions) is compared with the horizon the site build stored for every 4 m cell (`horizon_4m.npz`: near field
from the HiRISE DTM, far field such as Mount Sharp from the 200 m regional model).

The match is a least-squares fit over all cells (one matrix product), optionally over every heading too (no
compass works on Mars: no global magnetic field). The spread of the cells that fit almost as well is the
uncertainty: it grows in a featureless hollow and closes when a distinctive skyline comes into view.

Honest caveat: the "truth" here comes from the same terrain model, so the observed skyline is simulated from the
stored one plus noise (measurement noise, quantisation, a heading error). Real panoramas differ more.
"""

from __future__ import annotations

import math
import time

import numpy as np

AZ_STEPS_UNKNOWN = 48  # headings tried when the heading is unknown (7.5 deg apart)


class SkylineIndex:
    """The stored horizon of every 4 m cell as an (N, n_az) matrix of elevation angles (deg)."""

    def __init__(self, site):
        h, step, lo = site.horizon
        self.n_az = h.shape[0]
        self.shape = h.shape[1:]
        self.step = float(step)
        self.H = np.ascontiguousarray((lo + step * h.reshape(self.n_az, -1).astype(np.float32)).T)  # (N, n_az)
        self.H2 = np.einsum("ij,ij->i", self.H, self.H)
        self.grid = site.grid4
        self.site = site

    # ------------------------------------------------------------------ observing
    def profile(self, r: int, c: int) -> np.ndarray:
        return self.H[r * self.shape[1] + c].astype(np.float64)

    def observe(self, r: int, c: int, noise_deg: float = 0.5, heading_err_deg: float = 0.0, rng=None) -> np.ndarray:
        """The skyline the helmet would measure at cell (r, c): the stored one, read with a heading error
        (directions rotated by heading_err_deg) plus Gaussian noise."""
        rng = rng or np.random.default_rng()
        p = self.profile(r, c)
        out = _rotate(p, heading_err_deg / (360.0 / self.n_az))
        return out + rng.normal(0.0, noise_deg, self.n_az)

    # ------------------------------------------------------------------ matching
    def locate(self, obs: np.ndarray, heading_known: bool = True, heading_tol_deg: float = 10.0,
               sigma_deg: float = 0.6, prior: tuple | None = None) -> dict:
        """Best-fitting cell for an observed skyline, the heading error it implies, and how sure the fit is.

        heading_known: the heading is known to within heading_tol_deg (a sun compass); else every heading is tried.
        sigma_deg: one-sigma mismatch per direction (measurement noise, quantisation and model error).
        prior: (row, col, sigma_m) dead-reckoned position, or None (the whole site is possible).
        """
        t0 = time.perf_counter()
        n = self.n_az
        o = np.asarray(obs, np.float64)
        if heading_known:
            k = max(1, int(math.ceil(heading_tol_deg / 2.5)))
            shifts = np.linspace(-heading_tol_deg, heading_tol_deg, 2 * k + 1)
        else:
            shifts = np.arange(AZ_STEPS_UNKNOWN) * (360.0 / AZ_STEPS_UNKNOWN)
        # O[:, j] = the observation rotated back by shift j (so stored direction k lines up with observed k)
        O = np.stack([_rotate(o, -s / (360.0 / n)) for s in shifts], axis=1).astype(np.float32)  # (n, S)
        cross = self.H @ O  # (N, S)
        o2 = (O.astype(np.float64) ** 2).sum(0)  # (S,)
        ssd = self.H2[:, None] - 2.0 * cross + o2[None, :].astype(np.float32)
        best_s = np.argmin(ssd, axis=1)
        ssd_min = ssd[np.arange(ssd.shape[0]), best_s].astype(np.float64)
        ll = -0.5 * ssd_min / (sigma_deg ** 2)
        H, W = self.shape
        if prior is not None:
            pr, pc, ps = prior
            rr, cc = np.divmod(np.arange(H * W), W)
            d2 = ((rr - pr) ** 2 + (cc - pc) ** 2) * self.grid.res ** 2
            ll = ll - 0.5 * d2 / (ps ** 2)
        i = int(np.argmax(ll))
        w = np.exp(ll - ll[i])
        keep = w > 1e-4
        wk = w[keep]
        idx = np.flatnonzero(keep)
        rr, cc = np.divmod(idx, W)
        xs, ys = self.grid.rowcol_to_xy(rr.astype(float), cc.astype(float))
        wsum = wk.sum()
        mx, my = float((wk * xs).sum() / wsum), float((wk * ys).sum() / wsum)
        cov = np.cov(np.vstack([xs, ys]), aweights=wk) if idx.size > 2 else np.zeros((2, 2))
        ev = np.linalg.eigvalsh(np.atleast_2d(cov)) if idx.size > 2 else np.zeros(2)
        sd = float(math.sqrt(max(0.0, float(ev.max())))) if ev.size else 0.0
        r95 = max(self.grid.res, 2.45 * sd)  # 95 % circle of a 2-D normal ~ 2.45 sigma
        br, bc = divmod(i, W)
        blon, blat = (float(v) for v in self.grid.rowcol_to_lonlat(br, bc))
        heading = float(shifts[int(best_s[i])])
        if heading > 180:
            heading -= 360.0
        # the 12 next-best separate places (more than 3 r95 away from the best), for an ambiguity picture
        alts = []
        order = np.argsort(-ll)[:4000]
        for j in order.tolist():
            jr, jc = divmod(j, W)
            if math.hypot(jr - br, jc - bc) * self.grid.res < max(60.0, 3 * r95):
                continue
            if any(math.hypot(jr - a[0], jc - a[1]) * self.grid.res < 60.0 for a in alts):
                continue
            alts.append((jr, jc, float(ll[j] - ll[i])))
            if len(alts) >= 6:
                break
        return {"row": br, "col": bc, "lon": round(blon, 7), "lat": round(blat, 7), "heading_err_deg": round(heading, 1),
                "r95_m": round(r95, 1), "n_candidates": int(idx.size), "rms_deg": round(math.sqrt(max(0.0, float(ssd_min[i])) / n), 2),
                "alternatives": [{"lon": round(float(v[0]), 7), "lat": round(float(v[1]), 7), "dlog_lik": round(a[2], 1)}
                                 for a in alts for v in [self.grid.rowcol_to_lonlat(a[0], a[1])]],
                "compute_ms": round((time.perf_counter() - t0) * 1000.0, 1)}

    def likelihood_png(self, obs: np.ndarray, heading_known: bool = True, sigma_deg: float = 0.6, size: int = 512) -> bytes:
        """The fit of every cell as a picture: bright where the skyline matches (for the map)."""
        from PIL import Image
        import io
        n = self.n_az
        O = np.asarray(obs, np.float32)[:, None]
        if not heading_known:
            shifts = np.arange(AZ_STEPS_UNKNOWN) * (360.0 / AZ_STEPS_UNKNOWN)
            O = np.stack([_rotate(np.asarray(obs, float), -s / (360.0 / n)) for s in shifts], axis=1).astype(np.float32)
        ssd = (self.H2[:, None] - 2.0 * (self.H @ O) + (O ** 2).sum(0)[None, :]).min(1)
        ll = -0.5 * ssd / sigma_deg ** 2
        v = np.exp(np.clip(ll - ll.max(), -30, 0) / 6.0).reshape(self.shape)  # soft, so near-misses show too
        a = (np.clip(v, 0, 1) * 255).astype(np.uint8)
        rgba = np.zeros(self.shape + (4,), np.uint8)
        rgba[..., 0] = 255
        rgba[..., 1] = (120 + 0.53 * a).astype(np.uint8)
        rgba[..., 2] = 40
        rgba[..., 3] = (a * 0.85).astype(np.uint8)
        im = Image.fromarray(rgba, "RGBA").resize((size, size), Image.BILINEAR)
        buf = io.BytesIO()
        im.save(buf, "PNG")
        return buf.getvalue()


def _rotate(p: np.ndarray, k: float) -> np.ndarray:
    """p resampled at index i + k (circular, linear between the stored directions)."""
    n = p.size
    x = (np.arange(n) + k) % n
    i0 = np.floor(x).astype(int)
    f = x - i0
    return (1 - f) * p[i0 % n] + f * p[(i0 + 1) % n]


def evaluate(idx: SkylineIndex, n: int = 1000, noise_deg: float = 0.5, heading_known: bool = True,
             heading_err_deg: float = 4.0, seed: int = 7, walkable=None) -> dict:
    """feature B1 acceptance check: median error over n random cells with noise added (and a heading error)."""
    rng = np.random.default_rng(seed)
    H, W = idx.shape
    cells = np.flatnonzero(walkable.ravel()) if walkable is not None else np.arange(H * W)
    pick = rng.choice(cells, size=min(n, cells.size), replace=False)
    errs, r95, inside = [], [], 0
    for i in pick.tolist():
        r, c = divmod(i, W)
        he = float(rng.uniform(-heading_err_deg, heading_err_deg)) if heading_known else float(rng.uniform(0, 360))
        obs = idx.observe(r, c, noise_deg, he, rng)
        fx = idx.locate(obs, heading_known=heading_known, heading_tol_deg=max(heading_err_deg, 2.5) + 2.5)
        e = math.hypot(fx["row"] - r, fx["col"] - c) * idx.grid.res
        errs.append(e)
        r95.append(fx["r95_m"])
        inside += e <= fx["r95_m"] + idx.grid.res
    errs = np.asarray(errs)
    return {"n": len(errs), "noise_deg": noise_deg, "heading_known": heading_known,
            "median_m": round(float(np.median(errs)), 1), "p90_m": round(float(np.percentile(errs, 90)), 1),
            "within_20m": round(float((errs <= 20).mean()), 3), "within_100m": round(float((errs <= 100).mean()), 3),
            "median_r95_m": round(float(np.median(r95)), 1), "circle_holds": round(inside / max(1, len(errs)), 3)}


def features(site, lon: float, lat: float) -> list[dict]:
    """Named skyline features (config `skyline_features`) seen from a point: bearing, distance, elevation angle."""
    out = []
    g = site.grid
    x0, y0 = g.lonlat_to_xy(lon, lat)
    for f in site.cfg.get("skyline_features", []):
        x, y = g.lonlat_to_xy(f["lon"], f["lat"])
        dx, dy = float(x - x0), float(y - y0)
        d = math.hypot(dx, dy)
        az = math.degrees(math.atan2(dx, dy)) % 360.0
        out.append({"name": f["name"], "az": round(az, 1), "dist_km": round(d / 1000.0, 1), "note": f.get("note", "")})
    return out


def fix_quality_map(idx: SkylineIndex, stride: int = 4, radius_m: float = 240.0, step: int = 4, sigma_deg: float = 0.6,
                    noise_deg: float = 0.5) -> np.ndarray:
    """Expected 95 % fix radius (m) on a grid `stride` times coarser than 4 m: how far apart places with almost
    the same skyline lie (offsets up to radius_m, every `step` cells). Small = a distinctive skyline, a good fix;
    large = a featureless hollow. Capped at radius_m."""
    H, W = idx.shape
    P = idx.H.reshape(H, W, idx.n_az)
    sub = P[::stride, ::stride]  # (h, w, n)
    h, w = sub.shape[:2]
    rad = int(radius_m / idx.grid.res)
    num = np.zeros((h, w))
    den = np.zeros((h, w))
    s2 = sigma_deg ** 2 + noise_deg ** 2
    rr0 = np.arange(h) * stride
    cc0 = np.arange(w) * stride
    for dr in range(-rad, rad + 1, step):
        for dc in range(-rad, rad + 1, step):
            d2 = (dr * dr + dc * dc) * idx.grid.res ** 2
            if d2 > radius_m ** 2:
                continue
            ri = np.clip(rr0 + dr, 0, H - 1)
            ci = np.clip(cc0 + dc, 0, W - 1)
            other = P[ri][:, ci]
            ssd = ((other - sub) ** 2).sum(-1)
            wgt = np.exp(-0.5 * ssd / s2)
            num += wgt * d2
            den += wgt
    sd = np.sqrt(num / np.maximum(den, 1e-9) / 2.0)
    return np.clip(2.45 * sd, idx.grid.res, radius_m).astype(np.float32)


FIX_LEGEND = {"unit": "m (expected 95 % skyline-fix radius)", "stops": [[4, "#1a9850"], [25, "#a6d96a"], [60, "#fee08b"], [120, "#f46d43"], [240, "#a50026"]]}
