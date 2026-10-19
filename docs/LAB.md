# Lab prerequisites for the full Claims Desk demo

What the lab needs, beyond the portal VM and PostgreSQL, for every stage of the deck to work: the lab decisions, the shared services, a checklist per stage, then what this repository still has to provide. Addresses are the deck's examples; change them to your lab's.

Items marked *verify* come from general product knowledge and were not checked against the product guides; confirm them before relying on them.

## 1. Lab decisions

| Decision | Choice | Consequence |
| :--- | :--- | :--- |
| DNS | `claims.internal`, served by dnsmasq on `lab01` (this repository) | Every subnet's IPAM points at `lab01` for DNS |
| NTP | chrony on `lab01`, internet pool upstream | Every system takes time from `lab01` |
| Internet | Direct | dnf, PyPI, container images, Helm charts work online; the offline bundle is optional |
| Container registry | GHCR, images built by GitHub Actions | NKP needs outbound HTTPS to `ghcr.io` and a pull secret (the repository is private) |
| Certificates | One lab CA (`scripts/lab-ca.sh`) | Portal, Objects, NKP ingress and NAI get CA-signed certificates; the CA is trusted by cloud-init, pods and the laptop |
| Active Directory | None | Files is NFS-only; Objects uses local users |
| GPU and NAI | NAI provisioning and model deployment are demonstrated; the chat pods call an inference endpoint outside the lab | Chat pods need the external endpoint URL, an API key, and outbound HTTPS |
| NC2 and DR | Not in the lab | DR is shown on the slides only |

## 2. Shared services

### Lab services VM (`lab01`)

One Rocky Linux 9 VM on the management VLAN, 4 vCPU, 16 GB RAM, 60 GB disk, fixed IP (deck example 10.10.110.50). Deploy it first with [`deploy/cloud-init/lab-services.yaml`](../deploy/cloud-init/lab-services.yaml). Its address appears in two files: the `lab01` record in that cloud-init, and the `ntp` servers in the portal cloud-init. It provides:

- **DNS** for `claims.internal` (dnsmasq). Names outside the domain are forwarded to 1.1.1.1 and 8.8.8.8. Unknown names inside the domain get NXDOMAIN. PTR records are automatic.
- **NTP** (chrony) for the private ranges, and it keeps serving if the internet source drops.
- **Jump host tools**: `kubectl`, `helm`, `k9s`, `aws` (S3 client for Objects), `gh`, `psql`, `podman`, `nfs-utils`, `git`, `jq`. The `nkp` CLI comes from the Nutanix portal (sign-in required); copy it to `/usr/local/bin`.
- **Bootstrap machine** for NKP (container runtime plus `nkp`), the place to keep kubeconfigs, and the runbook endpoint for Self-Service in stage 6.

Manage records with `lab-dns`:

```bash
sudo lab-dns add portal 172.16.10.11 portal01     # A + PTR, alias portal01
sudo lab-dns wildcard apps 10.10.120.150          # *.apps.claims.internal
sudo lab-dns del portal
lab-dns list
lab-dns test portal
```

Then point the lab at it:

- [ ] In Prism Central, set `lab01` as the DNS server and `claims.internal` as the search domain in the IPAM settings of every managed subnet and VPC subnet. VMs and NKP nodes get them by DHCP.
- [ ] Set `lab01` as the DNS and NTP server for Prism Central, every Prism Element cluster, NDB, Files and Objects.
- [ ] Routing: the VPC subnets (172.16.x) must reach `lab01` on UDP/TCP 53 and UDP 123. With No-NAT VPCs this is ordinary routing through the DC core.
- [ ] Laptop over the VPN: either add `lab01` as a resolver for `claims.internal` (macOS: `/etc/resolver/claims.internal` containing `nameserver 10.10.110.50`), or use IPs.

### DNS records

Add these with `lab-dns` as each system is deployed.

| Name | Points to | Stage |
| :--- | :--- | :--- |
| `lab01` | Lab services VM (in the cloud-init) | all |
| `pc`, `pe1`, `pe2` | Prism Central, HCI cluster VIP, GPU cluster VIP | all |
| `ndb` | NDB server | 1 |
| `portal` (alias `portal01`) | Portal VM, routed overlay address (deck: 172.16.10.11) | 1 |
| `pg` | PostgreSQL VM (stage 1), then the HAProxy address (stage 2) | 1–2 |
| `docvm` | Document VM | 3 |
| `files` | One A record per FSVM client IP: `lab-dns add files IP1,IP2,IP3` (round robin) *verify the record layout Files expects* | 3 |
| `objects` | Objects public IP. Path-style S3 needs no wildcard | 3 |
| `nkp-api` | NKP control-plane VIP | 4 |
| `*.apps` | NKP ingress LoadBalancer IP (API, chat, dashboards) | 4–5 |
| `nai` | NAI UI and API ingress | 5 |
| `uat-portal` | UAT portal VM (or use the IP) | 6 |

