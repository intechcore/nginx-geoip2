#!/bin/bash
set -euo pipefail

# Tests for the UptimeRobot IP-list updater pipeline.
#
# Usage: ./tests/uptimerobot/test-uptimerobot.sh [IMAGE_NAME:TAG]
#
# Each test runs in a fresh container with fixtures mounted at /fixtures.
# The script uses file:// URLs against those fixtures so the tests are
# offline and deterministic (no real https://uptimerobot.com call).

IMAGE="${1:-nginx-geoip2:latest}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"
TEST_MMDB="$SCRIPT_DIR/../integration/fixtures/GeoLite2-Country-Test.mmdb"
PASS=0
FAIL=0
TOTAL=10

# Track containers we start so cleanup runs even on early exit.
STARTED_CONTAINERS=()
cleanup_containers() {
    for c in "${STARTED_CONTAINERS[@]:-}"; do
        [[ -n "$c" ]] && docker rm -f "$c" > /dev/null 2>&1 || true
    done
}
trap cleanup_containers EXIT

pass() {
    PASS=$((PASS + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1"
}

# Run a shell snippet inside a fresh container with the fixtures mounted.
in_image() {
    docker run --rm \
        --entrypoint /bin/sh \
        -v "$FIXTURES:/fixtures:ro" \
        "$IMAGE" -c "$1"
}

echo "=== UptimeRobot tests for $IMAGE ==="
echo ""

# --- Test 1: image exists ---
echo "[1/$TOTAL] Image exists"
if docker image inspect "$IMAGE" > /dev/null 2>&1; then
    pass "Image $IMAGE found"
else
    fail "Image $IMAGE not found — build it first"
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

# --- Test 2: scripts present and executable ---
echo "[2/$TOTAL] Scripts and baseline shipped in image"
if in_image '
    test -x /usr/local/bin/update-uptimerobot.sh && \
    test -x /usr/local/bin/uptimerobot-cron.sh && \
    test -f /usr/local/share/nginx-geoip/uptimerobot.map.baseline
'; then
    pass "Scripts + baseline are in place"
else
    fail "One of the UptimeRobot files is missing from the image"
fi

# --- Test 3: baseline renders to valid nginx config ---
echo "[3/$TOTAL] Baseline is a valid nginx geo block"
# We wrap the baseline in a minimal nginx.conf and run `nginx -t`. The base
# image's default config already has http{} so we only need a snippet that
# includes the map. We mount our baseline as conf.d/test-uptimerobot.conf.
if in_image '
    cp /usr/local/share/nginx-geoip/uptimerobot.map.baseline /etc/nginx/conf.d/zz-uptimerobot.conf && \
    nginx -t 2>&1 | grep -q "syntax is ok"
'; then
    pass "Baseline geo block validates with nginx -t"
else
    fail "Baseline did not validate with nginx -t"
fi

# --- Test 4: happy-path render from fixture ---
echo "[4/$TOTAL] Renders valid file from a good fixture"
RENDER_OUT=$(in_image '
    export UPTIMEROBOT_DIR=/tmp/ur
    export UPTIMEROBOT_URL=file:///fixtures/ips-v1.txt
    /usr/local/bin/update-uptimerobot.sh && \
    cat /tmp/ur/uptimerobot.map.conf
' 2>&1) || RENDER_OUT=""
if echo "$RENDER_OUT" | grep -q '^geo \$is_uptimerobot {$' \
        && echo "$RENDER_OUT" | grep -q '^  default 0;$' \
        && echo "$RENDER_OUT" | grep -q '^  216.144.250.150 1;$' \
        && echo "$RENDER_OUT" | grep -q '^  2001:db8::1 1;$' \
        && echo "$RENDER_OUT" | grep -q '^  2001:db8::/32 1;$'; then
    pass "Rendered geo block contains expected entries"
else
    fail "Rendered output missing expected entries:"
    echo "$RENDER_OUT" | sed 's/^/    /'
fi

# --- Test 5: rendered file validates with nginx -t ---
echo "[5/$TOTAL] Rendered file passes nginx -t"
if in_image '
    export UPTIMEROBOT_DIR=/etc/nginx/uptimerobot
    export UPTIMEROBOT_URL=file:///fixtures/ips-v1.txt
    /usr/local/bin/update-uptimerobot.sh && \
    cp /etc/nginx/uptimerobot/uptimerobot.map.conf /etc/nginx/conf.d/zz-uptimerobot.conf && \
    nginx -t 2>&1 | grep -q "syntax is ok"
'; then
    pass "Rendered file is consumed by nginx without error"
else
    fail "Rendered file failed nginx -t"
fi

# --- Test 6: idempotency — no change on second run with same fixture ---
echo "[6/$TOTAL] Idempotent re-run (same fixture → same hash)"
IDEMPOTENT_OUT=$(in_image '
    export UPTIMEROBOT_DIR=/tmp/ur
    export UPTIMEROBOT_URL=file:///fixtures/ips-v1.txt
    /usr/local/bin/update-uptimerobot.sh >/dev/null
    H1=$(sha256sum /tmp/ur/uptimerobot.map.conf | awk "{print \$1}")
    /usr/local/bin/update-uptimerobot.sh >/dev/null
    H2=$(sha256sum /tmp/ur/uptimerobot.map.conf | awk "{print \$1}")
    [ "$H1" = "$H2" ] && echo MATCH
' 2>&1) || IDEMPOTENT_OUT=""
if echo "$IDEMPOTENT_OUT" | grep -q '^MATCH$'; then
    pass "Second run produces byte-identical output"
else
    fail "Hashes differ between runs: $IDEMPOTENT_OUT"
fi

# --- Test 7: change detected — different fixture flips the hash ---
echo "[7/$TOTAL] Hash changes when upstream list changes"
CHANGE_OUT=$(in_image '
    export UPTIMEROBOT_DIR=/tmp/ur
    UPTIMEROBOT_URL=file:///fixtures/ips-v1.txt /usr/local/bin/update-uptimerobot.sh >/dev/null
    H1=$(sha256sum /tmp/ur/uptimerobot.map.conf | awk "{print \$1}")
    UPTIMEROBOT_URL=file:///fixtures/ips-v2.txt /usr/local/bin/update-uptimerobot.sh >/dev/null
    H2=$(sha256sum /tmp/ur/uptimerobot.map.conf | awk "{print \$1}")
    [ "$H1" != "$H2" ] && grep -q "^  69.162.124.228 1;$" /tmp/ur/uptimerobot.map.conf && echo CHANGED
' 2>&1) || CHANGE_OUT=""
if echo "$CHANGE_OUT" | grep -q '^CHANGED$'; then
    pass "Second fixture produces a different rendered file"
else
    fail "File did not change as expected: $CHANGE_OUT"
fi

# --- Test 8: fail-open — garbage upstream keeps existing file ---
echo "[8/$TOTAL] Fail-open: garbage response keeps previous file"
FAIL_OPEN_OUT=$(in_image '
    export UPTIMEROBOT_DIR=/tmp/ur
    UPTIMEROBOT_URL=file:///fixtures/ips-v1.txt /usr/local/bin/update-uptimerobot.sh >/dev/null
    H1=$(sha256sum /tmp/ur/uptimerobot.map.conf | awk "{print \$1}")
    # Garbage fixture has no IP-shaped lines — script must reject it.
    if UPTIMEROBOT_URL=file:///fixtures/ips-garbage.txt /usr/local/bin/update-uptimerobot.sh >/dev/null 2>&1; then
        echo "UNEXPECTED_OK"
    fi
    H2=$(sha256sum /tmp/ur/uptimerobot.map.conf | awk "{print \$1}")
    [ "$H1" = "$H2" ] && echo PRESERVED
' 2>&1) || FAIL_OPEN_OUT=""
if echo "$FAIL_OPEN_OUT" | grep -q '^PRESERVED$' \
        && ! echo "$FAIL_OPEN_OUT" | grep -q '^UNEXPECTED_OK$'; then
    pass "Previous file preserved when upstream returns garbage"
else
    fail "Fail-open behaviour incorrect: $FAIL_OPEN_OUT"
fi

# Start a container with the real entrypoint, the fixtures and a GeoIP DB.
start_container() {
    local name="$1"
    shift
    docker run -d --name "$name" \
        -e MAXMIND_LICENSE_KEY=test \
        -v "$FIXTURES:/fixtures:ro" \
        -v "$TEST_MMDB:/usr/share/GeoIP/GeoLite2-Country.mmdb:ro" \
        "$@" \
        "$IMAGE" > /dev/null
    STARTED_CONTAINERS+=("$name")
}

# Wait for a line to appear in the container logs.
wait_for_log() {
    local container="$1"
    local pattern="$2"
    local timeout="${3:-20}"
    for _ in $(seq 1 "$timeout"); do
        if grep -qF "$pattern" < <(docker logs "$container" 2>&1); then
            return 0
        fi
        sleep 1
    done
    return 1
}

# Wait for a file in the container to contain a fixed string.
wait_for_content() {
    local container="$1"
    local file="$2"
    local pattern="$3"
    local timeout="${4:-20}"
    for _ in $(seq 1 "$timeout"); do
        if docker exec "$container" grep -qF "$pattern" "$file" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# --- Test 9: UPTIMEROBOT_ENABLED=false skips the fetch and the cron entry ---
echo "[9/$TOTAL] UPTIMEROBOT_ENABLED=false skips the fetch and the cron entry"
DIS_C="nginx-geoip-ur-disabled"
start_container "$DIS_C" -e UPTIMEROBOT_ENABLED=false
DIS_OK=true
if ! wait_for_log "$DIS_C" "Handing off to nginx entrypoint" 20; then
    DIS_OK=false
    fail "Container did not finish the entrypoint within 20s"
fi
if ! grep -qF "UptimeRobot updater disabled" < <(docker logs "$DIS_C" 2>&1); then
    DIS_OK=false
    fail "Expected 'UptimeRobot updater disabled' message not found"
fi
if docker exec "$DIS_C" grep -qF uptimerobot-cron.sh /tmp/nginx-crontab; then
    DIS_OK=false
    fail "Crontab contains the UptimeRobot job despite UPTIMEROBOT_ENABLED=false"
fi
if docker exec "$DIS_C" test -e /etc/nginx/uptimerobot/uptimerobot.map.conf; then
    DIS_OK=false
    fail "Map file installed despite UPTIMEROBOT_ENABLED=false"
fi
docker rm -f "$DIS_C" > /dev/null 2>&1 || true
$DIS_OK && pass "No UptimeRobot job, no map file, disabled message logged"

# --- Test 10: UPTIMEROBOT_UPDATE_CRON runs the job, a change reloads nginx ---
echo "[10/$TOTAL] UPTIMEROBOT_UPDATE_CRON runs the job and a change reloads nginx (~70s wait)"
CRON_C="nginx-geoip-ur-cron"
MAP=/etc/nginx/uptimerobot/uptimerobot.map.conf
start_container "$CRON_C" \
    -e UPTIMEROBOT_URL=file:///fixtures/ips-v1.txt \
    -e UPTIMEROBOT_UPDATE_CRON="* * * * *"
CRON_OK=true
# The initial fetch renders the fixture. Then the baseline goes back in place,
# so the scheduled run finds a change and must reload nginx.
if ! wait_for_content "$CRON_C" "$MAP" "216.144.250.150 1;" 20; then
    CRON_OK=false
    fail "Initial fetch did not render the fixture within 20s"
fi
for _ in $(seq 1 30); do
    docker exec "$CRON_C" test -s /tmp/nginx.pid 2>/dev/null && break
    sleep 1
done
RELOADS_BEFORE=$(docker logs "$CRON_C" 2>&1 | grep -cF "nginx reload signalled" || true)
docker exec "$CRON_C" cp /usr/local/share/nginx-geoip/uptimerobot.map.baseline "$MAP"
if ! wait_for_log "$CRON_C" "[UptimeRobot] Update completed successfully" 90; then
    CRON_OK=false
    fail "Scheduled UptimeRobot job did not complete within 90s"
fi
if ! docker exec "$CRON_C" grep -qF "216.144.250.150 1;" "$MAP"; then
    CRON_OK=false
    fail "Scheduled job did not render the fixture again"
fi
RELOADS_AFTER=$(docker logs "$CRON_C" 2>&1 | grep -cF "nginx reload signalled" || true)
if [[ "$RELOADS_AFTER" -le "$RELOADS_BEFORE" ]]; then
    CRON_OK=false
    fail "No nginx reload after the scheduled job changed the map"
fi
docker rm -f "$CRON_C" > /dev/null 2>&1 || true
$CRON_OK && pass "Scheduled job rendered the list again and signalled a reload"

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
