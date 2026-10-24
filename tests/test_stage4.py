"""Stage 4: pod runtime in /api/v1/info, the stage 4 and 5 diagrams, and stage switching.

No PostgreSQL and no cluster: the middleware reply is faked, and update.sh's
apply_stage runs against a temporary /etc/claims-desk with stubbed systemctl and nginx.
"""
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import psycopg
import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "app"))

from claimsdesk import config  # noqa: E402

POD_ENV = {
    "POD_NAMESPACE": "claims",
    "NODE_NAME": "nkp-md-0-abcde",
    "NODE_IP": "10.10.120.21",
    "POD_IP": "192.168.3.17",
}


def test_runtime_is_vm_without_kubernetes(monkeypatch):
    for key in list(POD_ENV) + ["KUBERNETES_SERVICE_HOST"]:
        monkeypatch.delenv(key, raising=False)
    assert config.runtime() == {"kind": "vm"}


def test_runtime_reads_the_downward_api(monkeypatch):
    for key, value in POD_ENV.items():
        monkeypatch.setenv(key, value)
    assert config.runtime() == {
        "kind": "pod", "namespace": "claims", "node": "nkp-md-0-abcde",
        "node_ip": "10.10.120.21", "pod_ip": "192.168.3.17",
    }


def test_info_reports_the_pod_runtime(monkeypatch):
    from claimsdesk import api
    for key, value in POD_ENV.items():
        monkeypatch.setenv(key, value)
    monkeypatch.setattr(api, "RUNTIME", config.runtime())
    monkeypatch.setattr(api, "docs_health", lambda _cfg: {"enabled": True, "status": "ok"})

    async def database_down(*_args, **_kwargs):
        raise psycopg.OperationalError("connection refused")

    monkeypatch.setattr(api, "_run", database_down)
    body = TestClient(api.app).get("/api/v1/info").json()
    assert body["runtime"]["kind"] == "pod"
    assert body["runtime"]["node"] == "nkp-md-0-abcde"
    assert body["db"]["status"] == "unavailable"


def _pod_info(stage_label="Stage 4 - API pods", mounted=True):
    return {
        "service": "claims-api",
        "stage": stage_label,
        "host": {"hostname": "claims-desk-api-7d9f8-x2k4p", "ip": "192.168.3.17"},
        "runtime": {"kind": "pod", "namespace": "claims", "node": "nkp-md-0-abcde",
                    "node_ip": "10.10.120.21", "pod_ip": "192.168.3.17"},
        "db_endpoint": {"host": "10.38.12.40", "port": 5000, "database": "claims", "schema": "claimsdesk"},
        "db": {"status": "ok", "server_addr": "10.38.12.41", "in_recovery": False,
               "database": "claims", "db_user": "claims_app", "version": "PostgreSQL 16",
               "server_time": "2026-10-24T13:00:00Z"},
        "documents": {
            "enabled": True,
            "status": "ok" if mounted else "nfs not mounted",
            "url": "http://127.0.0.1:8090",
            "host": {"hostname": "claims-desk-api-7d9f8-x2k4p", "ip": "192.168.3.17"},
            "nfs": {"export": "10.10.140.11:/documents", "mount": "/mnt/claims-docs", "mounted": mounted},
            "s3": {"endpoint": "https://objects.ntnxlab.local", "bucket": "claims"},
        },
    }


@pytest.fixture
def web_at(monkeypatch):
    from claimsdesk import web

    def configure(stage, info, api_url="http://10.10.120.150:8443"):
        monkeypatch.setitem(web.CFG, "stage", stage)
        monkeypatch.setitem(web.CFG, "api_url", api_url)
        monkeypatch.setattr(web, "api_info", lambda: info)
        return TestClient(web.app)

    return configure


def test_stage4_diagram_extends_the_stage1_row(web_at):
    page = web_at(4, _pod_info()).get("/about").text
    row = [page.index(label) for label in
           ("Adjuster browser", "nginx + web tier", "<b>API pods</b>", "<b>PostgreSQL</b>")]
    assert row == sorted(row), "browser, web tier, API pods, PostgreSQL stay in one row, in order"
    assert "HTTP 8443" in page
    assert "claims-desk-api-7d9f8-x2k4p" in page and "node nkp-md-0-abcde" in page
    assert "10.10.140.11:/documents" in page and "bucket claims" in page
    assert "<b>Files</b>" in page and "<b>Objects</b>" in page
    assert "<b>Document VM</b>" not in page and "Document VM: idle" in page
    assert "<b>Middleware API</b>" not in page
    assert "<b>Chat pods</b>" not in page
    assert 'class="badge b-pod">POD' in page


