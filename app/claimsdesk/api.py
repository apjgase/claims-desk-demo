"""Middleware API: the only tier that talks to PostgreSQL.

Run: uvicorn claimsdesk.api:app --host 127.0.0.1 --port 8000
"""
import logging
from contextlib import asynccontextmanager
from datetime import date
from decimal import Decimal
from typing import Literal, Optional

import psycopg
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse
from psycopg_pool import PoolTimeout
from pydantic import BaseModel, Field

from . import STAGE, __version__, config, db

log = logging.getLogger("claimsdesk.api")
CFG = config.load()
IDENT = config.host_identity()
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
        "stage": STAGE,
        "host": IDENT,
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
                      limit: int = Query(default=50, ge=1, le=500)):
    return await _run(db.list_claims, status, q, limit)


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


@app.patch("/api/v1/claims/{claim_number}")
async def update_status(claim_number: str, body: StatusIn):
    row = await _run(db.set_status, claim_number, body.status)
    if row is None:
        raise HTTPException(status_code=404, detail="claim not found")
    return row
