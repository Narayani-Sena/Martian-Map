"""Raw-image feeds: Curiosity and Perseverance answer in different shapes; both become the same items."""

from server import rover_images


def _m20_payload():
    def img(i, inst, sol):
        base = f"https://mars.nasa.gov/mars2020-raw-images/pub/ods/surface/sol/{sol:05d}/ids/edr/browse/x/{i}"
        return {"imageid": f"IMG{i}", "sol": sol, "camera": {"instrument": inst}, "title": f"Image {i}",
                "caption": "c", "date_taken_utc": "2022-07-20T08:00:00",
                "image_files": {"small": base + "_320.jpg", "medium": base + "_800.jpg", "large": base + "_1200.jpg",
                                "full_res": base + ".png"}}
    return {"total_results": 3, "images": [img(1, "SKYCAM", 504), img(2, "NAVCAM_LEFT", 503), img(3, "MCZ_RIGHT", 503)]}


def test_perseverance_feed_is_parsed_and_ground_views_come_first(monkeypatch):
    seen = {}

    def fake_get_json(url, **kw):
        seen["url"], seen["params"] = url, kw.get("params", {})
        return _m20_payload()
    monkeypatch.setattr(rover_images, "get_json", fake_get_json)
    out = rover_images.images("mars2020", 503, 504, per_page=2)
    assert seen["url"] == rover_images.M20_API and seen["params"]["category"] == "mars2020"
    assert seen["params"]["condition_2"] == "503:sol:gte" and seen["params"]["condition_3"] == "504:sol:lte"
    assert out["total"] == 3 and [it["camera"] for it in out["items"]] == ["Mastcam-Z", "Navcam"]  # sky camera dropped
    it = out["items"][0]
    assert it["url"].endswith("_1200.jpg") and it["thumb"].endswith("_320.jpg") and it["sol"] == 503


def test_curiosity_feed_shape(monkeypatch):
    payload = {"total": 1, "items": [{"imageid": "A", "sol": 4500, "instrument": "NAV_LEFT_B", "title": "t",
                                      "https_url": "https://mars.nasa.gov/msl-raw-images/msss/04500/mcam/x.jpg"}]}
    monkeypatch.setattr(rover_images, "get_json", lambda url, **kw: payload)
    out = rover_images.images("msl", 4500, 4500)
    assert out["items"][0]["camera"] == "Navcam" and out["items"][0]["thumb"].endswith("-thm.jpg")
