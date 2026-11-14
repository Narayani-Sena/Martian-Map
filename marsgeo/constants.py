"""Physical constants for Mars used across the project."""

import math

# IAU 2000 sphere used by USGS (HiRISE/CTX DTMs) and JPL MMGIS basemaps.
MARS_RADIUS_M = 3_396_190.0

# Surface gravity (m/s^2) and Earth's for comparison.
MARS_GRAVITY = 3.721
EARTH_GRAVITY = 9.80665

# Length of a mean solar day ("sol") in SI seconds.
MARS_SOL_SECONDS = 88_775.244

# Metres per degree of latitude (and of longitude at the equator).
METERS_PER_DEG = 2.0 * math.pi * MARS_RADIUS_M / 360.0

# PROJ string for planetocentric, east-positive longitude/latitude on Mars.
MARS_LONLAT_PROJ = f"+proj=longlat +R={MARS_RADIUS_M:.0f} +no_defs"
