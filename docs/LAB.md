# Lab prerequisites for the full Claims Desk demo

What the lab needs, beyond the portal VM and PostgreSQL, for every stage of the deck to work: shared services first, then a checklist per stage, then what this repository still has to provide. Names and addresses follow the deck (`claims.lab` is an example domain; the RFC 1918 ranges are the deck's examples).

Items marked *verify* come from general product knowledge and were not checked against the product guides; confirm them before relying on them.

## 1. Decide these first

| Decision | Options | Affects |
| :--- | :--- | :--- |
| DNS domain and server | Existing lab DNS (AD or BIND) with a new zone `claims.lab`, or a small DNS VM | Every stage |
| Internet from the lab | Direct, through a proxy, or none (air-gapped) | dnf, PyPI, container images, Helm charts, NAI models, SaaS (Cost Governance, Security Central) |
| Container registry | GHCR (private, needs internet and a pull secret), or Harbor in the lab (mirror plus our images) | Stages 4–6 |
| Certificates | Self-signed everywhere, or one lab CA that signs the portal, Objects, NKP ingress, and NAI | Pods talking to Objects and NAI over TLS |
| Active Directory | Not needed if Files is NFS-only and Objects uses local users | Files (SMB, NFS Kerberos), optional SSO |
| GPU | Real GPU in the compute-only cluster (passthrough or vGPU), or run NAI on CPU for the demo | Stage 5 |
| NC2 | Already deployed with VPN or Direct Connect, or later | DR on every stage |

## 2. Shared services

### DNS

Forward and reverse zones. Every system below needs to resolve these names from on-prem **and** from NC2.

| Name (example) | Points to | Stage |
| :--- | :--- | :--- |
| `pc.claims.lab`, `pe1.claims.lab`, `pe2.claims.lab` | Prism Central, HCI cluster VIP, GPU cluster VIP | all |
| `ndb.claims.lab` | NDB server | 1 |
| `portal.claims.lab` | Portal VM, routed overlay address (deck: 172.16.10.11) | 1 |
| `pg.claims.lab` | PostgreSQL VM (stage 1), then the HAProxy address (stage 2) | 1–2 |
| `docvm.claims.lab` | Document VM | 3 |
| `files.claims.lab` | One A record per FSVM client IP (round robin) | 3 |
| `objects.claims.lab` | Objects public IPs. A wildcard `*.objects.claims.lab` is needed only for virtual-hosted-style S3; the app will use path-style | 3 |
| `nkp-api.claims.lab` | NKP control-plane VIP | 4 |
| `*.apps.claims.lab` | NKP ingress LoadBalancer IP (API, chat, dashboards) | 4–5 |
| `nai.claims.lab` | NAI UI and endpoint ingress | 5 |
| `uat-portal.claims.lab` | UAT portal VM (Self-Service runbook updates it, or use the IP) | 6 |
| `pc-nc2.claims.lab`, `files-dr.claims.lab`, `objects-dr.claims.lab`, `nkp-dr-api.claims.lab` | NC2 counterparts | DR |

- **Subnets hand out DNS.** In Prism, set the DNS servers and search domain in the IPAM settings of every managed subnet and VPC subnet. VMs and NKP nodes get them by DHCP.
- **Nutanix Files needs DNS and NTP at deployment.** Create its A and PTR records before or during deployment.
- **NC2 resolution.** The NC2 VPC must resolve `claims.lab`: a Route 53 Resolver outbound rule that forwards to the lab DNS, or a DNS VM on NC2.
- **DR failover changes the portal address** (DR VPC `claims-dr` is 172.20.10.0/24). Keep the TTL of `portal.claims.lab` low (60 s). Update the record in a recovery-plan script, or by hand during the test.

### NTP

One NTP source for everything: AOS and Prism Central on both sites, NDB, Files, Objects, NKP nodes, and VMs. Time drift breaks Kerberos and TLS, makes snapshot and log catch-up times confusing, and makes NKP certificates appear not yet valid. The portal cloud-init should set the same servers (see section 4).

### Certificates

- A **lab CA** is the simplest way to make HTTPS work end to end. Sign the portal, Objects (S3 endpoint), NKP ingress (cert-manager ClusterIssuer), and NAI with it.
- Trust the CA everywhere it is used as a client: VMs (`/etc/pki/ca-trust/source/anchors` + `update-ca-trust`), pods (mounted CA bundle), and the admin laptop.
- With self-signed certificates, every client has to skip verification, and pods calling Objects or NAI need explicit configuration for that.

### IP plan

Reserve static addresses outside the IPAM pools.

| VLAN / network | Reserve | Stage |
| :--- | :--- | :--- |
| 110 management | Prism Central, NDB server, admin jump host | all |
| 130 external No-NAT | VPC router IP (deck: .10). DC core route: 172.16.10.0/24 → VPC router | 1 |
| VPC `claims-prod` overlay 172.16.10.0/24 | Portal VM, document VM | 1, 3 |
| DB network (VLAN or VPC subnet) | PostgreSQL VM; for HA: 3 Patroni nodes, HAProxy nodes, HAProxy VIP | 1–2 |
| 140 storage clients | Files client IPs (one per FSVM), Objects public IPs, plus their internal/storage IPs | 3 |
| 120 NKP nodes | Control-plane VIP (.5), worker and GPU node IPs from IPAM, MetalLB pool (deck: .150–.159) for ingress, NDK intercom, EgressIP | 4–5 |
| VPC pod CIDR 172.16.128.0/17 | Flow CNI pod addresses (hybrid VPC) | 4 |
| 131 UAT external No-NAT, VPC `claims-uat` | UAT VPC router IP, UAT overlay 172.16.30.0/24, Self-Service VPC tunnel VM | 6 |
| NC2 | AWS VPC CIDR (no overlap with on-prem, not 192.168.5.0/24), FVN transit VPC, `claims-dr` 172.20.10.0/24 | DR |

### Internet, repositories and registries

| Need | If there is no direct internet |
| :--- | :--- |
| dnf (BaseOS, AppStream) | Local mirror or Satellite-style repository |
| Python packages | The offline bundle from Releases (already done) |
| NKP images and Helm charts | NKP air-gapped bundle into a lab registry *verify* |
| Our container images (API, chat) | Harbor in the lab; push from the jump host |
| Docker Hub images | Mirror them. Anonymous Docker Hub pulls are rate-limited even with internet |
| NAI models | Hugging Face token with internet; otherwise download elsewhere and upload *verify* |
| Cost Governance, Security Central | SaaS: Prism Central needs outbound HTTPS |

The portal VPC is No-NAT, so its internet path is the DC edge NAT. Allow 172.16.10.0/24 there if the VMs need the internet.

### Admin jump host

One Linux VM on the management VLAN (same cloud-init), reachable over the VPN. It holds the lab SSH key, kubeconfigs, and tools: `kubectl`, `helm`, `nkp`, `psql`, `aws` (or `mc`) for S3, `nfs-utils`, `git`, `jq`. It also serves as the Self-Service runbook endpoint for helm in stage 6, and is where bundles and images are downloaded once.

### Secrets to manage

PostgreSQL admin and app passwords; NDB API user; Objects access and secret keys; Prism service accounts for NKP (CAPX), NDK, and Self-Service; registry credentials; NAI endpoint API key; Hugging Face token. Keep them in one password manager entry per stage. In Kubernetes they become Secrets (namespace `claims`, `claims-uat`).

### Licences and versions

Licences have to cover: Flow Network Security and Flow Virtual Networking (VPC, Flow CNI), Nutanix DR (NearSync), NDB (PostgreSQL HA, multi-cluster), Files and Objects, NKP, NDK, NAI, NCM (Self-Service, Cost Governance, Intelligent Ops), NC2, and NVIDIA vGPU if vGPU is used. Release levels from the deck: NDB 2.10, Files and Objects 5.4, NDK 2.3, NAI 2.8, FVN 7.6, NCM 2.1, NKP on NC2 from 2.13. Check the interoperability matrix for the Prism Central and AOS versions on both sites.

## 3. Per stage

### Stage 1–2: portal VM and PostgreSQL (slides 4–5)

- [ ] VPC `claims-prod`, overlay subnet with IPAM, DNS and search domain; No-NAT external subnet on VLAN 130; DC core route to the VPC router
- [ ] Categories `AppType: Claims`, `AppTier: Web | Database | Documents`, `Environment: Prod | UAT`
- [ ] NDB: registered cluster, profiles (software: PostgreSQL version; network; compute; parameters), SSH key = lab key; No-NAT reachability to the database VMs
- [ ] Single instance for stage 1. For stage 2, PostgreSQL HA: IPs for 3 nodes, HAProxy, VIP; clients use 5000
- [ ] `pg_hba.conf` allows the portal VM (and later the NKP node IPs or EgressIP)
- [ ] Flow policy: Web → Database TCP 5432/5000; NDB server → database VMs TCP 22; database VMs → NDB server TCP 443
- [ ] Nutanix DR to NC2: protection policy on `AppTier: Web` (NearSync), recovery plan with network mapping to `claims-dr`
- [ ] Time Machine SLA; NDB multi-cluster with the NC2 cluster registered (TCP 2009, 2020, ICMP to every CVM and VIP)

### Stage 3: document VM, Files, Objects (slide 6)

- [ ] File server, 3 FSVMs, client network on VLAN 140, DNS and NTP set at deployment
- [ ] NFS export `claims-docs`: default no access, read-write for the portal and document VMs, later the NKP node IPs or EgressIP; root squash
- [ ] Smart DR: recovery file server on NC2, share-to-share policy (1 min minimum); clients remount after failover
- [ ] Object store: public IPs, internal IPs, DNS name, certificate (lab CA or self-signed)
- [ ] Bucket `claims`: versioning, WORM, retention. Same versioning, WORM, and retention on the NC2 bucket; streaming replication; TCP 7100 to the NC2 public IPs; no NAT between the instances
- [ ] Objects user with access keys for the app *verify: local users without AD*
- [ ] Document VM (same cloud-init), `nfs-utils`

### Stage 4: API pods on NKP with Flow CNI, NDK (slide 7)

- [ ] NKP bundle, CLI, and node OS image uploaded to Prism Central *verify the image source for your NKP version*
- [ ] Bootstrap machine (the jump host) with Docker or Podman, `nkp`, `kubectl`, `helm`
- [ ] Prism Central service account for the cluster API provider; target cluster, storage container, managed VLAN basic subnet on VLAN 120 (with Flow CNI, nodes go only on a VLAN basic subnet, not into the VPC)
- [ ] Hybrid VPC: pod CIDR on `claims-prod`; namespace `claims` mapped to it; Flow CNI chosen at cluster creation *verify it cannot be changed later*
- [ ] Control-plane VIP; MetalLB pool (Flow CNI does not allocate LoadBalancer IPs)
- [ ] Ingress (NKP ships Traefik *verify*), `*.apps.claims.lab`, cert-manager issuer with the lab CA
- [ ] EgressIP per VPC, added to the NFS export and the bucket policy
- [ ] Registry access and an image pull secret for our API image
- [ ] Flow policy: portal → PostgreSQL becomes a drop; portal → API pods 8443; API pods → PostgreSQL 5000
- [ ] NDK installed on the production and standby clusters; same storage class names; same Kubernetes distribution; separate Prism Element clusters
- [ ] Standby NKP cluster on NC2 (NKP 2.13 or later), NDK intercom LoadBalancer IP (Remote CR example port 2021) reachable across the WAN

### Stage 5: chat pods and NAI on the GPU pool (slide 8)

- [ ] Compute-only GPU cluster on external storage (PowerFlex or Pure FlashArray, NVMe/TCP, 3 nodes minimum), same Prism Central. Demo only
- [ ] GPU passthrough or vGPU; for vGPU, an NVIDIA licence server
- [ ] NKP GPU node pool on that cluster (`nkp create nodepool nutanix ... --prism-element-cluster <PE2> --gpu-name <GPU>`), tainted `nvidia.com/gpu:NoSchedule`
- [ ] NVIDIA GPU Operator on the cluster *verify how NKP 2.x ships it*
- [ ] NAI: licence, install, its own PostgreSQL from NDB for metadata (`nai_iep`, `nai_iam`; one per NAI instance), model storage *verify the storage class NAI 2.8 needs*
- [ ] Model: Hugging Face token or upload; endpoint created; API key issued
- [ ] Flow policy: chat pods → NAI endpoint 443

### Stage 6: UAT through NCM Self-Service (slide 10)

- [ ] Self-Service enabled; project `claims-uat` with quota, approval policy, and the lab SSH key as the blueprint credential
- [ ] VPC `claims-uat`, No-NAT VLAN 131; Self-Service VPC tunnel VM
- [ ] NDB API user for the runbook ("Clone from Time Machine"); masking script, run as the post-clone command
- [ ] Runbook endpoint with `helm` and the kubeconfig (the jump host); namespace `claims-uat` mapped to VPC `claims-uat`; separate EgressIP
- [ ] Separate UAT NFS share and bucket, seeded with synthetic documents
- [ ] Scheduler expiry (14 days) and NDB removal schedule
- [ ] Cost Governance onboarded (SaaS, outbound HTTPS from Prism Central); showback for the project

### NC2 side (used by every stage)

- [ ] NC2 on AWS cluster with its own Prism Central; VPN or Direct Connect, Transit Gateway; no CIDR overlap
- [ ] AWS security groups and WAN firewall open for: Prism Central to Prism Central 9440; CVMs 2009, 2020, ICMP; Objects 7100; NDK 2021; plus Files Smart DR (see the Files Port Reference)
- [ ] DNS resolution of `claims.lab` from NC2; same NTP
- [ ] Availability zone pairing between the two Prism Centrals; recovery plans tested with a test failover (not live in front of the customer)

## 4. What this repository still has to provide

| Item | Stage |
| :--- | :--- |
| cloud-init: NTP servers, lab CA trust, DNS search domain (if the subnet does not set them), and a jump-host variant | now |
| `install.sh`: certificate signed by the lab CA (already supported through `TLS_CERT` and `TLS_KEY`) | now |
| Document-tier code: NFS photo writes, S3 path-style client for the WORM packet, settings for both | 3 |
| Container image for the middleware (Dockerfile, CI build, push to the chosen registry) | 4 |
| Helm chart: API deployment, Service, Ingress, ConfigMap and Secret, probes, NDK Application and protection resources | 4 |
| Chat service and NAI client | 5 |
| Self-Service blueprint and runbooks, masking script, UAT values | 6 |
| DR helpers: DNS update after failover, demo reset | DR |
