#!/usr/bin/env bash
# Tests deploy/cloud-init/lab-services.yaml on Rocky Linux 9 with systemd: installs its
# packages, writes its files, then checks DNS records, forwarding, NTP config, CA trust,
# and the admin tools. Needs Docker and python3 with PyYAML (GitHub Actions runs it).
#
#   bash scripts/test-lab-services.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VM=claimsdesk-lab01
WORK="$(mktemp -d)"

cleanup() { docker rm -f "$VM" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
cleanup
mkdir -p "$WORK"

python3 - "$ROOT/deploy/cloud-init/lab-services.yaml" "$WORK" <<'PY'
import os, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
out = sys.argv[2]
os.makedirs(os.path.join(out, "files"))
with open(os.path.join(out, "manifest"), "w") as m:
    for i, f in enumerate(cfg["write_files"]):
        with open(os.path.join(out, "files", str(i)), "w") as fh:
            fh.write(f["content"])
        m.write(f"{f['path']} {f.get('permissions', '0644')} {i}\n")
with open(os.path.join(out, "packages"), "w") as fh:
    fh.write(" ".join(cfg["packages"]) + "\n")
with open(os.path.join(out, "ca.pem"), "w") as fh:
    fh.write(cfg["ca_certs"]["trusted"][0])
PY
chmod -R a+rX "$WORK"

docker build -q -t claimsdesk-rocky9-systemd - <<'EOF' >/dev/null
FROM rockylinux/rockylinux:9
RUN dnf -y -q install systemd procps-ng hostname iproute && dnf clean all
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
EOF
docker run -d --name "$VM" --hostname lab01.claims.internal \
  --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$WORK":/w:ro claimsdesk-rocky9-systemd >/dev/null

for _ in $(seq 1 30); do
  state="$(docker exec "$VM" systemctl is-system-running 2>/dev/null || true)"
  case "$state" in running|degraded) break ;; esac
  sleep 1
done
echo "systemd: $state"

vm() { docker exec "$VM" bash -c "$1"; }
expect() {
  local got
  got="$(vm "dig +short @127.0.0.1 $1" | sort | tr '\n' ' ' | sed 's/ $//')"
  if [ "$got" != "$2" ]; then echo "dig $1: expected '$2', got '$got'"; exit 1; fi
  echo "ok: $1 -> ${2:-NXDOMAIN}"
}

echo "== packages and files from cloud-init"
vm "dnf -y -q install \$(cat /w/packages)"
vm "while read -r path mode idx; do install -D -m \"\$mode\" \"/w/files/\$idx\" \"\$path\"; done < /w/manifest"
vm "cp /w/ca.pem /etc/pki/ca-trust/source/anchors/claims-internal-ca.crt && update-ca-trust"
vm "trust list | grep -q 'Claims Desk lab CA'"

echo "== DNS"
vm "dnsmasq --test"
vm "systemctl enable --now dnsmasq"
expect lab01.claims.internal 10.10.110.50
vm "lab-dns add portal 172.16.10.11 portal01"
vm "lab-dns add pg.claims.internal 172.16.20.21"
vm "lab-dns wildcard apps 10.10.120.150"
expect portal.claims.internal 172.16.10.11
expect portal01.claims.internal 172.16.10.11
expect pg.claims.internal 172.16.20.21
expect claims-api.apps.claims.internal 10.10.120.150
expect "-x 172.16.10.11" portal.claims.internal.
expect nosuch.claims.internal ""
vm "lab-dns add files 10.10.140.21,10.10.140.22,10.10.140.23"
expect files.claims.internal "10.10.140.21 10.10.140.22 10.10.140.23"
expect "-x 10.10.140.22" files.claims.internal.
vm "lab-dns add portal 172.16.10.12"
expect portal.claims.internal 172.16.10.12
expect portal01.claims.internal ""
vm "lab-dns del portal"
expect portal.claims.internal ""
vm "lab-dns unwildcard apps"
expect claims-api.apps.claims.internal ""
vm "lab-dns list"
vm "[ -n \"\$(dig +short @127.0.0.1 github.com)\" ]"
echo "ok: forwarding"

echo "== NTP"
vm "chronyd -p -f /etc/chrony.conf | grep -q '^allow 10.0.0.0/8'"
vm "grep -q '^local stratum 10' /etc/chrony.conf"

echo "== admin tools"
vm "/usr/local/sbin/lab-tools-install"
vm "kubectl version --client >/dev/null && helm version --short && aws --version && k9s version -s >/dev/null && gh --version >/dev/null"
vm "podman --version && psql --version"
echo "LAB SERVICES PASSED"
