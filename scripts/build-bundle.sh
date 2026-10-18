#!/usr/bin/env bash
# Build the offline bundle: the repository plus Python wheels for Rocky Linux 9 x86_64
# (CPython 3.11), so the VM needs only its dnf repositories, not PyPI.
#
#   bash scripts/build-bundle.sh            -> dist/claims-desk-demo-<version>.tar.gz
#
# Runs on any machine with python3 and internet access (macOS or Linux).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' app/claimsdesk/__init__.py)"
NAME="claims-desk-demo-${VERSION}"
STAGE_DIR="dist/${NAME}"
PIP="${PIP:-python3 -m pip}"

rm -rf "$STAGE_DIR" "dist/${NAME}.tar.gz"
mkdir -p "$STAGE_DIR/vendor/wheels"

if git rev-parse --git-dir >/dev/null 2>&1; then
  git archive --format=tar HEAD | tar -x -C "$STAGE_DIR"
else
  tar -c --exclude=dist --exclude=.git --exclude='__pycache__' . | tar -x -C "$STAGE_DIR"
fi
rm -rf "$STAGE_DIR/tests" "$STAGE_DIR/scripts"

$PIP download -q --dest "$STAGE_DIR/vendor/wheels" --only-binary=:all: \
  --implementation cp --python-version 3.11 --abi cp311 \
  --platform manylinux_2_34_x86_64 --platform manylinux_2_28_x86_64 \
  --platform manylinux_2_17_x86_64 --platform manylinux2014_x86_64 \
  -r app/requirements.txt -c app/constraints.txt

(cd "$STAGE_DIR/vendor/wheels" && ls -1 -- *.whl > ../WHEELS.txt)
tar -czf "dist/${NAME}.tar.gz" -C dist "$NAME"
(cd dist && shasum -a 256 "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256")
rm -rf "$STAGE_DIR"

echo "dist/${NAME}.tar.gz ($(du -h "dist/${NAME}.tar.gz" | cut -f1))"
cat "dist/${NAME}.tar.gz.sha256"
