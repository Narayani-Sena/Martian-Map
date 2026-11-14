"""Local metric grids for a small Mars site.

Map libraries assume Earth. Over a site a few kilometres across, Mars is
flat to well under a metre, so we use an equirectangular projection whose
true-scale latitude is the site's own latitude:

    x = R * cos(lat0) * (lon - lon0)      (metres east of the centre)
    y = R * (lat - lat0)                  (metres north of the centre)

The same two lines are mirrored in the web app (web/src/lib/geo.js), so the
browser and the server agree on every coordinate without needing PROJ.

Pixel convention: pixel (row, col) covers x in [x_min + col*res, x_min + (col+1)*res]
and y in [y_max - (row+1)*res, y_max - row*res]. Row 0 is the northern edge.
"""

from __future__ import annotations

import math
from dataclasses import asdict, dataclass

import numpy as np

from .constants import MARS_RADIUS_M


@dataclass(frozen=True)
class SiteGrid:
    lon0: float  # projection centre longitude (deg, east-positive)
    lat0: float  # projection centre latitude (deg) = true-scale latitude
    x_min: float  # west edge (m)
    y_max: float  # north edge (m)
    res: float  # cell size (m)
    width: int
    height: int

    # ------------------------------------------------------------------ build
    @classmethod
    def from_bbox(cls, bbox, res: float, lon0: float | None = None, lat0: float | None = None,
                  multiple: int = 1) -> "SiteGrid":
        """Grid covering bbox = (lon_min, lat_min, lon_max, lat_max).

        multiple rounds width/height to a multiple (so 2x/4x coarser grids align exactly).
        """
        lon_min, lat_min, lon_max, lat_max = bbox
        lon0 = (lon_min + lon_max) / 2 if lon0 is None else lon0
        lat0 = (lat_min + lat_max) / 2 if lat0 is None else lat0
        tmp = cls(lon0, lat0, 0.0, 0.0, res, 1, 1)
        x0, y0 = tmp.lonlat_to_xy(lon_min, lat_min)
        x1, y1 = tmp.lonlat_to_xy(lon_max, lat_max)
        width = int(round((x1 - x0) / res / multiple)) * multiple
        height = int(round((y1 - y0) / res / multiple)) * multiple
        # centre the grid on the bbox centre so rounding is symmetric
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        return cls(lon0, lat0, cx - width * res / 2, cy + height * res / 2, res, width, height)

    @classmethod
    def from_dict(cls, d: dict) -> "SiteGrid":
        return cls(**{k: d[k] for k in ("lon0", "lat0", "x_min", "y_max", "res", "width", "height")})

    def to_dict(self) -> dict:
        return asdict(self)

    def with_margin(self, margin_m: float, res: float | None = None) -> "SiteGrid":
        """Same projection, grown by margin_m on every side (optionally new res)."""
        res = self.res if res is None else res
        w = int(math.ceil((self.width * self.res + 2 * margin_m) / res))
        h = int(math.ceil((self.height * self.res + 2 * margin_m) / res))
        cx = self.x_min + self.width * self.res / 2
        cy = self.y_max - self.height * self.res / 2
        return SiteGrid(self.lon0, self.lat0, cx - w * res / 2, cy + h * res / 2, res, w, h)

    def resampled(self, factor: int) -> "SiteGrid":
        """Coarser grid covering the same area (factor must divide width/height)."""
        return SiteGrid(self.lon0, self.lat0, self.x_min, self.y_max, self.res * factor,
                        self.width // factor, self.height // factor)

    # ------------------------------------------------------------- properties
    @property
    def x_max(self) -> float:
        return self.x_min + self.width * self.res

    @property
    def y_min(self) -> float:
        return self.y_max - self.height * self.res

    @property
    def crs_proj4(self) -> str:
        return (f"+proj=eqc +lat_ts={self.lat0:.10f} +lat_0={self.lat0:.10f} "
                f"+lon_0={self.lon0:.10f} +x_0=0 +y_0=0 +R={MARS_RADIUS_M:.0f} +units=m +no_defs")

    @property
    def transform(self):
        from affine import Affine  # installed with rasterio
        return Affine(self.res, 0.0, self.x_min, 0.0, -self.res, self.y_max)

    @property
    def bounds_xy(self):
        return (self.x_min, self.y_min, self.x_max, self.y_max)

    def bounds_lonlat(self):
        lon_a, lat_a = self.xy_to_lonlat(self.x_min, self.y_min)
        lon_b, lat_b = self.xy_to_lonlat(self.x_max, self.y_max)
        return (float(lon_a), float(lat_a), float(lon_b), float(lat_b))

    # ------------------------------------------------------------ conversions
    @property
    def _kx(self) -> float:
        return MARS_RADIUS_M * math.cos(math.radians(self.lat0)) * math.pi / 180.0

    @property
    def _ky(self) -> float:
        return MARS_RADIUS_M * math.pi / 180.0

    def lonlat_to_xy(self, lon, lat):
        lon = np.asarray(lon, dtype=float)
        lat = np.asarray(lat, dtype=float)
        return (lon - self.lon0) * self._kx, (lat - self.lat0) * self._ky

    def xy_to_lonlat(self, x, y):
        x = np.asarray(x, dtype=float)
        y = np.asarray(y, dtype=float)
        return self.lon0 + x / self._kx, self.lat0 + y / self._ky

    def xy_to_rowcol(self, x, y):
        """Fractional (row, col) where integers are pixel centres."""
        x = np.asarray(x, dtype=float)
        y = np.asarray(y, dtype=float)
        return (self.y_max - y) / self.res - 0.5, (x - self.x_min) / self.res - 0.5

    def rowcol_to_xy(self, row, col):
        row = np.asarray(row, dtype=float)
        col = np.asarray(col, dtype=float)
        return self.x_min + (col + 0.5) * self.res, self.y_max - (row + 0.5) * self.res

    def lonlat_to_rowcol(self, lon, lat):
        return self.xy_to_rowcol(*self.lonlat_to_xy(lon, lat))

    def rowcol_to_lonlat(self, row, col):
        return self.xy_to_lonlat(*self.rowcol_to_xy(row, col))

    def contains_lonlat(self, lon, lat) -> bool:
        r, c = self.lonlat_to_rowcol(lon, lat)
        return bool(-0.5 <= r <= self.height - 0.5 and -0.5 <= c <= self.width - 0.5)


def sample_bilinear(arr: np.ndarray, rows, cols, fill=np.nan):
    """Bilinear sample of a 2-D array at fractional pixel-centre coordinates."""
    rows = np.asarray(rows, dtype=float)
    cols = np.asarray(cols, dtype=float)
    h, w = arr.shape
    r0 = np.floor(rows).astype(int)
    c0 = np.floor(cols).astype(int)
    fr = rows - r0
    fc = cols - c0
    r0c = np.clip(r0, 0, h - 1)
    r1c = np.clip(r0 + 1, 0, h - 1)
    c0c = np.clip(c0, 0, w - 1)
    c1c = np.clip(c0 + 1, 0, w - 1)
    out = (arr[r0c, c0c] * (1 - fr) * (1 - fc) + arr[r0c, c1c] * (1 - fr) * fc
           + arr[r1c, c0c] * fr * (1 - fc) + arr[r1c, c1c] * fr * fc)
    outside = (rows < -0.5) | (rows > h - 0.5) | (cols < -0.5) | (cols > w - 0.5)
    if np.ndim(out) == 0:
        return fill if outside else float(out)
    out = np.asarray(out, dtype=float)
    out[outside] = fill
    return out
