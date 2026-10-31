"""PostgreSQL access for the middleware API."""
from typing import Any, Dict, Optional

import psycopg
from psycopg import sql
from psycopg.conninfo import make_conninfo
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

STATUSES = ["SUBMITTED", "IN_REVIEW", "APPROVED", "REJECTED", "PAID"]
LOSS_TYPES = ["Auto", "Property", "Travel", "Health", "Other"]

CLAIM_COLUMNS = (
    "claim_number, policy_number, claimant_name, contact_email, loss_date, loss_type, "
    "amount, description, status, adjuster, photo_path, packet_url, created_by_host, "
    "created_at, updated_at"
)


def conninfo(cfg: Dict[str, Any], app_name: str = "claims-api", **override: Any) -> str:
    params = {
        "host": cfg["db_host"],
        "port": cfg["db_port"],
        "dbname": cfg["db_name"],
        "user": cfg["db_user"],
        "password": cfg["db_password"],
        "sslmode": cfg["db_sslmode"],
        "connect_timeout": cfg["db_connect_timeout"],
        "application_name": app_name,
        "options": "-c search_path={}".format(cfg["db_schema"]),
        # A Flow drop discards packets silently; without these an open connection
        # would hang for minutes instead of failing in seconds.
        "keepalives": 1,
        "keepalives_idle": 10,
        "keepalives_interval": 3,
        "keepalives_count": 3,
        "tcp_user_timeout": 3000,
    }
    params.update(override)
    return make_conninfo(**{k: v for k, v in params.items() if v not in (None, "")})


def make_pool(cfg: Dict[str, Any]) -> ConnectionPool:
    # check= revalidates a pooled connection before use, so the API recovers on its own
    # after a database failover or restart.
    return ConnectionPool(
        conninfo(cfg),
        min_size=1,
        max_size=cfg["db_pool_max"],
        open=False,
        timeout=cfg["db_connect_timeout"],
        kwargs={"row_factory": dict_row, "autocommit": True},
        check=ConnectionPool.check_connection,
        name="claims",
    )


def server_info(conn: psycopg.Connection) -> Dict[str, Any]:
    row = conn.execute(
        "SELECT version() AS version, current_database() AS database, "
        "current_user AS db_user, host(inet_server_addr()) AS server_addr, "
        "inet_server_port() AS server_port, pg_is_in_recovery() AS in_recovery, "
        "now() AS server_time"
    ).fetchone()
    return dict(row)


def list_claims(conn, status: Optional[str], q: Optional[str], limit: int,
                loss_type: Optional[str] = None, text: Optional[str] = None,
                loss_from=None, loss_to=None, amount_min=None, amount_max=None):
    where, args = [], []
    if status:
        where.append("status = %s")
        args.append(status)
    if q:
        where.append("(claim_number ILIKE %s OR policy_number ILIKE %s OR claimant_name ILIKE %s)")
        args += ["%" + q + "%"] * 3
    if text:
        where.append("description ILIKE %s")
        args.append("%" + text + "%")
    for clause, value in (("loss_type = %s", loss_type), ("loss_date >= %s", loss_from),
                          ("loss_date <= %s", loss_to), ("amount >= %s", amount_min),
                          ("amount <= %s", amount_max)):
        if value is not None:
            where.append(clause)
            args.append(value)
    query = "SELECT {} FROM claims {} ORDER BY id DESC LIMIT %s".format(
        CLAIM_COLUMNS, ("WHERE " + " AND ".join(where)) if where else ""
    )
    return conn.execute(query, args + [limit]).fetchall()


def get_claim(conn, claim_number: str):
    return conn.execute(
        "SELECT {} FROM claims WHERE claim_number = %s".format(CLAIM_COLUMNS), [claim_number]
    ).fetchone()


def insert_claim(conn, data: Dict[str, Any], host: str):
    cols = ["policy_number", "claimant_name", "contact_email", "loss_date", "loss_type",
            "amount", "description", "adjuster"]
    query = sql.SQL("INSERT INTO claims ({}, created_by_host) VALUES ({}, %s) RETURNING {}").format(
        sql.SQL(", ").join(map(sql.Identifier, cols)),
        sql.SQL(", ").join(sql.Placeholder() * len(cols)),
        sql.SQL(CLAIM_COLUMNS),
    )
    return conn.execute(query, [data.get(c) for c in cols] + [host]).fetchone()


def set_status(conn, claim_number: str, status: str, packet_url: Optional[str] = None):
    if packet_url is None:
        return conn.execute(
            "UPDATE claims SET status = %s, updated_at = now() WHERE claim_number = %s "
            "RETURNING {}".format(CLAIM_COLUMNS),
            [status, claim_number],
        ).fetchone()
    return conn.execute(
        "UPDATE claims SET status = %s, packet_url = %s, updated_at = now() "
        "WHERE claim_number = %s RETURNING {}".format(CLAIM_COLUMNS),
        [status, packet_url, claim_number],
    ).fetchone()


def set_photo_path(conn, claim_number: str, photo_path: str):
    return conn.execute(
        "UPDATE claims SET photo_path = %s, updated_at = now() WHERE claim_number = %s "
        "RETURNING {}".format(CLAIM_COLUMNS),
        [photo_path, claim_number],
    ).fetchone()


def stats(conn) -> Dict[str, Any]:
    rows = conn.execute(
        "SELECT status, count(*) AS n, coalesce(sum(amount), 0) AS amount "
        "FROM claims GROUP BY status"
    ).fetchall()
    by_status = {s: {"count": 0, "amount": 0} for s in STATUSES}
    for r in rows:
        by_status[r["status"]] = {"count": r["n"], "amount": r["amount"]}
    total = sum(v["count"] for v in by_status.values())
    by_type = {t: {"count": 0, "amount": 0} for t in LOSS_TYPES}
    for r in conn.execute("SELECT loss_type, count(*) AS n, coalesce(sum(amount), 0) AS amount "
                          "FROM claims GROUP BY loss_type").fetchall():
        by_type[r["loss_type"]] = {"count": r["n"], "amount": r["amount"]}
    by_month = conn.execute(
        "SELECT to_char(date_trunc('month', created_at), 'YYYY-MM') AS month, count(*) AS count, "
        "coalesce(sum(amount), 0) AS amount FROM claims "
        "GROUP BY 1 ORDER BY 1 DESC LIMIT 12").fetchall()
    return {"total": total, "by_status": by_status, "by_loss_type": by_type, "by_month": by_month}


def all_claims(conn, limit: int = 5000):
    """Every claim, newest first, for the fraud rules that compare claims with each other."""
    return conn.execute("SELECT {} FROM claims ORDER BY id DESC LIMIT %s".format(CLAIM_COLUMNS),
                        [limit]).fetchall()
