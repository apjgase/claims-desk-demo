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
    assert r.json()["packet_url"] is None
    assert any(c["claim_number"] == "CLM-000006"
               for c in api_client.get("/api/v1/claims", params={"status": "APPROVED"}).json())
    assert api_client.get("/api/v1/claims", params={"q": "test person"}).json()[0]["claim_number"] == "CLM-000006"
    assert api_client.get("/api/v1/stats").json()["total"] == 6

    assert api_client.get("/api/v1/claims/CLM-999999").status_code == 404
    assert api_client.patch("/api/v1/claims/CLM-000006", json={"status": "NOPE"}).status_code == 422
    assert api_client.post("/api/v1/claims", json={**new, "amount": "-1"}).status_code == 422
    assert api_client.post("/api/v1/claims", json={**new, "loss_type": "Boat"}).status_code == 422


def test_migrate_keeps_generated_claim_number(database):
    import psycopg
    os.environ["CLAIMS_DB_NAME"] = "claims_upgrade"
    info = dict(host=_SOCKET, port=ENV["CLAIMS_DB_PORT"], dbname="claims_upgrade",
                user="claims_app", password=ENV["CLAIMS_DB_PASSWORD"], autocommit=True)
    try:
        admin("bootstrap")
        with psycopg.connect(**info) as conn:
            conn.execute("CREATE SCHEMA IF NOT EXISTS claimsdesk; SET search_path TO claimsdesk; "
                         "CREATE TABLE claims (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, "
                         "claim_number text GENERATED ALWAYS AS ('CLM-' || lpad(id::text, 6, '0')) STORED, "
                         "status text NOT NULL DEFAULT 'SUBMITTED', created_at timestamptz NOT NULL DEFAULT now())")
        admin("migrate")
        admin("migrate")
        with psycopg.connect(**info) as conn:
            conn.execute("SET search_path TO claimsdesk")
            assert conn.execute("SELECT count(*) FROM pg_trigger WHERE tgname = 'claims_claim_number'"
                                ).fetchone()[0] == 0
            assert conn.execute("INSERT INTO claims DEFAULT VALUES RETURNING claim_number"
                                ).fetchone()[0] == "CLM-000001"
    finally:
        os.environ["CLAIMS_DB_NAME"] = ENV["CLAIMS_DB_NAME"]


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
    assert "unreachable" not in about.text
    new_page = web_client.get("/claims/new")
    assert 'type="file" disabled' in new_page.text
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


def test_stage3_about_and_photo_field(web_client, monkeypatch):
    from claimsdesk import api, web

    def fake_health(_cfg):
        return {
            "enabled": True,
            "status": "ok",
            "url": "http://10.1.1.8:8090",
            "host": {"hostname": "docvm.ntnxlab.local", "ip": "10.1.1.8"},
            "nfs": {"export": "labFS.ntnxlab.local:/documents", "mount": "/mnt/claims-docs", "mounted": True},
            "s3": {"endpoint": "https://objects.example", "bucket": "claims"},
        }

    monkeypatch.setattr(api, "docs_health", fake_health)
    web.CFG["stage"] = 3
    api.CFG["stage"] = 3
    web._info_cache["data"] = None
    try:
        about = web_client.get("/about")
        assert about.status_code == 200
        assert "Adjuster browser" in about.text and "nginx + web tier" in about.text
        assert "Middleware API" in about.text and "Document VM" in about.text
        assert "PostgreSQL HA" not in about.text
        assert "labFS.ntnxlab.local:/documents" in about.text
        assert "NFS 2049" in about.text and "S3 443" in about.text
        assert "primary" in about.text and "unreachable" not in about.text
        page = web_client.get("/claims/new")
        assert 'type="file" name="photo"' in page.text
        assert 'type="file" disabled' not in page.text
    finally:
        web.CFG["stage"] = 1
        api.CFG["stage"] = 1
        web._info_cache["data"] = None


