"""The Godot console builds its habitat, suits and rover from primitives (godot/scripts/world/models.gd) and merges
them into one mesh per material. Run godot/tests/models_check.gd headless: every model must build, the habitat must
stay cheap (at most 40 draw calls, beacon still separate) and the suit must have the knee and elbow joints its walk
cycle uses."""

import os
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


def test_models_build_cheaply_with_joints():
    out = subprocess.run([GODOT, "--headless", "--path", str(GODOT_PROJECT), "--script", "res://tests/models_check.gd"],
                         capture_output=True, text=True, timeout=180)
    assert "models_check: ok" in out.stdout, out.stdout + out.stderr
    habitat = next(ln for ln in out.stdout.splitlines() if ln.startswith("habitat"))
    assert int(habitat.split()[1]) <= 40, habitat
    assert out.returncode == 0
