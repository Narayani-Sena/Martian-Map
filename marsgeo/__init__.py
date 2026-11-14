"""marsgeo - a small, reusable toolkit for Mars mapping projects.

Written for the Martian Map project, but nothing in here is specific
to one site, so later NASA-challenge projects can import it as-is.

Modules
-------
constants  physical constants for Mars (radius, gravity, sol length)
grid       local metric "site grids" (equirectangular on the Mars sphere)
tiles      Web-Mercator / TMS tile math used by JPL MMGIS basemaps
mars24     NASA GISS Mars24 sun clock (Allison & McEwen 2000)
net        polite HTTP session with retries and an on-disk JSON cache
stac       USGS Astrogeology STAC search helpers
"""

from .constants import MARS_RADIUS_M, METERS_PER_DEG
from .grid import SiteGrid

__all__ = ["MARS_RADIUS_M", "METERS_PER_DEG", "SiteGrid"]
