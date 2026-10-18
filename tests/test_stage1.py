"""Stage 1 tests against a real, throwaway PostgreSQL (pgserver).

  pip install -r app/requirements.txt pytest pgserver
  pytest -q tests
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import pytest

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app"
sys.path.insert(0, str(APP))

pgserver = pytest.importorskip("pgserver")
_PGDATA = tempfile.mkdtemp(prefix="claimsdesk-pg-")
_SERVER = pgserver.get_server(_PGDATA, cleanup_mode="delete")
_URI = urlparse(_SERVER.get_uri())
_SOCKET = parse_qs(_URI.query)["host"][0]

ENV = {
    "CLAIMS_DB_HOST": _SOCKET,
    "CLAIMS_DB_PORT": str(_URI.port or 5432),
    "CLAIMS_DB_NAME": "claims_test",
    "CLAIMS_DB_USER": "claims_app",
    "CLAIMS_DB_PASSWORD": "Test-pw'with\"quotes$",
    "CLAIMS_DB_SSLMODE": "disable",
    "CLAIMS_DB_ADMIN_USER": _URI.username or "postgres",
    "CLAIMS_DB_ADMIN_PASSWORD": "",
    "CLAIMS_DB_ADMIN_DB": "postgres",
}
os.environ.update(ENV)
os.environ.pop("CLAIMS_CONFIG", None)


def admin(*args):
    r = subprocess.run([sys.executable, "-m", "claimsdesk.admin", *args], cwd=APP,
                       env=dict(os.environ), capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout


@pytest.fixture(scope="module")
def database():
    admin("bootstrap")
    admin("bootstrap")  # re-run is safe
    admin("migrate")
    out = admin("migrate")
    assert "table claims ready (0 rows)" in out
    assert "inserted 5 claims" in admin("seed", "5")
    assert "skipped" in admin("seed", "5", "--if-empty")
    assert "5 claims" in admin("check")
    yield


@pytest.fixture(scope="module")
def api_client(database):
    from fastapi.testclient import TestClient
    from claimsdesk import api
    with TestClient(api.app) as c:
        yield c


@pytest.fixture(scope="module")
def web_client(api_client):
    from fastapi.testclient import TestClient
    from claimsdesk import web
    web.client = api_client
    with TestClient(web.app) as c:
        yield c


def test_api_flow(api_client):
    assert api_client.get("/api/v1/health").json() == {"status": "ok", "db": "ok"}
    info = api_client.get("/api/v1/info").json()
    assert info["db"]["status"] == "ok" and info["db"]["in_recovery"] is False

    new = {"policy_number": "POL-12345", "claimant_name": "Test Person", "loss_date": "2026-10-01",
           "loss_type": "Auto", "amount": "1234.50", "description": "Scratch", "contact_email": ""}
    r = api_client.post("/api/v1/claims", json=new)
    assert r.status_code == 201, r.text
    claim = r.json()
    assert claim["claim_number"] == "CLM-000006"
    assert claim["status"] == "SUBMITTED" and claim["contact_email"] is None
    assert claim["created_by_host"]

    assert api_client.get("/api/v1/claims/CLM-000006").json()["amount"] in (1234.5, "1234.50")
    r = api_client.patch("/api/v1/claims/CLM-000006", json={"status": "APPROVED"})
    assert r.json()["status"] == "APPROVED"
    assert any(c["claim_number"] == "CLM-000006"
               for c in api_client.get("/api/v1/claims", params={"status": "APPROVED"}).json())
    assert api_client.get("/api/v1/claims", params={"q": "test person"}).json()[0]["claim_number"] == "CLM-000006"
    assert api_client.get("/api/v1/stats").json()["total"] == 6

    assert api_client.get("/api/v1/claims/CLM-999999").status_code == 404
    assert api_client.patch("/api/v1/claims/CLM-000006", json={"status": "NOPE"}).status_code == 422
    assert api_client.post("/api/v1/claims", json={**new, "amount": "-1"}).status_code == 422
    assert api_client.post("/api/v1/claims", json={**new, "loss_type": "Boat"}).status_code == 422


def test_web_flow(web_client):
    r = web_client.get("/")
    assert r.status_code == 200 and "CLM-000001" in r.text
    r = web_client.post("/claims/new", data={
        "policy_number": "POL-777", "claimant_name": "Web User", "contact_email": "",
        "loss_date": "2026-10-10", "loss_type": "Property", "amount": "99.99",
        "description": "Leak", "adjuster": ""}, follow_redirects=False)
    assert r.status_code == 303, r.text
    location = r.headers["location"]
    assert location.startswith("/claims/CLM-")
    page = web_client.get(location)
    assert "submitted and committed" in page.text and "Web User" in page.text
    num = location.split("/")[2].split("?")[0]
    r = web_client.post("/claims/{}/status".format(num), data={"status": "IN_REVIEW"},
                        follow_redirects=True)
    assert "IN REVIEW" in r.text

    bad = web_client.post("/claims/new", data={
        "policy_number": "P", "claimant_name": "X", "loss_date": "2026-10-10",
        "loss_type": "Auto", "amount": "1", "description": "d"})
    assert bad.status_code == 400 and "at least 3 characters" in bad.text

    assert web_client.get("/claims/CLM-999999").status_code == 404
    about = web_client.get("/about")
    assert "Request path" in about.text and "primary" in about.text
    assert web_client.get("/healthz").json()["backend"] == "ok"
    assert web_client.get("/static/style.css").status_code == 200


def test_web_when_api_down(web_client):
    import httpx
    from claimsdesk import web
    saved = web.client
    web.client = httpx.Client(base_url="http://127.0.0.1:9", timeout=1)
    web._info_cache["data"] = None
    try:
        r = web_client.get("/")
        assert r.status_code == 200 and "Middleware API unreachable" in r.text
        assert web_client.get("/healthz").status_code == 503
    finally:
        web.client = saved
        web._info_cache["data"] = None


def test_api_when_db_down(database):
    from fastapi.testclient import TestClient
    from claimsdesk import config, db
    from claimsdesk import api
    cfg = config.load()
    cfg.update(db_host="127.0.0.1", db_port=9, db_connect_timeout=1)
    saved = api.pool
    api.pool = db.make_pool(cfg)
    try:
        with TestClient(api.app) as c:
            r = c.get("/api/v1/health")
            assert r.status_code == 503 and r.json()["detail"] == "database unavailable"
            assert c.get("/api/v1/info").json()["db"]["status"] == "unavailable"
    finally:
        api.pool = saved


def test_reset(database):
    assert "numbering restarts" in admin("reset")
    assert "0 claims" in admin("check")
