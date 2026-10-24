#!/usr/bin/env bash
# Claims Desk, stage 1: install the portal on a Rocky Linux 9 (or RHEL 9) VM.
#
#   sudo ./install.sh                          interactive; asks for the PostgreSQL details
#   sudo ./install.sh --config claims-desk.conf   unattended (see claims-desk.conf.example)
#   sudo ./update.sh --stage 3                 add the document VM, Files, and Objects
#
# Installs nginx (HTTPS 443, HTTP 80 redirects), the web tier (127.0.0.1:8080) and the
# middleware API (127.0.0.1:8000) as systemd services, creates the application role,
# database and claims table on the PostgreSQL you provisioned, loads sample claims,
# registers this VM in Windows DNS, and runs an end-to-end check. Safe to re-run.
set -euo pipefail
umask 022

BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX=/opt/claims-desk
ETC=/etc/claims-desk
SVC_USER=claimsdesk
PY=python3.11
CERT=/etc/pki/tls/certs/claims-desk.crt
KEY=/etc/pki/tls/private/claims-desk.key
LOG=/var/log/claims-desk-install.log
DNS_SERVER="${DNS_SERVER:-10.55.19.6}"
DNS_ZONE="${DNS_ZONE:-ntnxlab.local}"

CONFIG=""
RECONFIGURE=0
ASSUME_YES=0
SEED_ARG=""

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --config FILE    read settings from FILE (unattended)
  --reconfigure    ask for the database settings again on an existing install
  --seed N         load N sample claims if the table is empty (default 12, 0 = none)
  -y, --yes        do not ask for confirmation
  -h, --help       this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="${2:?--config needs a file}"; shift 2 ;;
    --reconfigure) RECONFIGURE=1; shift ;;
    --seed) SEED_ARG="${2:?--seed needs a number}"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

step() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

INTERACTIVE=0
if [ -z "$CONFIG" ] && [ -t 0 ]; then INTERACTIVE=1; fi

# ask VAR "Prompt" default
ask() {
  local var="$1" prompt="$2" def="${3:-}" cur="${!1:-}" reply
  [ -n "$cur" ] && def="$cur"
  if [ "$INTERACTIVE" -eq 1 ]; then
    read -r -p "   $prompt${def:+ [$def]}: " reply
    printf -v "$var" '%s' "${reply:-$def}"
  else
    printf -v "$var" '%s' "$def"
  fi
}

# ask_secret VAR "Prompt"  (keeps a value that is already set, e.g. from --config)
ask_secret() {
  local var="$1" prompt="$2" reply
  if [ -n "${!1:-}" ] || [ "$INTERACTIVE" -eq 0 ]; then return 0; fi
  read -r -s -p "   $prompt: " reply
  echo
  printf -v "$var" '%s' "$reply"
}

ask_yes() {
  local prompt="$1" def="${2:-Y}" reply
  [ "$INTERACTIVE" -eq 1 ] || { [ "$def" = "Y" ]; return; }
  read -r -p "   $prompt [${def}/$([ "$def" = Y ] && echo n || echo y)]: " reply
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy] ]]
}

