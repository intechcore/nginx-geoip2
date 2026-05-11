#!/bin/sh
# Wrapper invoked by supercronic for periodic GeoIP database refresh.
# Adds the same '[GeoIP] ...' timestamped prefix the entrypoint uses, so
# scheduled-update output matches the rest of the container logs.
set -e

ts() {
    date '+%Y-%m-%d %H:%M:%S'
}

echo "$(ts) [GeoIP] Running scheduled update..."
if /usr/local/bin/update-geoip.sh; then
    echo "$(ts) [GeoIP] Update completed successfully"
else
    echo "$(ts) [GeoIP] Update failed, will retry on next cron fire"
fi
