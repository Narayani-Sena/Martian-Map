"""Ground-level photos from the rovers' raw-image feed (mars.nasa.gov), cached."""

from __future__ import annotations

from pathlib import Path

from marsgeo.net import get_json

API = "https://mars.nasa.gov/api/v1/raw_image_items/"  # Curiosity (and older missions)
M20_API = "https://mars.nasa.gov/rss/api/"  # Perseverance: the raw-images RSS feed, different shape
# Ground-level views first; sky, EDL and cache cameras last.
M20_PREFER = ("MCZ_", "NAVCAM_", "FRONT_HAZCAM", "REAR_HAZCAM", "SHERLOC_WATSON", "SUPERCAM")
CACHE = Path(__file__).resolve().parents[1] / "data" / "cache" / "raw_images"

CAMERA_NAMES = {
    "MAST": "Mastcam", "NAV": "Navcam", "FHAZ": "Front Hazcam", "RHAZ": "Rear Hazcam", "MAHLI": "MAHLI",
    "CHEMCAM": "ChemCam RMI", "MARDI": "MARDI",
    "MCZ": "Mastcam-Z", "NAVCAM": "Navcam", "FRONT_HAZCAM": "Front Hazcam", "REAR_HAZCAM": "Rear Hazcam",
    "SHERLOC": "SHERLOC WATSON", "SUPERCAM": "SuperCam RMI", "SKYCAM": "MEDA SkyCam", "HELI": "Ingenuity",
    "CACHECAM": "CacheCam", "EDL": "EDL camera",
}


def camera_name(instrument: str) -> str:
    inst = (instrument or "").upper()
    for k in sorted(CAMERA_NAMES, key=len, reverse=True):
        if inst.startswith(k):
            return CAMERA_NAMES[k]
    return inst.replace("_", " ").title()


def thumb_url(url: str) -> str:
    if "/msss/" in url and url.lower().endswith(".jpg") and "-thm" not in url:
        return url[:-4] + "-thm.jpg"
    return url


def _images_m20(sol_from: int, sol_to: int, per_page: int) -> dict:
    params = {"feed": "raw_images", "category": "mars2020", "feedtype": "json", "ver": "1.2", "num": 100, "page": 0,
              "order": "sol desc", "condition_2": f"{sol_from}:sol:gte", "condition_3": f"{sol_to}:sol:lte",
              "extended": "sample_type::full,"}
    js = get_json(M20_API, cache_path=CACHE / f"mars2020_{sol_from}_{sol_to}_rss.json", ttl_s=24 * 3600,
                  params=params, timeout=40)
    items = []
    for it in js.get("images", []):
        files = it.get("image_files") or {}
        url = files.get("large") or files.get("medium") or files.get("full_res")
        if not url:
            continue
        inst = str((it.get("camera") or {}).get("instrument") or "")
        items.append({
            "id": it.get("imageid"), "sol": it.get("sol"), "instrument": inst, "camera": camera_name(inst),
            "title": it.get("title"), "url": url, "thumb": files.get("small") or url,
            "date_taken": it.get("date_taken_utc"), "caption": (it.get("caption") or "")[:300],
        })

    def rank(it):
        return next((i for i, p in enumerate(M20_PREFER) if it["instrument"].upper().startswith(p)), len(M20_PREFER))
    items.sort(key=lambda it: (rank(it), -(it["sol"] or 0)))
    return {"mission": "mars2020", "sol_from": sol_from, "sol_to": sol_to, "total": js.get("total_results"),
            "items": items[:per_page]}


def ingenuity(sol: int, per_page: int = 24) -> dict:
    """Ingenuity's photos taken on a sol: the feed keeps them in their own category, "ingenuity"."""
    params = {"feed": "raw_images", "category": "ingenuity", "feedtype": "json", "ver": "1.2", "num": 100, "page": 0,
              "order": "sol desc", "condition_2": f"{sol}:sol:gte", "condition_3": f"{sol}:sol:lte"}
    js = get_json(M20_API, cache_path=CACHE / f"ingenuity_{sol}.json", ttl_s=7 * 24 * 3600, params=params, timeout=40)
    items = []
    for it in js.get("images", []):
        files = it.get("image_files") or {}
        url = files.get("large") or files.get("medium") or files.get("full_res")
        if not url:
            continue
        inst = str((it.get("camera") or {}).get("instrument") or "")
        items.append({
            "id": it.get("imageid"), "sol": it.get("sol"), "instrument": inst,
            "camera": "Ingenuity colour camera (RTE)" if "RTE" in inst.upper() else "Ingenuity navigation camera (down-looking)",
            "title": it.get("title"), "url": url, "thumb": files.get("small") or url,
            "date_taken": it.get("date_taken_utc"), "caption": (it.get("caption") or "")[:300],
        })
    items.sort(key=lambda it: (0 if "RTE" in it["instrument"].upper() else 1, str(it["date_taken"] or "")))
    return {"mission": "ingenuity", "sol_from": sol, "sol_to": sol, "total": js.get("total_results"), "items": items[:per_page]}


def images(mission: str, sol_from: int, sol_to: int, per_page: int = 60) -> dict:
    if mission == "mars2020":
        return _images_m20(sol_from, sol_to, per_page)
    params = {
        "order": "sol desc,instrument_sort asc,sample_type_sort asc, date_taken desc",
        "per_page": per_page, "page": 0,
        "condition_1": f"{mission}:mission",
        "condition_2": f"{sol_from}:sol:gte",
        "condition_3": f"{sol_to}:sol:lte",
        "extended": "thumbnail::sample_type::noteq",
    }
    js = get_json(API, cache_path=CACHE / f"{mission}_{sol_from}_{sol_to}_{per_page}.json", ttl_s=24 * 3600,
                  params=params, timeout=40)
    items = []
    for it in js.get("items", []):
        url = it.get("https_url") or it.get("url")
        if not url:
            continue
        items.append({
            "id": it.get("imageid"), "sol": it.get("sol"), "instrument": it.get("instrument"),
            "camera": camera_name(it.get("instrument")), "title": it.get("title"),
            "url": url, "thumb": thumb_url(url), "date_taken": it.get("date_taken"),
            "caption": (it.get("caption") or "")[:300],
        })
    return {"mission": mission, "sol_from": sol_from, "sol_to": sol_to, "total": js.get("total"), "items": items}
