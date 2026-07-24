#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
git add -A
git status -sb
git commit -m "feat: brand icon from icons/ + Gatekeeper damaged-app FAQ" || true
git push origin main
# optional new release tag
# git tag -a v1.0.3 -m "v1.0.3: brand icon + gatekeeper FAQ"
# git push origin v1.0.3
