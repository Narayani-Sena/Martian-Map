"""Touch the map (feature F2): the site as a block you can hold.

* STL (millimetres) for a 3D printer: the terrain as a closed, watertight block, with the planned route raised as a
  ridge, the stops as round bumps and the habitat as a square pad, so a finger can follow the walk.
* GLB (metres, y up) for 3D viewers and phone AR: the same block with the site's colour image on top and the route
  painted on it, sized to sit on a table.
"""

from __future__ import annotations

import io
import json
import struct
import warnings

import numpy as np
from PIL import Image, ImageDraw

PRINT_WIDTH_MM = 150.0  # longest side of the printed block
BASE_MM = 4.0           # solid base under the lowest point
ROUTE_MM = 1.2          # route ridge height
STOP_MM = 2.2           # stop bump height
HAB_MM = 3.0            # habitat pad height
AR_WIDTH_M = 0.40       # longest side of the AR model


# ------------------------------------------------------------------ height field
def heightfield(z: np.ndarray, n_max: int = 200) -> tuple[np.ndarray, int]:
    """Block mean of the DTM, at most n_max samples a side. Holes take the lowest valid height."""
    H, W = z.shape
    step = max(1, int(np.ceil(max(H, W) / n_max)))
    h, w = H // step, W // step
    blocks = z[: h * step, : w * step].astype(np.float64).reshape(h, step, w, step)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        m = np.nanmean(blocks, axis=(1, 3))
    if not np.isfinite(m).any():
        raise ValueError("the site has no terrain")
    return np.where(np.isfinite(m), m, np.nanmin(m)), step


def _to_cells(grid2, step: int, lonlat) -> np.ndarray:
    """[[lon, lat], ...] -> (N, 2) fractional (row, col) on the block-mean grid."""
    a = np.asarray(lonlat, float).reshape(-1, 2)
    if not len(a):
        return np.zeros((0, 2))
    r, c = grid2.lonlat_to_rowcol(a[:, 0], a[:, 1])
    return np.stack([(np.asarray(r) + 0.5) / step - 0.5, (np.asarray(c) + 0.5) / step - 0.5], 1)


def features(shape, cells_route, cells_stops, cell_hab) -> np.ndarray:
    """Extra height (mm) on the block-mean grid: route ridge (2 cells wide), stop bumps, habitat pad."""
    h, w = shape
    extra = np.zeros(shape)
    rr, cc = np.mgrid[0:h, 0:w]
    if len(cells_route) > 1:
        pts = []
        for a, b in zip(cells_route[:-1], cells_route[1:]):
            n = max(2, int(np.ceil(np.hypot(*(b - a)) * 4)))
            pts.append(a + (b - a) * np.linspace(0, 1, n)[:, None])
        p = np.concatenate(pts)
        mask = np.zeros(shape, bool)
        for dr in (-1, 0, 1):
            for dc in (-1, 0, 1):
                if abs(dr) + abs(dc) > 1:
                    continue
                r = np.clip(np.rint(p[:, 0]).astype(int) + dr, 0, h - 1)
                c = np.clip(np.rint(p[:, 1]).astype(int) + dc, 0, w - 1)
                mask[r, c] = True
        extra[mask] = ROUTE_MM
    for r0, c0 in cells_stops:
        extra = np.maximum(extra, np.where((rr - r0) ** 2 + (cc - c0) ** 2 <= 2.6 ** 2, STOP_MM, 0.0))
    if cell_hab is not None:
        r0, c0 = cell_hab
        extra = np.maximum(extra, np.where((np.abs(rr - r0) <= 2.5) & (np.abs(cc - c0) <= 2.5), HAB_MM, 0.0))
    return extra


# ------------------------------------------------------------------ closed block mesh
def block_mesh(top: np.ndarray):
    """A closed, consistently wound block under a height field.

    Returns (verts, faces, n_top): verts (N, 3) in (x east, y north, z up) with x, y in cell units and z as given,
    faces (M, 3) counter-clockwise seen from outside; the first n_top faces are the top surface, which uses the first
    h * w vertices (row-major, row 0 = north)."""
    h, w = top.shape
    ii, jj = np.mgrid[0:h, 0:w]
    v_top = np.stack([jj.ravel(), (h - 1 - ii).ravel(), top.ravel()], 1).astype(np.float64)
    idx = np.arange(h * w).reshape(h, w)
    v00, v01, v10, v11 = idx[:-1, :-1].ravel(), idx[:-1, 1:].ravel(), idx[1:, :-1].ravel(), idx[1:, 1:].ravel()
    f_top = np.concatenate([np.stack([v00, v10, v01], 1), np.stack([v10, v11, v01], 1)])
    # perimeter, clockwise seen from above: north edge eastward, east edge southward, south edge westward, west edge north
    ring = np.concatenate([idx[0, :], idx[1:, -1], idx[-1, -2::-1], idx[-2:0:-1, 0]])
    n_top_v = h * w
    v_bot = v_top[ring].copy()
    v_bot[:, 2] = 0.0
    bot = n_top_v + np.arange(len(ring))
    centre = n_top_v + len(ring)
    v_c = np.array([[(w - 1) / 2.0, (h - 1) / 2.0, 0.0]])
    a_t, b_t = ring, np.roll(ring, -1)
    a_b, b_b = bot, np.roll(bot, -1)
    f_wall = np.concatenate([np.stack([a_t, b_t, a_b], 1), np.stack([b_t, b_b, a_b], 1)])
    f_floor = np.stack([np.full(len(ring), centre), a_b, b_b], 1)
    verts = np.concatenate([v_top, v_bot, v_c])
    faces = np.concatenate([f_top, f_wall, f_floor]).astype(np.int64)
    return verts, faces, len(f_top)


