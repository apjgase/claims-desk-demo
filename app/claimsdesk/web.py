"""Web tier: server-rendered pages. Talks only to the middleware API, never to the database.

Run: uvicorn claimsdesk.web:app --host 127.0.0.1 --port 8080
"""
import time
from datetime import date, datetime
from pathlib import Path
from typing import Any, Dict, Optional, Tuple
from urllib.parse import quote, urlparse

import httpx
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from . import __version__, config
from .db import LOSS_TYPES, STATUSES

HERE = Path(__file__).parent
CFG = config.load()
IDENT = config.host_identity()

client = httpx.Client(base_url=CFG["api_url"], timeout=CFG["api_timeout"])
templates = Jinja2Templates(directory=str(HERE / "templates"))

app = FastAPI(title="Claims Desk web", version=__version__, docs_url=None, redoc_url=None,
              openapi_url=None)
app.mount("/static", StaticFiles(directory=str(HERE / "static")), name="static")


def _money(value: Any) -> str:
    try:
        return "{:,.2f}".format(float(value))
    except (TypeError, ValueError):
        return str(value)


def _when(value: Any) -> str:
    if not value:
        return ""
    try:
        return datetime.fromisoformat(str(value)).strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return str(value)


templates.env.filters["money"] = _money
templates.env.filters["when"] = _when


def api(method: str, path: str, **kw) -> Tuple[Optional[Any], Optional[str], int]:
    """Call the middleware. Returns (data, error message, HTTP status)."""
    try:
        r = client.request(method, path, **kw)
    except httpx.HTTPError as exc:
        return None, "Middleware API unreachable at {} ({})".format(
            CFG["api_url"], type(exc).__name__), 0
    try:
        body = r.json()
    except ValueError:
        body = None
    if r.status_code == 503:
        detail = body or {}
        return None, "Database unavailable at {}: {}".format(
            detail.get("db_endpoint", "?"), detail.get("error", "no detail")), 503
    # A document-tier failure carries the document VM URL as a string. /api/v1/info
    # also has a documents object; that is live health, not a failure.
    if (r.status_code >= 400 and isinstance(body, dict)
            and isinstance(body.get("documents"), str) and r.status_code not in (400, 404, 413, 415)):
        return None, "Document service unavailable at {}: {}".format(
            body["documents"], body.get("detail", "no detail")), r.status_code
    if r.status_code >= 400:
        return body, None, r.status_code
    return body, None, r.status_code


_info_cache: Dict[str, Any] = {"at": 0.0, "data": None}


def api_info() -> Optional[Dict[str, Any]]:
    if time.monotonic() - _info_cache["at"] > 10 or _info_cache["data"] is None:
        data, _err, _code = api("GET", "/api/v1/info")
        _info_cache.update(at=time.monotonic(), data=data)
    return _info_cache["data"]


def _port(url: str) -> int:
    parts = urlparse(url)
    try:
        explicit = parts.port
    except ValueError:
        explicit = None
    return explicit or (443 if parts.scheme == "https" else 80)


def render(request: Request, name: str, status_code: int = 200, **ctx) -> HTMLResponse:
    ctx.update(
        site_name=CFG["site_name"],
        environment=CFG["environment"],
        stage=config.stage_label(CFG),
        stage_number=config.stage_number(CFG),
        version=__version__,
        web=IDENT,
        api_url=CFG["api_url"],
        api_port=_port(CFG["api_url"]),
        info=api_info(),
        statuses=STATUSES,
        loss_types=LOSS_TYPES,
    )
    return templates.TemplateResponse(request, name, ctx, status_code=status_code)


@app.get("/healthz")
def healthz():
    _data, err, _code = api("GET", "/api/v1/health")
    body = {"web": "ok", "api_url": CFG["api_url"], "backend": "ok" if err is None else err}
    return JSONResponse(body, status_code=200 if err is None else 503)


@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request, status: str = "", q: str = ""):
    params = {k: v for k, v in {"status": status, "q": q.strip()}.items() if v}
    stats, err, _ = api("GET", "/api/v1/stats")
    claims, err2, _ = (None, None, 0) if err else api("GET", "/api/v1/claims", params=params)
    return render(request, "index.html", stats=stats, claims=claims or [], error=err or err2,
                  status=status, q=q)


