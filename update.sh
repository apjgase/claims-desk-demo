#!/usr/bin/env bash
# Claims Desk updater. One bundle, every stage. Re-run it from the same directory.
#
#   sudo ./update.sh --stage N
#   sudo ./update.sh --stage 4 --kubeconfig FILE
#   sudo LLM_API_KEY=... ./update.sh --stage 5
#
# --stage N selects the active path and the architecture diagram.
# The database address stays as configured. A lower stage stops using a later
# tier and does not remove it: the document VM, its keys, and any pods stay.
# The first --stage 3 installs the document VM. Later --stage 3 only selects it.
# The first --stage 4 deploys the API pods with Helm, using the kubeconfig.
# Later --stage 4 selects them, and upgrades them when this bundle is newer.
# The first --stage 5 adds the chat pods to the same release. Later --stage 5 selects them.
set -euo pipefail
umask 022

BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX=/opt/claims-desk
ETC=/etc/claims-desk
SECRET=/root/.claims-desk-stage3
SVC_USER=claimsdesk
PY=python3.11
LOG=/var/log/claims-desk-install.log
DOC_PORT=8090

STAGE=1
APPLY=0
CONFIG=""
RECONFIGURE=0
ASSUME_YES=0
SEED_ARG=""
DOC_HOST="${DOC_HOST:-}"
DOC_SSH_USER="${DOC_SSH_USER:-root}"
DOC_SSH_KEY="${DOC_SSH_KEY:-}"
DOC_SSH_PASSWORD="${DOC_SSH_PASSWORD:-}"
NFS_EXPORT="${NFS_EXPORT:-}"
NFS_MOUNT="${NFS_MOUNT:-/mnt/claims-docs}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_BUCKET="${S3_BUCKET:-claims}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${S3_SECRET_KEY:-}"
S3_REGION="${S3_REGION:-us-east-1}"
DNS_SERVER="${DNS_SERVER:-10.55.19.6}"
DNS_ZONE="${DNS_ZONE:-ntnxlab.local}"
POD_API_URL="${POD_API_URL:-}"
LOCAL_API_URL=http://127.0.0.1:8000
NGINX_CONF=/etc/nginx/nginx.conf

# Stage 4: API pods on NKP.
KUBE_DIR=/root/.claims-desk
KUBECONFIG_SAVED="$KUBE_DIR/kubeconfig"
STAGE4_STATE="$KUBE_DIR/stage4"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-}"
K8S_NAMESPACE="${K8S_NAMESPACE:-}"
STAGE4_LB_IP="${STAGE4_LB_IP:-}"
STAGE4_RUN_AS_UID="${STAGE4_RUN_AS_UID:-}"
STAGE4_RUN_AS_GID="${STAGE4_RUN_AS_GID:-}"
IMAGE="${IMAGE:-}"
RELEASE=claims-desk
POD_PORT=8443
KUBECTL_MINOR=1.35
KUBECTL_FALLBACK=v1.35.2
HELM_VERSION=v3.16.4
CHART="$BUNDLE/deploy/helm/claims-desk"

# Stage 5: chat pods and the OpenAI-compatible (NAI) endpoint.
STAGE5_STATE="$KUBE_DIR/stage5"
CHAT_SECRET=claims-desk-chat
LLM_BASE_URL="${LLM_BASE_URL:-}"
LLM_API_KEY="${LLM_API_KEY:-}"
LLM_MODEL="${LLM_MODEL:-}"
LLM_VISION_MODEL="${LLM_VISION_MODEL:-}"
LLM_VERIFY_TLS="${LLM_VERIFY_TLS:-}"
CHAT_LB_IP="${CHAT_LB_IP:-}"
CHAT_URL="${CHAT_URL:-}"
STAGE5_SECRET_HASH=""
LOCAL_CHAT_UPSTREAM=127.0.0.1:8100

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --stage N        1 to 5. Selects the active path and diagram. Does not remove later tiers.
  --kubeconfig F   stage 4 and 5: kubeconfig of the NKP cluster; kept in /root/.claims-desk (0600)
  --config FILE    settings file (see claims-desk.conf.example)
  --reconfigure    ask for the database, document and LLM settings again; redeploy the pods
  --seed N         sample claims on an empty table (default 12, 0 = none)
  -y, --yes        do not ask for confirmation
  -h, --help       this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --stage) STAGE="${2:?--stage needs a number}"; shift 2 ;;
    --apply-documents) APPLY=1; shift ;;
    --kubeconfig) KUBECONFIG_FILE="${2:?--kubeconfig needs a file}"; shift 2 ;;
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

ask_secret() {
  local var="$1" prompt="$2" reply
  if [ -n "${!1:-}" ] || [ "$INTERACTIVE" -eq 0 ]; then return 0; fi
  read -r -s -p "   $prompt: " reply
  echo
  printf -v "$var" '%s' "$reply"
}

# Same as ask_secret, but the console echoes each character. Used for the Objects keys.
ask_echo() {
  local var="$1" prompt="$2" reply
  if [ -n "${!1:-}" ] || [ "$INTERACTIVE" -eq 0 ]; then return 0; fi
  read -r -p "   $prompt: " reply
  printf -v "$var" '%s' "$reply"
}

ask_yes() {
  local prompt="$1" def="${2:-Y}" reply
  [ "$INTERACTIVE" -eq 1 ] || { [ "$def" = "Y" ]; return; }
  [ "$ASSUME_YES" -eq 1 ] && return 0
  read -r -p "   $prompt [${def}/$([ "$def" = Y ] && echo n || echo y)]: " reply
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy] ]]
}

valid_ipv4() {
  local ip="$1" oct
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for oct in "${BASH_REMATCH[@]:1}"; do
    [ "$((10#$oct))" -le 255 ] || return 1
  done
}

