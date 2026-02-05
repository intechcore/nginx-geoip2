#!/bin/sh
set -e

GEOIP_DIR="${GEOIP_DIR:-/usr/share/GeoIP}"
GEOIP_FILE="$GEOIP_DIR/GeoLite2-Country.mmdb"

if [ -z "$MAXMIND_LICENSE_KEY" ]; then
    echo "[GeoIP] ERROR: MAXMIND_LICENSE_KEY is not set"
    exit 1
fi

mkdir -p "$GEOIP_DIR"

TMP_DIR=$(mktemp -d)
ARCHIVE="$TMP_DIR/db.tar.gz"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "[GeoIP] Downloading GeoLite2-Country database..."
if curl -sSLf -o "$ARCHIVE" "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=${MAXMIND_LICENSE_KEY}&suffix=tar.gz"; then
    tar -xzf "$ARCHIVE" -C "$TMP_DIR"
    FOUND_FILE=$(find "$TMP_DIR" -name "GeoLite2-Country.mmdb" | head -n1)

    if [ -n "$FOUND_FILE" ] && [ -f "$FOUND_FILE" ]; then
        mv "$FOUND_FILE" "$GEOIP_FILE"
        echo "[GeoIP] Database updated: $GEOIP_FILE"
    else
        echo "[GeoIP] ERROR: GeoLite2-Country.mmdb not found in archive"
        exit 1
    fi
else
    echo "[GeoIP] ERROR: Failed to download database"
    exit 1
fi
