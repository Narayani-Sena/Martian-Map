"""The Godot client carries its own copy of Mars24 (godot/scripts/core/mars_time.gd).
Run it headless and check it agrees with marsgeo.mars24 to well under a second of Mars time."""

import json
import os
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import pytest

from marsgeo import mars24

ROOT = Path(__file__).resolve().parents[1]
GODOT_PROJECT = ROOT / "godot"
CANDIDATES = [os.environ.get("GODOT", ""), shutil.which("godot") or "", shutil.which("godot4") or "",
              r"D:\!!Pendrive\Coding\Python\ORON\godot_engine\Godot_v4.7.2-stable_win64_console.exe"]
GODOT = next((c for c in CANDIDATES if c and Path(c).exists()), None)

pytestmark = pytest.mark.skipif(
    GODOT is None or not (GODOT_PROJECT / ".godot" / "global_script_class_cache.cfg").exists(),
    reason="Godot 4.7 not available or the project has not been imported (run run_godot.ps1 once)")


@pytest.fixture(scope="module")
def godot_rows():
    out = subprocess.run([GODOT, "--headless", "--path", str(GODOT_PROJECT), "--script", "res://tests/mars_time_check.gd"],
                         capture_output=True, text=True, timeout=120)
    line = next((ln for ln in out.stdout.splitlines() if ln.startswith("JSON:")), None)
    assert line, out.stdout + out.stderr
    return json.loads(line[5:])


def test_godot_matches_python(godot_rows):
    lat, lon = -4.815, 137.385
    for row in godot_rows:
        mt = mars24.mars_time(datetime.fromtimestamp(row["unix"], tz=timezone.utc))
        assert row["ls"] == pytest.approx(mt.ls, abs=1e-4)
        assert row["msd"] == pytest.approx(mt.msd, abs=1e-6)
        assert row["eot"] == pytest.approx(mt.eot_deg, abs=1e-4)
        assert row["decl"] == pytest.approx(mt.declination, abs=1e-4)
        assert row["ltst"] == pytest.approx(mars24.local_true_solar_time(mt, lon), abs=1e-4)
        assert row["lmst"] == pytest.approx(mars24.local_mean_solar_time(mt, lon), abs=1e-4)
        elev, az, _ = mars24.sun_position(mt, lat, lon)
        assert row["elev"] == pytest.approx(elev, abs=1e-3)
        assert row["az"] == pytest.approx(az, abs=1e-3)
        rise, sset = mars24.sunrise_sunset_ltst(mt, lat)
        assert row["sunrise"] == pytest.approx(rise, abs=1e-4)
        assert row["sunset"] == pytest.approx(sset, abs=1e-4)


def test_godot_parses_api_timestamps(godot_rows):
    expected = datetime(2026, 11, 12, 10, 0, 7, 250000, tzinfo=timezone.utc).timestamp()
    assert godot_rows[0]["iso"] == pytest.approx(expected, abs=1e-3)
