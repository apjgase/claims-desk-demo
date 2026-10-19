#!/usr/bin/env bash
# End-to-end test of install.sh on Rocky Linux 9 with systemd, against PostgreSQL 16.
# Needs Docker on a Linux host (GitHub Actions runs it on every push).
#
#   bash scripts/e2e-rocky9.sh [bundle-dir]
#
# bundle-dir defaults to the repository; pass an extracted offline bundle to test that.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$(cd "${1:-$ROOT}" && pwd)"
NET=claimsdesk-e2e
PG=claimsdesk-pg
VM=claimsdesk-vm

cleanup() { docker rm -f "$VM" "$PG" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" -e POSTGRES_PASSWORD='Adm1n-pw!' postgres:16 >/dev/null

docker build -q -t claimsdesk-rocky9-systemd - <<'EOF' >/dev/null
FROM rockylinux/rockylinux:9
RUN dnf -y -q install systemd procps-ng hostname iproute && dnf clean all
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
EOF
docker run -d --name "$VM" --hostname portal01.claims.internal --network "$NET" \
  --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$BUNDLE":/bundle:ro claimsdesk-rocky9-systemd >/dev/null

for _ in $(seq 1 30); do
  state="$(docker exec "$VM" systemctl is-system-running 2>/dev/null || true)"
  case "$state" in running|degraded) break ;; esac
  sleep 1
done
echo "systemd: $state"
for _ in $(seq 1 30); do
  docker exec "$PG" pg_isready -q -U postgres && break
  sleep 1
done

vm() { docker exec "$VM" bash -c "$1"; }

echo "== first install (unattended, admin creates role and database)"
vm "cat > /root/claims-desk.conf <<'CONF'
DB_HOST='$PG'
DB_PORT=5432
DB_ADMIN_USER='postgres'
DB_ADMIN_PASSWORD='Adm1n-pw!'
DB_NAME='claims'
DB_APP_USER='claims_app'
DB_APP_PASSWORD=''
DB_SSLMODE='prefer'
SEED_COUNT=12
CONF"
vm "/bundle/install.sh --config /root/claims-desk.conf -y"

echo "== checks"
vm "curl -skf https://127.0.0.1/ | grep -q CLM-000001"
vm "curl -skf https://127.0.0.1/about | grep -q 'Request path'"
vm "curl -sf -o /dev/null -w '%{http_code}\n' http://127.0.0.1/ | grep -q 301"
vm "curl -skf -X POST https://127.0.0.1/api/v1/claims -H 'content-type: application/json' \
      -d '{\"policy_number\":\"POL-E2E\",\"claimant_name\":\"E2E\",\"loss_date\":\"2026-10-01\",\"loss_type\":\"Auto\",\"amount\":\"10\",\"description\":\"e2e\"}' \
    | grep -q CLM-000013"
vm "stat -c '%a %U:%G' /etc/claims-desk/api.json | grep -q '640 root:claimsdesk'"
vm "claims-desk check"
vm "claims-desk status"

echo "== re-run (keeps database settings and data)"
vm "/bundle/install.sh -y < /dev/null"
vm "curl -skf https://127.0.0.1/api/v1/claims/CLM-000013 | grep -q POL-E2E"
vm "curl -skf https://127.0.0.1/api/v1/stats | grep -q '\"total\":13'"

echo "== database outage is reported, then recovers"
docker stop "$PG" >/dev/null
vm "curl -sk https://127.0.0.1/ | grep -q 'Database unavailable'"
docker start "$PG" >/dev/null
for _ in $(seq 1 30); do docker exec "$PG" pg_isready -q -U postgres && break; sleep 1; done
recovered=0
for _ in $(seq 1 60); do
  if vm "curl -skf --max-time 15 https://127.0.0.1/healthz" >/dev/null 2>&1; then recovered=1; break; fi
  sleep 1
done
[ "$recovered" -eq 1 ] || { echo "API did not recover after the database came back"; exit 1; }
vm "curl -skf https://127.0.0.1/healthz"
echo

echo "== uninstall"
vm "/bundle/uninstall.sh -y"
vm "! systemctl is-active -q claims-api"
echo "E2E PASSED"
