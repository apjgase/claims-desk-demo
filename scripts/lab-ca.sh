#!/usr/bin/env bash
# Lab certificate authority for claims.internal.
#
#   bash scripts/lab-ca.sh init                  create the CA (once)
#   bash scripts/lab-ca.sh issue NAME [SAN ...]  key and certificate for NAME.claims.internal
#        SAN: more DNS names or IP addresses, e.g.  portal01 172.16.10.11
#        A leading '*.' issues a wildcard, e.g.     '*.apps'
#   bash scripts/lab-ca.sh show                  where the files are
#
# The CA private key stays in $LAB_CA_DIR (default ~/.claims-desk-lab/ca) and is never
# committed. The CA certificate is copied to deploy/pki/claims-internal-ca.crt.
# Name constraints limit the CA to *.claims.internal and private IPv4 ranges, so trusting
# it on a laptop cannot make it vouch for any other site.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${LAB_CA_DIR:-$HOME/.claims-desk-lab/ca}"
DOMAIN="${LAB_DOMAIN:-claims.internal}"
PUBLIC_CERT="$ROOT/deploy/pki/claims-internal-ca.crt"

die() { echo "ERROR: $*" >&2; exit 1; }

fqdn() {
  case "$1" in
    *."$DOMAIN"|"$DOMAIN") echo "$1" ;;
    *) echo "$1.$DOMAIN" ;;
  esac
}

is_ip() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }

init() {
  [ -f "$DIR/ca.key" ] && die "CA already exists in $DIR"
  mkdir -p "$DIR"
  chmod 700 "$DIR"
  cat > "$DIR/ca.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_ca
[dn]
O = Claims Desk lab
CN = Claims Desk lab CA (${DOMAIN})
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
nameConstraints = critical, permitted;DNS:${DOMAIN}, permitted;IP:10.0.0.0/255.0.0.0, permitted;IP:172.16.0.0/255.240.0.0, permitted;IP:192.168.0.0/255.255.0.0
EOF
  (umask 077 && openssl genrsa -out "$DIR/ca.key" 3072 2>/dev/null)
  openssl req -x509 -new -key "$DIR/ca.key" -sha256 -days 3650 -config "$DIR/ca.cnf" -out "$DIR/ca.crt"
  mkdir -p "$(dirname "$PUBLIC_CERT")"
  cp "$DIR/ca.crt" "$PUBLIC_CERT"
  echo "CA created: $DIR/ca.crt (key: $DIR/ca.key)"
  echo "public copy: ${PUBLIC_CERT#"$ROOT"/}"
  openssl x509 -in "$DIR/ca.crt" -noout -subject -enddate -fingerprint -sha256
}

issue() {
  [ -f "$DIR/ca.key" ] || die "no CA in $DIR; run: bash scripts/lab-ca.sh init"
  [ $# -ge 1 ] || die "usage: lab-ca.sh issue NAME [SAN ...]"
  local name; name="$(fqdn "$1")"; shift
  local safe="${name//\*/wildcard}"
  local out="$DIR/issued/$safe"
  local sans="DNS:$name"
  local extra
  for extra in "$@"; do
    if is_ip "$extra"; then sans="$sans,IP:$extra"; else sans="$sans,DNS:$(fqdn "$extra")"; fi
  done
  mkdir -p "$out"
  cat > "$out/ext.cnf" <<EOF
[v3]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
subjectAltName = ${sans}
EOF
  (umask 077 && openssl req -new -newkey rsa:2048 -nodes -keyout "$out/key.pem" \
     -subj "/O=Claims Desk lab/CN=${name}" -out "$out/csr.pem" 2>/dev/null)
  openssl x509 -req -in "$out/csr.pem" -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" -CAcreateserial \
    -days 825 -sha256 -extfile "$out/ext.cnf" -extensions v3 -out "$out/cert.pem" 2>/dev/null
  cat "$out/cert.pem" "$DIR/ca.crt" > "$out/fullchain.pem"
  rm -f "$out/csr.pem"
  openssl verify -CAfile "$DIR/ca.crt" "$out/cert.pem" >/dev/null
  echo "issued $name ($sans)"
  echo "  certificate: $out/fullchain.pem   (certificate + CA, for nginx and appliances)"
  echo "  private key: $out/key.pem"
}

case "${1:-}" in
  init) init ;;
  issue) shift; issue "$@" ;;
  show) echo "CA directory: $DIR"; ls -R "$DIR" 2>/dev/null || echo "(not created)" ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