valid_nfs_host() {
  local host="$1"
  # A dotted quad is an address, not a hostname, so 999.1.1.1 is rejected.
  if [[ "$host" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    if valid_ipv4 "$host"; then
      return 0
    fi
    return 1
  fi
  [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

valid_nfs_export() {
  local spec="$1" host path
  [[ "$spec" == *:* ]] || return 1
  host="${spec%%:*}"
  path="${spec#*:}"
  valid_nfs_host "$host" || return 1
  [[ "$path" == /* && "$path" != *" "* && "$path" != *..* ]]
}

# Hostname and the address it resolves to count as the same export.
nfs_host_key() {
  local host="" resolved=""
  host="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if valid_ipv4 "$host"; then
    printf '%s' "$host"
    return 0
  fi
  resolved="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
  printf '%s' "${resolved:-$host}"
}

nfs_same() {
  local a="$1" b="$2" ah ap bh bp
  [ -n "$a" ] && [ -n "$b" ] || return 1
  ah="${a%%:*}"; ap="${a#*:}"; ap="${ap%/}"
  bh="${b%%:*}"; bp="${b#*:}"; bp="${bp%/}"
  [ "$ap" = "$bp" ] || return 1
  [ "$(nfs_host_key "$ah")" = "$(nfs_host_key "$bh")" ]
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
}

ssh_run() {
  local -a opts
  opts=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/root/.ssh/known_hosts
        -o ConnectTimeout=15 -o ServerAliveInterval=15)
  if [ -n "$DOC_SSH_KEY" ]; then
    opts+=(-i "$DOC_SSH_KEY" -o IdentitiesOnly=yes)
  fi
  if [ -n "$DOC_SSH_PASSWORD" ]; then
    opts+=(-o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1)
    # shellcheck disable=SC2029 # arguments are for ssh, expanded on this machine
    SSHPASS="$DOC_SSH_PASSWORD" sshpass -e ssh "${opts[@]}" "${DOC_SSH_USER}@${DOC_HOST}" "$@"
  else
    opts+=(-o BatchMode=yes)
    # shellcheck disable=SC2029
    ssh "${opts[@]}" "${DOC_SSH_USER}@${DOC_HOST}" "$@"
  fi
}

remote_root() {
  if [ "$DOC_SSH_USER" = "root" ]; then
    ssh_run "$@"
  else
    ssh_run sudo -n "$@"
  fi
}

install_code() {
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
  if [ ! -x "$PREFIX/venv/bin/python" ]; then
    "$PY" -m venv "$PREFIX/venv"
  fi
  if [ -d "$BUNDLE/vendor/wheels" ]; then
    info "installing Python packages from the bundled wheels (offline)"
    "$PREFIX/venv/bin/pip" install -q --no-index --find-links "$BUNDLE/vendor/wheels" \
      -r "$PREFIX/app/requirements.txt" -c "$PREFIX/app/constraints.txt"
  else
    info "installing Python packages from ${PIP_INDEX_URL:-PyPI}"
    "$PREFIX/venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1 || true
    "$PREFIX/venv/bin/pip" install -q -r "$PREFIX/app/requirements.txt" -c "$PREFIX/app/constraints.txt" \
      || die "pip could not download packages. Use the offline bundle, or set PIP_INDEX_URL."
  fi
  "$PREFIX/venv/bin/python" -m compileall -q "$PREFIX/app" >/dev/null
}

apply_documents() {
  step "Preflight"
  [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 --stage 3 --apply-documents --config FILE"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in rocky|rhel|almalinux|centos) ;; *) die "unsupported OS ${PRETTY_NAME:-unknown}" ;; esac
  [ "${VERSION_ID%%.*}" = "9" ] || die "unsupported OS version ${VERSION_ID}: needs Rocky Linux 9 or RHEL 9"
  exec > >(tee -a "$LOG") 2>&1
  info "${PRETTY_NAME}, host $(hostname -f 2>/dev/null || hostname)"

  [ -n "$NFS_EXPORT" ] || die "NFS_EXPORT is required"
  valid_nfs_export "$NFS_EXPORT" \
    || die "NFS_EXPORT must look like labFS.ntnxlab.local:/documents or 10.10.140.11:/claims-docs"
  [ -n "$S3_ENDPOINT" ] || die "S3_ENDPOINT is required"
  [ -n "$S3_BUCKET" ] || die "S3_BUCKET is required"
  [ -n "$S3_ACCESS_KEY" ] || die "S3_ACCESS_KEY is required"
  [ -n "$S3_SECRET_KEY" ] || die "S3_SECRET_KEY is required"
  [[ "$NFS_MOUNT" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "NFS_MOUNT must be an absolute path"
  [[ "$NFS_MOUNT" == *..* ]] && die "NFS_MOUNT must not contain .."

  step "Packages"
  # curl is checked by command: Rocky ships curl-minimal, which conflicts with the curl package.
  local missing=()
  for p in "$PY" "${PY}-pip" nfs-utils openssl tar; do
    rpm -q "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  if [ ${#missing[@]} -gt 0 ]; then
    info "installing ${missing[*]}"
    dnf -y -q install "${missing[@]}" \
      || die "dnf could not install ${missing[*]}. The VM needs BaseOS and AppStream."
  else
    info "python, nfs-utils and curl already installed"
  fi

  step "Application"
  install_code
  info "code in $PREFIX/app"

  step "NFS"
  info "NFSv3 ${NFS_EXPORT} -> ${NFS_MOUNT}"
  local nfs_host="${NFS_EXPORT%%:*}"
  if ! valid_ipv4 "$nfs_host"; then
    getent ahostsv4 "$nfs_host" >/dev/null \
      || die "cannot resolve ${nfs_host} from this VM. Check /etc/resolv.conf."
  fi
  mkdir -p "$NFS_MOUNT"
  local current=""
  if mountpoint -q "$NFS_MOUNT"; then
    current="$(findmnt -n -o SOURCE "$NFS_MOUNT" || true)"
  fi
  if ! nfs_same "$current" "$NFS_EXPORT"; then
    if mountpoint -q "$NFS_MOUNT"; then
      umount "$NFS_MOUNT" || die "could not unmount ${NFS_MOUNT} (mounted from ${current:-unknown})"
    fi
    timeout 30 mount -t nfs -o vers=3,proto=tcp,hard,timeo=600,retrans=2,nolock \
      "$NFS_EXPORT" "$NFS_MOUNT" \
      || die "could not mount ${NFS_EXPORT} on ${NFS_MOUNT}. Check the Files name, export path, and TCP 2049 from this VM."
  fi
  local fstab_line="${NFS_EXPORT} ${NFS_MOUNT} nfs vers=3,proto=tcp,hard,timeo=600,retrans=2,nolock,_netdev 0 0"
  grep -v " ${NFS_MOUNT} " /etc/fstab > /etc/fstab.claims-desk.tmp || true
  printf '%s\n' "$fstab_line" >> /etc/fstab.claims-desk.tmp
  mv /etc/fstab.claims-desk.tmp /etc/fstab
  local uid
  uid="$(id -u "$SVC_USER")"
  if ! runuser -u "$SVC_USER" -- /bin/sh -c \
      "touch '${NFS_MOUNT}/.claims-desk-write-test' && rm -f '${NFS_MOUNT}/.claims-desk-write-test'"; then
    die "user ${SVC_USER} (uid ${uid}) cannot create a file on ${NFS_MOUNT}. The NFSv3 export must allow that uid to write."
  fi
  info "write test as ${SVC_USER} (uid ${uid}) succeeded"
  if command -v getenforce >/dev/null && [ "$(getenforce)" != "Disabled" ]; then
    warn "SELinux is $(getenforce). deploy/cloud-init/document-vm.yaml disables it. NFS writes from the service can be denied while it is enforcing."
  fi

  step "Objects"
  info "endpoint ${S3_ENDPOINT}  bucket ${S3_BUCKET}  TLS verification off"
  local tmpjson
  tmpjson="$(mktemp /tmp/claims-docs.XXXXXX.json)"
  chmod 600 "$tmpjson"
  NFS_EXPORT="$NFS_EXPORT" NFS_MOUNT="$NFS_MOUNT" S3_ENDPOINT="$S3_ENDPOINT" \
    S3_BUCKET="$S3_BUCKET" S3_ACCESS_KEY="$S3_ACCESS_KEY" S3_SECRET_KEY="$S3_SECRET_KEY" \
    S3_REGION="$S3_REGION" CLAIMS_JSON="$tmpjson" \
    "$PREFIX/venv/bin/python" - <<'PY'
import json, os
data = {
    "nfs_export": os.environ["NFS_EXPORT"],
    "nfs_mount": os.environ["NFS_MOUNT"],
    "s3_endpoint": os.environ["S3_ENDPOINT"],
    "s3_bucket": os.environ["S3_BUCKET"],
    "s3_access_key": os.environ["S3_ACCESS_KEY"],
    "s3_secret_key": os.environ["S3_SECRET_KEY"],
    "s3_region": os.environ["S3_REGION"],
    "s3_verify_tls": False,
}
fd = os.open(os.environ["CLAIMS_JSON"], os.O_WRONLY | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
  CLAIMS_CONFIG="$tmpjson" PYTHONPATH="$PREFIX/app" \
    "$PREFIX/venv/bin/python" -m claimsdesk.docs check
  install -m 0640 -o root -g "$SVC_USER" "$tmpjson" "$ETC/docs.json"
  rm -f "$tmpjson"
  info "settings in $ETC/docs.json"

  step "Service"
  sed "s|@NFS_MOUNT@|${NFS_MOUNT}|g" "$BUNDLE/deploy/systemd/claims-docs.service" \
    > /etc/systemd/system/claims-docs.service
  if systemctl is-active -q firewalld; then
    firewall-cmd -q --permanent --add-port="${DOC_PORT}/tcp"
    firewall-cmd -q --reload
    info "firewalld: TCP ${DOC_PORT} open"
  else
    info "firewalld not running: make sure TCP ${DOC_PORT} reaches this VM from the portal"
  fi
  systemctl daemon-reload
  systemctl enable -q claims-docs
  systemctl restart claims-docs
  local ok=0 body
  for _ in $(seq 1 20); do
    if body="$(curl -fsS --max-time 3 "http://127.0.0.1:${DOC_PORT}/health" 2>/dev/null)"; then
      ok=1
      break
    fi
    sleep 1
  done
  [ "$ok" -eq 1 ] || die "claims-docs did not become healthy: journalctl -u claims-docs"
  info "health ${body}"
  printf '%s\n' 3 > "$ETC/stage"

  if [ "${CONFIG:-}" = "/tmp/claims-docs.conf" ]; then
    rm -f /tmp/claims-docs.conf
  fi
  echo
  info "document service is listening on 0.0.0.0:${DOC_PORT}"
}

save_secret() {
  umask 077
  {
    printf 'DOC_HOST=%q\n' "$DOC_HOST"
    printf 'DOC_SSH_USER=%q\n' "$DOC_SSH_USER"
    printf 'DOC_SSH_KEY=%q\n' "$DOC_SSH_KEY"
    printf 'NFS_EXPORT=%q\n' "$NFS_EXPORT"
    printf 'NFS_MOUNT=%q\n' "$NFS_MOUNT"
    printf 'S3_ENDPOINT=%q\n' "$S3_ENDPOINT"
    printf 'S3_BUCKET=%q\n' "$S3_BUCKET"
    printf 'S3_ACCESS_KEY=%q\n' "$S3_ACCESS_KEY"
    printf 'S3_SECRET_KEY=%q\n' "$S3_SECRET_KEY"
    printf 'S3_REGION=%q\n' "$S3_REGION"
    printf 'DNS_SERVER=%q\n' "$DNS_SERVER"
    printf 'DNS_ZONE=%q\n' "$DNS_ZONE"
  } > "$SECRET"
  umask 022
  info "saved for the next run in ${SECRET} (root only, not read by the portal app)"
}

ensure_ssh() {
  install -d -m 700 /root/.ssh
  command -v ssh >/dev/null 2>&1 || dnf -y -q install openssh-clients \
    || die "could not install openssh-clients"
  if [ -z "$DOC_SSH_KEY" ] && [ -f /root/.ssh/claims-desk-lab ]; then
    DOC_SSH_KEY=/root/.ssh/claims-desk-lab
    info "using ${DOC_SSH_KEY}"
  fi
  if [ -n "$DOC_SSH_KEY" ] && [ ! -f "$DOC_SSH_KEY" ]; then
    die "SSH key not found: ${DOC_SSH_KEY}"
  fi
  if timeout 5 bash -c "echo >/dev/tcp/${DOC_HOST}/22" 2>/dev/null; then
    info "TCP 22 on ${DOC_HOST} is open"
  else
    die "cannot reach ${DOC_HOST} on TCP 22 from this VM"
  fi
  if [ -z "$DOC_SSH_PASSWORD" ] && ssh_run true; then
    info "SSH key login as ${DOC_SSH_USER}@${DOC_HOST} succeeded"
    return 0
  fi
  if [ -z "$DOC_SSH_PASSWORD" ] && [ "$INTERACTIVE" -eq 1 ]; then
    ask_secret DOC_SSH_PASSWORD "SSH password for ${DOC_SSH_USER}@${DOC_HOST}"
  fi
  if [ -z "$DOC_SSH_PASSWORD" ]; then
    die "cannot log in to ${DOC_SSH_USER}@${DOC_HOST}. Put the lab private key at /root/.ssh/claims-desk-lab (mode 600), or rerun and enter the password. The document VM cloud-init sets a root password."
  fi
  command -v sshpass >/dev/null 2>&1 || dnf -y -q install sshpass || die "sshpass is required for password login"
  ssh_run true || die "SSH password login to ${DOC_SSH_USER}@${DOC_HOST} failed"
  info "SSH password login as ${DOC_SSH_USER}@${DOC_HOST} succeeded"
}

portal_stage3() {
  local install_args=()
  [ -n "$CONFIG" ] && install_args+=(--config "$CONFIG")
  [ "$RECONFIGURE" -eq 1 ] && install_args+=(--reconfigure)
  [ -n "$SEED_ARG" ] && install_args+=(--seed "$SEED_ARG")
  [ "$ASSUME_YES" -eq 1 ] && install_args+=(-y)
  CLAIMS_UPDATE_FOLLOW=1 "$BUNDLE/install.sh" "${install_args[@]}"
  exec > >(tee -a "$LOG") 2>&1

  if [ -z "$CONFIG" ] && [ -f "$SECRET" ]; then
    # shellcheck disable=SC1090
    . "$SECRET"
    info "reusing document settings from ${SECRET} (--reconfigure asks again)"
  fi
  if [ "$RECONFIGURE" -eq 1 ] && [ -z "$CONFIG" ]; then
    S3_ACCESS_KEY=""
    S3_SECRET_KEY=""
    DOC_SSH_PASSWORD=""
  fi

  step "Document VM"
  if [ "$INTERACTIVE" -eq 1 ]; then
    info "This run logs into the document VM over SSH and installs the document service there."
    info "NFSv3, for example labFS.ntnxlab.local:/documents. Objects TLS is not verified."
  fi
  ask DOC_HOST "Document VM IP"
  valid_ipv4 "$DOC_HOST" || die "Document VM IP must be an IPv4 address"
  ask DOC_SSH_USER "SSH user on the document VM" root
  [[ "$DOC_SSH_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "SSH user must be a short account name"
  ask DOC_SSH_KEY "SSH private key (Enter tries the agent, then /root/.ssh/claims-desk-lab)" ""
  ask NFS_EXPORT "NFS export, host:/path"
  valid_nfs_export "$NFS_EXPORT" \
    || die "NFS export must look like labFS.ntnxlab.local:/documents or 10.10.140.11:/claims-docs"
  local nfs_host="${NFS_EXPORT%%:*}"
  if ! valid_ipv4 "$nfs_host"; then
    getent ahostsv4 "$nfs_host" >/dev/null \
      || die "cannot resolve ${nfs_host} from this VM. Check /etc/resolv.conf."
  fi
  ask NFS_MOUNT "Mount point on the document VM" /mnt/claims-docs
  [[ "$NFS_MOUNT" =~ ^/[A-Za-z0-9._/-]+$ && "$NFS_MOUNT" != *..* ]] || die "mount point must be an absolute path"
  ask S3_ENDPOINT "Objects endpoint URL"
  S3_ENDPOINT="${S3_ENDPOINT%/}"
  [[ "$S3_ENDPOINT" =~ ^https?://[^[:space:]]+$ ]] || die "Objects endpoint must be an http(s) URL"
  ask S3_BUCKET "Bucket" claims
  [[ "$S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "bucket name '$S3_BUCKET' is not a DNS-style bucket name"
  ask_echo S3_ACCESS_KEY "Objects access key"
  ask_echo S3_SECRET_KEY "Objects secret key"
  [ -n "$S3_ACCESS_KEY" ] || die "Objects access key is required"
  [ -n "$S3_SECRET_KEY" ] || die "Objects secret key is required"
  S3_REGION="${S3_REGION:-us-east-1}"

  echo
  info "Document VM  ${DOC_SSH_USER}@${DOC_HOST}  service :${DOC_PORT}"
  info "Files        ${NFS_EXPORT}  mounted at ${NFS_MOUNT}  (NFSv3)"
  info "Objects      ${S3_ENDPOINT}  bucket ${S3_BUCKET}  TLS verification off"
  ask_yes "Install the document service on ${DOC_HOST}?" Y || die "cancelled"

  step "SSH to the document VM"
  ensure_ssh
  if [ "$DOC_SSH_USER" != "root" ]; then
    ssh_run sudo -n true || die "SSH user ${DOC_SSH_USER} needs passwordless sudo, or log in as root"
  fi

  step "DNS"
  local doc_short
  doc_short="$(ssh_run hostname -s | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  [[ "$doc_short" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
    || die "document VM host name '${doc_short}' is not a DNS label"
  dns_upsert "${doc_short}.${DNS_ZONE}" "$DOC_HOST"
  save_secret

  step "Copy the bundle"
  local portal_cfg remote_src
  portal_cfg="$(mktemp /tmp/claims-desk-stage3.XXXXXX)"
  chmod 600 "$portal_cfg"
  {
    printf 'NFS_EXPORT=%q\n' "$NFS_EXPORT"
    printf 'NFS_MOUNT=%q\n' "$NFS_MOUNT"
    printf 'S3_ENDPOINT=%q\n' "$S3_ENDPOINT"
    printf 'S3_BUCKET=%q\n' "$S3_BUCKET"
    printf 'S3_ACCESS_KEY=%q\n' "$S3_ACCESS_KEY"
    printf 'S3_SECRET_KEY=%q\n' "$S3_SECRET_KEY"
    printf 'S3_REGION=%q\n' "$S3_REGION"
  } > "$portal_cfg"
  ssh_run "cat > /tmp/claims-docs.conf && chmod 600 /tmp/claims-docs.conf" < "$portal_cfg"
  rm -f "$portal_cfg"
  remote_src=/tmp/claims-desk-src
  tar -C "$BUNDLE" -czf - \
    --exclude='./.git' --exclude='./dist' --exclude='__pycache__' --exclude='.pytest_cache' . \
    | ssh_run "rm -rf '${remote_src}' && mkdir -p '${remote_src}' && tar -xzf - -C '${remote_src}' && chmod 755 '${remote_src}/update.sh'"

  step "Install on the document VM"
  remote_root "${remote_src}/update.sh" --stage 3 --apply-documents --config /tmp/claims-docs.conf -y
  ssh_run "rm -f /tmp/claims-docs.conf" || true

  step "Point the portal at the document VM"
  CLAIMS_DOCS_URL="http://${DOC_HOST}:${DOC_PORT}" "$PREFIX/venv/bin/python" - <<'PY'
import json, os
url = os.environ["CLAIMS_DOCS_URL"]

def merge(path, updates):
    with open(path) as fh:
        data = json.load(fh)
    data.update(updates)
    fd = os.open(path, os.O_WRONLY | os.O_TRUNC)
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")

merge("/etc/claims-desk/api.json", {"docs_url": url, "docs_timeout": 60, "stage": 3})
merge("/etc/claims-desk/web.json", {
    "stage": 3, "api_timeout": 60, "api_url": "http://127.0.0.1:8000"})
PY
  printf '%s\n' 3 > "$ETC/stage"
  systemctl restart claims-api claims-web
  info "portal calls ${DOC_HOST}:${DOC_PORT}. Objects keys stay on the document VM."

  step "End-to-end check"
  local body
  body="$(curl -fsS --max-time 10 "http://${DOC_HOST}:${DOC_PORT}/health")" \
    || die "portal cannot reach http://${DOC_HOST}:${DOC_PORT}/health. Open TCP ${DOC_PORT} from the portal to the document VM."
  printf '%s' "$body" | "$PREFIX/venv/bin/python" -c \
    'import json,sys; b=json.load(sys.stdin); assert b.get("status")=="ok", b' \
    || die "document VM health is not ok: ${body}"
  info "document  ${body}"
  local info_body="" ok=0
  for _ in $(seq 1 20); do
    if info_body="$(curl -skf --max-time 10 https://127.0.0.1/api/v1/info 2>/dev/null)"; then
      if printf '%s' "$info_body" | "$PREFIX/venv/bin/python" -c \
          'import json,sys; b=json.load(sys.stdin); raise SystemExit(0 if b.get("documents",{}).get("status")=="ok" else 1)'; then
        ok=1
        break
      fi
    fi
    sleep 1
  done
  [ "$ok" -eq 1 ] || die "portal /api/v1/info does not report the document VM: ${info_body:-no response}"
  local name ip
  name="$(hostname -f 2>/dev/null || hostname)"
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  cat <<EOF

$(printf '\033[1;32m')Claims Desk stage 3 is running.$(printf '\033[0m')

  Portal        https://${name}/   ${ip:+(or https://${ip}/)}
  Architecture  https://${name}/about
  Document VM   http://${DOC_HOST}:${DOC_PORT}/health
  DNS           $(hostname -s).${DNS_ZONE} and ${doc_short}.${DNS_ZONE} on ${DNS_SERVER}
  Files         ${NFS_EXPORT} on the document VM at ${NFS_MOUNT} (NFSv3)
  Objects       ${S3_ENDPOINT}  bucket ${S3_BUCKET}  (TLS verification off)
  Photo         optional, stored on Files when the claim is submitted
  Packet        stored on Objects when the claim is moved to APPROVED
  Settings      ${ETC}/api.json holds the document VM URL, not the keys
                ${SECRET} on this VM (root only) is how the next update logs in again
EOF
}

# ---------------------------------------------------------------- stage 4: API pods

kc() { kubectl --kubeconfig "$KUBECONFIG_SAVED" "$@"; }
hm() { helm --kubeconfig "$KUBECONFIG_SAVED" "$@"; }

bundle_version() {
  sed -n 's/^__version__ = "\(.*\)"/\1/p' "$BUNDLE/app/claimsdesk/__init__.py"
}

active_stage() {
  local s=""
  [ -f "$ETC/stage" ] && s="$(tr -dc '0-9' < "$ETC/stage")"
  printf '%s' "${s:-1}"
}

load_stage4_state() {
  local ns="$K8S_NAMESPACE" lb="$STAGE4_LB_IP" uid="$STAGE4_RUN_AS_UID" gid="$STAGE4_RUN_AS_GID" img="$IMAGE"
  if [ -f "$STAGE4_STATE" ]; then
    # shellcheck disable=SC1090
    . "$STAGE4_STATE"
  fi
  # Values from the command line or --config win over the saved ones.
  K8S_NAMESPACE="${ns:-${K8S_NAMESPACE:-claims}}"
  STAGE4_LB_IP="${lb:-${STAGE4_LB_IP:-}}"
  STAGE4_RUN_AS_UID="${uid:-${STAGE4_RUN_AS_UID:-}}"
  STAGE4_RUN_AS_GID="${gid:-${STAGE4_RUN_AS_GID:-}}"
  IMAGE="${img:-${IMAGE:-}}"
}

save_stage4_state() {
  install -d -m 700 "$KUBE_DIR"
  umask 077
  {
    printf 'K8S_NAMESPACE=%q\n' "$K8S_NAMESPACE"
    printf 'STAGE4_LB_IP=%q\n' "$STAGE4_LB_IP"
    printf 'STAGE4_RUN_AS_UID=%q\n' "$STAGE4_RUN_AS_UID"
    printf 'STAGE4_RUN_AS_GID=%q\n' "$STAGE4_RUN_AS_GID"
    printf 'IMAGE=%q\n' "$IMAGE"
  } > "$STAGE4_STATE"
  umask 022
}

have_kubeconfig() { [ -n "$KUBECONFIG_FILE" ] || [ -f "$KUBECONFIG_SAVED" ]; }

save_kubeconfig() {
  install -d -m 700 "$KUBE_DIR"
  if [ -z "$KUBECONFIG_FILE" ] && [ ! -f "$KUBECONFIG_SAVED" ]; then
    ask KUBECONFIG_FILE "Kubeconfig of the NKP cluster (path on this VM)"
  fi
  if [ -n "$KUBECONFIG_FILE" ]; then
    [ -r "$KUBECONFIG_FILE" ] || die "kubeconfig not found: ${KUBECONFIG_FILE}"
    grep -q '^clusters:' "$KUBECONFIG_FILE" || die "${KUBECONFIG_FILE} does not look like a kubeconfig (no clusters:)"
    if [ "$(readlink -f "$KUBECONFIG_FILE")" != "$KUBECONFIG_SAVED" ]; then
      install -m 600 "$KUBECONFIG_FILE" "$KUBECONFIG_SAVED"
    fi
    info "kubeconfig saved in ${KUBECONFIG_SAVED} (root only). You can delete ${KUBECONFIG_FILE}."
  fi
  [ -f "$KUBECONFIG_SAVED" ] || die "no kubeconfig. Rerun with --kubeconfig FILE"
}

# download URL FILE; verifies against URL.sha256 or URL.sha256sum when the server has one.
download_verified() {
  local url="$1" out="$2" sum="" ext
  curl -fsSL --retry 3 -o "$out" "$url" || die "could not download ${url}"
  for ext in sha256 sha256sum; do
    if sum="$(curl -fsSL "${url}.${ext}" 2>/dev/null)"; then
      sum="$(printf '%s' "$sum" | awk '{print $1; exit}')"
      break
    fi
    sum=""
  done
  if [ -z "$sum" ]; then
    warn "no checksum published next to ${url}. Not verified."
    return 0
  fi
  echo "${sum}  ${out}" | sha256sum --check --quiet || die "checksum mismatch for ${url}"
}

install_k8s_tools() {
  local tmp ver
  tmp="$(mktemp -d)"
  if ! command -v kubectl >/dev/null 2>&1; then
    ver="$(curl -fsSL "https://dl.k8s.io/release/stable-${KUBECTL_MINOR}.txt" 2>/dev/null || echo "$KUBECTL_FALLBACK")"
    info "installing kubectl ${ver}"
    download_verified "${KUBECTL_URL:-https://dl.k8s.io/release/${ver}/bin/linux/amd64/kubectl}" "$tmp/kubectl"
    install -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl
  fi
  info "kubectl $(kubectl version --client -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null || echo present)"
  if ! command -v helm >/dev/null 2>&1; then
    info "installing helm ${HELM_VERSION}"
    download_verified "${HELM_URL:-https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz}" "$tmp/helm.tgz"
    tar -xzf "$tmp/helm.tgz" -C "$tmp"
    install -m 0755 "$tmp/linux-amd64/helm" /usr/local/bin/helm
  fi
  info "helm $(helm version --short 2>/dev/null || echo present)"
  rm -rf "$tmp"
}

node_ips() {
  kc get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}' 2>/dev/null || true
}

stage4_preflight() {
  local server nodes
  server="$(kc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  info "cluster ${server:-unknown}"
  kc get nodes -o wide >/dev/null 2>&1 \
    || die "cannot reach the cluster at ${server:-the kubeconfig server}. Open TCP 6443 from this VM to the control-plane VIP, and check the kubeconfig."
  kc get nodes -o wide | sed 's/^/   /'
  nodes="$(node_ips)"
  STAGE4_NODE_IPS="${nodes% }"
  if kc get ipaddresspools.metallb.io -A >/dev/null 2>&1; then
    info "MetalLB pools: $(kc get ipaddresspools.metallb.io -A -o jsonpath='{range .items[*]}{.metadata.name}={.spec.addresses}{" "}{end}')"
  else
    warn "no MetalLB IPAddressPool found. The Service needs a load balancer; NKP sets one up from --kubernetes-service-load-balancer-ip-range."
  fi
  info "pods leave the cluster from the node IPs: ${STAGE4_NODE_IPS:-unknown}"
  info "allow them in pg_hba.conf (PostgreSQL) and on the NFS export, read-write"
}

# Fills DB_* from the portal's api.json, and NFS_* / S3_* from the stage 3 settings.
stage4_settings() {
  local line
  line="$(python3 - "$ETC/api.json" <<'PY'
import json, shlex, sys
c = json.load(open(sys.argv[1]))
for key in ("db_host", "db_port", "db_name", "db_user", "db_password", "db_sslmode", "db_schema"):
    print("{}={}".format(key.upper(), shlex.quote(str(c.get(key, "")))))
PY
)" || die "cannot read ${ETC}/api.json"
  eval "$line"
  [ -n "${DB_HOST:-}" ] || die "no database in ${ETC}/api.json. Run stage 1 first."

  if [ -f "$SECRET" ]; then
    # Non-empty values from --config win over the saved stage 3 settings.
    local c_nfs="" c_ep="" c_bucket="" c_ak="" c_sk="" c_host="" c_key=""
    if [ -n "$CONFIG" ]; then
      c_nfs="$NFS_EXPORT" c_ep="$S3_ENDPOINT" c_bucket="$S3_BUCKET" c_ak="$S3_ACCESS_KEY"
      c_sk="$S3_SECRET_KEY" c_host="$DOC_HOST" c_key="$DOC_SSH_KEY"
    fi
    # shellcheck disable=SC1090
    . "$SECRET"
    NFS_EXPORT="${c_nfs:-$NFS_EXPORT}" S3_ENDPOINT="${c_ep:-$S3_ENDPOINT}" S3_BUCKET="${c_bucket:-$S3_BUCKET}"
    S3_ACCESS_KEY="${c_ak:-$S3_ACCESS_KEY}" S3_SECRET_KEY="${c_sk:-$S3_SECRET_KEY}"
    DOC_HOST="${c_host:-$DOC_HOST}" DOC_SSH_KEY="${c_key:-$DOC_SSH_KEY}"
    info "Files and Objects settings from stage 3 (${SECRET})"
  fi
  if [ "$RECONFIGURE" -eq 1 ] && [ -z "$CONFIG" ]; then
    S3_ACCESS_KEY=""
    S3_SECRET_KEY=""
  fi
  if [ "$RECONFIGURE" -eq 1 ] || [ -z "$NFS_EXPORT" ] || [ -z "$S3_ENDPOINT" ] \
      || [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
    info "The API pods take the document role: they mount the share and hold the Objects keys."
    ask NFS_EXPORT "NFS export, host:/path (the same one the document VM uses)"
    ask S3_ENDPOINT "Objects endpoint URL"
    ask S3_BUCKET "Bucket" claims
    ask_echo S3_ACCESS_KEY "Objects access key"
    ask_echo S3_SECRET_KEY "Objects secret key"
  fi
  valid_nfs_export "$NFS_EXPORT" \
    || die "NFS export must look like labFS.ntnxlab.local:/documents or 10.10.140.11:/claims-docs"
  S3_ENDPOINT="${S3_ENDPOINT%/}"
  [[ "$S3_ENDPOINT" =~ ^https?://[^[:space:]]+$ ]] || die "Objects endpoint must be an http(s) URL"
  [[ "$S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "bucket name '$S3_BUCKET' is not a DNS-style bucket name"
  if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
    die "Objects access key and secret key are required"
  fi
  S3_REGION="${S3_REGION:-us-east-1}"

  # Kubelet mounts the export on the node, and the node may not resolve the lab zone.
  NFS_SERVER="${NFS_EXPORT%%:*}"
  NFS_PATH="${NFS_EXPORT#*:}"
  if ! valid_ipv4 "$NFS_SERVER"; then
    local ip=""
    ip="$(getent ahostsv4 "$NFS_SERVER" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
    if valid_ipv4 "$ip"; then
      info "NFS server ${NFS_SERVER} is ${ip}; the pods mount it by address"
      NFS_SERVER="$ip"
    else
      warn "cannot resolve ${NFS_SERVER} here. The nodes must resolve it."
    fi
  fi

  if [ -z "$STAGE4_RUN_AS_UID" ] && [ -n "$DOC_HOST" ]; then
    if [ -z "$DOC_SSH_KEY" ] && [ -f /root/.ssh/claims-desk-lab ]; then
      DOC_SSH_KEY=/root/.ssh/claims-desk-lab
    fi
    local ids=""
    ids="$(DOC_SSH_PASSWORD="" ssh_run 'id -u claimsdesk; id -g claimsdesk' 2>/dev/null | tr '\n' ' ' || true)"
    if [[ "$ids" =~ ^([0-9]+)\ ([0-9]+) ]]; then
      STAGE4_RUN_AS_UID="${BASH_REMATCH[1]}"
      STAGE4_RUN_AS_GID="${BASH_REMATCH[2]}"
      info "claimsdesk on the document VM is uid ${STAGE4_RUN_AS_UID}, gid ${STAGE4_RUN_AS_GID}; the pods use the same"
    fi
  fi
  if [ -z "$STAGE4_RUN_AS_UID" ]; then
    info "NFSv3 sends the numeric uid. Use the uid that owns the files on the share."
    ask STAGE4_RUN_AS_UID "uid for the pods" 10001
  fi
  [[ "$STAGE4_RUN_AS_UID" =~ ^[1-9][0-9]*$ ]] || die "uid must be a positive number (the pods do not run as root)"
  STAGE4_RUN_AS_GID="${STAGE4_RUN_AS_GID:-$STAGE4_RUN_AS_UID}"
  [[ "$STAGE4_RUN_AS_GID" =~ ^[0-9]+$ ]] || die "gid must be a number"

  if [ -n "$STAGE4_LB_IP" ]; then
    valid_ipv4 "$STAGE4_LB_IP" || die "STAGE4_LB_IP must be an IPv4 address"
  fi
  [[ "$K8S_NAMESPACE" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "namespace '${K8S_NAMESPACE}' is not a valid name"
}

# Secret from stdin, never on a command line or in a file. Prints a short hash of it.
stage4_secret() {
  kc get namespace "$K8S_NAMESPACE" >/dev/null 2>&1 || kc create namespace "$K8S_NAMESPACE" >/dev/null
  info "namespace ${K8S_NAMESPACE}"
  local manifest
  manifest="$(K8S_NAMESPACE="$K8S_NAMESPACE" DB_PASSWORD="$DB_PASSWORD" \
    S3_ACCESS_KEY="$S3_ACCESS_KEY" S3_SECRET_KEY="$S3_SECRET_KEY" python3 - <<'PY'
import hashlib, json, os
data = {
    "db-password": os.environ["DB_PASSWORD"],
    "s3-access-key": os.environ["S3_ACCESS_KEY"],
    "s3-secret-key": os.environ["S3_SECRET_KEY"],
}
digest = hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()[:12]
print(digest)
print(json.dumps({
    "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
    "metadata": {"name": "claims-desk", "namespace": os.environ["K8S_NAMESPACE"],
                 "labels": {"app.kubernetes.io/name": "claims-desk"}},
    "stringData": data,
}))
PY
)"
  STAGE4_SECRET_HASH="${manifest%%$'\n'*}"
  printf '%s\n' "${manifest#*$'\n'}" | kc apply -f - >/dev/null || die "could not write Secret claims-desk"
  info "Secret claims-desk (database password, Objects keys)"
}

stage4_values() {
  local out="$1" repo="" tag=""
  tag="$(bundle_version)"
  if [ -n "$IMAGE" ]; then
    if [[ "${IMAGE##*/}" == *:* ]]; then
      repo="${IMAGE%:*}"; tag="${IMAGE##*:}"
    else
      repo="$IMAGE"
    fi
  fi
  REPO="$repo" TAG="$tag" DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_NAME="$DB_NAME" DB_USER="$DB_USER" \
    DB_SSLMODE="$DB_SSLMODE" DB_SCHEMA="$DB_SCHEMA" NFS_SERVER="$NFS_SERVER" NFS_PATH="$NFS_PATH" \
    S3_ENDPOINT="$S3_ENDPOINT" S3_BUCKET="$S3_BUCKET" S3_REGION="$S3_REGION" \
    RUN_UID="$STAGE4_RUN_AS_UID" RUN_GID="$STAGE4_RUN_AS_GID" LB_IP="$STAGE4_LB_IP" \
    SECRET_HASH="$STAGE4_SECRET_HASH" STAGE="$STAGE" POD_PORT="$POD_PORT" OUT="$out" \
    CHAT_VALUES="$(stage5_chat_values)" python3 - <<'PY'
import json, os
e = os.environ
image = {"tag": e["TAG"]}
if e["REPO"]:
    image["repository"] = e["REPO"]
values = {
    "image": image,
    "stage": int(e["STAGE"]),
    "secretHash": e["SECRET_HASH"],
    "db": {"host": e["DB_HOST"], "port": int(e["DB_PORT"]), "name": e["DB_NAME"],
           "user": e["DB_USER"], "sslmode": e["DB_SSLMODE"], "schema": e["DB_SCHEMA"] or "claimsdesk"},
    "nfs": {"server": e["NFS_SERVER"], "path": e["NFS_PATH"]},
    "s3": {"endpoint": e["S3_ENDPOINT"], "bucket": e["S3_BUCKET"], "region": e["S3_REGION"]},
    "runAsUser": int(e["RUN_UID"]),
    "runAsGroup": int(e["RUN_GID"]),
    "service": {"port": int(e["POD_PORT"]), "loadBalancerIP": e["LB_IP"]},
}
# Keeps the stage 5 chat pods in the release when the API pods are redeployed.
if e.get("CHAT_VALUES"):
    values["chat"] = json.loads(e["CHAT_VALUES"])
with open(e["OUT"], "w") as fh:
    json.dump(values, fh, indent=2)
PY
}

stage4_diagnose() {
  local sel="app.kubernetes.io/instance=${RELEASE}" events
  warn "the API pods are not healthy. What the cluster says:"
  kc -n "$K8S_NAMESPACE" get pods -l "$sel" -o wide 2>&1 | sed 's/^/   /' || true
  events="$(kc -n "$K8S_NAMESPACE" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 15 || true)"
  printf '%s\n' "$events" | sed 's/^/   /'
  kc -n "$K8S_NAMESPACE" logs -l "$sel" --all-containers --tail=15 --prefix 2>/dev/null | sed 's/^/   /' || true
  if printf '%s' "$events" | grep -Eq 'ErrImagePull|ImagePullBackOff|manifest unknown'; then
    warn "image pull failed. The nodes need HTTPS to ghcr.io, and the image $(bundle_version) must be published (GitHub Actions on main or a tag). Set IMAGE= to use another one."
  fi
  if printf '%s' "$events" | grep -Eiq 'MountVolume|mount failed|access denied by server|nfs'; then
    warn "NFS mount failed. The export ${NFS_SERVER}:${NFS_PATH} must allow the node IPs (${STAGE4_NODE_IPS:-see kubectl get nodes -o wide}) read-write, and TCP 2049 from the nodes."
  fi
}

stage4_deploy() {
  local values
  values="$(mktemp /tmp/claims-desk-values.XXXXXX.json)"
  stage4_values "$values"
  info "helm upgrade --install ${RELEASE} (image tag $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["image"]["tag"])' "$values"))"
  if ! hm upgrade --install "$RELEASE" "$CHART" -n "$K8S_NAMESPACE" -f "$values" --wait --timeout 10m; then
    rm -f "$values"
    stage4_diagnose
    die "helm could not bring the API pods up. Fix the cause above, then rerun: sudo $0 --stage ${STAGE}"
  fi
  rm -f "$values"
  kc -n "$K8S_NAMESPACE" get pods -l "app.kubernetes.io/instance=${RELEASE}" -o wide | sed 's/^/   /'
}

stage4_wait_lb() {
  local ip="" svc="${RELEASE}-api"
  for _ in $(seq 1 60); do
    ip="$(kc -n "$K8S_NAMESPACE" get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [ -n "$ip" ] && break
    sleep 2
  done
  [ -n "$ip" ] || die "Service ${svc} has no load balancer IP after 2 minutes. Check MetalLB: kubectl -n ${K8S_NAMESPACE} describe svc ${svc}"
  POD_API_URL="http://${ip}:${POD_PORT}"
  info "Service ${svc}: ${POD_API_URL}"
}

stage4_check() {
  local body="" verdict="" ok=0
  for _ in $(seq 1 30); do
    if body="$(curl -fsS --max-time 10 "${POD_API_URL}/api/v1/info" 2>/dev/null)"; then
      verdict="$(printf '%s' "$body" | python3 -c '
import json, sys
b = json.load(sys.stdin)
problems = []
if (b.get("runtime") or {}).get("kind") != "pod":
    problems.append("runtime is not a pod")
if (b.get("db") or {}).get("status") != "ok":
    problems.append("db: " + str((b.get("db") or {}).get("error", "unavailable")))
if (b.get("documents") or {}).get("status") != "ok":
    problems.append("documents: " + str((b.get("documents") or {}).get("status") or (b.get("documents") or {}).get("error")))
print("; ".join(problems) or "ok")
' 2>/dev/null || echo "unreadable reply")"
      if [ "$verdict" = "ok" ]; then ok=1; break; fi
    fi
    sleep 2
  done
  if [ "$ok" -ne 1 ]; then
    if [ -z "$body" ]; then
      die "this VM cannot reach ${POD_API_URL}. Open TCP ${POD_PORT} from the portal to the load balancer IP."
    fi
    case "$verdict" in
      *db:*) warn "the pods cannot use PostgreSQL ${DB_HOST}:${DB_PORT}. Add the node IPs (${STAGE4_NODE_IPS:-see kubectl get nodes -o wide}) to pg_hba.conf, and allow TCP ${DB_PORT} from them." ;;
    esac
    case "$verdict" in
      *documents:*) stage4_diagnose ;;
    esac
    die "API pods are not ready: ${verdict}"
  fi
  printf '%s' "$body" | python3 -c '
import json, sys
b = json.load(sys.stdin)
r = b.get("runtime") or {}
print("   pod   {} on node {} ({})".format(b["host"]["hostname"], r.get("node", "?"), r.get("pod_ip", "?")))
print("   db    {}:{} served by {}".format(b["db_endpoint"]["host"], b["db_endpoint"]["port"], b["db"].get("server_addr")))
print("   docs  {} mounted, bucket {}".format(b["documents"]["nfs"]["export"], b["documents"]["s3"]["bucket"]))
'
}

# Image tag of the running Deployment, empty when it is not deployed.
stage4_deployed_tag() {
  local img=""
  img="$(kc -n "$K8S_NAMESPACE" get deploy "${RELEASE}-api" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  [ -n "$img" ] && printf '%s' "${img##*:}"
}

stage4_wanted_tag() {
  if [ -n "$IMAGE" ] && [[ "${IMAGE##*/}" == *:* ]]; then
    printf '%s' "${IMAGE##*:}"
  else
    bundle_version
  fi
}

portal_stage4() {
  step "Cluster"
  stage4_preflight
  step "Settings for the API pods"
  stage4_settings
  echo
  info "Cluster      $(kc config view --minify -o jsonpath='{.clusters[0].cluster.server}')  namespace ${K8S_NAMESPACE}"
  info "Database     ${DB_HOST}:${DB_PORT}  database ${DB_NAME}  role ${DB_USER}"
  info "Files        ${NFS_SERVER}:${NFS_PATH}  (NFSv3, pods run as uid ${STAGE4_RUN_AS_UID})"
  info "Objects      ${S3_ENDPOINT}  bucket ${S3_BUCKET}"
  info "Service      LoadBalancer :${POD_PORT}${STAGE4_LB_IP:+  IP ${STAGE4_LB_IP}}"
  ask_yes "Deploy the API pods?" Y || die "cancelled"
  save_stage4_state
  step "Deploy"
  stage4_secret
  stage4_deploy
  stage4_wait_lb
  step "Check the pods from the portal"
  stage4_check
}

# ---------------------------------------------------------------- stage 5: chat pods

load_stage5_state() {
  local base="$LLM_BASE_URL" m="$LLM_MODEL" vm="$LLM_VISION_MODEL" tls="$LLM_VERIFY_TLS" lb="$CHAT_LB_IP"
  if [ -f "$STAGE5_STATE" ]; then
    # shellcheck disable=SC1090
    . "$STAGE5_STATE"
  fi
  LLM_BASE_URL="${base:-${LLM_BASE_URL:-}}"
  LLM_MODEL="${m:-${LLM_MODEL:-gpt-oss-120b}}"
  LLM_VISION_MODEL="${vm:-${LLM_VISION_MODEL:-gemma-4-26b-a4b}}"
  LLM_VERIFY_TLS="${tls:-${LLM_VERIFY_TLS:-true}}"
  CHAT_LB_IP="${lb:-${CHAT_LB_IP:-}}"
}

save_stage5_state() {
  install -d -m 700 "$KUBE_DIR"
  umask 077
  {
    printf 'LLM_BASE_URL=%q\n' "$LLM_BASE_URL"
    printf 'LLM_MODEL=%q\n' "$LLM_MODEL"
    printf 'LLM_VISION_MODEL=%q\n' "$LLM_VISION_MODEL"
    printf 'LLM_VERIFY_TLS=%q\n' "$LLM_VERIFY_TLS"
    printf 'CHAT_LB_IP=%q\n' "$CHAT_LB_IP"
    printf 'STAGE5_SECRET_HASH=%q\n' "$STAGE5_SECRET_HASH"
  } > "$STAGE5_STATE"
  umask 022
}

# The chart's chat section as JSON, from the saved stage 5 settings. Empty before the first --stage 5.
stage5_chat_values() {
  [ -f "$STAGE5_STATE" ] || return 0
  (
    load_stage5_state
    BASE="$LLM_BASE_URL" MODEL="$LLM_MODEL" VMODEL="$LLM_VISION_MODEL" TLS="$LLM_VERIFY_TLS" \
      LB="$CHAT_LB_IP" HASH="$STAGE5_SECRET_HASH" PORT="$POD_PORT" SECRET_NAME="$CHAT_SECRET" python3 -c '
import json, os
e = os.environ
print(json.dumps({"enabled": True, "existingSecret": e["SECRET_NAME"], "secretHash": e["HASH"],
                  "llm": {"baseUrl": e["BASE"], "model": e["MODEL"], "visionModel": e["VMODEL"],
                          "verifyTls": e["TLS"] == "true"},
                  "service": {"port": int(e["PORT"]), "loadBalancerIP": e["LB"]}}))'
  )
}

chat_secret_exists() { kc -n "$K8S_NAMESPACE" get secret "$CHAT_SECRET" >/dev/null 2>&1; }

# The endpoint lists its models. A warning only: the portal may have no route to it, the nodes must.
stage5_probe_endpoint() {
  local out="" insecure=()
  [ "$LLM_VERIFY_TLS" = true ] || insecure=(-k)
  if ! out="$(curl -sS --max-time 15 "${insecure[@]}" \
      -H @<(printf 'Authorization: Bearer %s\n' "$LLM_API_KEY") "${LLM_BASE_URL%/}/models" 2>&1)"; then
    warn "this VM cannot reach ${LLM_BASE_URL}: ${out}. The NKP nodes need HTTPS to it; continuing."
    return 0
  fi
  printf '%s' "$out" | MODEL="$LLM_MODEL" VMODEL="$LLM_VISION_MODEL" python3 -c '
import json, os, sys
try:
    body = json.load(sys.stdin)
except ValueError:
    sys.exit("WARNING: the endpoint did not answer /models with JSON")
if "data" not in body:
    sys.exit("WARNING: the endpoint refused the key: " + json.dumps(body)[:200])
served = [m.get("id") for m in body["data"]]
missing = [m for m in (os.environ["MODEL"], os.environ["VMODEL"]) if m not in served]
print("   endpoint serves: " + ", ".join(served))
if missing:
    sys.exit("WARNING: not served: " + ", ".join(missing))
' || warn "check the API key and the model names"
}

# Secret from stdin, never on a command line or in a file.
stage5_secret() {
  local manifest
  manifest="$(K8S_NAMESPACE="$K8S_NAMESPACE" LLM_API_KEY="$LLM_API_KEY" SECRET_NAME="$CHAT_SECRET" python3 - <<'PY'
import hashlib, json, os
key = os.environ["LLM_API_KEY"]
print(hashlib.sha256(key.encode()).hexdigest()[:12])
print(json.dumps({
    "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
    "metadata": {"name": os.environ["SECRET_NAME"], "namespace": os.environ["K8S_NAMESPACE"],
                 "labels": {"app.kubernetes.io/name": "claims-desk", "app.kubernetes.io/component": "chat"}},
    "stringData": {"llm-api-key": key},
}))
PY
)"
  STAGE5_SECRET_HASH="${manifest%%$'\n'*}"
  printf '%s\n' "${manifest#*$'\n'}" | kc apply -f - >/dev/null || die "could not write Secret ${CHAT_SECRET}"
  info "Secret ${CHAT_SECRET} (LLM API key only)"
}

stage5_diagnose() {
  local sel="app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=chat"
  warn "the chat pods are not healthy. What the cluster says:"
  kc -n "$K8S_NAMESPACE" get pods -l "$sel" -o wide 2>&1 | sed 's/^/   /' || true
  kc -n "$K8S_NAMESPACE" logs -l "$sel" --tail=15 --prefix 2>/dev/null | sed 's/^/   /' || true
}

stage5_check() {
  local body="" verdict="" ok=0
  for _ in $(seq 1 30); do
    if body="$(curl -fsS --max-time 15 "${CHAT_URL}/health" 2>/dev/null)"; then
      verdict="$(printf '%s' "$body" | python3 -c '
import json, sys
b = json.load(sys.stdin)
problems = []
if (b.get("api") or {}).get("status") != "ok":
    problems.append("api: " + str((b.get("api") or {}).get("error") or (b.get("api") or {}).get("status")))
if (b.get("llm") or {}).get("status") != "ok":
    problems.append("llm: " + str((b.get("llm") or {}).get("error") or (b.get("llm") or {}).get("status")))
print("; ".join(problems) or "ok")
' 2>/dev/null || echo "unreadable reply")"
      if [ "$verdict" = "ok" ]; then ok=1; break; fi
    fi
    sleep 2
  done
  if [ "$ok" -ne 1 ]; then
    [ -n "$body" ] || die "this VM cannot reach ${CHAT_URL}. Open TCP ${POD_PORT} from the portal to the chat load balancer IP."
    case "$verdict" in
      *llm:*) warn "the chat pods cannot use ${LLM_BASE_URL}. The nodes (${STAGE4_NODE_IPS:-see kubectl get nodes -o wide}) need HTTPS to it; check the key and the model names." ;;
    esac
    stage5_diagnose
    die "chat pods are not ready: ${verdict}"
  fi
  printf '%s' "$body" | python3 -c '
import json, sys
b = json.load(sys.stdin)
r, l = b.get("runtime") or {}, b.get("llm") or {}
print("   pod   {} on node {} ({})".format(b["host"]["hostname"], r.get("node", "?"), r.get("pod_ip", "?")))
print("   llm   {}  model {}  vision {}".format(l.get("base_url"), l.get("model"), l.get("vision_model")))
print("   api   {}".format(b["api"]["url"]))
'
}

stage5_wait_lb() {
  local ip="" svc="${RELEASE}-chat"
  for _ in $(seq 1 60); do
    ip="$(kc -n "$K8S_NAMESPACE" get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [ -n "$ip" ] && break
    sleep 2
  done
  [ -n "$ip" ] || die "Service ${svc} has no load balancer IP after 2 minutes. Check MetalLB: kubectl -n ${K8S_NAMESPACE} describe svc ${svc}"
  CHAT_URL="http://${ip}:${POD_PORT}"
  info "Service ${svc}: ${CHAT_URL}"
}

chat_deployed() { kc -n "$K8S_NAMESPACE" get deploy "${RELEASE}-chat" >/dev/null 2>&1; }

portal_stage5() {
  step "Assistant settings"
  load_stage5_state
  local have_secret=0
  chat_secret_exists && have_secret=1
  if [ "$INTERACTIVE" -eq 1 ]; then
    info "The chat pods call an OpenAI-compatible endpoint (NAI): base URL, models, and an API key."
  fi
  ask LLM_BASE_URL "OpenAI-compatible base URL, ending in /v1"
  LLM_BASE_URL="${LLM_BASE_URL%/}"
  [[ "$LLM_BASE_URL" =~ ^https?://[^[:space:]]+$ ]] || die "LLM base URL must be an http(s) URL"
  ask LLM_MODEL "Chat model (needs tool calling)" gpt-oss-120b
  ask LLM_VISION_MODEL "Vision model for photos" gemma-4-26b-a4b
  [[ "$LLM_MODEL" =~ ^[A-Za-z0-9._:/-]+$ && "$LLM_VISION_MODEL" =~ ^[A-Za-z0-9._:/-]+$ ]] \
    || die "model names may contain letters, digits and . _ : / - only"
  case "$LLM_VERIFY_TLS" in true|false) ;; *) die "LLM_VERIFY_TLS must be true or false" ;; esac
  if [ -z "$LLM_API_KEY" ] && { [ "$RECONFIGURE" -eq 1 ] || [ "$have_secret" -eq 0 ]; }; then
    ask_secret LLM_API_KEY "API key for ${LLM_BASE_URL}"
  fi
  if [ -z "$LLM_API_KEY" ] && [ "$have_secret" -eq 0 ]; then
    die "the LLM API key is required: set LLM_API_KEY, or run interactively"
  fi
  if [ -n "$CHAT_LB_IP" ]; then
    valid_ipv4 "$CHAT_LB_IP" || die "CHAT_LB_IP must be an IPv4 address"
  fi
  echo
  info "Endpoint     ${LLM_BASE_URL}  TLS verification ${LLM_VERIFY_TLS}"
  info "Models       ${LLM_MODEL} (chat, tools)  ${LLM_VISION_MODEL} (photos)"
  info "API key      $([ -n "$LLM_API_KEY" ] && echo "new, into Secret ${CHAT_SECRET}" || echo "kept in Secret ${CHAT_SECRET}")"
  info "Service      LoadBalancer :${POD_PORT}${CHAT_LB_IP:+  IP ${CHAT_LB_IP}}"
  if [ -n "$LLM_API_KEY" ]; then
    stage5_probe_endpoint
  fi
  ask_yes "Deploy the chat pods?" Y || die "cancelled"

  step "Deploy the chat pods"
  if [ -n "$LLM_API_KEY" ]; then
    stage5_secret
    LLM_API_KEY=""
  else
    STAGE5_SECRET_HASH="${STAGE5_SECRET_HASH:-$(kc -n "$K8S_NAMESPACE" get secret "$CHAT_SECRET" \
      -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)}"
  fi
  save_stage5_state
  # The release's own values plus the chat section. Not --reuse-values: that would also
  # keep the old chart's defaults, which have no chat section.
  local values
  values="$(mktemp /tmp/claims-desk-chat.XXXXXX.json)"
  hm get values "$RELEASE" -n "$K8S_NAMESPACE" -o json > "$values" \
    || die "could not read the values of release ${RELEASE}. Run sudo $0 --stage 4 first"
  STAGE="$STAGE" CHAT="$(stage5_chat_values)" python3 -c '
import json, os, sys
values = json.load(open(sys.argv[1])) or {}
values["stage"] = int(os.environ["STAGE"])
values["chat"] = json.loads(os.environ["CHAT"])
json.dump(values, open(sys.argv[1], "w"))' "$values"
  info "helm upgrade ${RELEASE} (API pod values kept, chat enabled)"
  if ! hm upgrade "$RELEASE" "$CHART" -n "$K8S_NAMESPACE" -f "$values" --wait --timeout 10m; then
    rm -f "$values"
    stage5_diagnose
    die "helm could not bring the chat pods up. Fix the cause above, then rerun: sudo $0 --stage 5"
  fi
  rm -f "$values"
  kc -n "$K8S_NAMESPACE" get pods -l "app.kubernetes.io/instance=${RELEASE}" -o wide | sed 's/^/   /'
  stage5_wait_lb
  step "Check the chat pods from the portal"
  stage5_check
}

docs_configured() {
  [ -f "$ETC/api.json" ] || return 1
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
raise SystemExit(0 if str(d.get("docs_url") or "").strip() else 1)' "$ETC/api.json"
}

saved_pod_url() {
  [ -f "$ETC/web.json" ] || return 0
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("pod_api_url") or "")' "$ETC/web.json"
}

saved_chat_url() {
  [ -f "$ETC/web.json" ] || return 0
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("chat_url") or "")' "$ETC/web.json"
}

