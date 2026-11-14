"""Our hand-written A* must find the same optimum as a C Dijkstra on the same directed graph."""

import math

import numpy as np
import pytest
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import dijkstra

from server.routing import Router, evaluate_cells
from server.walkback import OFFS8, walkback_field
from server.walkmodel import WalkParams, speed_factor

P = WalkParams()


def make_router(z, mult, res=2.0):
    r = Router(z, res)
    r.set_multiplier("k", mult)
    return r


def reference_cost(z, mult, res, s, g, p):
    """Directed graph with exactly the A* edge costs, solved by scipy's Dijkstra."""
    H, W = z.shape
    idx = np.arange(H * W).reshape(H, W)
    rows, cols, data = [], [], []
    for dr, dc in OFFS8:
        rs = slice(max(0, -dr), H - max(0, dr))
        cs = slice(max(0, -dc), W - max(0, dc))
        rd = slice(max(0, dr), H - max(0, -dr))
        cd = slice(max(0, dc), W - max(0, -dc))
        d = res * math.hypot(dr, dc)
        t = d / (p.v_flat() * speed_factor((z[rd, cd] - z[rs, cs]) / d)) * 0.5 * (mult[rs, cs] + mult[rd, cd])
        ok = np.isfinite(t)
        rows.append(idx[rs, cs][ok])
        cols.append(idx[rd, cd][ok])
        data.append(t[ok])
    G = csr_matrix((np.concatenate(data), (np.concatenate(rows), np.concatenate(cols))), shape=(H * W, H * W))
    return dijkstra(G, directed=True, indices=idx[s])[idx[g]]


def test_flat_grid_straight_line():
    z = np.zeros((30, 30))
    r = make_router(z, np.ones_like(z))
    res = r.astar("k", (5, 5), (5, 25), P)
    assert res.cells[0] == (5, 5) and res.cells[-1] == (5, 25)
    assert len(res.cells) == 21
    assert res.cost_s == pytest.approx(40.0 / P.v_flat())


def test_routes_around_a_wall():
    z = np.zeros((40, 40))
    mult = np.ones_like(z)
    mult[5:35, 20] = np.inf
    r = make_router(z, mult)
    res = r.astar("k", (20, 5), (20, 35), P)
    assert res.cells, "should find a way around"
    assert all(np.isfinite(mult[c]) for c in res.cells)


def test_no_route_when_sealed():
    z = np.zeros((20, 20))
    mult = np.ones_like(z)
    mult[:, 10] = np.inf
    r = make_router(z, mult)
    res = r.astar("k", (10, 2), (10, 18), P)
    assert res.cells == [] and math.isinf(res.cost_s)


@pytest.mark.parametrize("seed", [0, 1, 2])
def test_astar_is_optimal_on_random_terrain(seed):
    rng = np.random.default_rng(seed)
    from scipy import ndimage
    z = ndimage.gaussian_filter(rng.normal(0, 8, (45, 50)), 3)
    mult = 1 + rng.random(z.shape)
    mult[rng.random(z.shape) < 0.12] = np.inf
    s, g = (2, 3), (42, 46)
    mult[s] = mult[g] = 1.0
    r = make_router(z, mult)
    res = r.astar("k", s, g, P, weight=1.0)
    ref = reference_cost(z, mult, 2.0, s, g, P)
    assert res.cost_s == pytest.approx(ref, rel=1e-9)
    # weighted A* is never worse than `weight` x optimal
    res_w = r.astar("k", s, g, P, weight=1.5)
    assert ref <= res_w.cost_s <= 1.5 * ref + 1e-9
    assert res_w.expansions <= res.expansions


def test_uphill_slower_than_downhill():
    z = np.tile(np.arange(30, dtype=float) * 0.3, (5, 1))  # rises east at 15 % grade per 2 m cell
    r = make_router(z, np.ones_like(z))
    up = r.astar("k", (2, 0), (2, 29), P)
    down = r.astar("k", (2, 29), (2, 0), P)
    # Tobler at +/-15 %: exp(-3.5*0.15) vs exp(-3.5*0.05) -> uphill takes ~1.42x as long
    assert up.cost_s / down.cost_s == pytest.approx(math.exp(3.5 * 0.10), rel=1e-6)


def test_evaluate_cells_matches_astar_cost():
    rng = np.random.default_rng(5)
    z = rng.normal(0, 0.3, (25, 25))
    mult = np.ones_like(z)
    r = make_router(z, mult)
    res = r.astar("k", (1, 1), (23, 22), P)
    ev = evaluate_cells(res.cells, z, np.zeros_like(z), mult, 2.0, P)
    assert ev["t"][-1] == pytest.approx(res.cost_s, rel=1e-9)


def test_dijkstra_engine_runs():
    z = np.zeros((30, 30))
    r = make_router(z, np.ones_like(z))
    res = r.dijkstra("k", (5, 5), (25, 25), P, np.zeros_like(z))
    assert res.cells[0] == (5, 5) and res.cells[-1] == (25, 25)


def test_walkback_field_on_flat_ground():
    z = np.zeros((41, 41))
    f = walkback_field(z, np.ones_like(z), 4.0, (20, 20), P)
    assert f[20, 20] == 0
    assert f[20, 40] == pytest.approx(80.0 / P.v_flat())  # 20 cells x 4 m at the loaded walking speed
    assert f[40, 40] == pytest.approx(20 * 4.0 * math.sqrt(2) / P.v_flat())


def test_walkback_is_time_to_return_not_to_leave():
    # hab at the bottom of a slope: coming back is downhill, so it's faster than going out
    z = np.tile(np.arange(41, dtype=float) * 0.6, (3, 1))
    f = walkback_field(z, np.ones_like(z), 4.0, (1, 0), P)
    r = make_router(z, np.ones_like(z), res=4.0)
    out = r.astar("k", (1, 0), (1, 40), P)
    back = r.astar("k", (1, 40), (1, 0), P)
    assert f[1, 40] == pytest.approx(back.cost_s, rel=1e-6)
    assert f[1, 40] < out.cost_s
