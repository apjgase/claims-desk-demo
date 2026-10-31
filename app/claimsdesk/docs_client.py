"""Middleware client for the document service.

Stage 3: the service runs on the document VM. Stage 4: it is the docs container
in the same pod as the middleware. The middleware never mounts Files and never
holds the Objects keys.
"""
from datetime import date, datetime
from decimal import Decimal
from typing import Any, Dict, Optional, Tuple

import httpx

from . import config


class DocsError(Exception):
    def __init__(self, message: str, status: int = 502):
        super().__init__(message)
        self.status = status


def plain(value: Any) -> Any:
    """JSON-ready copy of a database row."""
    if isinstance(value, dict):
        return {k: plain(v) for k, v in value.items()}
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, Decimal):
        return format(value, "f")
    return value


def _tier() -> str:
    return "document container" if config.runtime()["kind"] == "pod" else "document VM"


def _url(cfg: Dict[str, Any], path: str) -> str:
    return cfg["docs_url"].rstrip("/") + path


def _error(response: httpx.Response) -> DocsError:
    try:
        body = response.json()
    except ValueError:
        body = {}
    detail = body.get("detail") if isinstance(body, dict) else ""
    if not isinstance(detail, str) or not detail:
        detail = response.text.strip().splitlines()[0] if response.text.strip() else "no detail"
    status = response.status_code if response.status_code in (400, 404, 413, 415) else 502
    return DocsError(detail[:300], status)


def health(cfg: Dict[str, Any]) -> Dict[str, Any]:
    """Short probe for /api/v1/info. Below stage 3 the saved URL is not called."""
    if not config.documents_active(cfg):
        return {"enabled": False}
    url = _url(cfg, "/health")
    try:
        response = httpx.get(url, timeout=3)
        body = response.json()
    except (httpx.HTTPError, ValueError) as exc:
        text = str(exc).strip().splitlines()
        return {
            "enabled": True,
            "status": "unavailable",
            "url": cfg["docs_url"],
            "error": (text[0] if text else type(exc).__name__)[:200],
        }
    if not isinstance(body, dict):
        body = {}
    body["enabled"] = True
    body["url"] = cfg["docs_url"]
    if response.status_code != 200:
        body["status"] = "unavailable"
    return body


def put_photo(cfg: Dict[str, Any], claim_number: str, filename: str,
              content: bytes, content_type: str) -> str:
    try:
        response = httpx.post(
            _url(cfg, "/v1/photos"),
            data={"claim_number": claim_number},
            files={"photo": (filename or "photo", content, content_type or "application/octet-stream")},
            timeout=cfg["docs_timeout"],
        )
    except httpx.HTTPError as exc:
        raise DocsError("{} unreachable at {} ({})".format(
            _tier(), cfg["docs_url"], type(exc).__name__)) from exc
    if response.status_code >= 400:
        raise _error(response)
    return response.json()["photo_path"]


def get_photo(cfg: Dict[str, Any], claim_number: str) -> Tuple[bytes, str]:
    try:
        response = httpx.get(_url(cfg, "/v1/photos/" + claim_number), timeout=cfg["docs_timeout"])
    except httpx.HTTPError as exc:
        raise DocsError("{} unreachable at {} ({})".format(
            _tier(), cfg["docs_url"], type(exc).__name__)) from exc
    if response.status_code >= 400:
        raise _error(response)
    media = response.headers.get("content-type", "application/octet-stream")
    return response.content, media.split(";")[0]


def _get_json(cfg: Dict[str, Any], path: str) -> Optional[Dict[str, Any]]:
    """GET from the document service. None on 404."""
    try:
        response = httpx.get(_url(cfg, path), timeout=cfg["docs_timeout"])
    except httpx.HTTPError as exc:
        raise DocsError("{} unreachable at {} ({})".format(
            _tier(), cfg["docs_url"], type(exc).__name__)) from exc
    if response.status_code == 404:
        return None
    if response.status_code >= 400:
        raise _error(response)
    return response.json()


def photo_index(cfg: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    """Photo facts by claim number, read from the share by the document service."""
    body = _get_json(cfg, "/v1/photos/index") or {}
    return {p["claim_number"]: p for p in body.get("photos", [])}


def get_packet(cfg: Dict[str, Any], claim_number: str) -> Optional[Dict[str, Any]]:
    """The WORM packet from Objects, or None when it was never written."""
    return _get_json(cfg, "/v1/packets/" + claim_number)


def put_packet(cfg: Dict[str, Any], claim: Dict[str, Any]) -> str:
    try:
        response = httpx.post(
            _url(cfg, "/v1/packets"),
            json=plain(claim),
            timeout=cfg["docs_timeout"],
        )
    except httpx.HTTPError as exc:
        raise DocsError("{} unreachable at {} ({})".format(
            _tier(), cfg["docs_url"], type(exc).__name__)) from exc
    if response.status_code >= 400:
        raise _error(response)
    return response.json()["packet_url"]
