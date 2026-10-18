#!/usr/bin/env bash
# Run the test suite against a throwaway PostgreSQL (pgserver). No database or VM needed.
#
#   bash scripts/test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="${VENV:-/tmp/claimsdesk-test-venv}"

[ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q -r "$ROOT/app/requirements.txt" pytest pgserver
cd "$ROOT"
"$VENV/bin/python" -m pytest -q -p no:cacheprovider tests
