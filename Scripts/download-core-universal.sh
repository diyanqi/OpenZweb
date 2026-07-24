#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
chmod +x Scripts/download-core.sh

export FORCE_REDOWNLOAD=1

echo "==> Fetching darwin/arm64 engine"
FORCE_GOARCH=arm64 DEST_NAME=zju-connect-arm64 ./Scripts/download-core.sh

echo "==> Fetching darwin/amd64 engine"
FORCE_GOARCH=amd64 DEST_NAME=zju-connect-amd64 ./Scripts/download-core.sh

ARM64="$ROOT/Core/zju-connect-arm64"
AMD64="$ROOT/Core/zju-connect-amd64"
OUT="$ROOT/Core/zju-connect"
test -x "$ARM64"
test -x "$AMD64"

echo "==> Creating universal binary"
lipo -create -output "$OUT" "$ARM64" "$AMD64"
chmod +x "$OUT"
lipo -info "$OUT"
file "$OUT"
echo "✓ Universal Core/zju-connect ready"
