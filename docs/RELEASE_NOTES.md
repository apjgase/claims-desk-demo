`0.2.6`: the stage 3 architecture page extends the stage 1 row. The document VM, Files, and Objects hang off the middleware. Later stages keep that row and add a branch.

`0.2.5`: `./update.sh --stage N` selects the active path and the architecture diagram. A lower stage stops using a later tier and leaves that tier in place.

`0.2.4`: the architecture page keeps the live middleware reply, so stage 3 shows Portal, Document VM, Files, Objects, and PostgreSQL, and the photo field is enabled.

`0.2.3`: a refused Windows DNS update is a warning. The install continues.

`0.2.2`: an NFS export may be a hostname (`labFS.ntnxlab.local:/documents`). `install.sh` registers the portal, and `update.sh --stage 3` registers the document VM, as A records on Windows DNS `10.55.19.6` in `ntnxlab.local`. The zone must allow nonsecure dynamic updates.

Stage 3 is in this tree, together with stage 1. `sudo ./update.sh --stage 1` is the portal. `sudo ./update.sh --stage 3`, run on the portal, installs the document service on the document VM over SSH: NFSv3 photo on submit, Objects packet when the claim is approved. Objects TLS is not verified. `install.sh` remains the stage 1 installer.

Stage 1: the portal VM.

- nginx (HTTPS 443), web tier, and middleware API as systemd services on Rocky Linux 9 / RHEL 9.
- Creates the application role, database, schema and `claims` table on the PostgreSQL you provide (NDB single instance, or HAProxy 5000 for HA).
- `claims-desk-demo-<version>.tar.gz` is the offline bundle: it includes the Python wheels for Rocky 9 x86_64 (CPython 3.11), so the VM needs only its dnf repositories.

Install: `tar -xzf claims-desk-demo-*.tar.gz && cd claims-desk-demo-* && sudo ./install.sh`. See README.md.
