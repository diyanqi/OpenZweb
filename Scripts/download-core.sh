#!/usr/bin/env bash
# Download or build zju-connect (aTrust / EasyConnect engine) into Core/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Core"
mkdir -p "$DEST"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) GOARCH=arm64 ;;
  x86_64) GOARCH=amd64 ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

API="${ZJU_CONNECT_RELEASE_API:-https://api.github.com/repos/Mythologyli/zju-connect/releases/latest}"
TAG_FALLBACK="${ZJU_CONNECT_TAG:-v1.2.1}"
REPO_SLUG="Mythologyli/zju-connect"

# Optional Chinese-friendly GitHub proxies (tried after direct URLs)
MIRRORS=(
  ""
  "https://ghproxy.net/"
  "https://mirror.ghproxy.com/"
  "https://gitclone.com/github.com/"
)

have_network() {
  # DNS + HTTPS reachability probe
  if ! curl -fsSIL --connect-timeout 5 --max-time 10 "https://example.com" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

pick_asset_url() {
  python3 - "$GOARCH" <<'PY'
import json, sys, re
arch = sys.argv[1]
data = json.load(sys.stdin)
assets = data.get("assets") or []
names = [a.get("name", "") for a in assets]
print("Available assets:", ", ".join(names) or "(none)", file=sys.stderr)

patterns = [
    rf"zju-connect[-_]darwin[-_]{re.escape(arch)}\.zip$",
    rf"zju-connect[-_]darwin[-_]{re.escape(arch)}\.tar\.gz$",
    rf"zju-connect[-_]darwin[-_]{re.escape(arch)}\.tgz$",
    rf"zju-connect[-_]macos[-_]{re.escape(arch)}\.zip$",
    rf"zju-connect.*darwin.*{re.escape(arch)}.*\.(zip|tar\.gz|tgz)$",
]
for pat in patterns:
    rx = re.compile(pat, re.I)
    for a in assets:
        name = a.get("name") or ""
        if rx.search(name):
            url = a.get("browser_download_url")
            if url:
                print(url)
                print("Matched:", name, file=sys.stderr)
                sys.exit(0)
print("No matching asset for darwin/" + arch, file=sys.stderr)
sys.exit(1)
PY
}

download_and_extract() {
  local url="$1"
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  echo "→ Downloading $url"
  if ! curl -fL --retry 3 --retry-delay 1 --connect-timeout 15 --max-time 300 \
      -A "OpenZweb-download-core" "$url" -o "$tmp/asset"; then
    echo "  download failed" >&2
    return 1
  fi

  # Detect archive type by magic, not only URL suffix (mirrors may strip extension)
  local kind=zip
  if file "$tmp/asset" | grep -qi 'gzip\|tar'; then
    kind=tar
  elif file "$tmp/asset" | grep -qi 'Zip'; then
    kind=zip
  else
    local lower
    lower="$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lower" == *.tar.gz || "$lower" == *.tgz ]]; then
      kind=tar
    fi
  fi

  mkdir -p "$tmp/out"
  if [[ "$kind" == zip ]]; then
    unzip -qo "$tmp/asset" -d "$tmp/out"
  else
    tar -xzf "$tmp/asset" -C "$tmp/out"
  fi

  local bin
  bin="$(find "$tmp/out" -type f \( -name 'zju-connect' -o -name 'zju-connect_*' \) ! -name '*.md' | head -n1 || true)"
  if [[ -z "$bin" ]]; then
    bin="$(find "$tmp/out" -type f -perm -111 ! -name '*.sh' ! -name '*.bash' 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$bin" || ! -f "$bin" ]]; then
    echo "Binary not found in archive" >&2
    find "$tmp" -maxdepth 4 -type f >&2 || true
    return 1
  fi

  cp "$bin" "$DEST/zju-connect"
  chmod +x "$DEST/zju-connect"
  # Also install into Application Support for the app runtime
  local app_support="$HOME/Library/Application Support/OpenZweb"
  mkdir -p "$app_support"
  cp "$DEST/zju-connect" "$app_support/zju-connect"
  chmod +x "$app_support/zju-connect"

  echo "✓ Installed: $DEST/zju-connect"
  echo "✓ Also:      $app_support/zju-connect"
  return 0
}

try_url_with_mirrors() {
  local url="$1"
  local mirror full
  for mirror in "${MIRRORS[@]}"; do
    if [[ -z "$mirror" ]]; then
      full="$url"
    elif [[ "$mirror" == *gitclone.com* ]]; then
      # gitclone expects https://gitclone.com/github.com/owner/repo/...
      full="${mirror}${url#https://github.com/}"
      full="https://gitclone.com/github.com/${url#https://github.com/}"
    else
      full="${mirror}${url}"
    fi
    echo "→ Trying $full"
    if download_and_extract "$full"; then
      return 0
    fi
  done
  return 1
}

