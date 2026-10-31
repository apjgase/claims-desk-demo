"""Settings for both services.

Each service reads one JSON file (CLAIMS_CONFIG, written by install.sh).
Environment variables with the same name in upper case and a CLAIMS_ prefix
override the file, e.g. CLAIMS_DB_HOST overrides "db_host".
"""
import json
import os
import socket
from typing import Any, Dict

DEFAULTS: Dict[str, Any] = {
    # middleware API
    "db_host": "127.0.0.1",
    "db_port": 5432,
    "db_name": "claims",
    "db_user": "claims_app",
    "db_password": "",
    "db_sslmode": "prefer",
    "db_schema": "claimsdesk",
    "db_connect_timeout": 5,
    "db_pool_max": 5,
    # web tier
    "api_url": "http://127.0.0.1:8000",
    # Longer than the middleware's worst case for a dead database (a pooled connection
    # failing its check, then a fresh connect timing out), so the page reports the
    # database outage instead of a middleware timeout.
    "api_timeout": 15.0,
    "site_name": "Claims Desk",
    "environment": "Prod",
    # 1 portal, 3 document VM, 4 API pods, 5 chat pods. Empty docs_url keeps stage 1 behaviour.
    "stage": 1,
    "docs_url": "",
    "docs_timeout": 60.0,
    # Document VM only. The portal leaves these empty.
    "nfs_export": "",
    "nfs_mount": "/mnt/claims-docs",
    "s3_endpoint": "",
    "s3_bucket": "claims",
    "s3_access_key": "",
    "s3_secret_key": "",
    "s3_region": "us-east-1",
    "s3_verify_tls": False,
    # Stage 5. The web tier only needs chat_url (shown on /about; the browser goes
    # through nginx /chat/). The chat pods read the rest; they hold no database or S3 settings.
    "chat_url": "",
    "chat_api_url": "http://127.0.0.1:8000",
    "llm_base_url": "",
    "llm_api_key": "",
    "llm_model": "gpt-oss-120b",
    "llm_vision_model": "gemma-4-26b-a4b",
    "llm_guard_model": "",  # empty = llm_vision_model
    "chat_guard": True,
    "llm_verify_tls": True,
    "llm_timeout": 120.0,
    "llm_max_tokens": 1500,
}

_INT = {"db_port", "db_connect_timeout", "db_pool_max", "stage", "llm_max_tokens"}
_FLOAT = {"api_timeout", "docs_timeout", "llm_timeout"}
_BOOL = {"s3_verify_tls", "llm_verify_tls", "chat_guard"}


def _as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def stage_number(cfg: Dict[str, Any]) -> int:
    raw = cfg.get("stage")
    if raw is None or raw == "":
        return 1
    try:
        return int(raw)
    except (TypeError, ValueError):
        return 0


def documents_active(cfg: Dict[str, Any]) -> bool:
    """Stage 3 and above call the document tier. The saved URL stays either way."""
    return stage_number(cfg) >= 3 and bool(str(cfg.get("docs_url") or "").strip())


def stage_label(cfg: Dict[str, Any]) -> str:
    labels = {
        1: "Stage 1 - Portal VM",
        2: "Stage 2 - PostgreSQL HA",
        3: "Stage 3 - Document VM",
        4: "Stage 4 - API pods",
        5: "Stage 5 - Chat and NAI",
    }
    number = stage_number(cfg)
    return labels.get(number, "Stage {}".format(cfg.get("stage")))


def load() -> Dict[str, Any]:
    cfg = dict(DEFAULTS)
    path = os.environ.get("CLAIMS_CONFIG")
    if path and os.path.exists(path):
        with open(path) as fh:
            cfg.update(json.load(fh))
    for key in DEFAULTS:
        val = os.environ.get("CLAIMS_" + key.upper())
        if val is not None:
            cfg[key] = val
    for key in _INT:
        cfg[key] = int(cfg[key])
    for key in _FLOAT:
        cfg[key] = float(cfg[key])
    for key in _BOOL:
        cfg[key] = _as_bool(cfg[key])
    return cfg


def host_identity() -> Dict[str, str]:
    """Hostname and primary IPv4 of the machine (VM or pod) running this code."""
    name = socket.gethostname()
    addr = "unknown"
    try:
        # No packet is sent; this only asks the kernel which source address it would use.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.0.2.1", 9))
            addr = s.getsockname()[0]
    except OSError:
        try:
            addr = socket.gethostbyname(name)
        except OSError:
            pass
    return {"hostname": name, "ip": addr}


def runtime() -> Dict[str, str]:
    """VM or Kubernetes pod. The Helm chart passes the pod details through the downward API."""
    if not (os.environ.get("POD_NAMESPACE") or os.environ.get("KUBERNETES_SERVICE_HOST")):
        return {"kind": "vm"}
    return {
        "kind": "pod",
        "namespace": os.environ.get("POD_NAMESPACE", ""),
        "node": os.environ.get("NODE_NAME", ""),
        "node_ip": os.environ.get("NODE_IP", ""),
        "pod_ip": os.environ.get("POD_IP", ""),
    }
