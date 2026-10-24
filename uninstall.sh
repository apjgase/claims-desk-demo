#!/usr/bin/env bash
# Remove the Claims Desk portal from this VM. The database is left untouched.
#
#   sudo ./uninstall.sh [-y]
set -euo pipefail

PREFIX=/opt/claims-desk
ETC=/etc/claims-desk
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

if [ "${1:-}" != "-y" ]; then
  read -r -p "Remove Claims Desk services, code, settings and certificate from this VM? [y/N]: " reply
  [[ "$reply" =~ ^[Yy] ]] || { echo "cancelled"; exit 0; }
fi

DB_LINE=""
if [ -f "$ETC/api.json" ]; then
  DB_LINE="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print("{db_host}:{db_port} database {db_name}, role {db_user}".format(**c))' "$ETC/api.json" 2>/dev/null || true)"
fi

if [ -f /root/.claims-desk-stage3 ]; then
  doc_host="$(sed -n "s/^DOC_HOST=//p" /root/.claims-desk-stage3 | tr -d "'\"")"
  echo "Document VM ${doc_host:-on the saved address} was not modified. claims-docs is still running there."
  rm -f /root/.claims-desk-stage3
fi

if [ -d /root/.claims-desk ]; then
  ns="$(sed -n "s/^K8S_NAMESPACE=//p" /root/.claims-desk/stage4 2>/dev/null | tr -d "'\"")"
  echo "The API pods were not removed. To remove them from the cluster:"
  echo "  helm --kubeconfig <kubeconfig> -n ${ns:-claims} uninstall claims-desk"
  echo "  kubectl --kubeconfig <kubeconfig> -n ${ns:-claims} delete secret claims-desk"
  rm -rf /root/.claims-desk
fi

systemctl disable --now claims-web claims-api 2>/dev/null || true
rm -f /etc/systemd/system/claims-web.service /etc/systemd/system/claims-api.service
systemctl daemon-reload

if [ -f /etc/nginx/nginx.conf.claims-desk.orig ]; then
  mv /etc/nginx/nginx.conf.claims-desk.orig /etc/nginx/nginx.conf
  systemctl restart nginx 2>/dev/null || true
  echo "nginx.conf restored"
fi

rm -rf "$PREFIX" "$ETC" /usr/local/bin/claims-desk
rm -f /etc/pki/tls/certs/claims-desk.crt /etc/pki/tls/private/claims-desk.key
if getent passwd claimsdesk >/dev/null; then userdel claimsdesk || true; fi
if getent group claimsdesk >/dev/null; then groupdel claimsdesk 2>/dev/null || true; fi

echo "Claims Desk removed. nginx, python3.11 and the firewall rules were left in place."
if [ -n "$DB_LINE" ]; then
  cat <<EOF
The database was not touched (${DB_LINE}). To drop it, as the admin user:
  DROP DATABASE <name>;   DROP ROLE <role>;
EOF
fi
