#!/bin/sh
set -e

GEOIP_UPDATE_TIME="${GEOIP_UPDATE_TIME:-03:00}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [Entrypoint] $1"
}

log_updater() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [GeoIP Updater] $1"
}

if [ -z "$MAXMIND_LICENSE_KEY" ]; then
    log "ERROR: MAXMIND_LICENSE_KEY environment variable is required"
    exit 1
fi

# Validate GEOIP_UPDATE_TIME format (HH:MM)
case "$GEOIP_UPDATE_TIME" in
    [0-2][0-9]:[0-5][0-9])
        hour=$(echo "$GEOIP_UPDATE_TIME" | cut -d: -f1)
        if [ "$hour" -gt 23 ]; then
            log "ERROR: Invalid GEOIP_UPDATE_TIME='$GEOIP_UPDATE_TIME' (hour must be 00-23)"
            exit 1
        fi
        ;;
    *)
        log "ERROR: Invalid GEOIP_UPDATE_TIME='$GEOIP_UPDATE_TIME' (expected HH:MM, e.g. 03:00)"
        exit 1
        ;;
esac

# Calculate seconds until target time
seconds_until() {
    target_hour=$(echo "$1" | cut -d: -f1)
    target_min=$(echo "$1" | cut -d: -f2)

    now=$(date +%s)
    target=$(date -d "today $target_hour:$target_min" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M" "$(date +%Y-%m-%d) $target_hour:$target_min" +%s)

    # If target time already passed today, schedule for tomorrow
    if [ "$target" -le "$now" ]; then
        target=$((target + 86400))
    fi

    echo $((target - now))
}

# Initial GeoIP database download
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

# Start background updater (writes to original stdout, already has timestamps)
log "Starting GeoIP daily updater (scheduled at ${GEOIP_UPDATE_TIME})"
(
    while true; do
        sleep_seconds=$(seconds_until "$GEOIP_UPDATE_TIME")
        sleep_hours=$((sleep_seconds / 3600))
        sleep_mins=$(( (sleep_seconds % 3600) / 60 ))
        log_updater "Next update in ${sleep_hours}h ${sleep_mins}m (at ${GEOIP_UPDATE_TIME})"
        sleep "$sleep_seconds"
        log_updater "Running scheduled update..."
        if /usr/local/bin/update-geoip.sh; then
            log_updater "Update completed successfully"
        else
            log_updater "Update failed, will retry tomorrow"
        fi
        # Small delay to avoid running twice at the same minute
        sleep 60
    done
) &

# ─── Log rotation ───
# Render logrotate config from template via envsubst, run logrotate on a
# cron schedule via supercronic (cron replacement for non-root containers).
LOGROTATE_ENABLED="${LOGROTATE_ENABLED:-true}"
LOGROTATE_CRON="${LOGROTATE_CRON:-30 0 * * *}"
LOGROTATE_FREQUENCY="${LOGROTATE_FREQUENCY:-daily}"
LOGROTATE_KEEP="${LOGROTATE_KEEP:-14}"
LOGROTATE_COMPRESS="${LOGROTATE_COMPRESS:-true}"
LOGROTATE_PATTERN="${LOGROTATE_PATTERN:-/var/log/nginx/*.log}"

if [ "$LOGROTATE_ENABLED" = "true" ]; then
    if [ "$LOGROTATE_COMPRESS" = "true" ]; then
        LOGROTATE_COMPRESS_BLOCK='    compress
    delaycompress'
    else
        LOGROTATE_COMPRESS_BLOCK=""
    fi
    export LOGROTATE_PATTERN LOGROTATE_FREQUENCY LOGROTATE_KEEP LOGROTATE_COMPRESS_BLOCK

    LOGROTATE_CONF=/tmp/nginx-logrotate.conf
    LOGROTATE_CRONTAB=/tmp/nginx-crontab

    # shellcheck disable=SC2016
    # envsubst whitelist must be literal '${VAR}' tokens, not shell-expanded
    envsubst '${LOGROTATE_PATTERN} ${LOGROTATE_FREQUENCY} ${LOGROTATE_KEEP} ${LOGROTATE_COMPRESS_BLOCK}' \
        < /usr/local/share/nginx-geoip/logrotate.tpl > "$LOGROTATE_CONF"

    printf '%s /usr/sbin/logrotate -s /var/log/nginx/.logrotate-state %s\n' \
        "$LOGROTATE_CRON" "$LOGROTATE_CONF" > "$LOGROTATE_CRONTAB"

    log "Starting log rotation scheduler (cron='$LOGROTATE_CRON', frequency=$LOGROTATE_FREQUENCY, keep=$LOGROTATE_KEEP, compress=$LOGROTATE_COMPRESS)"
    /usr/local/bin/supercronic -quiet "$LOGROTATE_CRONTAB" &
else
    log "Log rotation disabled (LOGROTATE_ENABLED=false)"
fi

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
