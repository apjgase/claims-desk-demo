"""Database and configuration tasks used by install.sh and the claims-desk command.

Secrets come from the environment, never from argv (argv is visible in ps):
  CLAIMS_DB_HOST, CLAIMS_DB_PORT, CLAIMS_DB_NAME, CLAIMS_DB_USER, CLAIMS_DB_PASSWORD,
  CLAIMS_DB_SSLMODE, CLAIMS_DB_ADMIN_USER, CLAIMS_DB_ADMIN_PASSWORD, CLAIMS_DB_ADMIN_DB

  python -m claimsdesk.admin check-port     TCP reachability of the database endpoint
  python -m claimsdesk.admin bootstrap      as the admin user: app role, database, grants
  python -m claimsdesk.admin migrate        as the app user: schema and the claims table
  python -m claimsdesk.admin check          as the app user: connect and print server info
  python -m claimsdesk.admin seed [N] [--if-empty]
  python -m claimsdesk.admin reset          delete every claim and restart numbering
  python -m claimsdesk.admin info           server info and claim counts as JSON
  python -m claimsdesk.admin write-config --api FILE --web FILE
"""
import argparse
import json
import os
import random
import socket
import sys
from datetime import date, timedelta
from decimal import Decimal
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg.rows import dict_row

from . import config, db

HERE = Path(__file__).parent


def _cfg():
    return config.load()


def _fail(msg: str, code: int = 1):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(code)


def _first_line(exc: Exception) -> str:
    text = str(exc).strip()
    return text.splitlines()[0] if text else type(exc).__name__


def check_port(cfg) -> None:
    host, port = cfg["db_host"], cfg["db_port"]
    try:
        with socket.create_connection((host, port), timeout=cfg["db_connect_timeout"]):
            pass
    except OSError as exc:
        _fail("cannot reach PostgreSQL at {}:{} ({}). Check the address, the port "
              "(5432 single instance, 5000 HAProxy for NDB PostgreSQL HA), Flow policies, "
              "and firewalls between this VM and the database.".format(host, port, exc))
    print("ok: {}:{} is reachable".format(host, port))


def _admin_conn(cfg, dbname=None):
    user = os.environ.get("CLAIMS_DB_ADMIN_USER", "")
    if not user:
        _fail("CLAIMS_DB_ADMIN_USER is not set")
    info = db.conninfo(cfg, app_name="claims-desk-install", user=user,
                       password=os.environ.get("CLAIMS_DB_ADMIN_PASSWORD", ""),
                       dbname=dbname or os.environ.get("CLAIMS_DB_ADMIN_DB") or "postgres",
                       options=None)
    try:
        return psycopg.connect(info, autocommit=True)
    except psycopg.OperationalError as exc:
        _fail("admin login as {} failed: {}. If the message mentions pg_hba.conf, allow "
              "this VM's address in pg_hba.conf on the database server.".format(user, _first_line(exc)))


