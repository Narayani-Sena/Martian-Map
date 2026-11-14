"""The Godot console's crew never walks through the habitat, its solar field or a parked rover: plan routes start and
end at the habitat's centre, so world.gd keeps autopilot targets out of the models and steps round them
(MarsWorld.outside_structures). Run godot/tests/structures_check.gd headless: 576 walks from all round the habitat
to points all round beyond it, plus targets inside the models (the end of a walk or an ABORT: the habitat's airlock
door, PR-2's suitports) and walks from 150 m out (an abort, a catch-up), must stay out of the models and get there
without crawling round from far away; red abort routes built from 150 m must stay out of them and end at the door."""

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
GODOT_PROJECT = ROOT / "godot"
CANDIDATES = [os.environ.get("GODOT", ""), shutil.which("godot") or "", shutil.which("godot4") or "",
              r"D:\!!Pendrive\Coding\Python\ORON\godot_engine\Godot_v4.7.2-stable_win64_console.exe"]
GODOT = next((c for c in CANDIDATES if c and Path(c).exists()), None)

pytestmark = pytest.mark.skipif(
    GODOT is None or not (GODOT_PROJECT / ".godot" / "global_script_class_cache.cfg").exists(),
    reason="Godot 4.7 not available or the project has not been imported (run run_godot.ps1 once)")


def test_crew_walks_round_the_structures():
    out = subprocess.run([GODOT, "--headless", "--path", str(GODOT_PROJECT), "--script", "res://tests/structures_check.gd"],
                         capture_output=True, text=True, timeout=300)
    line = next((ln for ln in out.stdout.splitlines() if ln.startswith("structures_check:")), None)
    assert line, out.stdout + out.stderr
    m = re.search(r"(\d+) walks .*?, (\d+) failed \((\d+) never got there; least clearance (-?[\d.]+) m.*"
                  r"targets inside: (\d+) failed; from 150 m: (\d+) failed.*abort routes: (\d+) failed", line)
    assert m, line
    walks, failed, stuck, least = int(m[1]), int(m[2]), int(m[3]), float(m[4])
    inside_failed, far_failed, routes_failed = int(m[5]), int(m[6]), int(m[7])
    assert walks >= 500
    assert (failed, stuck, inside_failed, far_failed, routes_failed) == (0, 0, 0, 0, 0), out.stdout
    assert least > -0.1   # at most grazing a wall, never inside a model
    assert out.returncode == 0
