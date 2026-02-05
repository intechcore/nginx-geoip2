#!/bin/sh
set -e

GEOIP_UPDATE_TIME="${GEOIP_UPDATE_TIME:-03:00}"

if [ -z "$MAXMIND_LICENSE_KEY" ]; then
    echo "[Entrypoint] ERROR: MAXMIND_LICENSE_KEY environment variable is required"
    exit 1
fi

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
echo "[Entrypoint] Downloading initial GeoIP database..."
/usr/local/bin/update-geoip.sh

# Start background updater
echo "[Entrypoint] Starting GeoIP daily updater (scheduled at ${GEOIP_UPDATE_TIME})"
(
    while true; do
        sleep_seconds=$(seconds_until "$GEOIP_UPDATE_TIME")
        echo "[GeoIP Updater] Next update in ${sleep_seconds}s (at ${GEOIP_UPDATE_TIME})"
        sleep "$sleep_seconds"
        echo "[GeoIP Updater] Running scheduled update..."
        /usr/local/bin/update-geoip.sh || echo "[GeoIP Updater] Update failed, will retry tomorrow"
        # Small delay to avoid running twice at the same minute
        sleep 60
    done
) &

# Execute original nginx entrypoint
exec /docker-entrypoint.sh "$@"