try_github_release() {
  echo "→ Fetching latest zju-connect release for darwin/$GOARCH …"
  local json url
  if ! json="$(curl -fsSL --connect-timeout 15 -H 'Accept: application/vnd.github+json' -H 'User-Agent: OpenZweb' "$API" 2>/dev/null)"; then
    echo "⚠ Failed to query GitHub API (network / DNS / rate limit)" >&2
    return 1
  fi
  if [[ -z "$json" ]]; then
    echo "⚠ Empty GitHub API response" >&2
    return 1
  fi
  if url="$(printf '%s' "$json" | pick_asset_url)"; then
    try_url_with_mirrors "$url"
    return $?
  fi
  echo "⚠ No matching asset in latest release metadata" >&2
  return 1
}

try_tag_urls() {
  echo "→ Trying release tag $TAG_FALLBACK direct assets …"
  local base="https://github.com/${REPO_SLUG}/releases/download/${TAG_FALLBACK}"
  local candidates=(
    "zju-connect-darwin-${GOARCH}.zip"
    "zju-connect_darwin_${GOARCH}.zip"
    "zju-connect-darwin-${GOARCH}.tar.gz"
    "zju-connect_darwin_${GOARCH}.tar.gz"
    "zju-connect-macos-${GOARCH}.zip"
  )
  local name
  for name in "${candidates[@]}"; do
    if try_url_with_mirrors "$base/$name"; then
      return 0
    fi
  done
  return 1
}

try_go_install() {
  if ! command -v go >/dev/null 2>&1; then
    echo "⚠ Go not installed; skip source build" >&2
    return 1
  fi
  echo "→ Building with go install …"
  local gopath gobin
  gopath="$(go env GOPATH 2>/dev/null || echo "$HOME/go")"
  gobin="${GOBIN:-$gopath/bin}"
  # Prefer Chinese module proxy if default fails
  local proxies=("$(go env GOPROXY)" "https://goproxy.cn,direct" "https://proxy.golang.org,direct")
  local proxy
  for proxy in "${proxies[@]}"; do
    echo "  GOPROXY=$proxy"
    if GOBIN="$DEST" GOPROXY="$proxy" go install "github.com/Mythologyli/zju-connect@${TAG_FALLBACK}" 2>/tmp/openzweb-go-install.err \
      || GOBIN="$DEST" GOPROXY="$proxy" go install "github.com/Mythologyli/zju-connect@latest" 2>>/tmp/openzweb-go-install.err; then
      :
    fi
    if [[ -x "$DEST/zju-connect" ]]; then
      echo "✓ Built: $DEST/zju-connect"
      return 0
    fi
    if [[ -x "$gobin/zju-connect" ]]; then
      cp "$gobin/zju-connect" "$DEST/zju-connect"
      chmod +x "$DEST/zju-connect"
      echo "✓ Installed from GOPATH: $DEST/zju-connect"
      return 0
    fi
  done
  if [[ -f /tmp/openzweb-go-install.err ]]; then
    echo "  go install errors:" >&2
    tail -n 5 /tmp/openzweb-go-install.err >&2 || true
  fi
  return 1
}

main() {
  if [[ -x "$DEST/zju-connect" && "${FORCE_REDOWNLOAD:-}" != "1" ]]; then
    echo "✓ Already present: $DEST/zju-connect"
    file "$DEST/zju-connect" || true
    "$DEST/zju-connect" -h 2>&1 | head -n 6 || true
    exit 0
  fi

  if ! have_network; then
    cat >&2 <<'MSG'
✗ No outbound HTTPS network (DNS/connect failed).

This environment cannot reach the internet. On your Mac (outside sandbox), run:

  ./Scripts/download-core.sh

Or manually:
  1) Open https://github.com/Mythologyli/zju-connect/releases
  2) Download zju-connect-darwin-arm64.zip (Apple Silicon) or darwin-amd64 (Intel)
  3) Unzip and place binary at: Core/zju-connect
MSG
    exit 2
  fi

  if try_github_release || try_tag_urls || try_go_install; then
    if [[ -x "$DEST/zju-connect" ]]; then
      echo "—— version ——"
      "$DEST/zju-connect" -h 2>&1 | head -n 10 || true
      file "$DEST/zju-connect" || true
      exit 0
    fi
  fi

  cat >&2 <<'MSG'
✗ Failed to obtain zju-connect after all strategies.

Manual options:
  1) Download from https://github.com/Mythologyli/zju-connect/releases
     Expected asset: zju-connect-darwin-arm64.zip  (or darwin-amd64)
     Put binary at:  Core/zju-connect
  2) go install github.com/Mythologyli/zju-connect@latest
     then: cp "$(go env GOPATH)/bin/zju-connect" Core/
MSG
  exit 1
}

main "$@"
