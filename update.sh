#!/usr/bin/env bash
# Claims Desk updater. One bundle, every stage. Re-run it from the same directory.
#
#   sudo ./update.sh --stage 1                         portal only (same as ./install.sh)
#   sudo ./update.sh --stage 3                         portal, then the document VM over SSH
#   sudo ./update.sh --stage 3 --config claims-desk.conf -y
#
# Stage 3 runs on the portal VM. It asks for the document VM, the NFSv3 export
# (IP:/path), and the Objects endpoint and keys, then logs into the document VM
# and installs the document service there. The running portal process does not
# keep the Objects keys. A root-only copy is saved on the portal so the next
# ./update.sh --stage 3 can upgrade the document VM without asking again.
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

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --stage N        1 = portal (default), 3 = portal plus the document VM
  --config FILE    settings file (see claims-desk.conf.example)
  --reconfigure    ask for the database and the document settings again
  --seed N         sample claims on an empty table (default 12, 0 = none)
  -y, --yes        do not ask for confirmation
  -h, --help       this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --stage) STAGE="${2:?--stage needs a number}"; shift 2 ;;
    --apply-documents) APPLY=1; shift ;;
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

norm_nfs() {
  local spec="$1" host path
  host="${spec%%:*}"
  path="${spec#*:}"
  path="${path%/}"
  printf '%s:%s' "$host" "$path"
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
    SSHPASS="$DOC_SSH_PASSWORD" sshpass -e ssh "${opts[@]}" "${DOC_SSH_USER}@${DOC_HOST}" "$@"
  else
    opts+=(-o BatchMode=yes)
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
  mkdir -p "$NFS_MOUNT"
  local current=""
  if mountpoint -q "$NFS_MOUNT"; then
    current="$(findmnt -n -o SOURCE "$NFS_MOUNT" || true)"
  fi
  if [ "$(norm_nfs "$current")" != "$(norm_nfs "$NFS_EXPORT")" ]; then
    if mountpoint -q "$NFS_MOUNT"; then
      umount "$NFS_MOUNT" || die "could not unmount ${NFS_MOUNT} (mounted from ${current:-unknown})"
    fi
    timeout 30 mount -t nfs -o vers=3,proto=tcp,hard,timeo=600,retrans=2,nolock \
      "$NFS_EXPORT" "$NFS_MOUNT" \
      || die "could not mount ${NFS_EXPORT} on ${NFS_MOUNT}. Check the Files IP, export path, and TCP 2049 from this VM."
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
    info "NFSv3 by IP, for example 10.10.140.11:/claims-docs. Objects TLS is not verified."
  fi
  ask DOC_HOST "Document VM IP"
  valid_ipv4 "$DOC_HOST" || die "Document VM IP must be an IPv4 address"
  ask DOC_SSH_USER "SSH user on the document VM" root
  [[ "$DOC_SSH_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "SSH user must be a short account name"
  ask DOC_SSH_KEY "SSH private key (Enter tries the agent, then /root/.ssh/claims-desk-lab)" ""
  ask NFS_EXPORT "NFS export, IP:/path"
  local nfs_host="${NFS_EXPORT%%:*}" nfs_path="${NFS_EXPORT#*:}"
  valid_ipv4 "$nfs_host" || die "NFS export must start with an IPv4 address, for example 10.10.140.11:/claims-docs"
  [[ "$nfs_path" == /* && "$nfs_path" != *" "* ]] || die "NFS export path must be absolute and contain no spaces"
  ask NFS_MOUNT "Mount point on the document VM" /mnt/claims-docs
  [[ "$NFS_MOUNT" =~ ^/[A-Za-z0-9._/-]+$ && "$NFS_MOUNT" != *..* ]] || die "mount point must be an absolute path"
  ask S3_ENDPOINT "Objects endpoint URL"
  S3_ENDPOINT="${S3_ENDPOINT%/}"
  [[ "$S3_ENDPOINT" =~ ^https?://[^[:space:]]+$ ]] || die "Objects endpoint must be an http(s) URL"
  ask S3_BUCKET "Bucket" claims
  [[ "$S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "bucket name '$S3_BUCKET' is not a DNS-style bucket name"
  ask_secret S3_ACCESS_KEY "Objects access key"
  ask_secret S3_SECRET_KEY "Objects secret key"
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
merge("/etc/claims-desk/web.json", {"stage": 3, "api_timeout": 60})
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
  Files         ${NFS_EXPORT} on the document VM at ${NFS_MOUNT} (NFSv3)
  Objects       ${S3_ENDPOINT}  bucket ${S3_BUCKET}  (TLS verification off)
  Photo         optional, stored on Files when the claim is submitted
  Packet        stored on Objects when the claim is moved to APPROVED
  Settings      ${ETC}/api.json holds the document VM URL, not the keys
                ${SECRET} on this VM (root only) is how the next update logs in again
EOF
}

if [ -n "$CONFIG" ]; then
  [ -f "$CONFIG" ] || die "config file not found: $CONFIG"
  # shellcheck disable=SC1090
  . "$CONFIG"
fi

case "$STAGE" in
  1)
    [ "$APPLY" -eq 0 ] || die "--apply-documents is only valid with --stage 3"
    install_args=()
    [ -n "$CONFIG" ] && install_args+=(--config "$CONFIG")
    [ "$RECONFIGURE" -eq 1 ] && install_args+=(--reconfigure)
    [ -n "$SEED_ARG" ] && install_args+=(--seed "$SEED_ARG")
    [ "$ASSUME_YES" -eq 1 ] && install_args+=(-y)
    exec "$BUNDLE/install.sh" "${install_args[@]}"
    ;;
  3)
    [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 --stage 3"
    if [ "$APPLY" -eq 1 ]; then
      [ -n "$CONFIG" ] || die "--apply-documents needs --config"
      apply_documents
      exit 0
    fi
    portal_stage3
    ;;
  *)
    die "stage must be 1 or 3 (stage 2 is the same portal pointed at HAProxy port 5000)"
    ;;
esac
