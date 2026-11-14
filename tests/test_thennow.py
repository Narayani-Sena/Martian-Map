"""Then and now (feature E3): a rover photo's pose from the raw-image feed's camera model and rover attitude."""

import json
import math
from pathlib import Path

import numpy as np
import pytest

from server import thennow as tn

CACHE = Path(__file__).resolve().parents[1] / "data" / "cache" / "raw_images"


def _cahv(hs=1000.0, vs=1000.0, hc=512.0, vc=384.0):
    """A level camera 2 m up, looking along the rover's +x, image x to the right (+y), image y down (+z)."""
    C = np.array([0.0, 0.0, -2.0])
    A = np.array([1.0, 0.0, 0.0])
    H = hs * np.array([0.0, 1.0, 0.0]) + hc * A
    V = vs * np.array([0.0, 0.0, 1.0]) + vc * A
    return ";".join("(%s)" % ",".join(str(float(c)) for c in v) for v in (C, A, H, V))


def test_quaternion_heading():
    for yaw in (0.0, 37.0, 163.78, 250.0):
        h = math.radians(yaw) / 2.0
        R = tn.quat_matrix([math.cos(h), 0.0, 0.0, math.sin(h)])   # scalar first, about the down axis
        assert tn.heading_deg(R) == pytest.approx(yaw % 360.0, abs=1e-6)


def test_pose_of_a_level_camera_turned_east():
    h = math.radians(90.0) / 2.0
    item = {"cahv": _cahv(), "attitude": f"({math.cos(h)},0,0,{math.sin(h)})", "w": 1024, "h": 768}
    p = tn.frame_pose(item)
    assert np.allclose(p["dir_ned"], [0.0, 1.0, 0.0], atol=1e-6)          # looking east
    assert np.allclose(p["up_ned"], [0.0, 0.0, -1.0], atol=1e-6)          # the frame's up is up
    assert np.allclose(p["pos_ned"], [0.0, 0.0, -2.0], atol=1e-6)         # 2 m above the rover's origin
    assert p["hfov"] == pytest.approx(2 * math.degrees(math.atan(0.512)), abs=0.01)
    assert p["vfov"] == pytest.approx(2 * math.degrees(math.atan(0.384)), abs=0.01)
    assert tn.ned_to_world(p["dir_ned"]) == pytest.approx([1.0, 0.0, 0.0], abs=1e-5)   # world: x east
    assert tn.ned_to_world(p["up_ned"]) == pytest.approx([0.0, 1.0, 0.0], abs=1e-5)


def test_off_axis_crop_looks_through_its_own_middle():
    # a crop whose optical centre is its top-left corner looks down and to the right of the camera's axis
    item = {"cahv": _cahv(hc=0.0, vc=0.0), "attitude": "(1,0,0,0)", "w": 1000, "h": 1000}
    p = tn.frame_pose(item)
    az = math.degrees(math.atan2(p["dir_ned"][1], p["dir_ned"][0]))
    el = math.degrees(math.asin(-p["dir_ned"][2]))
    assert az == pytest.approx(math.degrees(math.atan(0.5)), abs=0.5) and el < -20.0
    # measured along the crop's middle row (27 degrees below the axis): rays (1, 0, 0.5) and (1, 1, 0.5)
    want = math.degrees(math.acos(1.25 / (math.sqrt(1.25) * 1.5)))
    assert p["hfov"] == pytest.approx(want, abs=0.05)


def test_pick_sols_spreads_over_the_stay():
    assert tn.pick_sols([5, 1, 3]) == [1, 3, 5]
    s = tn.pick_sols(list(range(100, 200)), 5)
    assert s[0] == 100 and s[-1] == 199 and len(s) == 5


@pytest.mark.skipif(not (CACHE / "mars2020_nav_586_588.json").exists(), reason="no cached Perseverance frame")
def test_real_perseverance_frame_agrees_with_its_heading():
    it = json.loads((CACHE / "mars2020_nav_586_588.json").read_text())["images"][0]
    ext = it["extended"]
    dim = [float(x) for x in ext["dimension"].strip("()").split(",")]
    p = tn.frame_pose({"cahv": it["camera"]["camera_model_component_list"], "attitude": it["attitude"],
                       "w": dim[0], "h": dim[1]})
    az = math.degrees(math.atan2(p["dir_ned"][1], p["dir_ned"][0])) % 360.0
    # the rover's heading (from its attitude) plus the mast's azimuth (in the rover frame)
    want = (p["heading"] + float(ext["mastAz"])) % 360.0
    assert abs((az - want + 180.0) % 360.0 - 180.0) < 1.5
    assert 1.8 < -p["pos_ned"][2] < 2.2   # the navigation cameras sit about 2 m up
