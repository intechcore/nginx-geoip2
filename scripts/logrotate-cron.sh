#!/bin/sh
# Wrapper invoked by supercronic for periodic log rotation.
# Adds the same '[LogRotate] ...' timestamped prefix the entrypoint uses, so
# scheduled-rotation output matches the rest of the container logs. logrotate
# itself prints config-parse details to stderr only on -d/-v; the normal,
# successful run is silent.
set -e

ts() {
    date '+%Y-%m-%d %H:%M:%S'
}

echo "$(ts) [LogRotate] Running scheduled rotation..."
if /usr/sbin/logrotate -s /var/log/nginx/.logrotate-state /tmp/nginx-logrotate.conf; then
    echo "$(ts) [LogRotate] Rotation completed"
else
    echo "$(ts) [LogRotate] Rotation failed"
fi
