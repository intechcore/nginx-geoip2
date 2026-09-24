#!/bin/sh
# Fetches the UptimeRobot monitoring IPs and renders an nginx `geo`
# block at $UPTIMEROBOT_DIR/uptimerobot.map.conf.
#
# Failure policy: fail-open. On network/HTTP/validation failure we leave the
# existing rendered file in place (which may be the baseline shipped in the
# image) and exit non-zero. The cron wrapper logs the failure but does not
# crash the container.
#
# Reload policy: nginx -s reload is only issued when the rendered file's
# sha256 differs from the previous version. Pidfile presence determines
# whether nginx is actually running (skips reload at first boot when the
# entrypoint is still wiring things up).
set -e

UPTIMEROBOT_DIR="${UPTIMEROBOT_DIR:-/etc/nginx/uptimerobot}"
UPTIMEROBOT_FILE="$UPTIMEROBOT_DIR/uptimerobot.map.conf"
UPTIMEROBOT_URL="${UPTIMEROBOT_URL:-https://uptimerobot.com/inc/files/ips/IPv4andIPv6.txt}"
NGINX_PID_FILE="${NGINX_PID_FILE:-/tmp/nginx.pid}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [UptimeRobot] $1"
}

mkdir -p "$UPTIMEROBOT_DIR"

TMP_DIR=$(mktemp -d)
RAW="$TMP_DIR/raw.txt"
RENDERED="$TMP_DIR/rendered.conf"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log "Fetching IP list from $UPTIMEROBOT_URL"
HTTP_CODE=$(curl -sSLf -o "$RAW" -w "%{http_code}" --max-time 30 "$UPTIMEROBOT_URL" 2>/dev/null) || {
    log "ERROR: Download failed (HTTP ${HTTP_CODE:-?}). Keeping existing file."
    exit 1
}

RAW_SIZE=$(wc -c < "$RAW" | tr -d ' ')
if [ "$RAW_SIZE" -lt 16 ]; then
    log "ERROR: Response too small (${RAW_SIZE} bytes), refusing to render. Keeping existing file."
    exit 1
fi

# Validate and collect entries. Each line must be a bare IPv4/IPv6 address or
# CIDR. We strip CR (the source ships CRLF), comments, and blank lines.
# Anything that doesn't match the IP regex is rejected so a corrupted
# response (HTML error page, redirect notice) can't slip into the rendered
# `geo` block and break nginx -s reload.
ENTRIES="$TMP_DIR/entries.txt"
tr -d '\r' < "$RAW" \
    | sed -e 's/#.*$//' -e 's/[[:space:]]\+$//' -e '/^[[:space:]]*$/d' \
    | grep -E '^([0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?|[0-9a-fA-F:]+(/[0-9]{1,3})?)$' \
    > "$ENTRIES" || true

COUNT=$(wc -l < "$ENTRIES" | tr -d ' ')
if [ "$COUNT" -lt 1 ]; then
    log "ERROR: No valid IP entries parsed from response. Keeping existing file."
    exit 1
fi

# Render nginx `geo` block. Same variable name as the legacy static map in
# intechcore/services so the vhost `if ($is_uptimerobot = 1)` checks stay
# unchanged.
#
# The header is deterministic on purpose — no timestamp. If the rendered
# bytes depend on $(date), the sha256 compare-and-skip below sees every
# run as a change, defeating the optimisation and triggering a spurious
# nginx -s reload on every cron tick. Generation time lives in the
# log()ged line above instead.
render_geo() {
    echo "# Source: $UPTIMEROBOT_URL"
    echo "# Entries: $COUNT"
    echo "geo \$is_uptimerobot {"
    echo "  default 0;"
    sed 's/.*/  & 1;/' "$ENTRIES"
    echo "}"
}
render_geo > "$RENDERED"

# Skip work if content is byte-identical to what's already in place. This
# also means no nginx reload — useful when supercronic fires daily but the
# upstream list rarely changes.
if [ -f "$UPTIMEROBOT_FILE" ]; then
    OLD_HASH=$(sha256sum "$UPTIMEROBOT_FILE" | awk '{print $1}')
    NEW_HASH=$(sha256sum "$RENDERED"          | awk '{print $1}')
    if [ "$OLD_HASH" = "$NEW_HASH" ]; then
        log "No changes ($COUNT entries, sha256=${NEW_HASH%????????????????????????????????????????????????????????})"
        exit 0
    fi
fi

mv -f "$RENDERED" "$UPTIMEROBOT_FILE"
log "Rendered $UPTIMEROBOT_FILE ($COUNT entries)"

# Reload nginx only if it's actually running. At first boot the entrypoint
# calls this script before nginx starts, so there's no pidfile yet and we
# just leave the new file in place — nginx will pick it up on its first load.
if [ -s "$NGINX_PID_FILE" ]; then
    PID=$(cat "$NGINX_PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        if nginx -t >/dev/null 2>&1; then
            kill -HUP "$PID" && log "nginx reload signalled (pid=$PID)"
        else
            log "ERROR: nginx -t failed after render. Not reloading. Inspect $UPTIMEROBOT_FILE manually."
            exit 1
        fi
    fi
fi