def test_stage4_marks_an_unmounted_share_down(web_at):
    page = web_at(4, _pod_info(mounted=False)).get("/about").text
    assert re.search(r'class="hop nfs down"', page)


def test_stage5_adds_the_chat_branch_as_not_deployed(web_at):
    page = web_at(5, _pod_info("Stage 5 - Chat and NAI")).get("/about").text
    assert "<b>API pods</b>" in page and "<b>Chat pods</b>" in page and "<b>NAI endpoint</b>" in page
    assert page.count("not deployed") == 2
    assert "<b>Document VM</b>" not in page


def test_https_pod_url_without_a_port_shows_443(web_at):
    page = web_at(4, _pod_info(), api_url="https://claims-api.apps.ntnxlab.local").get("/about").text
    assert "HTTPS 443" in page


# ---------------------------------------------------------------- apply_stage

def _extract(script: str, name: str) -> str:
    one_line = re.search(r"^{}\(\) \{{.*\}}$".format(name), script, re.M)
    if one_line:
        return one_line.group(0) + "\n"
    block = re.search(r"^{}\(\) \{{\n.*?^\}}\n".format(name), script, re.M | re.S)
    assert block, name
    return block.group(0)


def _gnu_sed() -> bool:
    try:
        return "GNU" in subprocess.run(["sed", "--version"], capture_output=True, text=True).stdout
    except OSError:
        return False


@pytest.mark.skipif(not _gnu_sed() or shutil.which("bash") is None,
                    reason="update.sh uses GNU sed -i -E (Rocky Linux, CI)")
def test_apply_stage_switches_3_4_3(tmp_path):
    script = (ROOT / "update.sh").read_text()
    functions = "".join(_extract(script, n) for n in
                        ("info", "warn", "die", "ask", "saved_pod_url", "set_api_upstream", "apply_stage"))
    etc = tmp_path / "etc"
    etc.mkdir()
    (etc / "api.json").write_text(json.dumps({"db_host": "10.38.12.40", "docs_url": "http://10.1.1.8:8090"}))
    (etc / "web.json").write_text(json.dumps({"api_url": "http://127.0.0.1:8000"}))
    nginx_conf = tmp_path / "nginx.conf"
    nginx_conf.write_text((ROOT / "deploy/nginx/nginx.conf.tmpl").read_text()
                          .replace("@API_UPSTREAM@", "127.0.0.1:8000")
                          .replace("@WEB_UPSTREAM@", "127.0.0.1:8080"))
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    calls = tmp_path / "calls"
    for tool in ("systemctl", "nginx"):
        stub = bin_dir / tool
        stub.write_text('#!/bin/sh\necho "{} $*" >> "{}"\n'.format(tool, calls))
        stub.chmod(0o755)
    harness = tmp_path / "harness.sh"
    harness.write_text("set -euo pipefail\n" + functions + 'apply_stage "$1"\n')

    def run(stage, pod_url=""):
        env = dict(os.environ, PATH="{}:{}".format(bin_dir, os.environ["PATH"]),
                   ETC=str(etc), NGINX_CONF=str(nginx_conf), LOCAL_API_URL="http://127.0.0.1:8000",
                   POD_API_URL=pod_url, INTERACTIVE="0")
        done = subprocess.run(["bash", str(harness), str(stage)],
                              env=env, capture_output=True, text=True)
        assert done.returncode == 0, done.stdout + done.stderr
        calls_text = calls.read_text()
        calls.write_text("")
        return (json.loads((etc / "web.json").read_text()), nginx_conf.read_text(), calls_text)

    web, conf, sysd = run(3)
    assert web["api_url"] == "http://127.0.0.1:8000" and web["stage"] == 3
    assert "server 127.0.0.1:8000;" in conf
    assert "enable -q claims-api" in sysd

    web, conf, sysd = run(4, "http://10.10.120.150:8443")
    assert web["api_url"] == web["pod_api_url"] == "http://10.10.120.150:8443"
    assert json.loads((etc / "api.json").read_text())["stage"] == 4
    assert (etc / "stage").read_text().strip() == "4"
    assert "upstream claims_api { server 10.10.120.150:8443;" in conf
    assert "disable -q --now claims-api" in sysd and "reload nginx" in sysd

    web, conf, sysd = run(3)
    assert web["api_url"] == "http://127.0.0.1:8000"
    assert web["pod_api_url"] == "http://10.10.120.150:8443", "the pods stay saved for the next --stage 4"
    assert "upstream claims_api { server 127.0.0.1:8000;" in conf
    assert "enable -q claims-api" in sysd and "restart claims-api claims-web" in sysd
    assert json.loads((etc / "api.json").read_text())["docs_url"] == "http://10.1.1.8:8090"
