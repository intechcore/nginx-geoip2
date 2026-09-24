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
# All periodic jobs are driven by supercronic via a single /tmp/nginx-crontab.
# GEOIP_UPDATE_CRON:       cron expression for the GeoIP refresh job (default 03:00).
# UPTIMEROBOT_UPDATE_CRON: cron expression for the UptimeRobot IP-list refresh (default 04:15).
# LOGROTATE_CRON:          cron expression for the logrotate job (default 00:30).
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

# ─── UptimeRobot IP-list bootstrap ─────────────────────────────────────────
# Always ensure a valid `geo $is_uptimerobot { ... }` file exists before
# nginx starts, even on a cold volume with no network. The baseline (shipped
# in the image at /usr/local/share/nginx-geoip/uptimerobot.map.baseline)
# contains only `default 0;` — so the variable resolves to 0 for everyone
# until the first successful fetch replaces it. This is fail-open in the
# nginx-startup sense (never block boot), but matches-nobody in the
# access-control sense (no IPs are pre-trusted as UptimeRobot).
UPTIMEROBOT_ENABLED="${UPTIMEROBOT_ENABLED:-true}"
UPTIMEROBOT_UPDATE_CRON="${UPTIMEROBOT_UPDATE_CRON:-15 4 * * *}"
UPTIMEROBOT_DIR="${UPTIMEROBOT_DIR:-/etc/nginx/uptimerobot}"
UPTIMEROBOT_URL="${UPTIMEROBOT_URL:-https://uptimerobot.com/inc/files/ips/IPv4andIPv6.txt}"
export UPTIMEROBOT_DIR UPTIMEROBOT_URL
UPTIMEROBOT_FILE="$UPTIMEROBOT_DIR/uptimerobot.map.conf"
UPTIMEROBOT_BASELINE=/usr/local/share/nginx-geoip/uptimerobot.map.baseline

# Initial fetch, run in the background. A failure keeps the baseline or the
# last-known-good file.
initial_uptimerobot_fetch() {
    if ! /usr/local/bin/update-uptimerobot.sh; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [UptimeRobot] WARNING: Initial fetch failed, continuing with baseline/last-known-good file"
    fi
}

if [ "$UPTIMEROBOT_ENABLED" = "true" ]; then
    mkdir -p "$UPTIMEROBOT_DIR"
    if [ ! -f "$UPTIMEROBOT_FILE" ]; then
        cp "$UPTIMEROBOT_BASELINE" "$UPTIMEROBOT_FILE"
        log "UptimeRobot: installed baseline at $UPTIMEROBOT_FILE"
    fi

    # Initial fetch is fail-open AND asynchronous — nginx starts immediately
    # on the baseline (or last-known-good) file, and the fresh list arrives
    # seconds later via the same script running in the background. Once nginx
    # is up, update-uptimerobot.sh issues `nginx -s reload` if and only if
    # the rendered content changed.
    #
    # Synchronous fetch was a problem under QEMU-emulated arm64 in CI: the
    # extra-slow TLS handshake could stretch the entrypoint past `docker
    # stop`'s grace window, producing a 137 exit on the graceful-shutdown
    # test. Backgrounding decouples startup time from upstream latency.
    log "Fetching initial UptimeRobot IP list (async, baseline already in place)..."
    initial_uptimerobot_fetch &
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

# UptimeRobot IP-list refresh job — optional. Default-on so existing
# deployments using $is_uptimerobot get fresh lists out of the box; set
# UPTIMEROBOT_ENABLED=false to skip both the initial fetch and the cron entry.
if [ "$UPTIMEROBOT_ENABLED" = "true" ]; then
    echo "$UPTIMEROBOT_UPDATE_CRON /usr/local/bin/uptimerobot-cron.sh" >> "$CRONTAB"
    log "Scheduling: UptimeRobot updater (cron='$UPTIMEROBOT_UPDATE_CRON', url='$UPTIMEROBOT_URL')"
else
    log "UptimeRobot updater disabled (UPTIMEROBOT_ENABLED=false)"
fi

# Log rotation job — optional.
if [ "$LOGROTATE_ENABLED" = "true" ]; then
    if [ "$LOGROTATE_COMPRESS" = "true" ]; then
        LOGROTATE_COMPRESS_BLOCK=$(printf '    compress\n    delaycompress')
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

# Named pipes to filter the nginx output through a timestamp formatter.
# nginx (via exec) becomes PID 1 and handles signals properly.
# The background readers add unified timestamps to every line.
LOGPIPE="/tmp/nginx-log-pipe"
ERRPIPE="/tmp/nginx-error-pipe"
rm -f "$LOGPIPE" "$ERRPIPE"
mkfifo "$LOGPIPE" "$ERRPIPE"

# The nginx image links /var/log/nginx/error.log to /dev/stderr, the default
# error_log. Point it at the error pipe instead, so the error log reaches the
# filter and still leaves the container on stderr. stderr itself stays
# unfiltered: nginx writes a fatal start error there right before it exits,
# and a filter could lose that line. A mounted log directory with a real file
# keeps it.
ERROR_LOG=/var/log/nginx/error.log
case "$(readlink "$ERROR_LOG" || true)" in
    /dev/stderr|"$ERRPIPE")
        ln -sf "$ERRPIPE" "$ERROR_LOG" || log "WARNING: Cannot link $ERROR_LOG to the log filter"
        ;;
esac

format_log() {
    while IFS= read -r line; do
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
    done
}

# The redirection opens the pipe in the background process, so the
# entrypoint does not block here. The error pipe is opened read-write, so
# its reader never sees end of file when nginx closes and reopens its logs.
format_log < "$LOGPIPE" &
format_log <> "$ERRPIPE" >&2 &

# Hand off to nginx entrypoint — all its output goes through the timestamp filter
log "Handing off to nginx entrypoint"
exec /docker-entrypoint.sh "$@" > "$LOGPIPE"
