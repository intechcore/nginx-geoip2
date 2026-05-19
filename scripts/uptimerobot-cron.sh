#!/bin/sh
# Wrapper invoked by supercronic for periodic UptimeRobot IP-list refresh.
# Mirrors the [GeoIP] / [LogRotate] wrappers so all background jobs share
# the same log shape.
set -e

ts() {
    date '+%Y-%m-%d %H:%M:%S'
}

echo "$(ts) [UptimeRobot] Running scheduled update..."
if /usr/local/bin/update-uptimerobot.sh; then
    echo "$(ts) [UptimeRobot] Update completed successfully"
else
    echo "$(ts) [UptimeRobot] Update failed, will retry on next cron fire"
fi
