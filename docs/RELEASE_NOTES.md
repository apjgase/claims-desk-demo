Stage 1: the portal VM.

- nginx (HTTPS 443), web tier, and middleware API as systemd services on Rocky Linux 9 / RHEL 9.
- Creates the application role, database, schema and `claims` table on the PostgreSQL you provide (NDB single instance, or HAProxy 5000 for HA).
- `claims-desk-demo-<version>.tar.gz` is the offline bundle: it includes the Python wheels for Rocky 9 x86_64 (CPython 3.11), so the VM needs only its dnf repositories.

Install: `tar -xzf claims-desk-demo-*.tar.gz && cd claims-desk-demo-* && sudo ./install.sh`. See README.md.
