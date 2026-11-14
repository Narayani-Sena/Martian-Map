"""Carried equipment: a heavier load means slower walking and a higher metabolic cost."""

import numpy as np
import pytest

from server.routing import Router
from server.walkmodel import LOAD_SPEED_K, WalkParams, metabolic_watts


def test_load_slows_the_walker():
    assert WalkParams(load_kg=0).v_flat() == pytest.approx(0.8)
    assert WalkParams(load_kg=30).v_flat() < WalkParams(load_kg=10).v_flat() < 0.8


def test_load_raises_metabolic_cost_walking_and_working():
    assert metabolic_watts(0.8, 0.1, load_kg=25) > metabolic_watts(0.8, 0.1, load_kg=0)
    assert metabolic_watts(0.8, -0.1, load_kg=25) > metabolic_watts(0.8, -0.1, load_kg=0)
    assert metabolic_watts(0, 0, working=True, load_kg=25) > metabolic_watts(0, 0, working=True)


def test_load_is_validated_and_part_of_the_cache_key():
    with pytest.raises(ValueError):
        WalkParams.from_dict({"load_kg": 120})
    assert WalkParams(load_kg=5).key() != WalkParams(load_kg=20).key()


def test_heavier_load_means_a_slower_route():
    z = np.zeros((20, 20))
    mult = np.ones_like(z)
    light, heavy = WalkParams(load_kg=0), WalkParams(load_kg=40)
    r = Router(z, 2.0)
    r.set_multiplier(light.key(), mult, light)
    r.set_multiplier(heavy.key(), mult, heavy)
    a = r.astar(light.key(), (2, 2), (2, 17), light)
    b = r.astar(heavy.key(), (2, 2), (2, 17), heavy)
    assert b.cells == a.cells
    assert b.cost_s == pytest.approx(a.cost_s * (1 + LOAD_SPEED_K * 40))