# nginx /chat/ goes to the chat pods at stage 5. Below that, to an unused local port.
set_chat_upstream() {
  local stage="$1" target="$LOCAL_CHAT_UPSTREAM" conf="$NGINX_CONF"
  [ -f "$conf" ] || return 0
  if ! grep -q 'upstream claims_chat' "$conf"; then
    [ "$stage" -lt 5 ] && return 0
    die "$conf has no /chat/ location (written by an older install.sh). Run sudo $BUNDLE/install.sh, then this again"
  fi
  if [ "$stage" -ge 5 ] && [ -n "$CHAT_URL" ]; then
    target="${CHAT_URL#*://}"
    target="${target%%/*}"
    [[ "$target" == *:* ]] || target="${target}:80"
  fi
  sed -i -E "s#^( *upstream claims_chat \\{ server )[^;]+;#\\1${target};#" "$conf"
}

run_portal_install() {
  local install_args=() quiet="${1:-}"
  [ -n "$CONFIG" ] && install_args+=(--config "$CONFIG")
  [ "$RECONFIGURE" -eq 1 ] && install_args+=(--reconfigure)
  [ -n "$SEED_ARG" ] && install_args+=(--seed "$SEED_ARG")
  [ "$ASSUME_YES" -eq 1 ] && install_args+=(-y)
  if [ "$quiet" = "quiet" ]; then
    CLAIMS_UPDATE_FOLLOW=1 "$BUNDLE/install.sh" "${install_args[@]}"
  else
    "$BUNDLE/install.sh" "${install_args[@]}"
  fi
}

