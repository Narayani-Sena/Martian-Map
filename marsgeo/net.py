"""Polite HTTP helpers: one shared session, retries, and an on-disk cache."""

from __future__ import annotations

import json
import os
import queue
import threading
import time
from concurrent.futures import Future
from pathlib import Path

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

USER_AGENT = "martian-map/1.0 (python-requests)"

_session: requests.Session | None = None


def session() -> requests.Session:
    global _session
    if _session is None:
        s = requests.Session()
        s.headers["User-Agent"] = USER_AGENT
        retry = Retry(total=4, backoff_factor=0.8, status_forcelist=(429, 500, 502, 503, 504),
                      allowed_methods=("GET", "POST"))
        adapter = HTTPAdapter(max_retries=retry, pool_connections=16, pool_maxsize=16)
        s.mount("https://", adapter)
        s.mount("http://", adapter)
        _session = s
    return _session


def download(url: str, dest: Path, overwrite: bool = False, timeout: float = 60.0) -> Path | None:
    """Download url to dest (atomically). Returns None on HTTP 404."""
    dest = Path(dest)
    if dest.exists() and not overwrite:
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    r = session().get(url, timeout=timeout)
    if r.status_code == 404:
        return None
    r.raise_for_status()
    tmp = dest.with_suffix(dest.suffix + ".part")
    tmp.write_bytes(r.content)
    os.replace(tmp, dest)
    return dest


def get_json(url: str, cache_path: Path | None = None, ttl_s: float | None = None,
             params: dict | None = None, timeout: float = 60.0, allow_stale: bool = True):
    """GET JSON with an optional file cache.

    ttl_s=None means the cache never expires. If the network fails and a stale
    cache exists, the stale copy is returned when allow_stale is True.
    """
    if cache_path is not None:
        cache_path = Path(cache_path)
        if cache_path.exists():
            age = time.time() - cache_path.stat().st_mtime
            if ttl_s is None or age < ttl_s:
                return json.loads(cache_path.read_text(encoding="utf-8"))
    try:
        r = session().get(url, params=params, timeout=timeout)
        r.raise_for_status()
        data = r.json()
    except Exception:
        if cache_path is not None and cache_path.exists() and allow_stale:
            return json.loads(cache_path.read_text(encoding="utf-8"))
        raise
    if cache_path is not None:
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = cache_path.with_suffix(".part")
        tmp.write_text(json.dumps(data), encoding="utf-8")
        os.replace(tmp, cache_path)
    return data


def gdal_http_env() -> dict:
    """GDAL settings for fast, range-request reads of cloud-optimised GeoTIFFs."""
    return {
        "GDAL_DISABLE_READDIR_ON_OPEN": "EMPTY_DIR",
        "CPL_VSIL_CURL_ALLOWED_EXTENSIONS": ".tif,.TIF,.tiff",
        "GDAL_HTTP_MULTIRANGE": "YES",
        "GDAL_HTTP_MERGE_CONSECUTIVE_RANGES": "YES",
        "GDAL_HTTP_USERAGENT": USER_AGENT,
        "GDAL_HTTP_MAX_RETRY": "4",
        "GDAL_HTTP_RETRY_DELAY": "1",
        "VSI_CACHE": "TRUE",
        "VSI_CACHE_SIZE": str(256 * 1024 * 1024),
    }


class DaemonPool:
    """A small thread pool whose workers never hold up the interpreter's exit.

    concurrent.futures' pools join their workers when Python exits, so one feed that answers slowly (a request's
    timeout is per socket read, not in total) kept the server, or a test run, from shutting down. These workers are
    daemon threads: at exit an unfinished fetch is simply dropped. submit() returns an ordinary Future."""

    def __init__(self, workers: int, name: str):
        self._q: queue.SimpleQueue = queue.SimpleQueue()
        self._n, self._name = workers, name
        self._started = False
        self._lock = threading.Lock()

    def _start(self):
        with self._lock:
            if self._started:
                return
            for i in range(self._n):
                threading.Thread(target=self._run, name=f"{self._name}_{i}", daemon=True).start()
            self._started = True

    def submit(self, fn, *args, **kwargs) -> Future:
        self._start()
        f: Future = Future()
        self._q.put((f, fn, args, kwargs))
        return f

    def map(self, fn, items) -> list:
        """Run fn over items on the pool and wait for all of them (results in order)."""
        futs = [self.submit(fn, x) for x in items]
        return [f.result() for f in futs]

    def _run(self):
        while True:
            f, fn, args, kwargs = self._q.get()
            if not f.set_running_or_notify_cancel():
                continue
            try:
                f.set_result(fn(*args, **kwargs))
            except BaseException as e:  # noqa: BLE001 - handed to the waiting caller
                f.set_exception(e)