def _face_normals(v: np.ndarray, f: np.ndarray) -> np.ndarray:
    n = np.cross(v[f[:, 1]] - v[f[:, 0]], v[f[:, 2]] - v[f[:, 0]])
    ln = np.linalg.norm(n, axis=1, keepdims=True)
    return n / np.where(ln > 0, ln, 1.0)


def stl_bytes(verts: np.ndarray, faces: np.ndarray, name: str = "Martian Map") -> bytes:
    rec = np.zeros(len(faces), dtype=[("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")])
    rec["n"] = _face_normals(verts, faces)
    rec["v"] = verts[faces]
    head = name.encode("ascii", "replace")[:80].ljust(80, b" ")
    return head + struct.pack("<I", len(faces)) + rec.tobytes()


# ------------------------------------------------------------------ the model
def build(site, route=(), stops=(), habitat=None, exaggeration: float = 1.5, n_max: int = 200):
    """Height field in millimetres plus the cell size, ready for STL or GLB."""
    z, step = heightfield(site.z2, n_max)
    h, w = z.shape
    cell_m = site.grid2.res * step
    s = PRINT_WIDTH_MM / (max(h, w) - 1) / cell_m  # mm per metre
    top = BASE_MM + (z - z.min()) * s * exaggeration
    hab = _to_cells(site.grid2, step, [habitat])[0] if habitat is not None else None
    top = top + features(z.shape, _to_cells(site.grid2, step, route), _to_cells(site.grid2, step, stops), hab)
    return {"top_mm": top, "step": step, "cell_m": cell_m, "mm_per_m": s, "cell_mm": cell_m * s,
            "relief_m": float(z.max() - z.min()), "exaggeration": exaggeration}


def stl(site, route=(), stops=(), habitat=None, exaggeration: float = 1.5) -> bytes:
    m = build(site, route, stops, habitat, exaggeration)
    v, f, _ = block_mesh(m["top_mm"])
    v[:, :2] *= m["cell_mm"]
    return stl_bytes(v, f, f"Martian Map {site.cfg.get('name', site.cfg.get('id', ''))}")


