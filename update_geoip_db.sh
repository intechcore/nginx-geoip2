#!/bin/bash
set -euo pipefail

LICENSE_KEY="${MAXMIND_LICENSE_KEY:-}"

if [[ -z "$LICENSE_KEY" ]]; then
    echo "[ERROR] MAXMIND_LICENSE_KEY environment variable is required"
    echo "Usage: MAXMIND_LICENSE_KEY=your_key ./update_geoip_db.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_FILE="$SCRIPT_DIR/GeoLite2-Country.mmdb"

TMP_DIR=$(mktemp -d)
ARCHIVE="$TMP_DIR/db.tar.gz"

trap 'rm -rf "$TMP_DIR"' EXIT

echo "[INFO] Downloading GeoLite2 database..."
curl -sSLf --proto '=https' --tlsv1.2 -o "$ARCHIVE" "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=${LICENSE_KEY}&suffix=tar.gz"

echo "[INFO] Extracting mmdb..."
tar -xzf "$ARCHIVE" -C "$TMP_DIR"

FOUND_FILE=$(find "$TMP_DIR" -name "GeoLite2-Country.mmdb" | head -n1)

if [[ -z "$FOUND_FILE" || ! -f "$FOUND_FILE" ]]; then
    echo "[ERROR] GeoLite2-Country.mmdb not found in archive"
    exit 1
fi

mv "$FOUND_FILE" "$TARGET_FILE"
echo "[INFO] GeoLite2-Country.mmdb saved to: $TARGET_FILE"
