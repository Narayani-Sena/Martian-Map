"""Ways home (feature A1): the fastest walk back from every 4 m cell, drawn as one network.

The walk-back field (server/walkback.py) runs Dijkstra from the haven over the reversed walking graph.
Asking scipy for the predecessors as well turns it into a tree: every cell points to the next cell on
its fastest way home. Counting how many cells pass through each cell (like drainage accumulation in
hydrology) shows the safety structure of the terrain: the trunks most of the site uses to get home, the
gateways where branches merge, and ground that has no way home at all. With several havens (the hab,
PR-2 parked at its drop-off, consumable caches) every cell drains to its nearest one and the site
splits into basins, one per haven.
"""

from __future__ import annotations

import math
import threading
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from . import walkback as wb
from .walkmodel import WalkParams

# Minutes from home -> line colour: white at home, cyan, sky blue, blue, violet far out (as in ideas/ways_home.jpg).
RAMP_MIN = [0.0, 15.0, 30.0, 60.0, 90.0, 130.0]
RAMP_RGB = [(255, 247, 232), (188, 240, 255), (118, 204, 255), (104, 146, 255), (148, 112, 252), (196, 92, 236)]
# One hue per haven for the basins (hab, PR-2, caches ...).
BASIN_RGB = [(120, 200, 255), (74, 222, 128), (255, 196, 64), (255, 120, 180), (170, 140, 255), (255, 150, 90)]
NOGO_RGBA = (120, 22, 28, 120)


def ramp(minutes) -> np.ndarray:
    m = np.asarray(minutes, dtype=float)
    out = np.empty(m.shape + (3,), np.float64)
    for ch in range(3):
        out[..., ch] = np.interp(m, RAMP_MIN, [c[ch] for c in RAMP_RGB])
    return np.clip(out, 0, 255).astype(np.uint8)


def legend() -> dict:
    return {"unit": "minutes from home (line width = how many places walk home that way)",
            "stops": [[m, "#%02x%02x%02x" % c] for m, c in zip(RAMP_MIN, RAMP_RGB)]}


def accumulate(dist_flat: np.ndarray, pred: np.ndarray) -> np.ndarray:
    """How many cells' fastest way home passes through each cell (itself included); 0 where there is no way home."""
    fin = np.isfinite(dist_flat)
    idx = np.flatnonzero(fin)
    order = idx[np.argsort(-dist_flat[idx], kind="stable")]  # farthest first: children before parents
    acc = fin.astype(np.int64).tolist()
    nxt = pred.tolist()
    for i in order.tolist():
        j = nxt[i]
        if j >= 0:
            acc[j] += acc[i]
    return np.asarray(acc, np.int32)


