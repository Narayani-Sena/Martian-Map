"""Search the USGS Astrogeology STAC catalog (HiRISE/CTX DTMs, THEMIS mosaics)."""

from __future__ import annotations

from .net import session

STAC_API = "https://stac.astrogeology.usgs.gov/api"


def search(collections, bbox=None, limit: int = 100, ids=None) -> list[dict]:
    """POST /search and follow 'next' links. bbox = (lon_min, lat_min, lon_max, lat_max)."""
    body: dict = {"collections": list(collections), "limit": limit}
    if bbox is not None:
        body["bbox"] = list(bbox)
    if ids:
        body["ids"] = list(ids)
    url = f"{STAC_API}/search"
    feats: list[dict] = []
    for _ in range(20):
        r = session().post(url, json=body, timeout=90)
        r.raise_for_status()
        js = r.json()
        feats.extend(js.get("features", []))
        nxt = next((l for l in js.get("links", []) if l.get("rel") == "next"), None)
        if not nxt or len(feats) >= limit:
            break
        url = nxt["href"]
        body = nxt.get("body", body)
    return feats


def asset_href(item: dict, key: str) -> str | None:
    a = item.get("assets", {}).get(key)
    return a.get("href") if a else None
