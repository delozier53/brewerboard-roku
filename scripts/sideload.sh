#!/usr/bin/env bash
# Bundle the channel and sideload it to a Roku TV in developer mode.
#
# Usage:
#   ./scripts/sideload.sh <tv-ip>            # prompts for password
#   ROKU_DEV_PASS=xxx ./scripts/sideload.sh <tv-ip>   # password from env
#
# How it works: zips manifest + source/ + components/ + images/ into a
# temp file, then POSTs to the TV's Developer Application Installer at
# `http://<tv-ip>/plugin_install` using Roku's `rokudev:<password>` HTTP
# basic auth. The TV reloads the channel and launches it immediately.

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <tv-ip>"
    echo "Example: $0 192.168.1.42"
    exit 1
fi

TV_IP="$1"
ROKU_DEV_USER="${ROKU_DEV_USER:-rokudev}"
ROKU_DEV_PASS="${ROKU_DEV_PASS:-}"

if [ -z "$ROKU_DEV_PASS" ]; then
    read -r -s -p "Roku dev password for $TV_IP: " ROKU_DEV_PASS
    echo
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Build a clean zip excluding scripts/, .git, README, etc.
ZIP_OUT="$(mktemp -t brewerboard-roku).zip"
trap 'rm -f "$ZIP_OUT"' EXIT

echo "==> Zipping channel into $ZIP_OUT"
zip -qr "$ZIP_OUT" \
    manifest \
    source \
    components \
    images

ZIP_SIZE=$(stat -f%z "$ZIP_OUT" 2>/dev/null || stat -c%s "$ZIP_OUT")
echo "    package size: $ZIP_SIZE bytes"

echo "==> Uploading to http://$TV_IP/plugin_install"

# Roku's installer wants digest auth and a multipart form post with field
# names `mysubmit=Install` + `archive=<zip>`. Using `--anyauth` instead of
# `--digest` matters: with strict `--digest`, curl pre-emptively sends an
# auth header but the Roku installer rejects the upload mid-stream with a
# second 401 (manifests as "Send failure: Broken pipe" or empty response).
# `--anyauth` does an unauth probe first, accepts the WWW-Authenticate
# challenge, then sends the authenticated upload — which the TV accepts.
RESP=$(curl -sS --anyauth \
    --user "$ROKU_DEV_USER:$ROKU_DEV_PASS" \
    --form "mysubmit=Install" \
    --form "archive=@$ZIP_OUT" \
    --form "passwd=" \
    "http://$TV_IP/plugin_install" || true)

if echo "$RESP" | grep -qi "Install Success"; then
    echo "==> Install success — channel running on $TV_IP"
elif echo "$RESP" | grep -qi "Application Received"; then
    echo "==> Application received — channel running on $TV_IP"
elif echo "$RESP" | grep -qi "Identical to previous"; then
    echo "==> No change (zip identical to last upload). Bump build_version in manifest if you want a forced reload."
else
    echo "!! Unexpected response from TV. First 1KB:"
    echo "$RESP" | head -c 1024
    exit 1
fi
