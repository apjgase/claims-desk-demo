# Stage 1: design and demo run sheet

## Components

| Tier | Process | Listens | Talks to | Code |
| :--- | :--- | :--- | :--- | :--- |
| Edge | nginx | 0.0.0.0:443 TLS, :80 redirect | web tier for `/`, middleware for `/api/` | `deploy/nginx/nginx.conf.tmpl` |
| Web | `claims-web` (uvicorn, FastAPI, Jinja2) | 127.0.0.1:8080 | middleware over HTTP (`api_url`) | `app/claimsdesk/web.py`, `templates/` |
| Middleware | `claims-api` (uvicorn, FastAPI) | 127.0.0.1:8000 | PostgreSQL through a connection pool | `app/claimsdesk/api.py`, `db.py` |
| Data | PostgreSQL (NDB) | 5432, or 5000 through HAProxy | — | `app/claimsdesk/schema.sql` |

Both services run as the unprivileged user `claimsdesk` under systemd (`ProtectSystem=strict`, `NoNewPrivileges`). They read one JSON file each: `/etc/claims-desk/api.json` and `/etc/claims-desk/web.json`. Environment variables `CLAIMS_<KEY>` override any key.

Choices that matter for later stages:

- **The web tier has no database credentials.** `web.json` holds only the middleware URL. Stage 4 changes `api_url` to the API pods' address. The Flow policy can then drop portal to database (deck slide 7) without breaking the portal.
- **The middleware's pool revalidates connections** (`check_connection`). After an NDB HA failover, a Flow change, or a restart, the next request reconnects. In between, the page says *Database unavailable* instead of hanging.
- **Every row records `created_by_host`**: the VM or pod that wrote it. When pods take over in stage 4, new claims show pod names.
- **`/api/v1/info` reports `inet_server_addr()` and `pg_is_in_recovery()`**: which PostgreSQL node answered and whether it is the primary. The footer of every page shows it.
- **The architecture page extends the stage 1 row.** Browser, nginx and the web tier, middleware, and PostgreSQL stay in that order. Stage 3 hangs the document VM off the middleware, and Files and Objects off the document VM. Stage 4 turns the middleware box into the API pods and hangs Files and Objects off them. Stage 5 adds chat and NAI as another branch. Do not replace the row.

## Data model

One table, `claimsdesk.claims`:

| Column | Type | Notes |
| :--- | :--- | :--- |
| `id` | bigint identity | Primary key |
| `claim_number` | text, set by an insert trigger from `id` | `CLM-000001` …, unique |
| `policy_number` | text | Required |
| `claimant_name` | text | Required |
| `contact_email` | text | Optional |
| `loss_date` | date | Required |
| `loss_type` | text | `Auto`, `Property`, `Travel`, `Health`, `Other` (check constraint) |
| `amount` | numeric(12,2) | ≥ 0 |
| `description` | text | Required |
| `status` | text | `SUBMITTED` → `IN_REVIEW` → `APPROVED` / `REJECTED` → `PAID` (check constraint) |
| `adjuster` | text | Optional |
| `photo_path` | text | NULL in stage 1; Nutanix Files path from stage 3 |
| `packet_url` | text | NULL in stage 1; Objects WORM object from stage 3 |
| `created_by_host` | text | Host that inserted the row |
| `created_at`, `updated_at` | timestamptz | |

Indexes: `status`, `created_at DESC`. The stage 3 columns exist now, so stage 3 needs no schema change.

Privileges: the application role owns schema `claimsdesk` and the table. It needs nothing else: no superuser, no `CREATEDB`. The admin account is used only by `install.sh` to create the role and database, and it is not stored.

## Middleware API

Published through nginx at `https://<portal>/api/`. OpenAPI UI at `/api/docs`.

| Method | Path | Body / query | Returns |
| :--- | :--- | :--- | :--- |
| GET | `/api/v1/health` | — | `200 {"status":"ok","db":"ok"}`, `503` if the database is unreachable |
| GET | `/api/v1/info` | — | API host and IP, database endpoint, server version, `server_addr`, `in_recovery` |
| GET | `/api/v1/stats` | — | Count and sum of amounts per status |
| GET | `/api/v1/claims` | `status`, `q` (claim, policy, or name), `limit` (≤ 500) | Newest first |
| POST | `/api/v1/claims` | JSON claim | `201` with the stored claim, `422` with field errors |
| GET | `/api/v1/claims/{claim_number}` | — | Claim, or `404` |
| PATCH | `/api/v1/claims/{claim_number}` | `{"status": "APPROVED"}` | Updated claim |

Every database failure returns `503 {"detail":"database unavailable","db_endpoint":…,"error":…}`.

```bash
P=https://<portal>
curl -k $P/api/v1/claims?status=SUBMITTED
curl -k -X POST $P/api/v1/claims -H 'content-type: application/json' \
  -d '{"policy_number":"POL-48213","claimant_name":"Ava Chen","loss_date":"2026-10-12",
       "loss_type":"Auto","amount":"1840.00","description":"Rear-ended at a light"}'
curl -k -X PATCH $P/api/v1/claims/CLM-000013 -H 'content-type: application/json' -d '{"status":"IN_REVIEW"}'
```

## Web pages

| Path | Page |
| :--- | :--- |
| `/` | Status tiles (count and value), search and filter, claims table with *Written by* |
| `/claims/new` | Submit form; field errors come back from the middleware's validation |
| `/claims/{number}` | Detail and status buttons |
| `/about` | The request path, read live: web host, middleware host, database endpoint and the node that answered |
| `/healthz` | JSON end-to-end check (web → middleware → database) for monitoring |

## Demo run sheet (deck slides 4–5)

Before the session: `sudo claims-desk reset` and `sudo claims-desk seed 12` give a clean, numbered set.

1. **The request path.** Open `/about`. Walk left to right: browser, nginx and the web tier on the portal VM, the middleware, PostgreSQL. Point at *served by … primary*.
2. **Submit a claim.** *New claim*, fill it in, submit. The banner says it was committed. *Written by* shows the portal VM.
3. **Prove it is in the database.** On the database VM (or with NDB's connection details):
   `psql -U claims_app -d claims -c "SELECT claim_number, claimant_name, status, created_by_host FROM claimsdesk.claims ORDER BY id DESC LIMIT 3;"`
4. **The API is the only database client.** `curl -k https://<portal>/api/v1/info`. The web tier's config (`/etc/claims-desk/web.json`) has no database settings.
5. **Microsegmentation, optional.** In Flow, remove the `AppTier: Web` → database rule (or add a drop). Reload: the page shows *Database unavailable at host:port*, and the footer turns coral. Restore the rule: the next reload works with no restart.
6. **Slide 5 (PostgreSQL HA).** `sudo ./install.sh --reconfigure`, point at the HAProxy address and port 5000. Fail over the Patroni primary in NDB. The footer's *DB* address changes to the new primary. Claims keep coming.
7. **Slide 4 DR (portal VM to NC2).** After a Nutanix DR test failover of the portal VM, the footer's *WEB* address shows where the VM now runs. Do not fail over in front of the customer (deck LIMITS).

## Not in stage 1

- Authentication. The portal is open to anyone who can reach it: demo only, keep it inside the VPC.
- Photo upload and the accepted packet. Those are stage 3: `sudo ./update.sh --stage 3` (see the README).
- Multiple portal VMs behind a load balancer. One VM, protected by Nutanix DR.