### Certificates

The lab CA lives on the admin laptop (`~/.claims-desk-lab/ca`, key never in the repository). Its certificate is [`deploy/pki/claims-internal-ca.crt`](../deploy/pki/claims-internal-ca.crt), and it can only sign names under `claims.internal` and private IPs (name constraints).

```bash
scripts/lab-ca.sh issue portal portal01            # portal.claims.internal + portal01.claims.internal
scripts/lab-ca.sh issue objects                    # Objects S3 endpoint
scripts/lab-ca.sh issue '*.apps' 10.10.120.150     # NKP ingress wildcard
scripts/lab-ca.sh show
```

Each certificate is in `~/.claims-desk-lab/ca/issued/<name>/` as `key.pem`, `cert.pem` and `fullchain.pem`.

- **VMs** trust the CA through `ca_certs` in both cloud-init files.
- **Pods** get it through a mounted CA bundle (stage 4 Helm chart).
- **NKP ingress**: a cert-manager CA issuer, or the wildcard certificate as a TLS Secret *verify which NKP prefers*.
- **Laptop** (macOS): `security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db deploy/pki/claims-internal-ca.crt`, then restart the browser.
- **Prism, Objects, NAI**: upload the issued certificate with its key and the CA as the chain.

### IP plan

Reserve static addresses outside the IPAM pools.

| VLAN / network | Reserve | Stage |
| :--- | :--- | :--- |
| 110 management | Prism Central, NDB server, `lab01` | all |
| 130 external No-NAT | VPC router IP (deck: .10). DC core route: 172.16.10.0/24 → VPC router | 1 |
| VPC `claims-prod` overlay 172.16.10.0/24 | Portal VM, document VM | 1, 3 |
| DB network (VLAN or VPC subnet) | PostgreSQL VM; for HA: 3 Patroni nodes, HAProxy nodes, HAProxy VIP | 1–2 |
| 140 storage clients | Files client IPs (one per FSVM), Objects public IPs, plus their internal/storage IPs | 3 |
| 120 NKP nodes | Control-plane VIP (.5), worker and GPU node IPs from IPAM, MetalLB pool (deck: .150–.159) for ingress, EgressIP | 4–5 |
| VPC pod CIDR 172.16.128.0/17 | Flow CNI pod addresses (hybrid VPC) | 4 |
| 131 UAT external No-NAT, VPC `claims-uat` | UAT VPC router IP, UAT overlay 172.16.30.0/24, Self-Service VPC tunnel VM | 6 |

### Internet and registry

- The portal VPC is No-NAT, so its internet path is the DC edge NAT. Allow 172.16.0.0/16 and the NKP node VLAN outbound there.
- Images are pulled from `ghcr.io/apjgase/...` with a pull secret (a GitHub token with `read:packages`). Docker Hub images are rate-limited for anonymous pulls; the charts here avoid them where possible.
- Cost Governance and Security Central are SaaS: Prism Central needs outbound HTTPS.

### Secrets to manage

PostgreSQL admin and app passwords; NDB API user; Objects access and secret keys; Prism service accounts for NKP (CAPX), NDK and Self-Service; the GHCR pull token; the external inference endpoint API key; Hugging Face token (for the NAI model demo). Keep them in one password manager entry per stage. In Kubernetes they become Secrets (namespaces `claims`, `claims-uat`).

### Licences and versions

Licences have to cover: Flow Network Security and Flow Virtual Networking (VPC, Flow CNI), NDB (PostgreSQL HA), Files and Objects, NKP, NDK, NAI, and NCM (Self-Service, Cost Governance, Intelligent Ops). Release levels from the deck: NDB 2.10, Files and Objects 5.4, NDK 2.3, NAI 2.8, FVN 7.6, NCM 2.1. Check the interoperability matrix for the Prism Central and AOS versions.

## 3. Per stage

### Stage 1–2: portal VM and PostgreSQL (slides 4–5)

- [ ] `lab01` deployed; records for `pc`, `ndb`, `portal`, `pg`
- [ ] VPC `claims-prod`, overlay subnet with IPAM, DNS `lab01`, search domain `claims.internal`; No-NAT external subnet on VLAN 130; DC core route to the VPC router
- [ ] Categories `AppType: Claims`, `AppTier: Web | Database | Documents`, `Environment: Prod | UAT`
- [ ] NDB: registered cluster, profiles (software: PostgreSQL version; network; compute; parameters), SSH key = lab key; No-NAT reachability to the database VMs
- [ ] Single instance for stage 1. For stage 2, PostgreSQL HA: IPs for 3 nodes, HAProxy, VIP; clients use 5000
- [ ] `pg_hba.conf` allows the portal VM (and later the NKP node IPs or EgressIP)
- [ ] Flow policy: Web → Database TCP 5432/5000; NDB server → database VMs TCP 22; database VMs → NDB server TCP 443; everything → `lab01` UDP/TCP 53 and UDP 123
- [ ] Portal certificate from the lab CA, passed to `install.sh` with `TLS_CERT` and `TLS_KEY`
- [ ] Time Machine SLA

