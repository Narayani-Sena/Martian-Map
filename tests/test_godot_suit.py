"""The Godot console carries its own copy of the suit atmosphere model (godot/scripts/core/suit_model.gd):
run it headless and check it matches server/eva.py, so the HUD and the planner agree on the CO2 alarms."""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from server import eva

ROOT = Path(__file__).resolve().parents[1]
GODOT_PROJECT = ROOT / "godot"
CANDIDATES = [os.environ.get("GODOT", ""), shutil.which("godot") or "", shutil.which("godot4") or "",
              r"D:\!!Pendrive\Coding\Python\ORON\godot_engine\Godot_v4.7.2-stable_win64_console.exe"]
GODOT = next((c for c in CANDIDATES if c and Path(c).exists()), None)

pytestmark = pytest.mark.skipif(
    GODOT is None or not (GODOT_PROJECT / ".godot" / "global_script_class_cache.cfg").exists(),
    reason="Godot 4.7 not available or the project has not been imported (run run_godot.ps1 once)")


@pytest.fixture(scope="module")
def godot():
    out = subprocess.run([GODOT, "--headless", "--path", str(GODOT_PROJECT), "--script", "res://tests/suit_model_check.gd"],
                         capture_output=True, text=True, timeout=120)
    line = next((ln for ln in out.stdout.splitlines() if ln.startswith("JSON:")), None)
    assert line, out.stdout + out.stderr
    return json.loads(line[5:])


def test_ppco2_and_ppo2_match_the_planner(godot):
    for r in godot["rows"]:
        pc = eva.ppco2_mmhg(r["met"], r["load"])
        assert r["ppco2"] == pytest.approx(pc, abs=1e-6)
        assert r["ppo2"] == pytest.approx(eva.ppo2_kpa(eva.SUIT_P_KPA, pc), abs=1e-6)


def test_alarm_levels_and_drills(godot):
    c = godot["consts"]
    assert c["p"] == eva.SUIT_P_KPA
    assert (c["caution"], c["warning"], c["limit"]) == (eva.PPCO2_CAUTION, eva.PPCO2_WARNING, eva.PPCO2_LIMIT)
    assert c["leak_60s"] == pytest.approx(eva.SUIT_P_KPA - 2.4, abs=1e-6)   # 2.4 kPa a minute
    assert c["co2_10s"] == pytest.approx(85.0)                               # from 70 % at 1.5 % a second