class FlowTree:
    """The walk-home tree for a set of havens: dist (s), next cell, basin, flow."""

    def __init__(self, site, havens: list[dict], p: WalkParams):
        t0 = time.perf_counter()
        self.site = site
        self.grid = g4 = site.grid4
        self.havens = havens
        self.p = p
        mult4 = wb.coarsen_multiplier(site.multiplier(p))
        rcs = []
        for h in havens:
            r, c = (int(round(float(v))) for v in g4.lonlat_to_rowcol(h["lon"], h["lat"]))
            r = min(max(r, 0), g4.height - 1)
            c = min(max(c, 0), g4.width - 1)
            if not np.isfinite(mult4[r, c]):  # a haven on no-go ground: open its cell so the tree is defined
                mult4[r, c] = 1.0
            rcs.append((r, c))
        self.haven_rc = rcs
        self.dist, self.next, self.basin = wb.walkback_tree(site.z4, mult4, g4.res, rcs, p)
        self.shape = self.dist.shape
        self.acc = accumulate(self.dist.ravel(), self.next)
        self.n_reach = int(np.isfinite(self.dist).sum())
        self.compute_ms = (time.perf_counter() - t0) * 1000.0
        self._streams: dict = {}
        self.lock = threading.Lock()  # pictures are drawn once per tree, however many tiles ask at once

    # ------------------------------------------------------------------ structure
    def minutes(self) -> np.ndarray:
        return self.dist / 60.0

    def streams(self, min_acc: int) -> list[np.ndarray]:
        """The network as streams (flat cell indices, upstream first), like river segments.

        Each stream follows its largest tributary upstream (the "main child") and ends where it joins a bigger
        stream (the junction cell is its last vertex) or at a haven.
        """
        min_acc = max(1, int(min_acc))
        if min_acc in self._streams:
            return self._streams[min_acc]
        acc, nxt = self.acc, self.next
        dist = self.dist.ravel()
        sel = np.flatnonzero((acc >= min_acc) & (nxt >= 0))
        if sel.size == 0:
            return []
        par = nxt[sel]
        o = np.lexsort((acc[sel], par))  # by parent, then by flow (the largest last)
        par_s, ch_s = par[o], sel[o]
        last = np.r_[par_s[1:] != par_s[:-1], True]
        main = np.full(acc.size, -1, np.int64)
        main[par_s[last]] = ch_s[last]
        # label every selected cell with its stream, upstream first: a cell continues its main child's stream
        order = sel[np.argsort(-dist[sel], kind="stable")]
        label = np.full(acc.size, -1, np.int64)
        lab = label  # local alias
        ml = main.tolist()
        nid = 0
        lab_list = {}
        for i in order.tolist():
            m = ml[i]
            if m >= 0 and m in lab_list:
                lab_list[i] = lab_list[m]
            else:
                lab_list[i] = nid
                nid += 1
        keys = np.fromiter(lab_list.keys(), np.int64, len(lab_list))
        vals = np.fromiter(lab_list.values(), np.int64, len(lab_list))
        lab[keys] = vals
        cells = keys[np.lexsort((-dist[keys], vals))]
        labs = lab[cells]
        cut = np.flatnonzero(np.diff(labs)) + 1
        out = []
        for seg in np.split(cells, cut):
            j = nxt[seg[-1]]
            out.append(np.append(seg, j) if j >= 0 else seg)
        self._streams[min_acc] = out
        return out

    def gateways(self, n: int = 6, min_frac: float = 0.05, min_minutes: float = 15.0, min_sep_m: float = 150.0) -> list[dict]:
        """Cells where many ways home merge, far from home: the leaves of the subtree of cells that carry at least
        `min_frac` of the site's ways home (each one is a confluence of smaller branches)."""
        acc, nxt = self.acc, self.next
        dist = self.dist.ravel()
        thr = max(2, int(min_frac * max(1, self.n_reach)))
        big = acc >= thr
        has_big_child = np.zeros(acc.size, bool)
        bi = np.flatnonzero(big & (nxt >= 0))
        has_big_child[nxt[bi]] = True
        leaves = np.flatnonzero(big & ~has_big_child & (dist >= min_minutes * 60.0))
        leaves = leaves[np.argsort(-acc[leaves], kind="stable")]
        W = self.shape[1]
        res = self.grid.res
        picked: list[int] = []
        for i in leaves.tolist():
            r, c = divmod(i, W)
            if all(math.hypot(r - pr, c - pc) * res >= min_sep_m for pr, pc in (divmod(k, W) for k in picked)):
                picked.append(i)
            if len(picked) >= n:
                break
        out = []
        for k, i in enumerate(picked):
            r, c = divmod(i, W)
            lon, lat = (float(v) for v in self.grid.rowcol_to_lonlat(r, c))
            b = int(self.basin.ravel()[i])
            out.append({"id": chr(ord("A") + k), "lon": round(lon, 7), "lat": round(lat, 7),
                        "share": round(float(acc[i]) / max(1, self.n_reach), 4), "cells": int(acc[i]),
                        "area_ha": round(float(acc[i]) * res * res / 1e4, 1),
                        "minutes": round(float(dist[i]) / 60.0, 1),
                        "haven": self.havens[b]["name"] if 0 <= b < len(self.havens) else None})
        return out

    def basins(self) -> list[dict]:
        res = self.grid.res
        b = self.basin.ravel()
        counts = np.bincount(b[b >= 0].astype(np.int64), minlength=len(self.havens))
        total = max(1, self.n_reach)
        return [{"name": h["name"], "lon": h["lon"], "lat": h["lat"], "area_ha": round(float(counts[k]) * res * res / 1e4, 1),
                 "share": round(float(counts[k]) / total, 4), "rgb": BASIN_RGB[k % len(BASIN_RGB)]}
                for k, h in enumerate(self.havens)]

    def stats(self) -> dict:
        fin = np.isfinite(self.dist)
        res = self.grid.res
        return {"reachable_fraction": round(float(fin.mean()), 4), "reachable_ha": round(float(fin.sum()) * res * res / 1e4, 1),
                "nogo_fraction": round(float((~fin).mean()), 4),
                "max_minutes": round(float(self.dist[fin].max()) / 60.0, 1) if fin.any() else 0.0,
                "compute_ms": round(self.compute_ms, 1)}

    def path_home(self, lon: float, lat: float, max_steps: int = 4000) -> dict:
        """The fastest walk home from a point, cell by cell along the tree (the trunk a lost walker follows)."""
        g = self.grid
        H, W = self.shape
        r, c = (int(round(float(v))) for v in g.lonlat_to_rowcol(lon, lat))
        if not (0 <= r < H and 0 <= c < W):
            return {"ok": False, "reason": "outside the site"}
        i = r * W + c
        if not np.isfinite(self.dist.ravel()[i]):
            # step to the nearest cell that has a way home (within ~60 m)
            rad = 15
            r0, r1, c0, c1 = max(0, r - rad), min(H, r + rad + 1), max(0, c - rad), min(W, c + rad + 1)
            win = np.isfinite(self.dist[r0:r1, c0:c1])
            if not win.any():
                return {"ok": False, "reason": "no way home from here"}
            yy, xx = np.nonzero(win)
            k = int(np.argmin((yy + r0 - r) ** 2 + (xx + c0 - c) ** 2))
            i = (yy[k] + r0) * W + (xx[k] + c0)
        cells = [i]
        nxt = self.next
        for _ in range(max_steps):
            j = int(nxt[cells[-1]])
            if j < 0:
                break
            cells.append(j)
        rr, cc = np.divmod(np.asarray(cells), W)
        lon_, lat_ = g.rowcol_to_lonlat(rr, cc)
        mins = self.dist.ravel()[cells] / 60.0
        b = int(self.basin.ravel()[cells[0]])
        return {"ok": True, "path": [[round(float(a), 7), round(float(b_), 7)] for a, b_ in zip(lon_, lat_)],
                "minutes": [round(float(m), 2) for m in mins], "start_minutes": round(float(mins[0]), 1),
                "haven": self.havens[b]["name"] if 0 <= b < len(self.havens) else None,
                "flow": [int(self.acc[k]) for k in cells]}

    def streams_json(self, min_acc: int, max_streams: int = 6000) -> dict:
        """Streams for the animated client layer: lon/lat, minutes and flow at each vertex (upstream first)."""
        st = self.streams(min_acc)
        st = sorted(st, key=lambda s: -int(self.acc[s[-1]]))[:max_streams]
        W = self.shape[1]
        dist = self.dist.ravel()
        out = []
        for s in st:
            s = _decimate(s, W)
            rr, cc = np.divmod(s, W)
            lon, lat = self.grid.rowcol_to_lonlat(rr.astype(float), cc.astype(float))
            out.append({"c": [[round(float(a), 6), round(float(b), 6)] for a, b in zip(lon, lat)],
                        "m": [round(float(dist[k]) / 60.0, 1) for k in s.tolist()],
                        "f": [int(self.acc[k]) for k in s.tolist()]})
        return {"streams": out, "min_acc": int(min_acc), "n_reach": self.n_reach}

    # ------------------------------------------------------------------ pictures
    def render(self, size: int = 2048, min_acc: int = 3, nogo: bool = True, glow: bool = True,
               basins: bool | None = None, wh: tuple[int, int] | None = None) -> Image.Image:
        """The network as an RGBA picture over the whole site (north up, size x size like the other drapes,
        or wh = (width, height) pixels)."""
        H, W = self.shape
        pw, ph = wh or (size, size)
        sx, sy = pw / W, ph / H
        size = int(round((pw + ph) / 2))  # line widths scale with the picture
        img = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
        if nogo:
            ng = (~np.isfinite(self.dist)).astype(np.uint8) * 255
            m = Image.fromarray(ng, "L").resize((pw, ph), Image.NEAREST)
            red = Image.new("RGBA", (pw, ph), NOGO_RGBA)
            img.paste(red, (0, 0), m)
        multi = len(self.havens) > 1 if basins is None else basins
        if multi:  # a light wash per basin, so the split between havens reads at a glance
            b = self.basin.astype(np.int16)
            rgba = np.zeros((H, W, 4), np.uint8)
            for k in range(len(self.havens)):
                rgba[b == k] = (*BASIN_RGB[k % len(BASIN_RGB)], 34)
            img = Image.alpha_composite(img, Image.fromarray(rgba, "RGBA").resize((pw, ph), Image.NEAREST))
        lines = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
        d = ImageDraw.Draw(lines)
        total = max(1, self.n_reach)
        dist = self.dist.ravel()
        streams = sorted(self.streams(min_acc), key=lambda s: int(self.acc[s[-1]]))  # small first, trunks on top
        lmax = math.log2(total)
        k_size = size / 2048.0
        for s in streams:
            rr, cc = np.divmod(s, W)
            xs = ((cc + 0.5) * sx).tolist()
            ys = ((rr + 0.5) * sy).tolist()
            f = self.acc[s].astype(float)
            lw = np.log2(np.maximum(f, 1.0)) / lmax  # 0..1
            mins = dist[s] / 60.0
            col = ramp(mins)
            alpha = (62 + 193 * np.clip(lw * 1.5, 0, 1) ** 1.2).astype(int)
            width = 1.0 + 12.0 * lw ** 1.9 * k_size
            n = len(s)
            # one draw call per short stream (colour and width barely change); long streams in chunks
            step = n if (n <= 24 and width[-1] - width[0] < 1.0) else 8
            k0 = 0
            while k0 < n - 1:
                k1 = min(n - 1, k0 + step)
                kk = (k0 + k1) // 2
                d.line(list(zip(xs[k0:k1 + 1], ys[k0:k1 + 1])),
                       fill=(int(col[kk, 0]), int(col[kk, 1]), int(col[kk, 2]), int(alpha[kk])),
                       width=max(1, int(round(width[kk]))), joint="curve" if width[kk] >= 3 else None)
                k0 = k1
        if glow:
            trunk = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
            dt = ImageDraw.Draw(trunk)
            thr = max(min_acc, int(0.004 * total))
            for s in self.streams(thr):
                rr, cc = np.divmod(s, W)
                mins = dist[s] / 60.0
                col = ramp(mins)
                kk = len(s) // 2
                dt.line([(float((c_ + 0.5) * sx), float((r_ + 0.5) * sy)) for r_, c_ in zip(rr, cc)],
                        fill=(int(col[kk, 0]), int(col[kk, 1]), int(col[kk, 2]), 200), width=max(2, int(6 * size / 2048)))
            trunk = trunk.filter(ImageFilter.GaussianBlur(radius=5 * size / 2048))
            img = Image.alpha_composite(img, trunk)
        img = Image.alpha_composite(img, lines)
        # the havens: a bright core
        dh = ImageDraw.Draw(img)
        for (r, c), k in zip(self.haven_rc, range(len(self.havens))):
            x, y = (c + 0.5) * sx, (r + 0.5) * sy
            rad = 7 * size / 2048
            dh.ellipse([x - rad, y - rad, x + rad, y + rad], fill=(255, 250, 240, 255), outline=(*BASIN_RGB[k % len(BASIN_RGB)], 255),
                       width=max(1, int(2 * size / 2048)))
        return img

    def data_texture(self, size: int = 1024) -> Image.Image:
        """For the Godot terrain shader's moving dashes: R = line strength, G = minutes from home (/150, 255 = no way home),
        B = basin index x 40, A = 255."""
        H, W = self.shape
        rimg = self.render(size, min_acc=3, nogo=False, glow=False, basins=False).split()[3]  # alpha = line strength
        m = self.dist / 60.0
        fin = np.isfinite(m)
        g = np.where(fin, np.clip(m / 150.0 * 254.0, 0, 254), 255).astype(np.uint8)
        gimg = Image.fromarray(g, "L").resize((size, size), Image.BILINEAR)
        b = np.where(self.basin >= 0, (self.basin.astype(np.int16) + 1) * 40, 0).clip(0, 255).astype(np.uint8)
        bimg = Image.fromarray(b, "L").resize((size, size), Image.NEAREST)
        a = Image.new("L", (size, size), 255)
        return Image.merge("RGBA", (rimg, gimg, bimg, a))


