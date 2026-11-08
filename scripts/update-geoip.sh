#!/bin/sh
# Downloads GeoLite2-Country and the editions in GEOIP_EXTRA_EDITIONS from
# MaxMind into GEOIP_DIR. Exits non-zero only when GeoLite2-Country fails.
# A failed extra edition logs a warning and keeps its previous file.
set -e

GEOIP_DIR="${GEOIP_DIR:-/usr/share/GeoIP}"
GEOIP_EXTRA_EDITIONS="${GEOIP_EXTRA_EDITIONS:-}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [GeoIP] $1"
}

if [ -z "$MAXMIND_LICENSE_KEY" ]; then
    log "ERROR: MAXMIND_LICENSE_KEY is not set"
    exit 1
fi

mkdir -p "$GEOIP_DIR"

TMP_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Downloads one edition and installs <edition>.mmdb into GEOIP_DIR.
# $1 is the edition ID, $2 the level of the failure messages.
# The caller runs it in an if, where set -e is off, so every step checks
# its own result. The URL holds the license key and is never printed.
update_edition() {
    edition=$1
    level=$2
    work="$TMP_DIR/$edition"
    archive="$work/db.tar.gz"
    target="$GEOIP_DIR/$edition.mmdb"
    mkdir -p "$work" || return 1

    log "Downloading $edition database..."
    http_code=$(curl -sSLf --proto '=https' --tlsv1.2 -o "$archive" -w "%{http_code}" "https://download.maxmind.com/app/geoip_download?edition_id=${edition}&license_key=${MAXMIND_LICENSE_KEY}&suffix=tar.gz" 2>/dev/null) || {
        log "$level: Download failed (HTTP $http_code)"
        return 1
    }

    archive_size=$(wc -c < "$archive" | tr -d ' ')
    if [ "$archive_size" -lt 1024 ]; then
        log "$level: Downloaded archive is too small (${archive_size} bytes), possibly corrupt"
        return 1
    fi

    tar -xzf "$archive" -C "$work" || {
        log "$level: Cannot extract the $edition archive"
        return 1
    }
    found=$(find "$work" -name "$edition.mmdb" | head -n1)
    if [ -z "$found" ] || [ ! -f "$found" ]; then
        log "$level: $edition.mmdb not found in archive"
        return 1
    fi

    # Stage the file in GEOIP_DIR first: a rename within one file system is
    # atomic, so a reader never sees a half-written database.
    db_size=$(wc -c < "$found" | tr -d ' ')
    staged="$GEOIP_DIR/.$edition.mmdb.tmp"
    if ! mv "$found" "$staged" || ! mv "$staged" "$target"; then
        rm -f "$staged"
        log "$level: Cannot install $target"
        return 1
    fi
    log "Database updated: $target ($(echo "$db_size" | awk '{printf "%.1f MB", $1/1048576}'))"
}

country_status=0
update_edition GeoLite2-Country ERROR || country_status=1

# The edition IDs go into the URL and a file name: letters, digits and
# hyphens only. set -f keeps a stray * from expanding to file names.
set -f
for edition in $GEOIP_EXTRA_EDITIONS; do
    case "$edition" in
        *[!A-Za-z0-9-]*)
            log "WARNING: Skipping invalid edition name '$edition', allowed are letters, digits and hyphens"
            continue
            ;;
    esac
    if ! update_edition "$edition" WARNING; then
        log "WARNING: $edition update failed, keeping the previous file"
    fi
done
set +f

exit "$country_status"