### Stage 3: document VM, Files, Objects (slide 6)

- [ ] File server, 3 FSVMs, client network on VLAN 140, DNS and NTP `lab01` at deployment; records created first
- [ ] NFS export `claims-docs`: default no access, read-write for the portal and document VMs, later the NKP node IPs or EgressIP; root squash
- [ ] Object store: public IPs, internal IPs, `objects.claims.internal`, certificate from the lab CA
- [ ] Bucket `claims`: versioning, WORM, retention
- [ ] Objects user with access keys for the app *verify: local users without AD*
- [ ] Document VM (portal cloud-init), `nfs-utils`

### Stage 4: API pods on NKP with Flow CNI, NDK (slide 7)

- [ ] NKP bundle, CLI, and node OS image uploaded to Prism Central *verify the image source for your NKP version*
- [ ] `lab01` as the bootstrap machine (Podman or Docker *verify which your NKP version supports*), `nkp`, `kubectl`, `helm`
- [ ] Prism Central service account for the cluster API provider; target cluster, storage container, managed VLAN basic subnet on VLAN 120 (with Flow CNI, nodes go only on a VLAN basic subnet, not into the VPC)
- [ ] Hybrid VPC: pod CIDR on `claims-prod`; namespace `claims` mapped to it; Flow CNI chosen at cluster creation *verify it cannot be changed later*
- [ ] Control-plane VIP (`nkp-api`); MetalLB pool (Flow CNI does not allocate LoadBalancer IPs)
- [ ] Ingress (NKP ships Traefik *verify*), `lab-dns wildcard apps <ingress IP>`, lab CA issuer or wildcard TLS Secret
- [ ] Nodes trust the lab CA if they pull from anything it signs *verify how NKP sets node CA trust*
- [ ] EgressIP per VPC, added to the NFS export and the bucket policy
- [ ] GHCR pull secret in namespace `claims`
- [ ] Flow policy: portal → PostgreSQL becomes a drop; portal → API pods 8443; API pods → PostgreSQL 5000
- [ ] NDK installed (snapshot and restore within the cluster; replication to a second site is on the slides only)

### Stage 5: chat pods and NAI (slide 8)

- [ ] NAI: licence, install, its own PostgreSQL from NDB for metadata (`nai_iep`, `nai_iam`) *verify the storage class NAI 2.8 needs*, `nai.claims.internal` with a lab CA certificate
- [ ] Model provisioning demo: Hugging Face token, model import, endpoint creation. A GPU node pool is needed only if the endpoint is actually started in the lab
- [ ] External inference endpoint: URL, model name, API key; the chat pods use these, and need outbound HTTPS through EgressIP and the DC edge
- [ ] Flow policy: chat pods → external endpoint 443

### Stage 6: UAT through NCM Self-Service (slide 10)

- [ ] Self-Service enabled; project `claims-uat` with quota, approval policy, and the lab SSH key as the blueprint credential
- [ ] VPC `claims-uat`, No-NAT VLAN 131; Self-Service VPC tunnel VM
- [ ] NDB API user for the runbook ("Clone from Time Machine"); masking script, run as the post-clone command
- [ ] Runbook endpoint: `lab01`, with `helm` and the kubeconfig; namespace `claims-uat` mapped to VPC `claims-uat`; separate EgressIP
- [ ] Separate UAT NFS share and bucket, seeded with synthetic documents
- [ ] Scheduler expiry (14 days) and NDB removal schedule
- [ ] Cost Governance onboarded (SaaS, outbound HTTPS from Prism Central); showback for the project

## 4. What this repository provides

| Item | Stage | Status |
| :--- | :--- | :--- |
| Portal app, `install.sh`, offline bundle | 1–2 | done |
| Portal cloud-init with NTP from `lab01` and lab CA trust | 1 | done |
| `lab01` cloud-init: DNS, NTP, jump host tools | all | done |
| Lab CA script and certificates | all | done |
| Document-tier code: NFS photo writes, S3 path-style client for the WORM packet, settings for both | 3 | next |
| Container image for the middleware (Dockerfile, CI build, push to GHCR) | 4 | |
| Helm chart: API deployment, Service, Ingress, ConfigMap and Secret, probes, CA bundle, NDK Application | 4 | |
| Chat service with a client for the external inference endpoint | 5 | |
| Self-Service blueprint and runbooks, masking script, UAT values | 6 | |