def bootstrap(cfg) -> None:
    app_user, app_pw, dbname = cfg["db_user"], cfg["db_password"], cfg["db_name"]
    if not app_pw:
        _fail("CLAIMS_DB_PASSWORD (the application password) is not set")
    with _admin_conn(cfg) as conn:
        me = conn.execute("SELECT current_user, rolsuper, rolcreaterole, rolcreatedb "
                          "FROM pg_roles WHERE rolname = current_user").fetchone()
        print("admin: {} (superuser={}, createrole={}, createdb={})".format(*me))
        exists = conn.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", [app_user]).fetchone()
        verb = "ALTER ROLE {} WITH LOGIN PASSWORD {}" if exists else "CREATE ROLE {} LOGIN PASSWORD {}"
        conn.execute(sql.SQL(verb).format(sql.Identifier(app_user), sql.Literal(app_pw)))
        print("role {}: {}".format(app_user, "password updated" if exists else "created"))

        if conn.execute("SELECT 1 FROM pg_database WHERE datname = %s", [dbname]).fetchone():
            print("database {}: exists, granting access".format(dbname))
        else:
            if not me[0] == app_user and not me[1]:
                # A non-superuser can only hand ownership to a role it is a member of.
                conn.execute(sql.SQL("GRANT {} TO current_user").format(sql.Identifier(app_user)))
            conn.execute(sql.SQL("CREATE DATABASE {} OWNER {}").format(
                sql.Identifier(dbname), sql.Identifier(app_user)))
            print("database {}: created, owner {}".format(dbname, app_user))
        conn.execute(sql.SQL("GRANT CONNECT, CREATE, TEMPORARY ON DATABASE {} TO {}").format(
            sql.Identifier(dbname), sql.Identifier(app_user)))

    with _admin_conn(cfg, dbname=dbname) as conn:
        owner = conn.execute("SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = %s",
                             [cfg["db_schema"]]).fetchone()
        if owner and owner[0] != app_user:
            try:
                conn.execute(sql.SQL("ALTER SCHEMA {} OWNER TO {}").format(
                    sql.Identifier(cfg["db_schema"]), sql.Identifier(app_user)))
                print("schema {}: ownership moved to {}".format(cfg["db_schema"], app_user))
            except psycopg.Error as exc:
                print("WARNING: schema {} is owned by {} and could not be reassigned: {}".format(
                    cfg["db_schema"], owner[0], _first_line(exc)))


def _app_conn(cfg, **kw):
    try:
        return psycopg.connect(db.conninfo(cfg, app_name="claims-desk-admin", **kw), autocommit=True)
    except psycopg.OperationalError as exc:
        _fail("login as {} to database {} on {}:{} failed: {}".format(
            cfg["db_user"], cfg["db_name"], cfg["db_host"], cfg["db_port"], _first_line(exc)))


def migrate(cfg) -> None:
    schema = cfg["db_schema"]
    with _app_conn(cfg, options=None) as conn:
        try:
            conn.execute(sql.SQL("CREATE SCHEMA IF NOT EXISTS {}").format(sql.Identifier(schema)))
            conn.execute(sql.SQL("SET search_path TO {}").format(sql.Identifier(schema)))
            conn.execute((HERE / "schema.sql").read_text())
        except psycopg.Error as exc:
            _fail("schema setup failed as {}: {}. The app user needs CREATE on database {} "
                  "(run bootstrap with an admin user).".format(cfg["db_user"], _first_line(exc),
                                                                cfg["db_name"]))
        n = conn.execute("SELECT count(*) FROM claims").fetchone()[0]
    print("schema {}: table claims ready ({} rows)".format(schema, n))


def check(cfg) -> None:
    with _app_conn(cfg) as conn:
        conn.row_factory = dict_row
        info = db.server_info(conn)
        n = conn.execute("SELECT count(*) AS n FROM claims").fetchone()["n"]
    print("ok: {}@{}:{}/{} served by {} ({}), {} claims".format(
        cfg["db_user"], cfg["db_host"], cfg["db_port"], info["database"],
        info["server_addr"] or "local socket",
        "replica" if info["in_recovery"] else "primary", n))
    print("    " + info["version"].split(" on ")[0])


FIRST = ["Olivia", "Liam", "Noah", "Ava", "Mia", "Lucas", "Isla", "Leo", "Grace", "Jack",
         "Chloe", "Henry", "Zoe", "Oscar", "Ruby", "Arjun", "Mei", "Sofia", "Kenji", "Amara"]
LAST = ["Nguyen", "Smith", "Patel", "Wilson", "Chen", "Brown", "Taylor", "Kumar", "Martin",
        "Lee", "Walker", "Singh", "Harris", "Kim", "Clarke", "Rossi", "Tanaka", "Okafor"]
