# Claims Desk demo

The working application behind the Claims Desk architecture deck. An adjuster submits a claim to a portal, and the claim lands in PostgreSQL. Each stage of the deck adds one piece to the same application. This repository holds the software and the scripts that install it. You provision the infrastructure (VMs, NDB, Flow, NC2); `install.sh` turns a plain Rocky Linux 9 VM into the portal.

| Stage | Deck slide | What runs | Status |
| :--- | :--- | :--- | :--- |
| **1** | **4–5** | **Portal VM: nginx, web tier, middleware API. PostgreSQL provisioned by you (NDB).** | **This release** |
| 2 | 5 | Same app on NDB PostgreSQL HA: point it at HAProxy port 5000 | Configuration only |
| 3 | 6 | Document VM writes the photo to Nutanix Files and the packet to Objects WORM | Planned |
| 4 | 7 | API pods on NKP (Flow CNI) take the middleware role; portal to database becomes a Flow drop | Planned |
| 5 | 8 | Chat pods and a NAI endpoint on the same NKP cluster | Planned |
| 6 | 10 | UAT copy by NCM Self-Service from a masked NDB clone | Planned |

Design, API, data model and a demo run sheet: [`docs/STAGE1.md`](docs/STAGE1.md).
Everything else the lab needs for the full demo (DNS, NTP, certificates, IP plan, registries, NKP, NAI, NC2): [`docs/LAB.md`](docs/LAB.md).

## Stage 1 at a glance

```
 Adjuster ──HTTPS 443──▶ ┌──────────────── Portal VM (Rocky Linux 9) ─────────────────┐
                         │ nginx :443 ──▶ claims-web :8080 ──▶ claims-api :8000        │──TCP 5432──▶ PostgreSQL
                         │ (TLS)          (HTML pages)          (REST, only DB client) │  (5000 HA)   (NDB)
                         └─────────────────────────────────────────────────────────────┘
```

The web tier never connects to the database; only the middleware does. That is what lets stage 4 move the middleware into pods by changing one URL.

## What you need to provision

### Portal VM

| Item | Requirement |
| :--- | :--- |
| OS | Rocky Linux 9 or RHEL 9, x86_64, minimal install is fine |
| Size | 2 vCPU, 4 GB RAM, 20 GB disk |
| Network | VPC `claims-prod` overlay subnet (deck: 172.16.10.0/24, No-NAT) or any routed subnet |
| Categories (deck) | `AppType: Claims`, `AppTier: Web`, `Environment: Prod` |
| Access | SSH with a sudo user |
| Packages | BaseOS and AppStream repositories reachable (internet or a local mirror). The script installs `nginx`, `python3.11`, `python3.11-pip`, `openssl`, `tar`, `curl` |
| Python packages | From PyPI, **or** none if you use the offline bundle (recommended in a No-NAT VPC) |

### PostgreSQL

| Item | Requirement |
| :--- | :--- |
| Engine | PostgreSQL 12 or later (the table uses a generated column). CI tests against 16 |
| Provisioning | NDB single instance for stage 1. For NDB PostgreSQL HA, use the HAProxy address and port 5000 |
| Credentials | **Either** an admin account (NDB: user `postgres` and the database password set at provisioning), so the installer creates the role and database, **or** an existing database and role that has `CREATE` on that database |
| Access | `pg_hba.conf` must allow the portal VM's address with password authentication (`scram-sha-256` or `md5`) |

The installer creates database `claims`, role `claims_app`, and schema `claimsdesk` owned by that role, with one table `claims`. All names can be changed. If NDB already created a database, give its name and the installer adds the schema to it.

### Network flows

| From | To | Port | Why |
| :--- | :--- | :--- | :--- |
| Adjusters, demo laptop | Portal VM | TCP 443 (80 redirects to 443) | Portal and API |
| Admin workstation | Portal VM | TCP 22 | Install |
| Portal VM | PostgreSQL | TCP 5432 (5000 for HAProxy) | Middleware to database |
| Portal VM | dnf repositories, PyPI | TCP 443 | Install only. PyPI not needed with the offline bundle |

In a Flow policy for `AppTier: Web`, the outbound rule to the database is the only one this app needs.

