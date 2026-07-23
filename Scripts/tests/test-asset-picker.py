#!/usr/bin/env python3
"""Offline test: release asset naming used by download-core.sh"""
import json, re, sys

def pick(assets, arch):
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
                return a.get("browser_download_url"), name
    return None, None

# Real-world v1.2.1 style assets
modern = [
    {"name": "zju-connect-darwin-arm64.zip", "browser_download_url": "https://example/zju-connect-darwin-arm64.zip"},
    {"name": "zju-connect-darwin-amd64.zip", "browser_download_url": "https://example/zju-connect-darwin-amd64.zip"},
    {"name": "checksums.txt", "browser_download_url": "https://example/checksums.txt"},
]
# Legacy style
legacy = [
    {"name": "zju-connect_darwin_arm64.tar.gz", "browser_download_url": "https://example/legacy-arm64.tar.gz"},
]

url, name = pick(modern, "arm64")
assert name == "zju-connect-darwin-arm64.zip", name
assert url.endswith("arm64.zip")

url, name = pick(modern, "amd64")
assert name == "zju-connect-darwin-amd64.zip"

url, name = pick(legacy, "arm64")
assert name == "zju-connect_darwin_arm64.tar.gz"

# Old broken marker would fail on modern assets
old_marker = "zju-connect_darwin_arm64"
assert not any(old_marker in a["name"] and a["name"].endswith(".tar.gz") for a in modern)

print("OK: asset picker matches modern + legacy release names")