def test_lower_stage_keeps_documents_configured_but_unused(web_client, api_client):
    from claimsdesk import api, web
    saved = (api.CFG.get("stage"), api.CFG.get("docs_url"), web.CFG.get("stage"))
    api.CFG["stage"] = 1
    api.CFG["docs_url"] = "http://10.1.1.8:8090"
    web.CFG["stage"] = 1
    web._info_cache["data"] = None
    try:
        about = web_client.get("/about")
        assert "Stage 1 - Portal VM" in about.text
        assert "<b>Document VM</b>" not in about.text
        assert 'type="file" disabled' in web_client.get("/claims/new").text
        info = api_client.get("/api/v1/info").json()
        assert info["documents"]["enabled"] is False
        web.CFG["stage"] = 2
        web._info_cache["data"] = None
        ha = web_client.get("/about")
        assert "PostgreSQL HA" in ha.text and "<b>Document VM</b>" not in ha.text
        web.CFG["stage"] = 5
        web.CFG["api_url"] = "https://claims-api.apps.ntnxlab.local"
        web._info_cache["data"] = None
        pods = web_client.get("/about")
        assert "API pods" in pods.text and "Chat pods" in pods.text
        assert "<b>Document VM</b>" not in pods.text
    finally:
        api.CFG["stage"], api.CFG["docs_url"], web.CFG["stage"] = saved
        web.CFG["api_url"] = "http://127.0.0.1:8000"
        web._info_cache["data"] = None


def test_photo_and_packet(api_client, monkeypatch):
    from claimsdesk import api
    calls = {"photo": 0, "packet": 0}

    def fake_photo(_cfg, claim_number, _filename, content, _content_type):
        calls["photo"] += 1
        calls["bytes"] = content
        return "/mnt/claims-docs/{}/photo.png".format(claim_number)

    seen = {}

    def fake_get(_cfg, claim_number):
        seen["claim"] = claim_number
        return calls["bytes"], "image/png"

    def fake_packet(_cfg, claim):
        calls["packet"] += 1
        return "https://objects.example/claims/{}/packet.json".format(claim["claim_number"])

    monkeypatch.setattr(api, "put_photo", fake_photo)
    monkeypatch.setattr(api, "get_photo", fake_get)
    monkeypatch.setattr(api, "put_packet", fake_packet)
    api.CFG["docs_url"] = "http://10.0.0.8:8090"
    api.CFG["docs_timeout"] = 5
    api.CFG["stage"] = 3
    try:
        new = {"policy_number": "POL-90001", "claimant_name": "Photo Person",
               "loss_date": "2026-10-02", "loss_type": "Auto", "amount": "10.00",
               "description": "Dent"}
        created = api_client.post("/api/v1/claims", json=new)
        assert created.status_code == 201, created.text
        number = created.json()["claim_number"]
        png = b"\x89PNG\r\n\x1a\n" + b"x" * 8
        stored = api_client.post("/api/v1/claims/{}/photo".format(number),
                                 files={"photo": ("damage.png", png, "image/png")})
        assert stored.status_code == 200, stored.text
        assert stored.json()["photo_path"].endswith("/photo.png")
        fetched = api_client.get("/api/v1/claims/{}/photo".format(number))
        assert fetched.status_code == 200 and fetched.content == png
        assert seen["claim"] == number

        reviewed = api_client.patch("/api/v1/claims/{}".format(number), json={"status": "IN_REVIEW"})
        assert reviewed.json()["packet_url"] is None and calls["packet"] == 0
        approved = api_client.patch("/api/v1/claims/{}".format(number), json={"status": "APPROVED"})
        assert approved.json()["packet_url"].endswith("/packet.json")
        assert calls["packet"] == 1
        again = api_client.patch("/api/v1/claims/{}".format(number), json={"status": "APPROVED"})
        assert again.json()["packet_url"] == approved.json()["packet_url"]
        assert calls["packet"] == 1
    finally:
        api.CFG["docs_url"] = ""
        api.CFG["stage"] = 1


def test_reset(database):
    assert "numbering restarts" in admin("reset")
    assert "0 claims" in admin("check")
