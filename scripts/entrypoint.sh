#!/bin/sh
set -e

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [Entrypoint] $1"
}

if [ -z "$MAXMIND_LICENSE_KEY" ]; then
    log "ERROR: MAXMIND_LICENSE_KEY environment variable is required"
    exit 1
fi

# ─── Schedule contracts ────────────────────────────────────────────────────
# Both periodic jobs are driven by supercronic via a single /tmp/nginx-crontab.
# GEOIP_UPDATE_CRON: cron expression for the GeoIP refresh job (default 03:00).
# LOGROTATE_CRON:    cron expression for the logrotate job (default 00:30).
GEOIP_UPDATE_CRON="${GEOIP_UPDATE_CRON:-0 3 * * *}"

# Initial GeoIP database download — synchronous so we fail fast if the very
# first download fails AND no bundled DB exists.
GEOIP_FILE="${GEOIP_DIR:-/usr/share/GeoIP}/GeoLite2-Country.mmdb"
log "Downloading initial GeoIP database..."
if ! /usr/local/bin/update-geoip.sh; then
    if [ -f "$GEOIP_FILE" ]; then
        log "WARNING: Download failed, using existing database"
    else
        log "ERROR: Download failed and no existing database found"
        exit 1
    fi
fi

# ─── Build combined crontab for supercronic ────────────────────────────────
LOGROTATE_ENABLED="${LOGROTATE_ENABLED:-true}"
LOGROTATE_CRON="${LOGROTATE_CRON:-30 0 * * *}"
LOGROTATE_FREQUENCY="${LOGROTATE_FREQUENCY:-daily}"
LOGROTATE_KEEP="${LOGROTATE_KEEP:-14}"
LOGROTATE_MAXAGE="${LOGROTATE_MAXAGE:-30}"
LOGROTATE_MAXSIZE="${LOGROTATE_MAXSIZE:-}"
LOGROTATE_COMPRESS="${LOGROTATE_COMPRESS:-true}"
LOGROTATE_PATTERN="${LOGROTATE_PATTERN:-/var/log/nginx/*.log}"

CRONTAB=/tmp/nginx-crontab
: > "$CRONTAB"

# GeoIP refresh job — always scheduled (license validated above).
echo "$GEOIP_UPDATE_CRON /usr/local/bin/geoip-cron.sh" >> "$CRONTAB"
log "Scheduling: GeoIP updater (cron='$GEOIP_UPDATE_CRON')"

# Log rotation job — optional.
if [ "$LOGROTATE_ENABLED" = "true" ]; then
    if [ "$LOGROTATE_COMPRESS" = "true" ]; then
        LOGROTATE_COMPRESS_BLOCK='    compress
    delaycompress'
    else
        LOGROTATE_COMPRESS_BLOCK=""
    fi
    if [ -n "$LOGROTATE_MAXSIZE" ]; then
        LOGROTATE_MAXSIZE_LINE="    maxsize $LOGROTATE_MAXSIZE"
    else
        LOGROTATE_MAXSIZE_LINE=""
    fi
    export LOGROTATE_PATTERN LOGROTATE_FREQUENCY LOGROTATE_KEEP LOGROTATE_MAXAGE \
        LOGROTATE_MAXSIZE_LINE LOGROTATE_COMPRESS_BLOCK

    LOGROTATE_CONF=/tmp/nginx-logrotate.conf
    # shellcheck disable=SC2016
    # envsubst whitelist must be literal '${VAR}' tokens, not shell-expanded
    envsubst '${LOGROTATE_PATTERN} ${LOGROTATE_FREQUENCY} ${LOGROTATE_KEEP} ${LOGROTATE_MAXAGE} ${LOGROTATE_MAXSIZE_LINE} ${LOGROTATE_COMPRESS_BLOCK}' \
        < /usr/local/share/nginx-geoip/logrotate.tpl > "$LOGROTATE_CONF"

    echo "$LOGROTATE_CRON /usr/local/bin/logrotate-cron.sh" >> "$CRONTAB"
    log "Scheduling: log rotator (cron='$LOGROTATE_CRON', frequency=$LOGROTATE_FREQUENCY, keep=$LOGROTATE_KEEP, maxage=$LOGROTATE_MAXAGE, maxsize='${LOGROTATE_MAXSIZE:-none}', compress=$LOGROTATE_COMPRESS)"
else
    log "Log rotation disabled (LOGROTATE_ENABLED=false)"
fi

# Validate the generated crontab BEFORE starting supercronic in the background:
# a bad cron expression here would otherwise crash supercronic silently
# (background &) and leave us with a healthy-looking container that never
# fires its scheduled jobs.
if ! /usr/local/bin/supercronic -test "$CRONTAB" >/dev/null 2>&1; then
    log "ERROR: Invalid crontab — supercronic -test failed. Rendered crontab:"
    sed 's/^/    /' "$CRONTAB"
    exit 1
fi

log "Starting supercronic"
# -quiet suppresses supercronic's own info messages (job started/succeeded);
# -passthrough-logs keeps job stdout/stderr unwrapped so our prefixed
# wrapper output (e.g. '[GeoIP] Update completed') reaches the container
# logs verbatim instead of being embedded in supercronic's JSON-ish format.
/usr/local/bin/supercronic -quiet -passthrough-logs "$CRONTAB" &

# Named pipe to filter all nginx output through a timestamp formatter.
# nginx (via exec) becomes PID 1 and handles signals properly.
# The background reader adds unified timestamps to every line.
LOGPIPE="/tmp/nginx-log-pipe"
rm -f "$LOGPIPE"
mkfifo "$LOGPIPE"

(while IFS= read -r line; do
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    case "$line" in
        # nginx error_log: strip its timestamp "YYYY/MM/DD HH:MM:SS [level] ..."
        [0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\ *)
            printf '%s %s\n' "$ts" "${line#????/??/?? ??:??:?? }"
            ;;
        # /docker-entrypoint.sh: ... → [nginx] ...
        /docker-entrypoint.sh:\ *)
            printf '%s [nginx] %s\n' "$ts" "${line#/docker-entrypoint.sh: }"
            ;;
        # 10-listen-on-ipv6-by-default.sh: ... → [nginx] ...
        [0-9][0-9]-*.sh:\ *)
            printf '%s [nginx] %s\n' "$ts" "${line#*: }"
            ;;
        *)
            printf '%s %s\n' "$ts" "$line"
            ;;
    esac
done < "$LOGPIPE") &

# Hand off to nginx entrypoint — all its output goes through the timestamp filter
log "Handing off to nginx entrypoint"
exec /docker-entrypoint.sh "$@" > "$LOGPIPE"