valid_ident() { [[ "$1" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; }

valid_ipv4() {
  local ip="$1" oct
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for oct in "${BASH_REMATCH[@]:1}"; do
    [ "$((10#$oct))" -le 255 ] || return 1
  done
}

# Address this VM uses to reach Windows DNS. Falls back to the first address.
local_ipv4() {
  local ip=""
  ip="$(ip -4 route get "$DNS_SERVER" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  if ! valid_ipv4 "$ip"; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "$ip"
}

# Publish an A record. A missing server or a refused update is a warning.
# The install continues either way.
dns_upsert() {
  local fqdn="$1" ip="$2"
  [[ "$fqdn" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
    || die "DNS name '$fqdn' is not a valid host name"
  valid_ipv4 "$ip" || die "DNS update needs an IPv4 address for ${fqdn}, got '${ip}'"
  valid_ipv4 "$DNS_SERVER" || die "DNS_SERVER '${DNS_SERVER}' must be an IPv4 address"
  [[ "$DNS_ZONE" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]] \
    || die "DNS_ZONE '${DNS_ZONE}' is not a valid domain"
  command -v nsupdate >/dev/null 2>&1 || die "nsupdate is missing. Install bind-utils."
  if ! timeout 5 bash -c "echo >/dev/tcp/${DNS_SERVER}/53" 2>/dev/null; then
    warn "DNS server ${DNS_SERVER} is not accepting TCP 53. Left ${fqdn} unchanged."
    return 0
  fi
  info "DNS ${fqdn} -> ${ip} on ${DNS_SERVER}"
  if ! nsupdate -v <<EOF
server ${DNS_SERVER}
zone ${DNS_ZONE}
update delete ${fqdn}. A
update add ${fqdn}. 300 A ${ip}
send
EOF
  then
    warn "DNS update for ${fqdn} was refused by ${DNS_SERVER}. Set the ${DNS_ZONE} zone to Nonsecure and secure dynamic updates. Continuing."
    return 0
  fi
  local answers=""
  answers="$(dig +short "$fqdn" @"$DNS_SERVER" A || true)"
  if ! printf '%s\n' "$answers" | grep -x "$ip" >/dev/null; then
    warn "DNS server ${DNS_SERVER} did not return ${ip} for ${fqdn}. Continuing."
    return 0
  fi
  DNS_PUBLISHED="$fqdn"
}

admin_cli() {
  PYTHONPATH="$PREFIX/app" "$PREFIX/venv/bin/python" -m claimsdesk.admin "$@"
}

# ---------------------------------------------------------------- preflight
step "Preflight"
[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in rocky|rhel|almalinux|centos) ;; *) die "unsupported OS ${PRETTY_NAME:-unknown}: needs Rocky Linux 9 or RHEL 9" ;; esac
[ "${VERSION_ID%%.*}" = "9" ] || die "unsupported OS version ${VERSION_ID}: needs Rocky Linux 9 or RHEL 9"
[ "$(uname -m)" = "x86_64" ] || warn "architecture $(uname -m): the offline wheels are x86_64 only"
info "${PRETTY_NAME}, $(uname -m), host $(hostname -f 2>/dev/null || hostname)"
exec > >(tee -a "$LOG") 2>&1
info "log: $LOG"

if [ -n "$CONFIG" ]; then
  [ -f "$CONFIG" ] || die "config file not found: $CONFIG"
  # shellcheck disable=SC1090
  . "$CONFIG"
  info "settings from $CONFIG"
fi

KEEP_DB=0
if [ -f "$ETC/api.json" ] && [ "$RECONFIGURE" -eq 0 ] && [ -z "$CONFIG" ]; then
  KEEP_DB=1
  info "existing install found: keeping the database settings in $ETC/api.json (use --reconfigure to change them)"
fi
# Set by update.sh when stage 4 is already active: the API pods are the database
# client, and the Flow policy may drop this VM's traffic to PostgreSQL.
NO_DB=0
if [ "${CLAIMS_PORTAL_NO_DB:-}" = "1" ] && [ "$KEEP_DB" -eq 1 ]; then
  NO_DB=1
fi

# ---------------------------------------------------------------- settings
if [ "$KEEP_DB" -eq 0 ]; then
  step "PostgreSQL settings"
  if [ "$INTERACTIVE" -eq 1 ]; then
    info "Single instance: the database VM, port 5432."
    info "NDB PostgreSQL HA: the HAProxy address, port 5000."
  fi
  ask DB_HOST "PostgreSQL host or IP"
  [ -n "${DB_HOST:-}" ] || die "DB_HOST is required"
  ask DB_PORT "Port" 5432
  [[ "$DB_PORT" =~ ^[0-9]+$ ]] || die "DB_PORT must be a number"
  ask DB_NAME "Application database" claims
  ask DB_APP_USER "Application role" claims_app
  valid_ident "$DB_NAME" || die "database name '$DB_NAME': use lower case letters, digits and _"
  valid_ident "$DB_APP_USER" || die "role name '$DB_APP_USER': use lower case letters, digits and _"

  if [ "$INTERACTIVE" -eq 1 ]; then
    DB_ADMIN_USER="${DB_ADMIN_USER-postgres}"
    if ask_yes "Create the role and database with an admin account (NDB: user postgres)?" Y; then
      ask DB_ADMIN_USER "Admin user" postgres
      ask_secret DB_ADMIN_PASSWORD "Admin password"
      ask DB_ADMIN_DB "Admin maintenance database" postgres
    else
      DB_ADMIN_USER=""
    fi
  fi
  if [ -n "${DB_ADMIN_USER:-}" ]; then
    ask_secret DB_APP_PASSWORD "Password for $DB_APP_USER (Enter = generate one)"
    if [ -z "${DB_APP_PASSWORD:-}" ]; then
      DB_APP_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)"
      GENERATED_PW=1
    fi
  else
    ask_secret DB_APP_PASSWORD "Password for existing role $DB_APP_USER"
    [ -n "${DB_APP_PASSWORD:-}" ] || die "DB_APP_PASSWORD is required when no admin user is given"
  fi
  ask DB_SSLMODE "TLS to PostgreSQL (disable, prefer, require, verify-full)" prefer
fi

step "Portal settings"
DEFAULT_NAME="$(hostname -f 2>/dev/null || hostname)"
ask SERVER_NAME "TLS server name" "$DEFAULT_NAME"
[[ "$SERVER_NAME" =~ ^[A-Za-z0-9.-]+$ ]] || die "SERVER_NAME '$SERVER_NAME' is not a valid host name"
SITE_NAME="${SITE_NAME:-Claims Desk}"
ENVIRONMENT="${ENVIRONMENT:-Prod}"
SEED_COUNT="${SEED_ARG:-${SEED_COUNT:-12}}"
[[ "$SEED_COUNT" =~ ^[0-9]+$ ]] || die "seed count must be a number"

if [ "$KEEP_DB" -eq 0 ]; then
  echo
  info "PostgreSQL   ${DB_HOST}:${DB_PORT}  database ${DB_NAME}  role ${DB_APP_USER}  sslmode ${DB_SSLMODE}"
  info "Admin        ${DB_ADMIN_USER:-none (role and database already exist)}"
fi
info "Portal       https://${SERVER_NAME}/   environment ${ENVIRONMENT}   sample claims ${SEED_COUNT}"
if [ "$ASSUME_YES" -eq 0 ] && [ "$INTERACTIVE" -eq 1 ]; then
  ask_yes "Proceed?" Y || die "cancelled"
fi

# ---------------------------------------------------------------- packages
step "Packages"
MISSING=()
for p in nginx "$PY" "${PY}-pip"; do rpm -q "$p" >/dev/null 2>&1 || MISSING+=("$p"); done
# By command, not package: Rocky ships curl-minimal, which conflicts with the curl package.
for c in openssl tar curl; do command -v "$c" >/dev/null 2>&1 || MISSING+=("$c"); done
command -v nsupdate >/dev/null 2>&1 || MISSING+=("bind-utils")
if [ ${#MISSING[@]} -gt 0 ]; then
  info "installing ${MISSING[*]}"
  dnf -y -q install "${MISSING[@]}" \
    || die "dnf could not install ${MISSING[*]}. The VM needs the BaseOS and AppStream repositories (or a local mirror)."
else
  info "nginx, $PY, openssl already installed"
fi

# ---------------------------------------------------------------- application
step "Application"
getent group "$SVC_USER" >/dev/null || groupadd --system "$SVC_USER"
getent passwd "$SVC_USER" >/dev/null || \
  useradd --system --gid "$SVC_USER" --home-dir "$PREFIX" --no-create-home --shell /sbin/nologin "$SVC_USER"
install -d -m 0755 "$PREFIX"
install -d -m 0750 -o root -g "$SVC_USER" "$ETC"

rm -rf "$PREFIX/app.new"
cp -R "$BUNDLE/app" "$PREFIX/app.new"
find "$PREFIX/app.new" -name '__pycache__' -prune -exec rm -rf {} +
rm -rf "$PREFIX/app.old"
[ -d "$PREFIX/app" ] && mv "$PREFIX/app" "$PREFIX/app.old"
mv "$PREFIX/app.new" "$PREFIX/app"
rm -rf "$PREFIX/app.old"
info "code in $PREFIX/app (version $(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$PREFIX/app/claimsdesk/__init__.py"))"

if [ ! -x "$PREFIX/venv/bin/python" ]; then
  "$PY" -m venv "$PREFIX/venv"
fi
if [ -d "$BUNDLE/vendor/wheels" ]; then
  info "installing Python packages from the bundled wheels (offline)"
  "$PREFIX/venv/bin/pip" install -q --no-index --find-links "$BUNDLE/vendor/wheels" -r "$PREFIX/app/requirements.txt" -c "$PREFIX/app/constraints.txt"
else
  info "installing Python packages from ${PIP_INDEX_URL:-PyPI}"
  "$PREFIX/venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1 || true
  "$PREFIX/venv/bin/pip" install -q -r "$PREFIX/app/requirements.txt" -c "$PREFIX/app/constraints.txt" \
    || die "pip could not download packages. Use the offline bundle (release asset) or set PIP_INDEX_URL to a mirror."
fi
"$PREFIX/venv/bin/python" -m compileall -q "$PREFIX/app" >/dev/null
install -m 0755 "$BUNDLE/deploy/claims-desk" /usr/local/bin/claims-desk

# ---------------------------------------------------------------- database
step "Database"
if [ "$NO_DB" -eq 1 ]; then
  info "stage 4 is active: the API pods use PostgreSQL, this VM does not. Skipped the database check."
elif [ "$KEEP_DB" -eq 1 ]; then
  export CLAIMS_CONFIG="$ETC/api.json"
  admin_cli check-port
  admin_cli migrate
else
  export CLAIMS_DB_HOST="$DB_HOST" CLAIMS_DB_PORT="$DB_PORT" CLAIMS_DB_NAME="$DB_NAME" \
         CLAIMS_DB_USER="$DB_APP_USER" CLAIMS_DB_PASSWORD="$DB_APP_PASSWORD" \
         CLAIMS_DB_SSLMODE="$DB_SSLMODE"
  admin_cli check-port
  if [ -n "${DB_ADMIN_USER:-}" ]; then
    CLAIMS_DB_ADMIN_USER="$DB_ADMIN_USER" CLAIMS_DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-}" \
      CLAIMS_DB_ADMIN_DB="${DB_ADMIN_DB:-postgres}" admin_cli bootstrap
  fi
  admin_cli migrate
  CLAIMS_API_URL="http://127.0.0.1:8000" CLAIMS_SITE_NAME="$SITE_NAME" CLAIMS_ENVIRONMENT="$ENVIRONMENT" \
    admin_cli write-config --api "$ETC/api.json.new" --web "$ETC/web.json.new"
  mv "$ETC/api.json.new" "$ETC/api.json"
  mv "$ETC/web.json.new" "$ETC/web.json"
  export CLAIMS_CONFIG="$ETC/api.json"
fi
chown root:"$SVC_USER" "$ETC"/api.json "$ETC"/web.json
chmod 0640 "$ETC"/api.json "$ETC"/web.json
unset DB_ADMIN_PASSWORD CLAIMS_DB_PASSWORD
if [ "$NO_DB" -eq 0 ]; then
  admin_cli check
fi

# ---------------------------------------------------------------- TLS
step "TLS certificate"
if [ -n "${TLS_CERT:-}" ] && [ -n "${TLS_KEY:-}" ]; then
  install -m 0644 "$TLS_CERT" "$CERT"
  install -m 0600 "$TLS_KEY" "$KEY"
  info "installed the certificate from $TLS_CERT"
elif [ -f "$CERT" ] && [ -f "$KEY" ]; then
  info "keeping $CERT"
else
  IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  SAN="DNS:${SERVER_NAME},DNS:$(hostname -s)${IP:+,IP:$IP}"
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 -sha256 \
    -subj "/O=Claims Desk demo/CN=${SERVER_NAME}" -addext "subjectAltName=${SAN}" \
    -keyout "$KEY" -out "$CERT" 2>/dev/null
  chmod 0600 "$KEY"
  info "self-signed certificate for ${SAN}"
fi
if command -v restorecon >/dev/null; then restorecon -q "$CERT" "$KEY" || true; fi

# ---------------------------------------------------------------- nginx
step "nginx"
[ -f /etc/nginx/nginx.conf.claims-desk.orig ] || cp -p /etc/nginx/nginx.conf /etc/nginx/nginx.conf.claims-desk.orig
sed -e "s|@SERVER_NAME@|${SERVER_NAME}|g" -e "s|@TLS_CERT@|${CERT}|g" -e "s|@TLS_KEY@|${KEY}|g" \
    -e "s|@WEB_UPSTREAM@|127.0.0.1:8080|g" -e "s|@API_UPSTREAM@|127.0.0.1:8000|g" \
    "$BUNDLE/deploy/nginx/nginx.conf.tmpl" > /etc/nginx/nginx.conf
nginx -t -q || die "nginx configuration test failed"
info "/etc/nginx/nginx.conf written (original kept as nginx.conf.claims-desk.orig)"

# ---------------------------------------------------------------- SELinux, firewall
step "SELinux and firewall"
if command -v getenforce >/dev/null && [ "$(getenforce)" != "Disabled" ]; then
  if [ "$(getsebool httpd_can_network_connect | awk '{print $3}')" != "on" ]; then
    setsebool -P httpd_can_network_connect 1
  fi
  info "SELinux $(getenforce): httpd_can_network_connect on (nginx to 127.0.0.1:8000/8080)"
else
  info "SELinux disabled"
fi
if systemctl is-active -q firewalld; then
  firewall-cmd -q --permanent --add-service=http --add-service=https
  firewall-cmd -q --reload
  info "firewalld: http and https open"
else
  info "firewalld not running: make sure TCP 80 and 443 reach this VM"
fi

# ---------------------------------------------------------------- services
step "Services"
install -m 0644 "$BUNDLE/deploy/systemd/claims-api.service" /etc/systemd/system/claims-api.service
install -m 0644 "$BUNDLE/deploy/systemd/claims-web.service" /etc/systemd/system/claims-web.service
systemctl daemon-reload
if [ "$NO_DB" -eq 1 ]; then
  systemctl enable -q claims-web nginx
  systemctl restart claims-web
  systemctl restart nginx
  info "claims-web and nginx restarted; claims-api stays off while the API pods serve stage 4"
else
  systemctl enable -q claims-api claims-web nginx
  systemctl restart claims-api claims-web
  systemctl restart nginx
  info "claims-api, claims-web and nginx enabled and started"
fi

if [ "$SEED_COUNT" -gt 0 ] && [ "$NO_DB" -eq 0 ]; then
  admin_cli seed "$SEED_COUNT" --if-empty
fi

# ---------------------------------------------------------------- smoke test
step "End-to-end check"
ok=0
for _ in $(seq 1 20); do
  if curl -skf --max-time 5 https://127.0.0.1/healthz >/dev/null; then ok=1; break; fi
  sleep 1
done
if [ "$ok" -eq 1 ]; then
  info "web     $(curl -sk https://127.0.0.1/healthz)"
  if [ "$NO_DB" -eq 0 ]; then
    info "api     $(curl -sk https://127.0.0.1/api/v1/health)"
  fi
else
  warn "health check failed: $(curl -sk https://127.0.0.1/healthz || echo 'no response')"
  warn "see: sudo claims-desk logs"
  exit 1
fi

step "DNS"
SHORT="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
IP="$(local_ipv4)"
DNS_PUBLISHED=""
if [[ "$SHORT" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
  dns_upsert "${SHORT}.${DNS_ZONE}" "$IP"
else
  warn "host name '${SHORT}' is not a DNS label. Skipped the A record."
fi

if [ "${CLAIMS_UPDATE_FOLLOW:-}" = "1" ]; then
  info "portal tier is in place"
  if [ "${GENERATED_PW:-0}" -eq 1 ]; then
    echo "  App password  generated; stored only in ${ETC}/api.json"
  fi
  exit 0
fi

cat <<EOF

$(printf '\033[1;32m')Claims Desk stage 1 is running.$(printf '\033[0m')

  Portal        https://${SERVER_NAME}/   (or https://${IP}/)
  Architecture  https://${SERVER_NAME}/about
  API           https://${SERVER_NAME}/api/v1/claims   docs: /api/docs
  DNS           ${DNS_PUBLISHED:-not updated} on ${DNS_SERVER}
  Helper        sudo claims-desk status | check | info | seed N | reset | logs
  Settings      ${ETC}/api.json (database), ${ETC}/web.json (web tier)
EOF
if [ "${GENERATED_PW:-0}" -eq 1 ]; then
  echo "  App password  generated; stored only in ${ETC}/api.json"
fi
