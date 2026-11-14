"""Route finding on the 2 m terrain grid.

Two engines, so you can compare them:

* ``astar``  - our own A* in plain Python. Each step's cost uses the real
  direction of travel, so walking uphill costs more than walking down.
  Heuristic: octile distance / fastest possible speed (admissible, so with
  weight=1 the route is optimal). weight>1 = "weighted A*": faster, at most
  `weight` times longer than optimal.
* ``dijkstra`` - scikit-image's MCP_Geometric (Dijkstra in C). Very fast, but
  it only knows a cost per *cell*, so it can't tell uphill from downhill.

Both paths are then evaluated with the same directional walking model, so the
numbers in the comparison panel are apples to apples.
"""

from __future__ import annotations

import heapq
import math
import time
from array import array
from dataclasses import dataclass, field

import numpy as np

from .walkmodel import WalkParams, isotropic_seconds_per_meter

SQ2 = math.sqrt(2.0)
INF = float("inf")


@dataclass
class RouteResult:
    cells: list  # [(row, col), ...] on the 2 m grid
    cost_s: float
    expansions: int
    compute_ms: float
    engine: str
    warnings: list = field(default_factory=list)


class Router:
    """Holds the padded grids as flat arrays for the hand-written A*."""

    def __init__(self, z: np.ndarray, res: float):
        self.H, self.W = z.shape
        self.Wp = self.W + 2
        self.res = float(res)
        zp = np.pad(z.astype(np.float64), 1, mode="edge")
        self.z = array("d")
        self.z.frombytes(zp.ravel().tobytes())
        Wp, r, d = self.Wp, self.res, self.res * SQ2
        self.nbrs = ((-Wp - 1, d), (-Wp, r), (-Wp + 1, d), (-1, r), (1, r), (Wp - 1, d), (Wp, r), (Wp + 1, d))
        self._mult: dict[str, tuple[np.ndarray, array]] = {}

    # ------------------------------------------------------------ cost grids
    def set_multiplier(self, key: str, mult: np.ndarray, p: WalkParams | None = None):
        """Store the cost multiplier and precompute the 8 directional edge costs.

        Edge cost i -> i+offset = step length / walking speed for that grade x mean
        multiplier. Doing this once with numpy turns A*'s inner loop into a single
        array lookup instead of an exp() per neighbour (~2-3x faster in CPython).
        """
        p = p or WalkParams()
        H, W, Wp = self.H, self.W, self.Wp
        zp = np.pad(np.frombuffer(self.z, dtype=np.float64).reshape(H + 2, Wp)[1:-1, 1:-1], 1, mode="edge")
        mp = np.pad(mult.astype(np.float64), 1, constant_values=np.inf)
        edges = []
        for off, d in self.nbrs:
            dr, dc = (off + Wp + 1) // Wp - 1, (off + Wp + 1) % Wp - 1
            src_z, src_m = zp[1:H + 1, 1:W + 1], mp[1:H + 1, 1:W + 1]
            dst_z = zp[1 + dr:H + 1 + dr, 1 + dc:W + 1 + dc]
            dst_m = mp[1 + dr:H + 1 + dr, 1 + dc:W + 1 + dc]
            with np.errstate(invalid="ignore"):
                t = d / (p.v_flat() * p.grade_factor((dst_z - src_z) / d)) * 0.5 * (src_m + dst_m)
            full = np.full((H + 2, Wp), np.inf)
            full[1:H + 1, 1:W + 1] = np.where(np.isfinite(t), t, np.inf)
            a = array("d")
            a.frombytes(full.ravel().tobytes())
            edges.append((off, a))
        if len(self._mult) > 2:  # each entry holds ~200 MB of edge costs on a 1600^2 grid
            self._mult.pop(next(iter(self._mult)))
        self._mult[key] = (mult, edges, p)

    def has_multiplier(self, key: str) -> bool:
        return key in self._mult

    def multiplier(self, key: str) -> np.ndarray:
        return self._mult[key][0]

    def idx(self, r: int, c: int) -> int:
        return (r + 1) * self.Wp + (c + 1)

    def rc(self, i: int):
        r, c = divmod(i, self.Wp)
        return r - 1, c - 1

    def snap_passable(self, key: str, r: int, c: int, radius: int = 15):
        """Nearest passable cell (within radius cells) - stops can sit on a no-go cell."""
        mult = self._mult[key][0]
        r = min(max(r, 0), self.H - 1)
        c = min(max(c, 0), self.W - 1)
        if np.isfinite(mult[r, c]):
            return r, c, False
        r0, r1 = max(0, r - radius), min(self.H, r + radius + 1)
        c0, c1 = max(0, c - radius), min(self.W, c + radius + 1)
        sub = np.isfinite(mult[r0:r1, c0:c1])
        if not sub.any():
            return r, c, True
        rr, cc = np.nonzero(sub)
        k = np.argmin((rr + r0 - r) ** 2 + (cc + c0 - c) ** 2)
        return int(rr[k] + r0), int(cc[k] + c0), True

    # ------------------------------------------------------------------- A*
    def astar(self, key: str, start, goal, p: WalkParams, weight: float = 1.0,
              max_expansions: int = 4_000_000) -> RouteResult:
        t0 = time.perf_counter()
        _, edges, p_cost = self._mult[key]
        p = p_cost  # edge costs were built with these walking parameters
        Wp, res = self.Wp, self.res
        s, g = self.idx(*start), self.idx(*goal)
        n = len(self.z)
        gs = array("d", [INF]) * n
        parent = array("l", [-1]) * n
        closed = bytearray(n)
        gr, gc = divmod(g, Wp)
        inv_vmax = res / (p.v_flat() * p.max_factor())  # octile cells -> seconds (admissible)
        k_oct = SQ2 - 2.0
        w = float(weight)
        push, pop = heapq.heappush, heapq.heappop
        gs[s] = 0.0
        heap = [(0.0, s)]
        expansions = 0
        found = False
        while heap:
            _, i = pop(heap)
            if closed[i]:
                continue
            closed[i] = 1
            expansions += 1
            if i == g:
                found = True
                break
            if expansions > max_expansions:
                break
            gi = gs[i]
            for off, ec in edges:
                j = i + off
                if closed[j]:
                    continue
                ng = gi + ec[i]  # inf for no-go neighbours -> never improves gs[j]
                if ng < gs[j]:
                    gs[j] = ng
                    parent[j] = i
                    jr, jc = divmod(j, Wp)
                    dr = jr - gr if jr > gr else gr - jr
                    dc = jc - gc if jc > gc else gc - jc
                    h = (dr + dc + k_oct * (dr if dr < dc else dc)) * inv_vmax
                    push(heap, (ng + w * h, j))
        ms = (time.perf_counter() - t0) * 1000
        if not found:
            return RouteResult([], INF, expansions, ms, "astar", ["No safe route found within the limits"])
        cells, i = [], g
        while i != -1:
            cells.append(self.rc(i))
            i = parent[i]
        cells.reverse()
        return RouteResult(cells, gs[g], expansions, ms, "astar")

    # ---------------------------------------------------- Dijkstra (skimage)
    def dijkstra(self, key: str, start, goal, p: WalkParams, slope: np.ndarray) -> RouteResult:
        from skimage.graph import MCP_Geometric

        t0 = time.perf_counter()
        mult = self._mult[key][0]
        costs = isotropic_seconds_per_meter(p, slope, mult) * self.res
        costs[~np.isfinite(costs)] = -1.0  # MCP: negative = impassable
        mcp = MCP_Geometric(costs, fully_connected=True)
        cum, _ = mcp.find_costs([start], [goal], find_all_ends=True)
        ms = (time.perf_counter() - t0) * 1000
        if not np.isfinite(cum[goal]):
            return RouteResult([], INF, 0, ms, "dijkstra", ["No safe route found within the limits"])
        cells = [tuple(map(int, rc)) for rc in mcp.traceback(goal)]
        expansions = int(np.isfinite(cum).sum())
        return RouteResult(cells, float(cum[goal]), expansions, ms, "dijkstra")


