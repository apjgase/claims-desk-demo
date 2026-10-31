"""Middleware API: the only tier that talks to PostgreSQL.

Run: uvicorn claimsdesk.api:app --host 127.0.0.1 --port 8000
"""
import logging
from contextlib import asynccontextmanager
from datetime import date
from decimal import Decimal
from typing import Literal, Optional

import psycopg
from fastapi import FastAPI, File, HTTPException, Query, Request, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse, Response
from psycopg_pool import PoolTimeout
from pydantic import BaseModel, Field

from . import __version__, config, db, fraud
from .docs_client import DocsError, get_photo, health as docs_health, put_packet, put_photo
from .docs_client import get_packet as docs_get_packet, photo_index as docs_photo_index

log = logging.getLogger("claimsdesk.api")
CFG = config.load()
IDENT = config.host_identity()
RUNTIME = config.runtime()
pool = db.make_pool(CFG)

Status = Literal["SUBMITTED", "IN_REVIEW", "APPROVED", "REJECTED", "PAID"]
LossType = Literal["Auto", "Property", "Travel", "Health", "Other"]


class ClaimIn(BaseModel):
    policy_number: str = Field(min_length=3, max_length=32)
    claimant_name: str = Field(min_length=1, max_length=120)
    contact_email: Optional[str] = Field(default=None, max_length=200)
    loss_date: date
    loss_type: LossType
    amount: Decimal = Field(ge=0, max_digits=12, decimal_places=2)
    description: str = Field(min_length=1, max_length=4000)
    adjuster: Optional[str] = Field(default=None, max_length=120)


class StatusIn(BaseModel):
    status: Status


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # wait=False: the API starts even when the database is unreachable, and reports it.
    pool.open(wait=False)
    yield
    pool.close()


app = FastAPI(title="Claims Desk API", version=__version__, lifespan=lifespan,
              docs_url="/api/docs", openapi_url="/api/openapi.json", redoc_url=None)


@app.exception_handler(PoolTimeout)
@app.exception_handler(psycopg.OperationalError)
async def db_unavailable(_request: Request, exc: Exception):
    log.warning("database unavailable: %s", exc)
    return JSONResponse(status_code=503, content={
        "detail": "database unavailable",
        "db_endpoint": "{}:{}".format(CFG["db_host"], CFG["db_port"]),
        "error": str(exc).strip().splitlines()[0] if str(exc).strip() else type(exc).__name__,
    })


def _run(fn, *args, timeout=None):
    def work():
        with pool.connection(timeout=timeout) as conn:
            return fn(conn, *args)
    return run_in_threadpool(work)


@app.get("/api/v1/health")
async def health():
    await _run(lambda c: c.execute("SELECT 1").fetchone())
    return {"status": "ok", "db": "ok"}


@app.get("/api/v1/info")
async def info():
    out = {
        "service": "claims-api",
        "version": __version__,
        "stage": config.stage_label(CFG),
        "documents": docs_health(CFG),
        "host": IDENT,
        "runtime": RUNTIME,
        "db_endpoint": {"host": CFG["db_host"], "port": CFG["db_port"],
                        "database": CFG["db_name"], "schema": CFG["db_schema"]},
    }
    try:
        # Every page footer calls this, so it gives up quickly when the database is down.
        out["db"] = await _run(db.server_info, timeout=2)
        out["db"]["status"] = "ok"
    except (PoolTimeout, psycopg.OperationalError) as exc:
        out["db"] = {"status": "unavailable", "error": str(exc).strip().splitlines()[0]}
    return out


@app.get("/api/v1/stats")
async def stats():
    return await _run(db.stats)


@app.get("/api/v1/claims")
async def list_claims(status: Optional[Status] = None,
                      q: Optional[str] = Query(default=None, max_length=64),
                      limit: int = Query(default=50, ge=1, le=500),
                      loss_type: Optional[LossType] = None,
                      text: Optional[str] = Query(default=None, max_length=64),
                      loss_from: Optional[date] = None, loss_to: Optional[date] = None,
                      amount_min: Optional[Decimal] = Query(default=None, ge=0),
                      amount_max: Optional[Decimal] = Query(default=None, ge=0)):
    return await _run(db.list_claims, status, q, limit, loss_type, text,
                      loss_from, loss_to, amount_min, amount_max)


@app.post("/api/v1/claims", status_code=201)
async def create_claim(claim: ClaimIn):
    data = claim.model_dump()
    for key in ("contact_email", "adjuster"):
        if data[key] is not None and not data[key].strip():
            data[key] = None
    return await _run(db.insert_claim, data, IDENT["hostname"])


@app.get("/api/v1/claims/{claim_number}")
async def get_claim(claim_number: str):
    row = await _run(db.get_claim, claim_number)
    if row is None:
        raise HTTPException(status_code=404, detail="claim not found")
    return row


def _docs_failure(exc: DocsError):
    return JSONResponse(status_code=exc.status, content={
        "detail": str(exc),
        "documents": CFG["docs_url"],
    })


@app.post("/api/v1/claims/{claim_number}/photo")
async def upload_photo(claim_number: str, photo: UploadFile = File(...)):
    if not config.documents_active(CFG):
        raise HTTPException(status_code=409, detail="document tier is not in the active stage")
    row = await _run(db.get_claim, claim_number)
    if row is None:
        raise HTTPException(status_code=404, detail="claim not found")
    blob = await photo.read()
    if not blob:
        raise HTTPException(status_code=400, detail="photo is empty")
    if len(blob) > 10 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="photo larger than 10 MB")
    try:
        path = await run_in_threadpool(
            put_photo, CFG, claim_number, photo.filename or "photo", blob,
            photo.content_type or "application/octet-stream")
    except DocsError as exc:
        return _docs_failure(exc)
    stored = await _run(db.set_photo_path, claim_number, path)
    return stored


