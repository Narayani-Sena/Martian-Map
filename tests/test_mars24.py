"""Mars24 against the published worked example (GISS Mars24 algorithm page, example A)."""

from datetime import datetime, timezone

import pytest

from marsgeo import mars24


@pytest.fixture
def example_a(monkeypatch):
    # In January 2000 TT-UTC was 64.184 s (32 leap seconds), not today's 69.184 s.
    monkeypatch.setattr(mars24, "TT_MINUS_UTC_S", 64.184)
    return mars24.mars_time(datetime(2000, 1, 6, 0, 0, 0, tzinfo=timezone.utc))


def test_example_a_core_values(example_a):
    mt = example_a
    assert mt.jd_tt == pytest.approx(2451549.500743, abs=1e-6)
    assert mt.ls == pytest.approx(277.18758, abs=2e-4)
    assert mt.eot_deg == pytest.approx(-5.18774, abs=2e-4)
    assert mt.msd == pytest.approx(44795.99976, abs=2e-5)
    assert mt.mtc == pytest.approx(23.99425, abs=5e-4)


def test_example_a_subsolar_longitude(example_a):
    # Published: 174.72600 deg West  ->  -174.726 deg East
    assert example_a.subsolar_lon == pytest.approx(-174.726, abs=5e-3)


def test_local_true_solar_time_at_subsolar_point_is_noon(example_a):
    ltst = mars24.local_true_solar_time(example_a, example_a.subsolar_lon)
    assert ltst == pytest.approx(12.0, abs=1e-6)


def test_sun_overhead_at_subsolar_point(example_a):
    elev, _, _ = mars24.sun_position(example_a, example_a.declination, example_a.subsolar_lon)
    assert elev == pytest.approx(90.0, abs=1e-3)


def test_morning_sun_is_in_the_east():
    mt = mars24.mars_time(datetime(2026, 11, 11, 12, 0, tzinfo=timezone.utc))
    lon = 137.385
    t = mars24.utc_for_ltst(datetime(2026, 11, 11, 12, 0, tzinfo=timezone.utc), lon, 8.5)
    elev, az, _ = mars24.sun_position(mars24.mars_time(t), -4.8, lon)
    assert 0 < elev < 60
    assert 45 < az < 135
    assert mt.mars_year == 39


def test_utc_for_ltst_round_trip():
    lon = 137.385
    t = mars24.utc_for_ltst(datetime(2026, 11, 11, 12, 0, tzinfo=timezone.utc), lon, 15.25)
    assert mars24.local_true_solar_time(mars24.mars_time(t), lon) == pytest.approx(15.25, abs=1e-4)


def test_curiosity_sol_calibration():
    # Raw-image feed: sol 4700 image taken 2025-10-26T10:19:58Z
    mt = mars24.mars_time(datetime(2025, 10, 26, 10, 19, 58, tzinfo=timezone.utc))
    assert mars24.mission_sol(mt, 137.38, 49269) == 4700


def test_daylight_is_about_twelve_hours_near_equator():
    mt = mars24.mars_time(datetime(2026, 11, 11, tzinfo=timezone.utc))
    rise, set_ = mars24.sunrise_sunset_ltst(mt, -4.8)
    assert 11.5 < set_ - rise < 12.6
