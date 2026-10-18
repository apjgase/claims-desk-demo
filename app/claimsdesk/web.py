"""Web tier: server-rendered pages. Talks only to the middleware API, never to the database.

Run: uvicorn claimsdesk.web:app --host 127.0.0.1 --port 8080
"""
import time
from datetime import date, datetime
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

import httpx
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from . import STAGE, __version__, config
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
    if r.status_code >= 400:
        return body, None, r.status_code
    return body, None, r.status_code


_info_cache: Dict[str, Any] = {"at": 0.0, "data": None}


def api_info() -> Optional[Dict[str, Any]]:
    if time.monotonic() - _info_cache["at"] > 10 or _info_cache["data"] is None:
        data, _err, _code = api("GET", "/api/v1/info")
        _info_cache.update(at=time.monotonic(), data=data)
    return _info_cache["data"]


def render(request: Request, name: str, status_code: int = 200, **ctx) -> HTMLResponse:
    ctx.update(
        site_name=CFG["site_name"],
        environment=CFG["environment"],
        stage=STAGE,
        version=__version__,
        web=IDENT,
        api_url=CFG["api_url"],
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


@app.post("/claims/new", response_class=HTMLResponse)
def create_claim(request: Request,
                 policy_number: str = Form(""), claimant_name: str = Form(""),
                 contact_email: str = Form(""), loss_date: str = Form(""),
                 loss_type: str = Form(""), amount: str = Form(""),
                 description: str = Form(""), adjuster: str = Form("")):
    form = {
        "policy_number": policy_number.strip(), "claimant_name": claimant_name.strip(),
        "contact_email": contact_email.strip() or None, "loss_date": loss_date,
        "loss_type": loss_type, "amount": amount.strip(), "description": description.strip(),
        "adjuster": adjuster.strip() or None,
    }
    data, err, code = api("POST", "/api/v1/claims", json=form)
    if code == 201:
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
def claim_detail(request: Request, claim_number: str, created: int = 0):
    data, err, code = api("GET", "/api/v1/claims/{}".format(claim_number))
    if code == 404:
        return render(request, "claim.html", status_code=404, claim=None,
                      error="Claim {} not found".format(claim_number))
    return render(request, "claim.html", claim=data, error=err, created=created)


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
