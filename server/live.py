"""Habitat and suit, live (feature D1): the API as a relay between the helmet and the habitat console.

Earth is 3 to 22 light-minutes away, too far to direct an EVA, so the habitat does: a crew member inside follows
the walker live (position, suit, alerts) on the web console and can push a new waypoint into the visor. The
console also shows the crew "as Earth sees them": the same telemetry, one light-time late.

One WebSocket per client at /ws/live/{site}. The first message says who it is ({"type": "hello", "role":
"helmet" | "console"}). The helmet sends {"type": "telemetry", ...}; consoles receive it. A console sends
{"type": "waypoint", lon, lat, name} or {"type": "message", text}; helmets receive it. Plain HTTP endpoints do the
same for clients without WebSockets.
"""

from __future__ import annotations

import asyncio
import json
import time
from collections import deque


class Hub:
    def __init__(self):
        self.clients: dict = {}  # websocket -> role
        self.last: dict | None = None
        self.history: deque = deque(maxlen=3600)  # ~30 min at 2 Hz: enough for the Earth-delayed view
        self.inbox: deque = deque(maxlen=50)  # console -> helmet messages, for HTTP polling helmets
        self.lock = asyncio.Lock()
        self.seq = 0

    def roles(self) -> dict:
        out = {"helmet": 0, "console": 0}
        for r in self.clients.values():
            out[r] = out.get(r, 0) + 1
        return out

    async def send_to(self, role: str, msg: dict):
        dead = []
        data = json.dumps(msg)
        for ws, r in list(self.clients.items()):
            if r != role:
                continue
            try:
                await ws.send_text(data)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.clients.pop(ws, None)

    async def telemetry(self, msg: dict):
        msg = {**msg, "type": "telemetry", "server_t": time.time()}
        self.last = msg
        self.history.append(msg)
        await self.send_to("console", msg)

    async def command(self, msg: dict):
        self.seq += 1
        msg = {**msg, "id": self.seq, "server_t": time.time()}
        self.inbox.append(msg)
        await self.send_to("helmet", msg)
        await self.send_to("console", {**msg, "echo": True})
        return msg

    def status(self) -> dict:
        age = time.time() - self.last["server_t"] if self.last else None
        return {"clients": self.roles(), "last": self.last, "age_s": round(age, 1) if age is not None else None,
                "history": len(self.history)}


_hubs: dict[str, Hub] = {}


def hub(site_id: str) -> Hub:
    if site_id not in _hubs:
        _hubs[site_id] = Hub()
    return _hubs[site_id]


ALLOWED_TELEMETRY = {"lon", "lat", "heading", "eva_t", "mode", "speed", "o2_pct", "battery_pct", "co2_pct", "water_pct", "ppco2_mmhg",
                     "suit_kpa", "hr_bpm", "met_w", "margin_min", "walkback_min", "alerts", "phase", "next_wp", "dose_usv", "source",
                     "drill", "autopilot", "playing"}


def clean_telemetry(msg: dict) -> dict:
    """Keep the known fields only, as plain numbers / short strings (the relay passes them to browsers)."""
    out = {}
    for k, v in msg.items():
        if k not in ALLOWED_TELEMETRY:
            continue
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            out[k] = float(v)
        elif isinstance(v, bool):
            out[k] = v
        elif isinstance(v, str):
            out[k] = v[:80]
        elif isinstance(v, list):
            out[k] = [str(x)[:80] for x in v[:8]]
    return out


def clean_command(msg: dict) -> dict | None:
    t = msg.get("type")
    if t == "waypoint":
        try:
            return {"type": "waypoint", "lon": float(msg["lon"]), "lat": float(msg["lat"]), "name": str(msg.get("name") or "Habitat waypoint")[:40]}
        except (KeyError, TypeError, ValueError):
            return None
    if t == "message":
        return {"type": "message", "text": str(msg.get("text") or "")[:160]}
    if t == "clear_waypoint":
        return {"type": "clear_waypoint"}
    return None
