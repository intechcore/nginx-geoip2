#!/bin/bash
set -euo pipefail

# Structural + validation tests for log rotation feature.
#
# Usage: ./tests/logrotate/test-logrotate.sh [IMAGE_NAME:TAG]
#
# Level 1 (structural): assert binaries and template are present in the image.
# Level 2 (validation): render the template with various env-var combinations,
#   assert the output, and validate it with logrotate -d and supercronic -test.

IMAGE="${1:-nginx-geoip2:latest}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_MMDB="$SCRIPT_DIR/../integration/fixtures/GeoLite2-Country-Test.mmdb"
PASS=0
FAIL=0
TOTAL=16

# Track containers we start so cleanup runs even on early exit.
STARTED_CONTAINERS=()
cleanup_containers() {
    for c in "${STARTED_CONTAINERS[@]:-}"; do
        [ -n "$c" ] && docker rm -f "$c" > /dev/null 2>&1 || true
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

# Run a shell snippet inside a fresh container.
in_image() {
    docker run --rm --entrypoint /bin/sh "$IMAGE" -c "$1"
}

# Render the logrotate template with given env vars; print rendered config.
# Mirrors the rendering block in scripts/entrypoint.sh.
render() {
    local pattern="${1:-/var/log/nginx/*.log}"
    local frequency="${2:-daily}"
    local keep="${3:-14}"
    local maxage="${4:-30}"
    local compress="${5:-true}"
    local maxsize="${6:-}"

    in_image "
        export LOGROTATE_PATTERN='$pattern'
        export LOGROTATE_FREQUENCY='$frequency'
        export LOGROTATE_KEEP='$keep'
        export LOGROTATE_MAXAGE='$maxage'
        if [ '$compress' = 'true' ]; then
            export LOGROTATE_COMPRESS_BLOCK='    compress
    delaycompress'
        else
            export LOGROTATE_COMPRESS_BLOCK=''
        fi
        if [ -n '$maxsize' ]; then
            export LOGROTATE_MAXSIZE_LINE='    maxsize $maxsize'
        else
            export LOGROTATE_MAXSIZE_LINE=''
        fi
        envsubst '\${LOGROTATE_PATTERN} \${LOGROTATE_FREQUENCY} \${LOGROTATE_KEEP} \${LOGROTATE_MAXAGE} \${LOGROTATE_MAXSIZE_LINE} \${LOGROTATE_COMPRESS_BLOCK}' \
            < /usr/local/share/nginx-geoip/logrotate.tpl
    "
}

echo "=== Logrotate tests for $IMAGE ==="
echo ""

# ============================================================
# Level 1: Structural
# ============================================================

# --- Test 1: Image exists ---
echo "[1/$TOTAL] Image exists"
if docker image inspect "$IMAGE" > /dev/null 2>&1; then
    pass "Image $IMAGE found"
else
    fail "Image $IMAGE not found — build it first"
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

# --- Test 2: logrotate binary ---
echo "[2/$TOTAL] logrotate binary present and executable"
if in_image 'test -x /usr/sbin/logrotate'; then
    pass "/usr/sbin/logrotate is executable"
else
    fail "/usr/sbin/logrotate not found or not executable"
fi

# --- Test 3: supercronic binary + version ---
echo "[3/$TOTAL] supercronic binary present and reports a version"
SUPERCRONIC_OUT=$(in_image '/usr/local/bin/supercronic -version 2>&1' || true)
if echo "$SUPERCRONIC_OUT" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+'; then
    pass "supercronic reports version: $SUPERCRONIC_OUT"
else
    fail "supercronic missing or no version: $SUPERCRONIC_OUT"
fi

# --- Test 4: envsubst (gettext-base) ---
echo "[4/$TOTAL] envsubst present (gettext-base installed)"
if in_image 'command -v envsubst > /dev/null'; then
    pass "envsubst is on PATH"
else
    fail "envsubst not found — gettext-base missing"
fi

# --- Test 5: Template file ---
echo "[5/$TOTAL] logrotate template installed"
if in_image 'test -f /usr/local/share/nginx-geoip/logrotate.tpl'; then
    pass "/usr/local/share/nginx-geoip/logrotate.tpl exists"
else
    fail "logrotate.tpl not found at expected path"
fi

# --- Test 6: Template placeholders ---
echo "[6/$TOTAL] Template contains expected envsubst placeholders"
TPL=$(in_image 'cat /usr/local/share/nginx-geoip/logrotate.tpl' || true)
MISSING=""
for var in LOGROTATE_PATTERN LOGROTATE_FREQUENCY LOGROTATE_KEEP LOGROTATE_MAXAGE LOGROTATE_MAXSIZE_LINE LOGROTATE_COMPRESS_BLOCK; do
    if ! echo "$TPL" | grep -qF "\${$var}"; then
        MISSING="$MISSING \${$var}"
    fi
done
if [ -z "$MISSING" ]; then
    pass "All 6 placeholders present"
else
    fail "Missing placeholders:$MISSING"
fi

# ============================================================
# Level 2: Validation (render + logrotate -d + supercronic -test)
# ============================================================

# --- Test 7: Render with defaults produces expected directives ---
echo "[7/$TOTAL] Render with defaults produces expected directives"
DEFAULT_OUT=$(render)
OK=true
for line in 'daily' 'rotate 14' 'maxage 30' 'compress' 'delaycompress' 'sharedscripts' 'nginx -s reopen'; do
    if ! echo "$DEFAULT_OUT" | grep -qF "$line"; then
        OK=false
        fail "Default render missing: $line"
    fi
done
if $OK; then
    pass "Default render contains daily/rotate 14/maxage 30/compress/delaycompress/sharedscripts/postrotate"
fi

# --- Test 8: LOGROTATE_COMPRESS=false omits compress lines ---
echo "[8/$TOTAL] LOGROTATE_COMPRESS=false omits compress/delaycompress"
NO_COMPRESS=$(render '/var/log/nginx/*.log' daily 14 30 false)
if echo "$NO_COMPRESS" | grep -qE '^[[:space:]]*compress$'; then
    fail "compress line present when LOGROTATE_COMPRESS=false"
elif echo "$NO_COMPRESS" | grep -qE '^[[:space:]]*delaycompress$'; then
    fail "delaycompress line present when LOGROTATE_COMPRESS=false"
else
    pass "No compress/delaycompress lines when COMPRESS=false"
fi

# --- Test 9: Custom values are substituted ---
echo "[9/$TOTAL] Custom LOGROTATE_KEEP/MAXAGE/PATTERN values are substituted"
CUSTOM=$(render '/var/log/nginx/access*.log' weekly 7 90 true)
OK=true
echo "$CUSTOM" | grep -qF '/var/log/nginx/access*.log {' || { OK=false; fail "custom pattern not substituted"; }
echo "$CUSTOM" | grep -qE '^[[:space:]]*weekly$' || { OK=false; fail "frequency=weekly not substituted"; }
echo "$CUSTOM" | grep -qE '^[[:space:]]*rotate 7$' || { OK=false; fail "rotate 7 not substituted"; }
echo "$CUSTOM" | grep -qE '^[[:space:]]*maxage 90$' || { OK=false; fail "maxage 90 not substituted"; }
$OK && pass "Pattern, weekly, rotate 7, maxage 90 all reflected in render"

# --- Test 10: Rendered config parses with logrotate -d ---
echo "[10/$TOTAL] Rendered config validates with logrotate -d"
LR_OUT=$(in_image "
    export LOGROTATE_PATTERN='/var/log/nginx/*.log'
    export LOGROTATE_FREQUENCY='daily'
    export LOGROTATE_KEEP='14'
    export LOGROTATE_MAXAGE='30'
    export LOGROTATE_MAXSIZE_LINE=''
    export LOGROTATE_COMPRESS_BLOCK='    compress
    delaycompress'
    envsubst '\${LOGROTATE_PATTERN} \${LOGROTATE_FREQUENCY} \${LOGROTATE_KEEP} \${LOGROTATE_MAXAGE} \${LOGROTATE_MAXSIZE_LINE} \${LOGROTATE_COMPRESS_BLOCK}' \
        < /usr/local/share/nginx-geoip/logrotate.tpl > /tmp/c
    /usr/sbin/logrotate -d -s /tmp/state /tmp/c 2>&1
" || true)
if echo "$LR_OUT" | grep -q 'rotating pattern: /var/log/nginx/\*\.log after 1 days'; then
    if echo "$LR_OUT" | grep -q 'old logs are removed after 30 days'; then
        pass "logrotate -d confirms daily + 14 rotations + maxage 30 + compress"
    else
        fail "logrotate -d output missing maxage 30 confirmation: $LR_OUT"
    fi
else
    fail "logrotate -d did not parse config correctly: $LR_OUT"
fi

# --- Test 11: supercronic -test validates a generated crontab ---
echo "[11/$TOTAL] supercronic -test validates the generated crontab line"
SC_OUT=$(in_image "
    echo '30 0 * * * /usr/sbin/logrotate -s /var/log/nginx/.logrotate-state /tmp/nginx-logrotate.conf' > /tmp/ct
    /usr/local/bin/supercronic -test /tmp/ct 2>&1
" || true)
if echo "$SC_OUT" | grep -q 'crontab is valid'; then
    pass "supercronic accepts the generated crontab"
else
    fail "supercronic did not accept crontab: $SC_OUT"
fi

# --- Test 12: LOGROTATE_CRON custom expression accepted by supercronic ---
echo "[12/$TOTAL] supercronic accepts custom LOGROTATE_CRON expressions"
CUSTOM_CRONS=("*/15 * * * *" "0 */6 * * *" "15 2 * * 0")
OK=true
for cron in "${CUSTOM_CRONS[@]}"; do
    OUT=$(in_image "
        echo '$cron /usr/sbin/logrotate -s /var/log/nginx/.logrotate-state /tmp/c' > /tmp/ct
        /usr/local/bin/supercronic -test /tmp/ct 2>&1
    " || true)
    if ! echo "$OUT" | grep -q 'crontab is valid'; then
        OK=false
        fail "supercronic rejected '$cron': $OUT"
    fi
done
$OK && pass "supercronic accepts */15, hourly-by-6, weekly cron expressions"

# --- Test 13: LOGROTATE_MAXSIZE rendering ---
echo "[13/$TOTAL] LOGROTATE_MAXSIZE rendering"
MAXSIZE_OK=true
# Empty (default): no maxsize line should appear
DEFAULT_RENDER=$(render)
if echo "$DEFAULT_RENDER" | grep -qE '^[[:space:]]*maxsize '; then
    MAXSIZE_OK=false
    fail "Default render unexpectedly contains a maxsize directive"
fi
# Custom value: maxsize line with the value appears
MAXSIZE_RENDER=$(render '/var/log/nginx/*.log' daily 14 30 true 100M)
if ! echo "$MAXSIZE_RENDER" | grep -qE '^[[:space:]]*maxsize 100M$'; then
    MAXSIZE_OK=false
    fail "Render with LOGROTATE_MAXSIZE=100M missing 'maxsize 100M' line"
fi
$MAXSIZE_OK && pass "LOGROTATE_MAXSIZE adds 'maxsize N' line when set, omits when unset"

# ============================================================
# Level 3: End-to-end (live container, real time)
# ============================================================

# Helper: start a container in the background with mocked GeoIP DB. Tracks
# the container in STARTED_CONTAINERS so the EXIT trap removes it.
start_container() {
    local name="$1"
    shift
    docker run -d --name "$name" \
        -e MAXMIND_LICENSE_KEY=test \
        -v "$TEST_MMDB:/usr/share/GeoIP/GeoLite2-Country.mmdb:ro" \
        "$@" \
        "$IMAGE" > /dev/null
    STARTED_CONTAINERS+=("$name")
}

# Helper: wait for a line to appear in container logs.
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

# Helper: count processes inside container whose /proc/PID/comm equals NAME.
# Uses comm (binary basename, 15-char limit) to avoid self-match — searching
# cmdline for "supercronic" would also match the shell that runs the search.
count_procs_by_comm() {
    docker exec "$1" sh -c '
        count=0
        for c in /proc/[0-9]*/comm; do
            [ -r "$c" ] || continue
            [ "$(cat "$c")" = "'"$2"'" ] && count=$((count + 1))
        done
        echo "$count"
    ' | tr -d '[:space:]'
}

# Helper: returns 0 if container PID 1 is nginx (i.e. master process via exec).
pid1_is_nginx() {
    docker exec "$1" sh -c 'test "$(cat /proc/1/comm)" = nginx' 2>/dev/null
}

# --- Test 13: Entrypoint lifecycle ---
echo "[14/$TOTAL] Entrypoint starts log rotation scheduler and supercronic"
LIFE_C="nginx-geoip-lr-lifecycle"
start_container "$LIFE_C"
LIFE_OK=true
if ! wait_for_log "$LIFE_C" "Starting log rotation scheduler" 20; then
    LIFE_OK=false
    fail "Entrypoint did not log 'Starting log rotation scheduler' within 20s"
fi
if ! grep -qF "Starting GeoIP daily updater" < <(docker logs "$LIFE_C" 2>&1); then
    LIFE_OK=false
    fail "Entrypoint did not log 'Starting GeoIP daily updater'"
fi
if [ "$(count_procs_by_comm "$LIFE_C" supercronic)" = "0" ]; then
    LIFE_OK=false
    fail "supercronic process not running inside container"
fi
docker rm -f "$LIFE_C" > /dev/null 2>&1 || true
$LIFE_OK && pass "Scheduler log message present, GeoIP updater started, supercronic running"

# --- Test 14: End-to-end rotation under supercronic ---
echo "[15/$TOTAL] supercronic triggers logrotate end-to-end (~70s wait)"
E2E_C="nginx-geoip-lr-e2e"
start_container "$E2E_C" -e LOGROTATE_CRON="* * * * *"
E2E_OK=true
if ! wait_for_log "$E2E_C" "Starting log rotation scheduler" 20; then
    E2E_OK=false
    fail "Scheduler did not start"
fi

# Inject a non-empty log file matching the rotation pattern AND backdate the
# state file so logrotate's daily check actually triggers on the next supercronic
# fire. Without backdating, logrotate's first encounter with a new file just
# records its current time and defers rotation by a full day (documented
# logrotate behavior, would make the test take 24h).
docker exec "$E2E_C" sh -c '
    echo "rotation-test $(date -u +%s)" > /var/log/nginx/e2e-rotation-test.log
    two_days_ago=$(date -d "2 days ago" "+%Y-%m-%d-%H:%M:%S")
    printf "logrotate state -- version 2\n\"/var/log/nginx/e2e-rotation-test.log\" %s\n" "$two_days_ago" \
        > /var/log/nginx/.logrotate-state
'
EXPECTED_CONTENT=$(docker exec "$E2E_C" cat /var/log/nginx/e2e-rotation-test.log)

# Wait up to 90s for supercronic to fire logrotate at the minute boundary.
ROTATED=false
for _ in $(seq 1 90); do
    if docker exec "$E2E_C" test -f /var/log/nginx/e2e-rotation-test.log.1 2>/dev/null; then
        ROTATED=true
        break
    fi
    sleep 1
done

if ! $ROTATED; then
    E2E_OK=false
    fail "e2e-rotation-test.log.1 did not appear within 90s — supercronic did not trigger rotation"
else
    # Rotated file should hold the original content; new live .log absent or empty
    ROTATED_CONTENT=$(docker exec "$E2E_C" cat /var/log/nginx/e2e-rotation-test.log.1 2>/dev/null)
    if [ "$ROTATED_CONTENT" != "$EXPECTED_CONTENT" ]; then
        E2E_OK=false
        fail "Rotated .log.1 content mismatch: expected '$EXPECTED_CONTENT', got '$ROTATED_CONTENT'"
    fi
    # nginx master is PID 1 in our exec'd entrypoint; after SIGUSR1-reopen it
    # stays alive (not a restart).
    if ! pid1_is_nginx "$E2E_C"; then
        E2E_OK=false
        fail "PID 1 is no longer nginx — supercronic-triggered postrotate killed master"
    fi
fi
docker rm -f "$E2E_C" > /dev/null 2>&1 || true
$E2E_OK && pass "supercronic invoked logrotate, .log.1 has original content, nginx alive"

# --- Test 15: LOGROTATE_ENABLED=false skips supercronic ---
echo "[16/$TOTAL] LOGROTATE_ENABLED=false skips supercronic"
DIS_C="nginx-geoip-lr-disabled"
start_container "$DIS_C" -e LOGROTATE_ENABLED=false
DIS_OK=true
if ! wait_for_log "$DIS_C" "Handing off to nginx entrypoint" 20; then
    DIS_OK=false
    fail "Container did not finish entrypoint within 20s"
fi
if ! grep -qF "Log rotation disabled" < <(docker logs "$DIS_C" 2>&1); then
    DIS_OK=false
    fail "Expected 'Log rotation disabled' message not found"
fi
if [ "$(count_procs_by_comm "$DIS_C" supercronic)" != "0" ]; then
    DIS_OK=false
    fail "supercronic is running despite LOGROTATE_ENABLED=false"
fi
docker rm -f "$DIS_C" > /dev/null 2>&1 || true
$DIS_OK && pass "Scheduler suppressed: log message present, no supercronic process"

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