## Install

### 0. Prepare the VM with cloud-init (optional)

[`deploy/cloud-init/portal-vm.yaml`](deploy/cloud-init/portal-vm.yaml) prepares a Rocky Linux 9 cloud image (GenericCloud qcow2) at first boot:

- sets the host name and time zone, and installs the lab SSH key for `rocky` and `root`
- sets the root password (lab default, stored as a SHA-512 hash) and allows SSH password logins, root included
- runs `dnf upgrade` and installs nginx, python3.11, python3.11-pip, openssl and tar, plus psql, nc, dig, jq, chrony, git, rsync and vim
- disables SELinux (now, in `/etc/selinux/config`, and with the `selinux=0` kernel argument)
- stops and masks firewalld
- reboots once

In Prism Central: **Create VM → Guest Customization → Cloud-init (Linux) → Custom Script**, and paste the file after editing the lines marked `EDIT` (host name, FQDN). The lab SSH key is already in it. The VM needs dnf repository access during first boot. It is ready when `/var/lib/claims-desk/vm-ready` exists; first-boot output is in `/var/log/cloud-init-output.log`. With the packages already present, `install.sh` skips dnf, reports SELinux and firewalld as disabled, and needs no repository access.

Optionally, set `BUNDLE_URL` in the file to an internal address that serves the offline bundle; the VM then extracts it to `/opt/claims-desk-bundle`. The GitHub release needs a token, so for GitHub copy the bundle with `scp` (step 1).

### Lab SSH key

One key pair for every lab machine. The public key is [`deploy/ssh/claims-desk-lab.pub`](deploy/ssh/claims-desk-lab.pub). The private key is `~/.ssh/claims-desk-lab` on the admin laptop and is never committed.

| Where | How |
| :--- | :--- |
| Portal VM | Already in `deploy/cloud-init/portal-vm.yaml`; log in as `rocky` |
| NDB database server VMs | Paste the public key into the SSH public key field when provisioning the database server |
| NKP clusters (later stages) | `--ssh-public-key-file deploy/ssh/claims-desk-lab.pub` |
| Any other VM | Prism guest customization, or `ssh-copy-id -i ~/.ssh/claims-desk-lab.pub user@host` |

On another admin machine, copy the private key to `~/.ssh/claims-desk-lab` (mode 600).

### 1. Get the bundle onto the VM

The repository is private, so download from a machine that can sign in to GitHub, then copy to the VM.

**Offline bundle (recommended).** Includes the Python wheels for Rocky 9, so the VM needs only its dnf repositories:

```bash
# on your laptop
gh release download v0.1.0 -R apjgase/claims-desk-demo -p 'claims-desk-demo-*.tar.gz*'
shasum -a 256 -c claims-desk-demo-0.1.0.tar.gz.sha256
scp claims-desk-demo-0.1.0.tar.gz rocky@<portal-vm>:

# on the VM
tar -xzf claims-desk-demo-0.1.0.tar.gz && cd claims-desk-demo-0.1.0
```

Or in a browser: GitHub, **Releases**, download `claims-desk-demo-0.1.0.tar.gz`.

**Source download.** GitHub, **Code → Download ZIP**, or `gh repo clone apjgase/claims-desk-demo`. The VM then installs Python packages from PyPI (set `PIP_INDEX_URL` for a mirror).

### 2. Run the installer

```bash
sudo ./install.sh
```

It asks:

| Prompt | Default | Notes |
| :--- | :--- | :--- |
| PostgreSQL host or IP | — | NDB database server VM, or the HAProxy address for HA |
| Port | `5432` | `5000` for NDB PostgreSQL HA through HAProxy |
| Application database | `claims` | Created if missing |
| Application role | `claims_app` | Created if missing; the password is updated if it exists |
| Create the role and database with an admin account? | yes | Then: admin user (`postgres`), admin password, maintenance database (`postgres`) |
| Password for the application role | generated | Stored only in `/etc/claims-desk/api.json` (0640) |
| TLS to PostgreSQL | `prefer` | `require` or `verify-full` if your NDB instance has TLS |
| TLS server name | VM's FQDN | Used for the self-signed certificate |

