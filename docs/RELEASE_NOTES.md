`0.4.3`: `--stage 3` upgrades the document VM when it runs another version than the bundle, with the settings saved in `/root/.claims-desk-stage3`, and then selects stage 3 as before. Before, a portal on a newer bundle kept calling an older document service. A 0.3.x document VM has no packet read or photo index, so at stage 3 the packet view reported every packet as missing. A document VM that does not answer, or no saved settings, gives a warning and a reselect. Tested on the lab with `--stage` 2 → 3 → 4 → 5 → 2 → 5 → 3.

`0.4.2`: the assistant answers only Claims Desk questions. A scope check on the guard model (the vision model by default, chart value `chat.llm.guardModel`) runs before the chat model and returns a fixed reply to off-topic requests, such as songs, poems, jokes, general knowledge, programming or attempts to change the rules, with no model answer and no tool call. The system prompt has the same rule, so if the guard model is unavailable the question goes through and the chat model still declines. `CHAT_SCOPE_GUARD=false` (chart value `chat.scopeGuard`) turns it off. `/chat/health` reports the guard model and counts it in the model check.

`0.4.1`: every `--stage 5` adds the demo claims for the assistant when they are missing, through the API pods; `STAGE5_SEED=0` skips it. `claims-desk seed-fraud` matches each demo claim on policy, claimant and description, so reruns and 5 → 4 → 5 round trips never duplicate them, a deleted one comes back, and a lower stage leaves them in place. The change made behind the packet's back happens only when that claim is created. The claims table drops the *Written by* column (it stays on the claim page), and the assistant panel takes 40% of the screen.

`0.4.0`: stage 5, a claims assistant on the main page. `sudo ./update.sh --stage 5`, run on the portal after stage 4, deploys chat pods with the same Helm release and its own MetalLB Service on TCP 8443; nginx `/chat/` streams to them. The pods call an OpenAI-compatible endpoint (NAI): a chat model with tool calls, and a vision model for photos. The API key is read from the environment or a prompt and stored only in Secret `claims-desk-chat`. The assistant is read-only and reaches claims, photos and packets only through the API pods; it holds no database or Objects credentials. New read-only middleware views: `/api/v1/fraud` (rule-based scores and signals across PostgreSQL, the photos on Files and the packets on Objects), `/api/v1/fraud/{claim}`, `/api/v1/claims/{claim}/related`, `/api/v1/claims/{claim}/packet` (packet compared with the row), filters on `/api/v1/claims`, and stats by loss type and month. The document service adds `/v1/photos/index` (SHA-256, perceptual hash, EXIF date) and `/v1/packets/{claim}`. `sudo claims-desk seed-fraud` adds demo claims made to be found. Pillow is a new dependency, in the offline bundle.

`0.3.1`: PostgreSQL 10 and 11 work. `claim_number` is set by an insert trigger instead of a generated column, which needs 12. Tables created by earlier releases keep their generated column. A schema error now names the server version, and asks for CREATE on the database only when the error is about privileges.

`0.3.0`: stage 4, API pods on NKP. `sudo ./update.sh --stage 4 --kubeconfig FILE`, run on the portal, installs `kubectl` and `helm`, writes the Secret, deploys `deploy/helm/claims-desk`, and checks the pods end to end. Each pod runs the middleware and the document service as two containers: one image, `ghcr.io/apjgase/claims-desk-demo:0.3.0`, built and pushed by GitHub Actions. The Service is a MetalLB LoadBalancer on TCP 8443. At stage 4 nginx `/api/` goes to the pods, and `claims-api` on the portal is stopped; `--stage 3` starts it again and leaves the pods running. Any stage can follow any other; switching from 4 or 5 down to 1, 2 or 3, and `--stage 4 --reconfigure`, check PostgreSQL from the portal, so remove the Flow drop first. `/api/v1/info` reports `runtime` (VM or pod, with node and namespace). The stage 4 and 5 architecture pages extend the stage 1 row, like stage 3.

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