def _decimate(s: np.ndarray, W: int, tol: float = 0.75) -> np.ndarray:
    """Drop vertices that sit on a straight run (8-connected staircases collapse to their corners)."""
    if len(s) <= 3:
        return s
    rr, cc = np.divmod(s, W)
    dr = np.diff(rr)
    dc = np.diff(cc)
    turn = np.r_[True, (dr[1:] != dr[:-1]) | (dc[1:] != dc[:-1]), True]
    keep = np.flatnonzero(turn)
    # keep at least every 12th vertex so long runs still carry their minutes and flow
    every = np.arange(0, len(s), 12)
    keep = np.union1d(keep, every)
    keep = np.union1d(keep, [len(s) - 1])
    return s[keep]


def parse_havens(text: str | None, default: list[dict]) -> list[dict]:
    """'lon,lat,name;lon,lat,name' -> [{lon, lat, name}] (the default when empty)."""
    out = []
    for k, part in enumerate((text or "").split(";")):
        bits = [b.strip() for b in part.split(",")]
        if len(bits) >= 2 and bits[0] and bits[1]:
            try:
                lon, lat = float(bits[0]), float(bits[1])
            except ValueError:
                continue
            out.append({"lon": lon, "lat": lat, "name": (bits[2] if len(bits) > 2 and bits[2] else f"Haven {k + 1}")[:40]})
    return out[:8] or default


def havens_key(havens: list[dict]) -> str:
    return ";".join(f"{h['lon']:.6f},{h['lat']:.6f}" for h in havens)