def evaluate_cells(cells, z: np.ndarray, slope: np.ndarray, mult: np.ndarray, res: float, p: WalkParams):
    """Distance/time/grade along a cell path using the directional mobility model (walker or rover)."""
    rc = np.asarray(cells, dtype=int)
    if len(rc) < 2:
        return {"d": np.zeros(len(rc)), "t": np.zeros(len(rc)), "z": z[rc[:, 0], rc[:, 1]] if len(rc) else np.zeros(0),
                "grade": np.zeros(len(rc)), "slope": np.zeros(len(rc))}
    zz = z[rc[:, 0], rc[:, 1]].astype(float)
    step = res * np.hypot(*np.diff(rc, axis=0).T)
    dz = np.diff(zz)
    grade = dz / step
    m = mult[rc[:, 0], rc[:, 1]].astype(float)
    m = np.where(np.isfinite(m), m, 3.0)  # snapped endpoints: treat as very slow, not infinite
    dt = step / (p.v_flat() * p.grade_factor(grade)) * 0.5 * (m[:-1] + m[1:])
    return {
        "d": np.concatenate([[0.0], np.cumsum(step)]),
        "t": np.concatenate([[0.0], np.cumsum(dt)]),
        "z": zz,
        "grade": np.concatenate([grade[:1], grade]),
        "slope": slope[rc[:, 0], rc[:, 1]].astype(float),
        "step": step,
        "dt": dt,
        "dz": dz,
    }


def simplify_cells(cells, tol_cells: float = 0.75):
    """Douglas-Peucker on the cell path (display only - keeps every corner that matters)."""
    pts = np.asarray(cells, dtype=float)
    if len(pts) < 3:
        return list(range(len(pts)))
    keep = np.zeros(len(pts), bool)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        a, b = stack.pop()
        if b <= a + 1:
            continue
        seg = pts[b] - pts[a]
        L = np.hypot(*seg)
        rel = pts[a + 1:b] - pts[a]
        if L == 0:
            dist = np.hypot(rel[:, 0], rel[:, 1])
        else:
            dist = np.abs(seg[0] * rel[:, 1] - seg[1] * rel[:, 0]) / L
        k = int(np.argmax(dist))
        if dist[k] > tol_cells:
            keep[a + 1 + k] = True
            stack.append((a, a + 1 + k))
            stack.append((a + 1 + k, b))
    return list(np.nonzero(keep)[0])