@app.get("/claims/new", response_class=HTMLResponse)
def new_claim(request: Request):
    return render(request, "new.html", form={"loss_date": date.today().isoformat()}, errors={})


def _field(form, name: str) -> str:
    value = form.get(name)
    if value is None or hasattr(value, "read"):
        return ""
    return str(value).strip()


@app.post("/claims/new", response_class=HTMLResponse)
async def create_claim(request: Request):
    incoming = await request.form()
    form = {
        "policy_number": _field(incoming, "policy_number"),
        "claimant_name": _field(incoming, "claimant_name"),
        "contact_email": _field(incoming, "contact_email") or None,
        "loss_date": _field(incoming, "loss_date"),
        "loss_type": _field(incoming, "loss_type"),
        "amount": _field(incoming, "amount"),
        "description": _field(incoming, "description"),
        "adjuster": _field(incoming, "adjuster") or None,
    }
    upload = incoming.get("photo")
    blob = b""
    filename = ""
    content_type = "application/octet-stream"
    if upload is not None and hasattr(upload, "read"):
        filename = getattr(upload, "filename", "") or ""
        blob = await upload.read()
        content_type = getattr(upload, "content_type", None) or content_type
    data, err, code = api("POST", "/api/v1/claims", json=form)
    if code == 201:
        if filename and blob:
            _pdata, perr, pcode = api(
                "POST", "/api/v1/claims/{}/photo".format(data["claim_number"]),
                files={"photo": (filename, blob, content_type)})
            if perr or pcode >= 400:
                detail = ""
                if isinstance(_pdata, dict) and isinstance(_pdata.get("detail"), str):
                    detail = _pdata["detail"]
                msg = (perr or detail or "Photo was not stored ({})".format(pcode))[:180]
                return RedirectResponse(
                    "/claims/{}?created=1&photo_error={}".format(data["claim_number"], quote(msg)),
                    status_code=303)
        return RedirectResponse("/claims/{}?created=1".format(data["claim_number"]),
                                status_code=303)
    errors: Dict[str, str] = {}
    if code == 422 and data:
        for item in data.get("detail", []):
            field = item.get("loc", ["", "form"])[-1]
            errors[str(field)] = item.get("msg", "invalid")
    return render(request, "new.html", status_code=400 if code == 422 else 502,
                  form=form, errors=errors, error=err)


@app.get("/claims/{claim_number}", response_class=HTMLResponse)
def claim_detail(request: Request, claim_number: str, created: int = 0, photo_error: str = ""):
    data, err, code = api("GET", "/api/v1/claims/{}".format(claim_number))
    if code == 404:
        return render(request, "claim.html", status_code=404, claim=None,
                      error="Claim {} not found".format(claim_number))
    return render(request, "claim.html", claim=data, error=photo_error or err, created=created)


@app.get("/claims/{claim_number}/photo")
def claim_photo(claim_number: str):
    try:
        response = client.request("GET", "/api/v1/claims/{}/photo".format(claim_number))
    except httpx.HTTPError:
        return HTMLResponse("Middleware API unreachable", status_code=502)
    if response.status_code >= 400:
        return HTMLResponse("Photo not available", status_code=response.status_code)
    return Response(content=response.content,
                    media_type=response.headers.get("content-type", "application/octet-stream"))


@app.post("/claims/{claim_number}/status")
def claim_status(request: Request, claim_number: str, status: str = Form(...)):
    _data, err, code = api("PATCH", "/api/v1/claims/{}".format(claim_number),
                           json={"status": status})
    if err or code >= 400:
        claim, err2, _ = api("GET", "/api/v1/claims/{}".format(claim_number))
        return render(request, "claim.html", status_code=502 if err else code, claim=claim,
                      error=err or err2 or "Status update rejected ({})".format(code))
    return RedirectResponse("/claims/{}".format(claim_number), status_code=303)


@app.get("/about", response_class=HTMLResponse)
def about(request: Request):
    _info_cache["data"] = None
    return render(request, "about.html")
