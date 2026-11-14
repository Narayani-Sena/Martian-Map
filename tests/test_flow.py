"""Ways home (feature A1): the walk-home tree, its flow, gateways, basins and the path home."""

import numpy as np
import pytest

from server.site_store import get_site, is_built
from server.walkmodel import WalkParams
from server import flow

pytestmark = pytest.mark.skipif(not is_built("gale_boxwork"), reason="gale_boxwork not built")


@pytest.fixture(scope="module")
def tree():
    s = get_site("gale_boxwork")
    return s.flow([s.habitat_haven()], WalkParams())


def test_tree_matches_walkback_field(tree):
    s = tree.site
    hab = s.habitat_haven()
    f = s.walkback((hab["lon"], hab["lat"]), WalkParams())["field"]
    fin = np.isfinite(f)
    assert np.array_equal(fin, np.isfinite(tree.dist))
    assert np.allclose(f[fin], tree.dist[fin], atol=1e-3)


def test_flow_sums_at_the_haven(tree):
    r, c = tree.haven_rc[0]
    W = tree.shape[1]
    assert int(tree.acc[r * W + c]) == tree.n_reach
    # every reachable cell counts itself; unreachable cells carry nothing
    fin = np.isfinite(tree.dist.ravel())
    assert (tree.acc[fin] >= 1).all() and (tree.acc[~fin] == 0).all()


def test_streams_cover_the_network(tree):
    st = tree.streams(50)
    assert len(st) > 100
    dist = tree.dist.ravel()
    for s in st[:200]:
        d = dist[s]
        assert (np.diff(d) < 0).all()  # upstream first: every step is closer to home


def test_gateways(tree):
    gw = tree.gateways(n=6)
    assert 3 <= len(gw) <= 6
    for g in gw:
        assert g["share"] >= 0.05 and g["minutes"] >= 15


def test_path_through_a_gateway_is_the_way_home(tree):
    """feature A1 acceptance check: the trunk through a gateway matches the way home from a point behind it."""
    W = tree.shape[1]
    g = tree.gateways(n=1)[0]
    r, c = (int(round(float(v))) for v in tree.grid.lonlat_to_rowcol(g["lon"], g["lat"]))
    gi = r * W + c
    # a cell upstream of the gateway: walk the tree from far cells until one passes through it
    dist = tree.dist.ravel()
    far = np.flatnonzero(np.isfinite(dist) & (dist > dist[gi] + 600))
    rng = np.random.default_rng(1)
    hit = None
    for i in rng.choice(far, size=min(4000, far.size), replace=False):
        j = int(i)
        while j >= 0 and j != gi:
            j = int(tree.next[j])
        if j == gi:
            hit = int(i)
            break
    assert hit is not None
    rr, cc = divmod(hit, W)
    lon, lat = tree.grid.rowcol_to_lonlat(rr, cc)
    ph = tree.path_home(float(lon), float(lat))
    assert ph["ok"]
    glon, glat = tree.grid.rowcol_to_lonlat(r, c)
    d = [np.hypot(p[0] - float(glon), p[1] - float(glat)) for p in ph["path"]]
    assert min(d) < 1e-6  # the path walks through the gateway cell
    assert abs(ph["start_minutes"] - dist[hit] / 60.0) < 0.2
    m = np.array(ph["minutes"])
    assert (np.diff(m) <= 1e-6).all() and m[-1] == 0.0


def test_two_havens_split_the_site_into_basins():
    s = get_site("gale_boxwork")
    hab = s.habitat_haven()
    pr2 = {"lon": 137.39, "lat": -4.82, "name": "PR-2"}
    t2 = s.flow([hab, pr2], WalkParams())
    b = t2.basins()
    assert len(b) == 2 and all(x["share"] > 0.1 for x in b)
    assert abs(sum(x["share"] for x in b) - 1.0) < 1e-3
    one = s.flow([hab], WalkParams())
    assert t2.stats()["max_minutes"] < one.stats()["max_minutes"]  # a second haven brings the far side closer


def test_parse_havens_defaults():
    d = [{"lon": 1.0, "lat": 2.0, "name": "Hab"}]
    assert flow.parse_havens(None, d) == d
    assert flow.parse_havens("3,4,PR-2;bad;5,6", d) == [{"lon": 3.0, "lat": 4.0, "name": "PR-2"}, {"lon": 5.0, "lat": 6.0, "name": "Haven 3"}]
