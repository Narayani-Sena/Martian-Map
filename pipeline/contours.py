"""Elevation contour lines as GeoJSON (marching squares from scikit-image)."""

from __future__ import annotations

import numpy as np
from scipy import ndimage
from shapely.geometry import LineString
from skimage import measure

from marsgeo.grid import SiteGrid


def contours_geojson(dem: np.ndarray, grid: SiteGrid, interval: float = 5.0, index_every: int = 5,
                     smooth_sigma_px: float = 1.5, simplify_m: float = 1.0, min_len_m: float = 30.0) -> dict:
    z = ndimage.gaussian_filter(dem.astype(np.float64), smooth_sigma_px)
    lo = np.ceil(np.nanmin(z) / interval) * interval
    hi = np.floor(np.nanmax(z) / interval) * interval
    feats = []
    for level in np.arange(lo, hi + interval / 2, interval):
        lines = []
        for path in measure.find_contours(z, level):
            x, y = grid.rowcol_to_xy(path[:, 0], path[:, 1])
            ls = LineString(np.column_stack([x, y]))
            if ls.length < min_len_m:
                continue
            ls = ls.simplify(simplify_m)
            xy = np.asarray(ls.coords)
            lon, lat = grid.xy_to_lonlat(xy[:, 0], xy[:, 1])
            lines.append([[round(float(a), 7), round(float(b), 7)] for a, b in zip(lon, lat)])
        if lines:
            is_index = int(round(level / interval)) % index_every == 0
            feats.append({"type": "Feature", "geometry": {"type": "MultiLineString", "coordinates": lines},
                          "properties": {"elev": float(level), "index": bool(is_index)}})
    return {"type": "FeatureCollection", "features": feats}
