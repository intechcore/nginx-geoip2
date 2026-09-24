#!/bin/sh
set -e

GEOIP_DIR="${GEOIP_DIR:-/usr/share/GeoIP}"
GEOIP_FILE="$GEOIP_DIR/GeoLite2-Country.mmdb"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [GeoIP] $1"
}

if [ -z "$MAXMIND_LICENSE_KEY" ]; then
    log "ERROR: MAXMIND_LICENSE_KEY is not set"
    exit 1
fi

mkdir -p "$GEOIP_DIR"

TMP_DIR=$(mktemp -d)
ARCHIVE="$TMP_DIR/db.tar.gz"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log "Downloading GeoLite2-Country database..."
HTTP_CODE=$(curl -sSLf --proto '=https' --tlsv1.2 -o "$ARCHIVE" -w "%{http_code}" "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=${MAXMIND_LICENSE_KEY}&suffix=tar.gz" 2>/dev/null) || {
    log "ERROR: Download failed (HTTP $HTTP_CODE)"
    exit 1
}

ARCHIVE_SIZE=$(wc -c < "$ARCHIVE" | tr -d ' ')
if [ "$ARCHIVE_SIZE" -lt 1024 ]; then
    log "ERROR: Downloaded archive is too small (${ARCHIVE_SIZE} bytes), possibly corrupt"
    exit 1
fi

tar -xzf "$ARCHIVE" -C "$TMP_DIR"
FOUND_FILE=$(find "$TMP_DIR" -name "GeoLite2-Country.mmdb" | head -n1)

if [ -n "$FOUND_FILE" ] && [ -f "$FOUND_FILE" ]; then
    DB_SIZE=$(wc -c < "$FOUND_FILE" | tr -d ' ')
    mv "$FOUND_FILE" "$GEOIP_FILE"
    log "Database updated: $GEOIP_FILE ($(echo "$DB_SIZE" | awk '{printf "%.1f MB", $1/1048576}'))"
else
    log "ERROR: GeoLite2-Country.mmdb not found in archive"
    exit 1
fi
