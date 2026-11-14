"""Touch the map (feature F2): the STL must be a closed, printable solid and the GLB a valid glTF 2.0 file."""

import json
import struct
from collections import Counter

import numpy as np
import pytest
from fastapi.testclient import TestClient

from server import export3d
from server.main import app
from server.site_store import get_site, is_built

SITE = "gale_boxwork"
client = TestClient(app)
pytestmark = pytest.mark.skipif(not is_built(SITE), reason="site not built (run the pipeline first)")


def test_block_mesh_is_closed_and_outward_facing():
    top = np.random.default_rng(1).uniform(2, 5, (7, 9))
    v, f, n_top = export3d.block_mesh(top)
    directed = Counter((int(a), int(b)) for tri in f for a, b in ((tri[0], tri[1]), (tri[1], tri[2]), (tri[2], tri[0])))
    assert all(n == 1 for n in directed.values())                      # no edge used twice in the same direction
    assert all(directed[(b, a)] == 1 for (a, b) in directed)           # every edge shared by exactly two faces
    # signed volume of a closed outward mesh is positive and equals the volume under the surface
    vol = np.einsum("ij,ij->i", v[f[:, 0]], np.cross(v[f[:, 1]], v[f[:, 2]])).sum() / 6.0
    cells = (top[:-1, :-1] + top[1:, :-1] + top[:-1, 1:] + top[1:, 1:]) / 4.0
    assert vol > 0 and abs(vol - cells.sum()) / cells.sum() < 0.05
    assert n_top == 2 * 6 * 8


def _site_body():
    site = client.get(f"/api/sites/{SITE}").json()
    stops = [[s["lon"], s["lat"]] for s in site["stops"]]
    hab = [site["habitat"]["lon"], site["habitat"]["lat"]]
    return {"route": [hab] + stops + [hab], "stops": stops, "habitat": hab}


def test_stl_endpoint_gives_a_printable_block():
    r = client.post(f"/api/sites/{SITE}/export/stl", json=_site_body())
    assert r.status_code == 200 and r.headers["content-type"] == "model/stl"
    data = r.content
    n = struct.unpack("<I", data[80:84])[0]
    assert len(data) == 84 + 50 * n and n > 50_000
    tri = np.frombuffer(data[84:], dtype=[("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")])
    xyz = tri["v"].reshape(-1, 3)
    assert xyz[:, 2].min() == 0.0                                      # flat base on the print bed
    size = xyz.max(0) - xyz.min(0)
    assert 149 <= max(size[0], size[1]) <= 151 and 4 < size[2] < 80    # 150 mm block of sensible height
    # the route is raised: the top is higher along the route than the plain terrain model there
    plain = export3d.build(get_site(SITE))
    raised = export3d.build(get_site(SITE), **{k: v for k, v in _site_body().items()})
    diff = raised["top_mm"] - plain["top_mm"]
    assert diff.max() == pytest.approx(export3d.HAB_MM) and np.isclose(diff, export3d.ROUTE_MM).sum() > 100


def test_glb_endpoint_is_valid_gltf():
    r = client.post(f"/api/sites/{SITE}/export/glb", json=_site_body())
    assert r.status_code == 200 and r.headers["content-type"] == "model/gltf-binary"
    data = r.content
    magic, version, total = struct.unpack("<4sII", data[:12])
    assert magic == b"glTF" and version == 2 and total == len(data)
    jlen, jtype = struct.unpack("<I4s", data[12:20])
    assert jtype == b"JSON"
    doc = json.loads(data[20:20 + jlen])
    blen, btype = struct.unpack("<I4s", data[20 + jlen:28 + jlen])
    assert btype == b"BIN\x00" and blen == doc["buffers"][0]["byteLength"]
    for bv in doc["bufferViews"]:
        assert bv["byteOffset"] + bv["byteLength"] <= blen
    prims = doc["meshes"][0]["primitives"]
    assert len(prims) == 2 and "TEXCOORD_0" in prims[0]["attributes"]
    pos = doc["accessors"][prims[0]["attributes"]["POSITION"]]
    span = max(pos["max"][0] - pos["min"][0], pos["max"][2] - pos["min"][2])
    assert 0.39 <= span <= 0.41                                        # table-top size, in metres
    img = doc["bufferViews"][doc["images"][0]["bufferView"]]
    start = 28 + jlen + img["byteOffset"]
    assert data[start:start + 2] == b"\xff\xd8"                        # an embedded JPEG


def test_unknown_format_is_404():
    assert client.post(f"/api/sites/{SITE}/export/obj", json={}).status_code == 404
