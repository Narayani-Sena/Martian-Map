"""Minutes-to-habitat field ("walk-back rings").

We need, for *every* cell, the fastest walking time from that cell back to the
habitat. Walking time is direction-dependent (uphill is slower), so we build a
directed graph on the 4 m grid - 8 edges per cell - and run Dijkstra *from*
the habitat over the reversed edges (scipy.sparse.csgraph, written in C).
Reversing the edges turns "time from the hab to p" into "time from p to the hab".
"""

from __future__ import annotations

import time

import numpy as np
from scipy import ndimage
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import dijkstra
from skimage import measure

from marsgeo.grid import SiteGrid

from .walkmodel import WalkParams

OFFS8 = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
RING_LEVELS_MIN = [15, 30, 45, 60, 90, 120]


def coarsen_multiplier(mult2: np.ndarray) -> np.ndarray:
    """2 m -> 4 m: mean of passable sub-cells; no-go if 2+ of the 4 are no-go."""
    h, w = (mult2.shape[0] // 2) * 2, (mult2.shape[1] // 2) * 2
    v = mult2[:h, :w].reshape(h // 2, 2, w // 2, 2)
    bad = (~np.isfinite(v)).sum(axis=(1, 3))
    ok = np.isfinite(v)
    n = ok.sum(axis=(1, 3))
    with np.errstate(invalid="ignore", divide="ignore"):
        m = np.where(ok, v, 0.0).sum(axis=(1, 3)) / n
    m[(bad >= 2) | (n == 0)] = np.inf
    return m.astype(np.float32)


def reverse_graph(z4: np.ndarray, mult4: np.ndarray, res: float, p: WalkParams) -> csr_matrix:
    """The 8-connected walking graph on the 4 m grid with every edge reversed.

    Entry (dst, src) holds the time to walk src -> dst, so Dijkstra *from* a haven over this graph gives
    the time from every cell *to* the haven. Its transpose is the forward graph (time from a start cell).
    """
    H, W = z4.shape
    idx = np.arange(H * W).reshape(H, W)
    rows, cols, data = [], [], []
    for dr, dc in OFFS8:
        rs = slice(max(0, -dr), H - max(0, dr))
        cs = slice(max(0, -dc), W - max(0, dc))
        rd = slice(max(0, dr), H - max(0, -dr))
        cd = slice(max(0, dc), W - max(0, -dc))
        d = res * np.hypot(dr, dc)
        grade = (z4[rd, cd] - z4[rs, cs]) / d
        t = d / (p.v_flat() * p.grade_factor(grade)) * 0.5 * (mult4[rs, cs] + mult4[rd, cd])
        ok = np.isfinite(t)
        # reversed edge: (dst -> src) carries the time of walking src -> dst
        rows.append(idx[rd, cd][ok])
        cols.append(idx[rs, cs][ok])
        data.append(t[ok].astype(np.float64))
    return csr_matrix((np.concatenate(data), (np.concatenate(rows), np.concatenate(cols))), shape=(H * W, H * W))


def walkback_field(z4: np.ndarray, mult4: np.ndarray, res: float, hab_rc, p: WalkParams) -> np.ndarray:
    H, W = z4.shape
    g = reverse_graph(z4, mult4, res, p)
    r, c = hab_rc
    dist = dijkstra(g, directed=True, indices=int(r * W + c))
    return dist.reshape(H, W).astype(np.float32)


def walkback_tree(z4: np.ndarray, mult4: np.ndarray, res: float, sources_rc, p: WalkParams, graph=None):
    """Fastest way home from every cell to the nearest of several havens.

    Returns (dist_s HxW float32, next_cell flat int32 (-1 = none: a haven or no way home), basin HxW int8
    (index into sources_rc, -1 = no way home)). next_cell[i] is the next 4 m cell on cell i's fastest walk home.
    """
    H, W = z4.shape
    g = graph if graph is not None else reverse_graph(z4, mult4, res, p)
    src = [int(r) * W + int(c) for r, c in sources_rc]
    dist, pred, origin = dijkstra(g, directed=True, indices=src, min_only=True, return_predecessors=True)
    pred = np.where(pred < 0, -1, pred).astype(np.int32)
    basin = np.full(H * W, -1, np.int8)
    ok = origin >= 0
    if ok.any():  # source node index -> its position in sources_rc
        src_arr = np.asarray(src)
        order = np.argsort(src_arr, kind="stable")
        pos = np.clip(np.searchsorted(src_arr[order], origin[ok]), 0, len(src) - 1)
        basin[ok] = order[pos].astype(np.int8)
    return dist.reshape(H, W).astype(np.float32), pred, basin.reshape(H, W)


def forward_field(z4: np.ndarray, mult4: np.ndarray, res: float, start_rc, p: WalkParams, graph=None) -> np.ndarray:
    """Walking time (s) from one cell to every other cell (the forward graph: the reverse graph transposed)."""
    H, W = z4.shape
    g = graph if graph is not None else reverse_graph(z4, mult4, res, p)
    r, c = start_rc
    dist = dijkstra(g.T.tocsr(), directed=True, indices=int(r) * W + int(c))
    return dist.reshape(H, W).astype(np.float32)


def rings_geojson(field_s: np.ndarray, grid4: SiteGrid, levels_min=RING_LEVELS_MIN, min_vertices: int = 40) -> dict:
    """Contour lines of the walk-back field.

    No-go pockets are *masked out* rather than given a huge value - otherwise every
    steep patch gets its own little ring at every level. Short loops (< ~160 m of
    contour) are dropped as clutter.
    """
    minutes = field_s / 60.0
    ok = np.isfinite(minutes)
    if not ok.any():
        return {"type": "FeatureCollection", "features": []}
    # fill no-go cells with their nearest reachable value so smoothing doesn't bleed
    idx = ndimage.distance_transform_edt(~ok, return_distances=False, return_indices=True)
    m = ndimage.gaussian_filter(minutes[tuple(idx)], 1.5)
    mask = ok
    feats = []
    for lv in levels_min:
        lines = []
        for path in measure.find_contours(m, lv, mask=mask):
            if len(path) < min_vertices:
                continue
            lon, lat = grid4.rowcol_to_lonlat(path[:, 0], path[:, 1])
            lines.append([[round(float(a), 7), round(float(b), 7)] for a, b in zip(lon[::2], lat[::2])])
        if lines:
            feats.append({"type": "Feature", "properties": {"minutes": lv},
                          "geometry": {"type": "MultiLineString", "coordinates": lines}})
    return {"type": "FeatureCollection", "features": feats}


class WalkbackCache:
    def __init__(self, maxsize: int = 8):
        self.maxsize = maxsize
        self.items: dict[str, dict] = {}

    def get(self, key):
        v = self.items.pop(key, None)
        if v is not None:
            self.items[key] = v
        return v

    def put(self, key, value):
        self.items[key] = value
        while len(self.items) > self.maxsize:
            self.items.pop(next(iter(self.items)))


def compute(site, hab_lonlat, p: WalkParams) -> dict:
    t0 = time.perf_counter()
    g4 = site.grid4
    r, c = (int(round(v)) for v in g4.lonlat_to_rowcol(*hab_lonlat))
    r = min(max(r, 0), g4.height - 1)
    c = min(max(c, 0), g4.width - 1)
    mult4 = coarsen_multiplier(site.multiplier(p))
    if not np.isfinite(mult4[r, c]):  # hab on a no-go cell: open it so the field is defined
        mult4[r, c] = 1.0
    field_s = walkback_field(site.z4, mult4, g4.res, (r, c), p)
    rings = rings_geojson(field_s, g4)
    fin = np.isfinite(field_s)
    return {
        "field": field_s,
        "rings": rings,
        "max_min": float(field_s[fin].max() / 60) if fin.any() else 0.0,
        "reachable_fraction": float(fin.mean()),
        "compute_ms": (time.perf_counter() - t0) * 1000,
    }
