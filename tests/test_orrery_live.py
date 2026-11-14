"""The interplanetary map (feature A5), Ask Earth (D2) and the habitat-helmet relay (D1)."""

import asyncio
import json
from datetime import datetime, timezone

from fastapi.testclient import TestClient

from server import live, orrery
from server.main import app

client = TestClient(app)


def _t(s):
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)


def test_close_approach_and_conjunction_distances():
    # Mars came within 0.642 AU of Earth on 2025-01-12; the 2023 solar conjunction was ~2.5 AU; 2027 opposition 0.678 AU
    assert abs(orrery.light_time_s(_t("2025-01-12")) / orrery.LIGHT_S_PER_AU - 0.642) < 0.01
    assert abs(orrery.light_time_s(_t("2023-11-18")) / orrery.LIGHT_S_PER_AU - 2.52) < 0.05
    assert abs(orrery.light_time_s(_t("2027-02-20")) / orrery.LIGHT_S_PER_AU - 0.678) < 0.01


def test_light_time_bounds_and_ask_earth():
    for d in ("2026-01-01", "2026-06-01", "2027-01-01", "2028-06-01"):
        lt = orrery.light_time_s(_t(d)) / 60
        assert 3.0 < lt < 22.5
    a = orrery.ask_earth(_t("2026-11-14"), think_min=10)
    assert abs(a["answer_after_s"] - (2 * a["one_way_s"] + 600)) < 1


def test_cme_direction_follows_earth_longitude():
    sims = [{"cmeInputs": [{"CMEID": "X", "time21_5": "2026-11-10T00:00Z", "longitude": 0.0, "latitude": 0, "speed": 800, "halfAngle": 30}],
             "impactList": [{"location": "Earth", "arrivalTime": "2026-11-12T12:00Z"}]}]
    snap = orrery.snapshot(_t("2026-11-11"), sims)
    c = snap["cmes"][0]
    assert abs(((c["lon_ecliptic"] - snap["lon_earth"] + 180) % 360) - 180) < 0.1  # a CME at longitude 0 points at Earth
    assert 0 < c["front_au_now"] < 1.0


def test_orrery_endpoint():
    j = client.get("/api/orrery").json()
    assert 3 < j["light_time_min"] < 23 and len(j["earth_orbit"]) > 100 and len(j["light_time_curve_min"]) > 50


class FakeWS:
    def __init__(self):
        self.sent = []

    async def send_text(self, t):
        self.sent.append(json.loads(t))


def test_hub_relays_telemetry_and_commands():
    async def run():
        h = live.Hub()
        helmet, console = FakeWS(), FakeWS()
        h.clients[helmet] = "helmet"
        h.clients[console] = "console"
        await h.telemetry(live.clean_telemetry({"type": "telemetry", "lon": 1.5, "lat": 2.5, "o2_pct": 80, "evil": "<script>"}))
        assert console.sent[-1]["lon"] == 1.5 and "evil" not in console.sent[-1] and not helmet.sent
        cmd = live.clean_command({"type": "waypoint", "lon": 3, "lat": 4, "name": "Look"})
        await h.command(cmd)
        assert helmet.sent[-1]["type"] == "waypoint" and helmet.sent[-1]["lon"] == 3.0
        assert console.sent[-1].get("echo") is True
        assert live.clean_command({"type": "rm -rf"}) is None
        assert h.status()["clients"] == {"helmet": 1, "console": 1}
    asyncio.run(run())


def test_live_http_fallback():
    r = client.post("/api/live/test_site/telemetry", json={"lon": 1, "lat": 2, "eva_t": 30})
    assert r.status_code == 200
    assert client.get("/api/live/test_site").json()["last"]["eva_t"] == 30.0
    c = client.post("/api/live/test_site/command", json={"type": "message", "text": "Hello EV1"}).json()
    items = client.get("/api/live/test_site/inbox", params={"after": c["id"] - 1}).json()["items"]
    assert items and items[-1]["text"] == "Hello EV1"