# ------------------------------------------------------------------ GLB
def _paint_texture(site, step: int, route, stops, habitat, size: int = 2048) -> bytes:
    p = site.dir / "texture_2048.jpg"
    if not p.exists():
        p = site.dir / "texture_4096.jpg"
    img = Image.open(p).convert("RGB")
    if max(img.size) > size:
        img = img.resize((size, size * img.size[1] // img.size[0]), Image.LANCZOS)
    W2, H2 = site.grid2.width, site.grid2.height
    sx, sy = img.size[0] / W2, img.size[1] / H2

    def px(lonlat):
        a = np.asarray(lonlat, float).reshape(-1, 2)
        r, c = site.grid2.lonlat_to_rowcol(a[:, 0], a[:, 1])
        return [((ci + 0.5) * sx, (ri + 0.5) * sy) for ri, ci in zip(np.atleast_1d(r), np.atleast_1d(c))]

    d = ImageDraw.Draw(img)
    lw = max(3, img.size[0] // 340)
    if len(route) > 1:
        pts = px(route)
        d.line(pts, fill=(20, 20, 20), width=lw + 4, joint="curve")
        d.line(pts, fill=(255, 140, 50), width=lw, joint="curve")
    for x, y in px(stops) if len(stops) else []:
        r = lw * 2.2
        d.ellipse([x - r, y - r, x + r, y + r], fill=(255, 140, 50), outline=(255, 255, 255), width=max(2, lw // 2))
    if habitat is not None:
        (x, y), = px([habitat])
        r = lw * 2.6
        d.rectangle([x - r, y - r, x + r, y + r], fill=(245, 245, 245), outline=(20, 20, 20), width=max(2, lw // 2))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=85)
    return buf.getvalue()


def _vertex_normals(v: np.ndarray, f: np.ndarray) -> np.ndarray:
    fn = np.cross(v[f[:, 1]] - v[f[:, 0]], v[f[:, 2]] - v[f[:, 0]])  # area-weighted
    n = np.zeros_like(v)
    for k in range(3):
        np.add.at(n, f[:, k], fn)
    ln = np.linalg.norm(n, axis=1, keepdims=True)
    return n / np.where(ln > 0, ln, 1.0)


def glb(site, route=(), stops=(), habitat=None, exaggeration: float = 1.5) -> bytes:
    m = build(site, route, stops, habitat, exaggeration, n_max=256)
    top = m["top_mm"]
    h, w = top.shape
    v, f, n_top = block_mesh(top)
    v[:, :2] *= m["cell_mm"]
    k = AR_WIDTH_M / PRINT_WIDTH_MM  # mm of the print -> metres of the AR model
    # (east, north, up) -> glTF (x right, y up, z towards the viewer = south), centred, base on y = 0
    g = np.stack([v[:, 0], v[:, 2], -v[:, 1]], 1) * k
    g[:, 0] -= (g[:, 0].max() + g[:, 0].min()) / 2
    g[:, 2] -= (g[:, 2].max() + g[:, 2].min()) / 2
    n_top_v = h * w
    f_top, f_side = f[:n_top], f[n_top:]
    top_pos = g[:n_top_v].astype(np.float32)
    top_nrm = _vertex_normals(g[:n_top_v], f_top).astype(np.float32)
    ii, jj = np.mgrid[0:h, 0:w]
    step = m["step"]
    uv = np.stack([(jj.ravel() * step + step / 2) / site.grid2.width, (ii.ravel() * step + step / 2) / site.grid2.height], 1).astype(np.float32)
    top_idx = f_top.astype(np.uint32).ravel()
    # sides and floor: flat shaded, one vertex per corner
    side_pos = g[f_side].reshape(-1, 3).astype(np.float32)
    side_nrm = np.repeat(_face_normals(g, f_side), 3, axis=0).astype(np.float32)
    side_idx = np.arange(len(side_pos), dtype=np.uint32)
    tex = _paint_texture(site, step, route, stops, habitat)

    blobs, views, accessors = [], [], []
    offset = 0

    def add_view(data: bytes, target=None) -> int:
        nonlocal offset
        pad = (-len(data)) % 4
        blobs.append(data + b"\x00" * pad)
        views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(data), **({"target": target} if target else {})})
        offset += len(data) + pad
        return len(views) - 1

    def add_acc(arr: np.ndarray, kind: str, comp: int, target: int, minmax: bool = False) -> int:
        bv = add_view(arr.tobytes(), target)
        acc = {"bufferView": bv, "componentType": comp, "count": int(arr.shape[0] if kind != "SCALAR" else arr.size), "type": kind}
        if minmax:
            acc["min"] = [float(x) for x in arr.min(axis=0)]
            acc["max"] = [float(x) for x in arr.max(axis=0)]
        accessors.append(acc)
        return len(accessors) - 1

    FLOAT, UINT = 5126, 5125
    ARRAY, ELEMENTS = 34962, 34963
    a_tp = add_acc(top_pos, "VEC3", FLOAT, ARRAY, True)
    a_tn = add_acc(top_nrm, "VEC3", FLOAT, ARRAY)
    a_uv = add_acc(uv, "VEC2", FLOAT, ARRAY)
    a_ti = add_acc(top_idx, "SCALAR", UINT, ELEMENTS)
    a_sp = add_acc(side_pos, "VEC3", FLOAT, ARRAY, True)
    a_sn = add_acc(side_nrm, "VEC3", FLOAT, ARRAY)
    a_si = add_acc(side_idx, "SCALAR", UINT, ELEMENTS)
    img_view = add_view(tex)
    doc = {
        "asset": {"version": "2.0", "generator": "Martian Map"},
        "scene": 0,
        "scenes": [{"name": site.cfg.get("name", "site"), "nodes": [0]}],
        "nodes": [{"name": "terrain", "mesh": 0}],
        "meshes": [{"name": "terrain", "primitives": [
            {"attributes": {"POSITION": a_tp, "NORMAL": a_tn, "TEXCOORD_0": a_uv}, "indices": a_ti, "material": 0},
            {"attributes": {"POSITION": a_sp, "NORMAL": a_sn}, "indices": a_si, "material": 1}]}],
        "materials": [
            {"name": "surface", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicFactor": 0.0, "roughnessFactor": 0.95}},
            {"name": "strata", "pbrMetallicRoughness": {"baseColorFactor": [0.42, 0.25, 0.16, 1.0], "metallicFactor": 0.0, "roughnessFactor": 1.0}}],
        "textures": [{"source": 0, "sampler": 0}],
        "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 33071, "wrapT": 33071}],
        "images": [{"bufferView": img_view, "mimeType": "image/jpeg"}],
        "accessors": accessors,
        "bufferViews": views,
        "buffers": [{"byteLength": offset}],
    }
    js = json.dumps(doc, separators=(",", ":")).encode("utf-8")
    js += b" " * ((-len(js)) % 4)
    bin_ = b"".join(blobs)
    total = 12 + 8 + len(js) + 8 + len(bin_)
    return (struct.pack("<4sII", b"glTF", 2, total) + struct.pack("<I4s", len(js), b"JSON") + js
            + struct.pack("<I4s", len(bin_), b"BIN\x00") + bin_)