@app.get("/api/v1/claims/{claim_number}/photo")
async def download_photo(claim_number: str):
    if not config.documents_active(CFG):
        raise HTTPException(status_code=409, detail="document tier is not in the active stage")
    row = await _run(db.get_claim, claim_number)
    if row is None or not row["photo_path"]:
        raise HTTPException(status_code=404, detail="photo not found")
    try:
        content, media = await run_in_threadpool(get_photo, CFG, claim_number)
    except DocsError as exc:
        return _docs_failure(exc)
    return Response(content=content, media_type=media)


# ---------------------------------------------------------------- stage 5: read-only views
# The chat assistant reads these. None of them writes to PostgreSQL, Files, or Objects.

async def _photo_facts():
    """Photo facts by claim number, or (None, reason) when Files cannot be read."""
    if not config.documents_active(CFG):
        return None, "files: document tier not active"
    try:
        return await run_in_threadpool(docs_photo_index, CFG), None
    except DocsError as exc:
        return None, "files: {}".format(exc)


async def _packet_for(row):
    """The packet document, "missing", or None when there is nothing to check."""
    if not (row.get("packet_url") and config.documents_active(CFG)):
        return None
    try:
        found = await run_in_threadpool(docs_get_packet, CFG, row["claim_number"])
    except DocsError:
        return None
    return found["packet"] if found else "missing"


@app.get("/api/v1/claims/{claim_number}/related")
async def related_claims(claim_number: str):
    row = await _run(db.get_claim, claim_number)
    if row is None:
        raise HTTPException(status_code=404, detail="claim not found")
    claims = await _run(db.all_claims)
    return dict(fraud.related(row, claims), claim_number=claim_number)


@app.get("/api/v1/claims/{claim_number}/packet")
async def claim_packet(claim_number: str):
    row = await _run(db.get_claim, claim_number)
    if row is None:
        raise HTTPException(status_code=404, detail="claim not found")
    if not config.documents_active(CFG):
        raise HTTPException(status_code=409, detail="document tier is not in the active stage")
    if not row["packet_url"]:
        return {"claim_number": claim_number, "status": row["status"], "packet": None,
                "note": "no packet: it is written when the claim is first approved"}
    try:
        found = await run_in_threadpool(docs_get_packet, CFG, claim_number)
    except DocsError as exc:
        return _docs_failure(exc)
    if found is None:
        return {"claim_number": claim_number, "status": row["status"], "packet": None,
                "packet_url": row["packet_url"], "note": "packet_url is set but the object is missing"}
    diff = fraud.packet_diff(row, found["packet"])
    return {"claim_number": claim_number, "status": row["status"], "packet_url": found["packet_url"],
            "accepted_at": found["packet"].get("accepted_at"), "matches_database": not diff,
            "differences": diff, "packet": found["packet"]}


@app.get("/api/v1/fraud/{claim_number}")
async def fraud_check(claim_number: str):
    claims = await _run(db.all_claims)
    row = next((c for c in claims if c["claim_number"] == claim_number), None)
    if row is None:
        raise HTTPException(status_code=404, detail="claim not found")
    photo_index, why = await _photo_facts()
    result = fraud.analyse(row, claims, photo_index, await _packet_for(row))
    if why:
        result["skipped"].append(why)
    return result


@app.get("/api/v1/fraud")
async def fraud_scan(scope: Literal["open", "decided", "all"] = "open",
                     limit: int = Query(default=10, ge=1, le=100),
                     min_score: int = Query(default=1, ge=0, le=100)):
    claims = await _run(db.all_claims)
    photo_index, why = await _photo_facts()
    wanted = set(fraud.scope_statuses(scope))
    results, packets = [], 0
    for row in claims:
        if row["status"] not in wanted:
            continue
        packet = None
        if packets < 50:
            packet = await _packet_for(row)
            packets += packet is not None
        results.append(fraud.analyse(row, claims, photo_index, packet))
    ranked = sorted((r for r in results if r["score"] >= min_score),
                    key=lambda r: (-r["score"], r["claim_number"]))
    return {
        "scope": scope, "scored": len(results), "flagged": len(ranked), "claims": ranked[:limit],
        "sources": {"postgresql": len(claims), "files_photos": None if photo_index is None else len(photo_index),
                    "objects_packets": packets},
        "skipped": [why] if why else [],
        "levels": {"high": ">= 50", "medium": "25-49", "low": "1-24"},
    }


@app.patch("/api/v1/claims/{claim_number}")
async def update_status(claim_number: str, body: StatusIn):
    current = await _run(db.get_claim, claim_number)
    if current is None:
        raise HTTPException(status_code=404, detail="claim not found")
    packet_url = None
    # The accepted packet is written once, when the claim first becomes APPROVED.
    if (body.status == "APPROVED" and not current["packet_url"] and config.documents_active(CFG)):
        try:
            packet_url = await run_in_threadpool(put_packet, CFG, dict(current))
        except DocsError as exc:
            return _docs_failure(exc)
    row = await _run(db.set_status, claim_number, body.status, packet_url)
    if row is None:
        raise HTTPException(status_code=404, detail="claim not found")
    return row
