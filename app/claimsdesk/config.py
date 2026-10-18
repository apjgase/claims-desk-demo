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
}

_INT = {"db_port", "db_connect_timeout", "db_pool_max"}
_FLOAT = {"api_timeout"}


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