STORIES = {
    "Auto": ["Rear-ended at a traffic light, bumper and tail lights damaged.",
             "Windscreen cracked by a stone on the highway.",
             "Side mirror and door scraped in a car park."],
    "Property": ["Burst pipe in the kitchen, water damage to floor and cabinets.",
                 "Hail damaged roof tiles and a skylight.",
                 "Storm brought down a tree onto the back fence."],
    "Travel": ["Checked luggage lost on a connecting flight.",
               "Trip cancelled after a hospital admission.",
               "Camera stolen from a hotel room."],
    "Health": ["Emergency dental treatment while interstate.",
               "Physiotherapy after a sports injury."],
    "Other": ["Laptop dropped and screen broken.", "Bicycle stolen from a locked shed."],
}
ADJUSTERS = ["A. Rahman", "J. Doyle", "S. Ito", "M. Fernandes", None]


def seed(cfg, count: int, if_empty: bool) -> None:
    rnd = random.Random(42)
    host = socket.gethostname() + " (seed)"
    with _app_conn(cfg) as conn:
        if if_empty and conn.execute("SELECT count(*) FROM claims").fetchone()[0]:
            print("seed: table not empty, skipped")
            return
        with conn.transaction():
            for _ in range(count):
                loss_type = rnd.choice(list(STORIES))
                first, last = rnd.choice(FIRST), rnd.choice(LAST)
                row = {
                    "policy_number": "POL-{:05d}".format(rnd.randint(10000, 99999)),
                    "claimant_name": "{} {}".format(first, last),
                    "contact_email": "{}.{}@example.com".format(first, last).lower(),
                    "loss_date": date.today() - timedelta(days=rnd.randint(1, 60)),
                    "loss_type": loss_type,
                    "amount": Decimal(rnd.randint(150, 25000)) + Decimal("0.00"),
                    "description": rnd.choice(STORIES[loss_type]),
                    "adjuster": rnd.choice(ADJUSTERS),
                }
                new = db.insert_claim(conn, row, host)
                status = rnd.choice(db.STATUSES)
                if status != "SUBMITTED":
                    db.set_status(conn, new[0], status)
    print("seed: inserted {} claims".format(count))


def reset(cfg) -> None:
    with _app_conn(cfg) as conn:
        conn.execute("TRUNCATE claims RESTART IDENTITY")
    print("reset: all claims deleted, numbering restarts at CLM-000001")


def info(cfg) -> None:
    with _app_conn(cfg) as conn:
        conn.row_factory = dict_row
        out = {"db_endpoint": "{}:{}".format(cfg["db_host"], cfg["db_port"]),
               "server": db.server_info(conn), "claims": db.stats(conn)}
    print(json.dumps(out, indent=2, default=str))


def write_config(cfg, api_path: str, web_path: str) -> None:
    api_keys = ["db_host", "db_port", "db_name", "db_user", "db_password", "db_sslmode",
                "db_schema", "db_connect_timeout", "db_pool_max", "stage", "docs_url",
                "docs_timeout"]
    web_keys = ["api_url", "api_timeout", "site_name", "environment", "stage"]
    for path, keys in ((api_path, api_keys), (web_path, web_keys)):
        data = {k: cfg[k] for k in keys}
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.chmod(path, 0o640)
        print("wrote " + path)


def main(argv=None) -> None:
    p = argparse.ArgumentParser(prog="claimsdesk.admin")
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("check-port", "bootstrap", "migrate", "check", "reset", "info"):
        sub.add_parser(name)
    s = sub.add_parser("seed")
    s.add_argument("count", nargs="?", type=int, default=12)
    s.add_argument("--if-empty", action="store_true")
    w = sub.add_parser("write-config")
    w.add_argument("--api", required=True)
    w.add_argument("--web", required=True)
    args = p.parse_args(argv)

    cfg = _cfg()
    try:
        if args.cmd == "check-port":
            check_port(cfg)
        elif args.cmd == "bootstrap":
            bootstrap(cfg)
        elif args.cmd == "migrate":
            migrate(cfg)
        elif args.cmd == "check":
            check(cfg)
        elif args.cmd == "seed":
            seed(cfg, args.count, args.if_empty)
        elif args.cmd == "reset":
            reset(cfg)
        elif args.cmd == "info":
            info(cfg)
        elif args.cmd == "write-config":
            write_config(cfg, args.api, args.web)
    except psycopg.Error as exc:
        _fail(_first_line(exc))


if __name__ == "__main__":
    main()