The admin password is used once and is not stored. The run is logged to `/var/log/claims-desk-install.log`. Passwords are not written there.

**Unattended:** `cp claims-desk.conf.example claims-desk.conf`, fill it in, `sudo ./install.sh --config claims-desk.conf -y`, then delete the file.

Options: `--seed N` (sample claims for an empty table, default 12, 0 for none), `--reconfigure` (ask for the database settings again), `-y` (no confirmation).

### 3. Verify

The installer finishes with an end-to-end check through nginx. Then, from your laptop:

```bash
curl -k https://<portal-vm>/healthz                 # {"web":"ok",...,"backend":"ok"}
curl -k https://<portal-vm>/api/v1/info              # which host served it, which DB node answered
```

Open `https://<portal-vm>/` in a browser (accept the self-signed certificate).

## Operating it

```bash
sudo claims-desk status     # services and end-to-end health
sudo claims-desk check      # log in to PostgreSQL as the app user; primary or replica
sudo claims-desk info       # server details and claim counts (JSON)
sudo claims-desk seed 20    # add sample claims
sudo claims-desk reset      # delete every claim (asks first)
sudo claims-desk logs 200   # nginx, claims-web, claims-api
```

| On the VM | What |
| :--- | :--- |
| `/opt/claims-desk/app`, `/opt/claims-desk/venv` | Code and Python environment |
| `/etc/claims-desk/api.json` | Database settings, including the app password (root:claimsdesk 0640) |
| `/etc/claims-desk/web.json` | Web tier settings: middleware URL, site name, environment |
| `/etc/systemd/system/claims-{api,web}.service` | Services, user `claimsdesk`, loopback only |
| `/etc/nginx/nginx.conf` | Portal config; the original is `nginx.conf.claims-desk.orig` |
| `/etc/pki/tls/certs/claims-desk.crt`, `/etc/pki/tls/private/claims-desk.key` | Certificate. Replace with your own and `systemctl reload nginx`, or set `TLS_CERT`/`TLS_KEY` |

**Upgrade:** copy the new bundle and run `sudo ./install.sh` again. Code and packages are replaced; the database settings and data are kept.
**Point at another database** (for example HAProxy 5000 for stage 2): `sudo ./install.sh --reconfigure`.
**Remove:** `sudo ./uninstall.sh`. The database is left alone.

## Troubleshooting

| Symptom | Cause and fix |
| :--- | :--- |
| `cannot reach PostgreSQL at host:port` | Routing, Flow policy, or firewall between the portal VM and the database. Test with `curl -v telnet://host:5432`. |
| `no pg_hba.conf entry for host` | Add the portal VM's address to `pg_hba.conf` on the database server and reload PostgreSQL. |
| `password authentication failed` | Wrong admin or app password. Re-run `sudo ./install.sh --reconfigure`. |
| `permission denied to create database` | The admin account lacks `CREATEDB`. Use `postgres`, or create the database first and give its name. |
| `schema setup failed ... needs CREATE on database` | No admin account was given and the role cannot create a schema. Run once with an admin account. |
| `dnf could not install` | The VM cannot reach BaseOS/AppStream. Configure a mirror. |
| `pip could not download packages` | No PyPI access. Use the offline bundle from Releases. |
| Page shows **Database unavailable** | The middleware cannot reach PostgreSQL right now (outage, failover, Flow drop). It reconnects on its own. |
| Page shows **Middleware API unreachable** | `claims-api` is down: `sudo claims-desk logs`. |
| 502 Bad Gateway | `claims-web` is down, or SELinux blocks nginx: `getsebool httpd_can_network_connect` must be `on`. |

## Development

```bash
bash scripts/test.sh            # tests against a throwaway PostgreSQL (pgserver); no VM needed
bash scripts/build-bundle.sh    # dist/claims-desk-demo-<version>.tar.gz with Rocky 9 wheels
bash scripts/e2e-rocky9.sh      # install.sh on Rocky 9 + systemd + PostgreSQL 16 in Docker (Linux host)
```

GitHub Actions runs all three on every push to `main`. A tag `v*` attaches the offline bundle to a release.
