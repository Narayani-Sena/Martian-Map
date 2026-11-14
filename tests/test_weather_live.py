"""Measured-weather summary (no network: synthetic feed rows)."""

from server.weather_live import MARS_YEAR_SOLS, parse_rows, summarize


def _feed(sols):
    return {"soles": [{"sol": str(s), "terrestrial_date": f"d{s}", "ls": str((s * 0.5) % 360), "min_temp": str(-70 - s % 3),
                       "max_temp": str(-5 - s % 2), "pressure": "800", "min_gts_temp": "-80", "max_gts_temp": "2",
                       "atmo_opacity": "Sunny"} for s in sols] + [{"sol": "9999", "min_temp": "--", "max_temp": "--"}]}


def test_latest_measured_sol_skips_missing_values():
    rows = parse_rows(_feed(range(100, 4000)))
    out = summarize(rows, current_sol=4100)
    assert out["available"] and out["latest"]["sol"] == 3999
    assert out["lag_sols"] == 101


def test_same_season_last_year_is_a_window_around_one_mars_year_ago():
    out = summarize(parse_rows(_feed(range(100, 4000))), current_sol=4100)
    ly = out["same_season_last_year"]
    target = 4100 - MARS_YEAR_SOLS
    assert ly["sol_from"] >= target - 5 and ly["sol_to"] <= target + 5
    assert -73 <= ly["min_c"] <= -70


def test_model_vs_measured_reports_the_error():
    out = summarize(parse_rows(_feed(range(100, 400))), current_sol=500)
    m = out["model_vs_measured"]
    assert m["error_max_c"] == round(m["max_c"] - out["latest"]["max_c"], 1)


def test_empty_feed_is_reported_not_raised():
    assert summarize([], 10)["available"] is False


def test_climate_calibration_overrides_then_falls_back():
    from server import climate
    base = climate.air_temp_range(20.0)
    with climate.calibrated(lambda ls: {"min_c": -70.0, "max_c": -15.0, "pressure_pa": 820.0}):
        assert climate.air_temp_range(20.0) == (-70.0, -15.0)
        assert 700 < climate.pressure_pa(20.0, 12.0) < 900
    with climate.calibrated(lambda ls: 1 / 0):  # a broken feed must not break the conditions endpoint
        assert climate.air_temp_range(20.0) == base
    assert climate.air_temp_range(20.0) == base
