Stage 3 is in this tree, together with stage 1. `sudo ./update.sh --stage 1` is the portal. `sudo ./update.sh --stage 3`, run on the portal, installs the document service on the document VM over SSH: NFSv3 photo on submit, Objects packet when the claim is approved. Objects TLS is not verified. `install.sh` remains the stage 1 installer.

Stage 1: the portal VM.

- nginx (HTTPS 443), web tier, and middleware API as systemd services on Rocky Linux 9 / RHEL 9.
- Creates the application role, database, schema and `claims` table on the PostgreSQL you provide (NDB single instance, or HAProxy 5000 for HA).
- `claims-desk-demo-<version>.tar.gz` is the offline bundle: it includes the Python wheels for Rocky 9 x86_64 (CPython 3.11), so the VM needs only its dnf repositories.

Install: `tar -xzf claims-desk-demo-*.tar.gz && cd claims-desk-demo-* && sudo ./install.sh`. See README.md.