# nginx publishes /api/ too. Stage 4 and 5 send it to the pods, lower stages to this VM.
set_api_upstream() {
  local stage="$1" target="127.0.0.1:8000" scheme=http conf="$NGINX_CONF"
  [ -f "$conf" ] || return 0
  if [ "$stage" -ge 4 ]; then
    scheme="${POD_API_URL%%://*}"
    target="${POD_API_URL#*://}"
    target="${target%%/*}"
    if [[ "$target" != *:* ]]; then
      if [ "$scheme" = https ]; then target="${target}:443"; else target="${target}:80"; fi
    fi
  fi
  sed -i -E \
    -e "s#^( *upstream claims_api \\{ server )[^;]+;#\\1${target};#" \
    -e "s#(location /api/ \\{ proxy_pass )https?://claims_api;#\\1${scheme}://claims_api;#" "$conf"
  nginx -t -q || die "nginx configuration test failed after pointing /api/ at ${target}"
  systemctl reload nginx
}

# Select the path and the diagram. Does not change the database address,
# the document VM, or any pod deployment.
apply_stage() {
  local stage="$1" saved=""
  if [ ! -f "$ETC/api.json" ] || [ ! -f "$ETC/web.json" ]; then
    die "portal is not installed"
  fi
  saved="$(saved_pod_url)"
  if [ -z "$POD_API_URL" ] && [ -n "$saved" ]; then
    POD_API_URL="$saved"
  fi
  if [ "$stage" -ge 4 ] && [ -z "$POD_API_URL" ]; then
    ask POD_API_URL "API pod URL"
  fi
  if [ "$stage" -ge 4 ]; then
    [[ "$POD_API_URL" =~ ^https?://[^[:space:]]+$ ]] || die "API pod URL must be an http(s) URL"
  fi
  [ -n "$CHAT_URL" ] || CHAT_URL="$(saved_chat_url)"
  if [ "$stage" -ge 5 ]; then
    [[ "$CHAT_URL" =~ ^https?://[^[:space:]]+$ ]] \
      || die "no chat pod URL. Run sudo $0 --stage 5 with the kubeconfig, or set CHAT_URL"
  fi
  CLAIMS_STAGE="$stage" POD_API_URL="$POD_API_URL" LOCAL_API_URL="$LOCAL_API_URL" ETC="$ETC" \
    CHAT_URL="$CHAT_URL" python3 - <<'PY'
import json, os
stage = int(os.environ["CLAIMS_STAGE"])
pod = os.environ.get("POD_API_URL") or ""
local = os.environ["LOCAL_API_URL"]
chat = os.environ.get("CHAT_URL") or ""

def merge(path, updates):
    with open(path) as fh:
        data = json.load(fh)
    data.update(updates)
    fd = os.open(path, os.O_WRONLY | os.O_TRUNC)
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")

web_updates = {"stage": stage}
if stage >= 4:
    web_updates["pod_api_url"] = pod
    web_updates["api_url"] = pod
elif pod:
    web_updates["api_url"] = local
    web_updates["pod_api_url"] = pod
else:
    web_updates["api_url"] = local
# Kept on lower stages too; the web tier shows the assistant only at stage 5.
if chat:
    web_updates["chat_url"] = chat
merge(os.path.join(os.environ["ETC"], "api.json"), {"stage": stage})
merge(os.path.join(os.environ["ETC"], "web.json"), web_updates)
PY
  printf '%s\n' "$stage" > "$ETC/stage"
  set_chat_upstream "$stage"
  set_api_upstream "$stage"
  if [ "$stage" -ge 4 ]; then
    # The pods are the only database client now; the portal middleware stays off.
    systemctl disable -q --now claims-api 2>/dev/null || true
    systemctl restart claims-web
  else
    systemctl enable -q claims-api
    systemctl restart claims-api claims-web
  fi
  info "active stage ${stage}. Database address unchanged."
  if [ "$stage" -ge 5 ]; then
    info "the assistant on the main page uses /chat/ -> ${CHAT_URL}."
  fi
  if [ "$stage" -ge 4 ]; then
    info "web tier and /api/ call ${POD_API_URL}. Pods are left as they are."
    info "claims-api on this VM is stopped: the portal no longer connects to PostgreSQL."
  else
    info "web tier calls ${LOCAL_API_URL}. claims-api on this VM is running."
  fi
  if [ "$stage" -lt 3 ]; then
    info "document VM is not on this path. Its configuration is unchanged."
  fi
}

if [ -n "$CONFIG" ]; then
  [ -f "$CONFIG" ] || die "config file not found: $CONFIG"
  cli_kubeconfig="$KUBECONFIG_FILE"
  # shellcheck disable=SC1090
  . "$CONFIG"
  KUBECONFIG_FILE="${cli_kubeconfig:-$KUBECONFIG_FILE}"
fi

case "$STAGE" in
  1)
    [ "$APPLY" -eq 0 ] || die "--apply-documents is only valid with --stage 3"
    run_portal_install
    apply_stage 1
    ;;
  2)
    [ "$APPLY" -eq 0 ] || die "--apply-documents is only valid with --stage 3"
    run_portal_install quiet
    apply_stage 2
    ;;
  3)
    [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 --stage 3"
    if [ "$APPLY" -eq 1 ]; then
      [ -n "$CONFIG" ] || die "--apply-documents needs --config"
      apply_documents
      exit 0
    fi
    if docs_configured && [ "$RECONFIGURE" -eq 0 ]; then
      run_portal_install quiet
      apply_stage 3
      info "document VM left as it is."
    else
      portal_stage3
    fi
    ;;
  4|5)
    [ "$APPLY" -eq 0 ] || die "--apply-documents is only valid with --stage 3"
    [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 --stage ${STAGE}"
    if [ "$(active_stage)" -ge 4 ] && [ "$RECONFIGURE" -eq 0 ]; then
      # The portal may already be cut off from PostgreSQL by the stage 4 Flow policy.
      CLAIMS_PORTAL_NO_DB=1 run_portal_install quiet
    else
      run_portal_install quiet
    fi
    exec > >(tee -a "$LOG") 2>&1
    load_stage4_state
    [ -n "$POD_API_URL" ] || POD_API_URL="$(saved_pod_url)"
    DEPLOYED=0
    if ! have_kubeconfig && [ -n "$POD_API_URL" ]; then
      info "no kubeconfig: selecting the saved API pod URL ${POD_API_URL} without checking the cluster"
    else
      step "Kubernetes tools"
      save_kubeconfig
      install_k8s_tools
      current_tag="$(stage4_deployed_tag || true)"
      wanted_tag="$(stage4_wanted_tag)"
      if [ "$RECONFIGURE" -eq 1 ] || [ -z "$current_tag" ]; then
        portal_stage4
        DEPLOYED=1
      elif [ "$current_tag" != "$wanted_tag" ]; then
        info "API pods run ${current_tag}; this bundle is ${wanted_tag}. Upgrading them."
        portal_stage4
        DEPLOYED=1
      else
        info "API pods ${current_tag} are deployed in namespace ${K8S_NAMESPACE}. Selecting them (--reconfigure redeploys)."
        stage4_wait_lb
      fi
    fi
    CHAT_DEPLOYED=0
    if [ "$STAGE" -ge 5 ]; then
      if have_kubeconfig; then
        if [ "$RECONFIGURE" -eq 1 ] || [ -n "$LLM_API_KEY" ] || [ ! -f "$STAGE5_STATE" ] || ! chat_deployed; then
          portal_stage5
          CHAT_DEPLOYED=1
        else
          info "chat pods are deployed in namespace ${K8S_NAMESPACE}. Selecting them (--reconfigure asks for the LLM settings again)."
          load_stage5_state
          stage5_wait_lb
        fi
      elif [ -z "$CHAT_URL" ] && [ -z "$(saved_chat_url)" ]; then
        die "the first --stage 5 needs the kubeconfig: sudo $0 --stage 5 --kubeconfig FILE"
      fi
    fi
    apply_stage "$STAGE"
    if [ "$CHAT_DEPLOYED" -eq 1 ]; then
      name="$(hostname -f 2>/dev/null || hostname)"
      cat <<EOF

$(printf '\033[1;32m')Claims Desk stage 5: the assistant is running on the chat pods.$(printf '\033[0m')

  Portal        https://${name}/   (Ask the assistant, bottom right)
  Chat pods     ${CHAT_URL}/health   (namespace ${K8S_NAMESPACE}, release ${RELEASE})
  Endpoint      ${LLM_BASE_URL}   models ${LLM_MODEL}, ${LLM_VISION_MODEL}
  API key       Secret ${CHAT_SECRET} in namespace ${K8S_NAMESPACE}; nowhere on this VM
  Demo data     sudo claims-desk seed-fraud   (suspicious claims, photos, one changed after approval)
  Back          sudo $0 --stage 4   (hides the assistant; the chat pods keep running)
EOF
    fi
    if [ "$DEPLOYED" -eq 1 ]; then
      name="$(hostname -f 2>/dev/null || hostname)"
      cat <<EOF

$(printf '\033[1;32m')Claims Desk stage ${STAGE} is running on the API pods.$(printf '\033[0m')

  Portal        https://${name}/
  Architecture  https://${name}/about
  API pods      ${POD_API_URL}/api/v1/info   (namespace ${K8S_NAMESPACE}, release ${RELEASE})
  Node IPs      ${STAGE4_NODE_IPS:-see kubectl get nodes -o wide}: allowed in pg_hba.conf and on the NFS export
  Kubeconfig    ${KUBECONFIG_SAVED} (root only)
  Back to VMs   sudo $0 --stage 3   (pods keep running; the portal middleware takes over)
EOF
    fi
    ;;
  *)
    die "stage must be 1, 2, 3, 4, or 5"
    ;;
esac
