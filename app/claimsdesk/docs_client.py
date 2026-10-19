"""Portal middleware client for the document VM.

The portal never mounts Files and never holds the Objects keys. It calls this
service on the document VM.
"""
from datetime import date, datetime
from decimal import Decimal
from typing import Any, Dict, Tuple

import httpx


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
    """Short probe for /api/v1/info. Empty docs_url means stage 1."""
    if not cfg.get("docs_url"):
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
        raise DocsError("document VM unreachable at {} ({})".format(
            cfg["docs_url"], type(exc).__name__)) from exc
    if response.status_code >= 400:
        raise _error(response)
    return response.json()["photo_path"]


def get_photo(cfg: Dict[str, Any], claim_number: str) -> Tuple[bytes, str]:
    try:
        response = httpx.get(_url(cfg, "/v1/photos/" + claim_number), timeout=cfg["docs_timeout"])
    except httpx.HTTPError as exc:
        raise DocsError("document VM unreachable at {} ({})".format(
            cfg["docs_url"], type(exc).__name__)) from exc
    if response.status_code >= 400:
        raise _error(response)
    media = response.headers.get("content-type", "application/octet-stream")
    return response.content, media.split(";")[0]


def put_packet(cfg: Dict[str, Any], claim: Dict[str, Any]) -> str:
    try:
        response = httpx.post(
            _url(cfg, "/v1/packets"),
            json=plain(claim),
            timeout=cfg["docs_timeout"],
        )
    except httpx.HTTPError as exc:
        raise DocsError("document VM unreachable at {} ({})".format(
            cfg["docs_url"], type(exc).__name__)) from exc
    if response.status_code >= 400:
        raise _error(response)
    return response.json()["packet_url"]
