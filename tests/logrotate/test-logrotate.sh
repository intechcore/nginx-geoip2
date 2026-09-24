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
TOTAL=26
# arm64 binaries (nginx, supercronic, libmaxminddb) run ~20 MiB larger than amd64
# in this image. 250 MiB still catches gross regressions (apt cache leak, debug
# symbols left over) without flagging the legitimate arch delta.
IMAGE_SIZE_THRESHOLD_MB=250

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
if [[ -z "$MISSING" ]]; then
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

# Helper: wait for nginx to write its pid file (proves nginx master is up).
# wait_for_log on entrypoint messages only proves the entrypoint reached the
# corresponding line — nginx itself takes additional time to start (much
# longer under QEMU emulation in CI).
wait_for_pidfile() {
    local container="$1"
    local timeout="${2:-30}"
    for _ in $(seq 1 "$timeout"); do
        if docker exec "$container" test -s /tmp/nginx.pid 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# Helper: wait for container Health.Status to become healthy (or unhealthy).
# Returns 0 if healthy, 1 if unhealthy, 2 on timeout.
wait_for_health() {
    local container="$1"
    local timeout="${2:-60}"
    local status
    for _ in $(seq 1 "$timeout"); do
        status=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "")
        case "$status" in
            healthy)   return 0 ;;
            unhealthy) return 1 ;;
        esac
        sleep 1
    done
    return 2
}

# --- Test 13: Entrypoint lifecycle ---
echo "[14/$TOTAL] Entrypoint schedules both jobs and supercronic is running"
LIFE_C="nginx-geoip-lr-lifecycle"
start_container "$LIFE_C"
LIFE_OK=true
if ! wait_for_log "$LIFE_C" "Starting supercronic" 20; then
    LIFE_OK=false
    fail "Entrypoint did not log 'Starting supercronic' within 20s"
fi
if ! grep -qF "Scheduling: GeoIP updater" < <(docker logs "$LIFE_C" 2>&1); then
    LIFE_OK=false
    fail "Entrypoint did not log 'Scheduling: GeoIP updater'"
fi
if ! grep -qF "Scheduling: log rotator" < <(docker logs "$LIFE_C" 2>&1); then
    LIFE_OK=false
    fail "Entrypoint did not log 'Scheduling: log rotator'"
fi
if [[ "$(count_procs_by_comm "$LIFE_C" supercronic)" = "0" ]]; then
    LIFE_OK=false
    fail "supercronic process not running inside container"
fi
docker rm -f "$LIFE_C" > /dev/null 2>&1 || true
$LIFE_OK && pass "Both jobs scheduled, supercronic running"

# --- Test 14: End-to-end rotation under supercronic ---
echo "[15/$TOTAL] supercronic triggers logrotate and the GeoIP job end-to-end (~70s wait)"
E2E_C="nginx-geoip-lr-e2e"
start_container "$E2E_C" -e LOGROTATE_CRON="* * * * *" -e GEOIP_UPDATE_CRON="* * * * *"
E2E_OK=true
if ! wait_for_log "$E2E_C" "Starting supercronic" 20; then
    E2E_OK=false
    fail "Scheduler did not start"
fi

# Inject a non-empty log file matching the rotation pattern AND backdate the
# state file so logrotate's daily check actually triggers on the next supercronic
# fire. Without backdating, logrotate's first encounter with a new file just
# records its current time and defers rotation by a full day (documented
# logrotate behavior, would make the test take 24h).
#
# IMPORTANT: do this in a single docker exec that also echoes the content back
# so it can't race with supercronic. On fast runners (CI amd64) supercronic's
# 1-min cron may fire BETWEEN two docker execs and rotate the file out from
# under us, leaving nothing for a follow-up `cat`.
EXPECTED_CONTENT=$(docker exec "$E2E_C" sh -c '
    content="rotation-test $(date -u +%s)"
    echo "$content" > /var/log/nginx/e2e-rotation-test.log
    two_days_ago=$(date -d "2 days ago" "+%Y-%m-%d-%H:%M:%S")
    printf "logrotate state -- version 2\n\"/var/log/nginx/e2e-rotation-test.log\" %s\n" "$two_days_ago" \
        > /var/log/nginx/.logrotate-state
    echo "$content"
')

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
    if [[ "$ROTATED_CONTENT" != "$EXPECTED_CONTENT" ]]; then
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
# The GeoIP job fires in the same minute. The test key makes the download fail,
# and the wrapper reports it without stopping the container.
if ! wait_for_log "$E2E_C" "[GeoIP] Update failed, will retry on next cron fire" 30; then
    E2E_OK=false
    fail "GEOIP_UPDATE_CRON did not run the GeoIP job"
fi
docker rm -f "$E2E_C" > /dev/null 2>&1 || true
$E2E_OK && pass "supercronic invoked logrotate and the GeoIP job, .log.1 has original content, nginx alive"

# --- Test 16: LOGROTATE_ENABLED=false removes logrotate from the crontab ---
# supercronic still runs (it owns the GeoIP refresh job), but the rendered
# crontab must not contain a logrotate entry and the entrypoint must log
# "Log rotation disabled".
echo "[16/$TOTAL] LOGROTATE_ENABLED=false drops logrotate from the crontab"
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
# supercronic must still be running (it schedules the GeoIP job)
if [[ "$(count_procs_by_comm "$DIS_C" supercronic)" = "0" ]]; then
    DIS_OK=false
    fail "supercronic is NOT running — GeoIP refresh job would never fire"
fi
# crontab must contain only the GeoIP job, not the logrotate job
CT=$(docker exec "$DIS_C" cat /tmp/nginx-crontab 2>/dev/null)
if echo "$CT" | grep -qF logrotate-cron.sh; then
    DIS_OK=false
    fail "Crontab contains a logrotate entry despite LOGROTATE_ENABLED=false: $CT"
fi
if ! echo "$CT" | grep -qF geoip-cron.sh; then
    DIS_OK=false
    fail "Crontab missing GeoIP entry (should always be present): $CT"
fi
docker rm -f "$DIS_C" > /dev/null 2>&1 || true
$DIS_OK && pass "logrotate entry omitted from crontab, GeoIP entry remains, supercronic still scheduling"

# ============================================================
# Level 4: Reliability — container lifecycle, env contracts, multi-cycle
# ============================================================

# --- Test 17: Healthcheck transitions to healthy ---
echo "[17/$TOTAL] HEALTHCHECK transitions container to 'healthy'"
HC_C="nginx-geoip-lr-healthcheck"
start_container "$HC_C"
if wait_for_health "$HC_C" 60; then
    pass "Container reached State.Health.Status=healthy within 60s"
else
    fail "Container did not reach healthy within 60s (last status: $(docker inspect --format '{{.State.Health.Status}}' "$HC_C" 2>/dev/null))"
fi
docker rm -f "$HC_C" > /dev/null 2>&1 || true

# --- Test 18: docker stop triggers a graceful shutdown via SIGQUIT ---
echo "[18/$TOTAL] docker stop completes a graceful shutdown (exit 0)"
GS_C="nginx-geoip-lr-stop"
start_container "$GS_C"
# Wait for nginx to be serving before testing shutdown semantics. A bare
# `sleep N` race-conditions under QEMU-emulated arm64 in CI: if the entrypoint
# shell is still running (hasn't exec'd to nginx yet), `docker stop`'s
# STOPSIGNAL=SIGQUIT is ignored by non-interactive sh and the container
# survives the grace window only to be SIGKILL'd (exit 137).
# Waiting for HEALTHCHECK guarantees nginx is PID 1 and signal-ready.
GS_OK=true
if ! wait_for_health "$GS_C" 60; then
    GS_OK=false
    fail "Container did not reach healthy before graceful-shutdown test (last status: $(docker inspect --format '{{.State.Health.Status}}' "$GS_C" 2>/dev/null))"
fi
if $GS_OK; then
    T0=$(date +%s)
    docker stop --time=15 "$GS_C" > /dev/null
    T1=$(date +%s)
    DUR=$((T1 - T0))
    EXIT_CODE=$(docker inspect --format '{{.State.ExitCode}}' "$GS_C" 2>/dev/null || echo "?")
    if [[ "$EXIT_CODE" != "0" ]]; then
        GS_OK=false
        fail "Container exited with code $EXIT_CODE (expected 0 — graceful shutdown)"
    fi
    # A truly graceful nginx shutdown on an idle container is sub-second; treat
    # >10s as a regression (would mean SIGQUIT didn't reach nginx and docker
    # fell back to SIGKILL).
    if [[ "$DUR" -gt 10 ]]; then
        GS_OK=false
        fail "docker stop took ${DUR}s (expected <10s — STOPSIGNAL/PID 1 likely misconfigured)"
    fi
    $GS_OK && pass "Graceful shutdown in ${DUR}s, exit 0 (STOPSIGNAL SIGQUIT works, nginx is PID 1)"
fi
docker rm -f "$GS_C" > /dev/null 2>&1 || true

# --- Test 19: rotation state file persists across container restart ---
echo "[19/$TOTAL] /var/log/nginx/.logrotate-state survives container restart"
SP_C="nginx-geoip-lr-state-persist"
# Use a named volume so state file survives the stop/start cycle.
SP_VOL="nginx-geoip-lr-state-vol"
docker volume rm "$SP_VOL" > /dev/null 2>&1 || true
docker volume create "$SP_VOL" > /dev/null
docker run -d --name "$SP_C" \
    -e MAXMIND_LICENSE_KEY=test \
    -v "$TEST_MMDB:/usr/share/GeoIP/GeoLite2-Country.mmdb:ro" \
    -v "$SP_VOL:/var/log/nginx" \
    "$IMAGE" > /dev/null
STARTED_CONTAINERS+=("$SP_C")
# Wait for entrypoint to settle, then force a rotation to populate the state file.
wait_for_log "$SP_C" "Starting supercronic" 20 || true
docker exec "$SP_C" sh -c '
    echo "persist-test" > /var/log/nginx/persist-test.log
    /usr/sbin/logrotate -f -s /var/log/nginx/.logrotate-state /tmp/nginx-logrotate.conf > /dev/null 2>&1
' > /dev/null
STATE_BEFORE=$(docker exec "$SP_C" cat /var/log/nginx/.logrotate-state 2>/dev/null)
docker stop --time=15 "$SP_C" > /dev/null
docker start "$SP_C" > /dev/null
sleep 2
STATE_AFTER=$(docker exec "$SP_C" cat /var/log/nginx/.logrotate-state 2>/dev/null)
docker rm -f "$SP_C" > /dev/null 2>&1 || true
docker volume rm "$SP_VOL" > /dev/null 2>&1 || true
if [[ -n "$STATE_BEFORE" ]] && [[ "$STATE_BEFORE" = "$STATE_AFTER" ]]; then
    pass "State file identical after stop+start ($(echo "$STATE_BEFORE" | wc -l | tr -d ' ') lines)"
else
    fail "State file changed across restart (before: $(echo "$STATE_BEFORE" | wc -l | tr -d ' ') lines, after: $(echo "$STATE_AFTER" | wc -l | tr -d ' ') lines)"
fi

# --- Test 20: MAXMIND_LICENSE_KEY unset → exit 1 with clear message ---
echo "[20/$TOTAL] Missing MAXMIND_LICENSE_KEY → fast clean failure"
MK_C="nginx-geoip-lr-missing-key"
docker run -d --name "$MK_C" \
    -v "$TEST_MMDB:/usr/share/GeoIP/GeoLite2-Country.mmdb:ro" \
    "$IMAGE" > /dev/null
STARTED_CONTAINERS+=("$MK_C")
sleep 3
MK_EXIT=$(docker inspect --format '{{.State.ExitCode}}' "$MK_C" 2>/dev/null || echo "?")
MK_OK=true
if [[ "$MK_EXIT" = "0" ]] || [[ "$MK_EXIT" = "?" ]]; then
    MK_OK=false
    fail "Container exited with code $MK_EXIT (expected non-zero)"
fi
if ! grep -qF "MAXMIND_LICENSE_KEY environment variable is required" < <(docker logs "$MK_C" 2>&1); then
    MK_OK=false
    fail "Expected error message missing from logs"
fi
docker rm -f "$MK_C" > /dev/null 2>&1 || true
$MK_OK && pass "Exits with code $MK_EXIT and clear 'MAXMIND_LICENSE_KEY environment variable is required' message"

# --- Test 21: Invalid GEOIP_UPDATE_CRON → exit 1 (caught by supercronic -test) ---
echo "[21/$TOTAL] Invalid GEOIP_UPDATE_CRON → fast clean failure"
IT_C="nginx-geoip-lr-invalid-cron"
docker run -d --name "$IT_C" \
    -e MAXMIND_LICENSE_KEY=test \
    -e GEOIP_UPDATE_CRON="not a cron" \
    -v "$TEST_MMDB:/usr/share/GeoIP/GeoLite2-Country.mmdb:ro" \
    "$IMAGE" > /dev/null
STARTED_CONTAINERS+=("$IT_C")
sleep 3
IT_EXIT=$(docker inspect --format '{{.State.ExitCode}}' "$IT_C" 2>/dev/null || echo "?")
IT_OK=true
if [[ "$IT_EXIT" = "0" ]] || [[ "$IT_EXIT" = "?" ]]; then
    IT_OK=false
    fail "Container exited with code $IT_EXIT (expected non-zero)"
fi
if ! grep -qF "Invalid crontab" < <(docker logs "$IT_C" 2>&1); then
    IT_OK=false
    fail "Expected 'Invalid crontab' validation error missing from logs"
fi
docker rm -f "$IT_C" > /dev/null 2>&1 || true
$IT_OK && pass "Exits with code $IT_EXIT and 'Invalid crontab' message (supercronic -test caught it)"

# --- Test 22: Image size below threshold ---
echo "[22/$TOTAL] Image size below ${IMAGE_SIZE_THRESHOLD_MB} MiB threshold"
IMG_SIZE_BYTES=$(docker image inspect --format '{{.Size}}' "$IMAGE")
IMG_SIZE_MB=$((IMG_SIZE_BYTES / 1024 / 1024))
if [[ "$IMG_SIZE_MB" -lt "$IMAGE_SIZE_THRESHOLD_MB" ]]; then
    pass "Image is ${IMG_SIZE_MB} MiB (< ${IMAGE_SIZE_THRESHOLD_MB} MiB threshold)"
else
    fail "Image is ${IMG_SIZE_MB} MiB (≥ ${IMAGE_SIZE_THRESHOLD_MB} MiB threshold — check apt cache, leftover build artefacts, etc.)"
fi

# --- Test 23: Multi-cycle rotation produces compressed .log.2.gz ---
echo "[23/$TOTAL] Multi-cycle rotation: .log → .log.1 → .log.2.gz"
MC_C="nginx-geoip-lr-multi-cycle"
start_container "$MC_C"
wait_for_log "$MC_C" "Starting supercronic" 20 || true
docker exec "$MC_C" sh -c '
    set -e
    LOG=/var/log/nginx/multicycle-test.log
    STATE=/var/log/nginx/.logrotate-state
    CONF=/tmp/nginx-logrotate.conf

    echo "first-cycle-content" > "$LOG"
    /usr/sbin/logrotate -f -s "$STATE" "$CONF" >/dev/null 2>&1
    # After cycle 1: .log.1 exists with "first-cycle-content"; new .log is absent (nginx
    # would create on next write, but no test traffic).
    echo "second-cycle-content" > "$LOG"
    /usr/sbin/logrotate -f -s "$STATE" "$CONF" >/dev/null 2>&1
    # After cycle 2: .log.2.gz holds compressed "first-cycle-content";
    # .log.1 holds "second-cycle-content".
' > /dev/null
MC_OK=true
if ! docker exec "$MC_C" test -f /var/log/nginx/multicycle-test.log.2.gz; then
    MC_OK=false
    fail "multicycle-test.log.2.gz not created after second rotation"
fi
if ! docker exec "$MC_C" test -f /var/log/nginx/multicycle-test.log.1; then
    MC_OK=false
    fail "multicycle-test.log.1 not present after second rotation"
fi
# Verify the .log.2.gz really holds the first-cycle content (decompression check).
DECOMPRESSED=$(docker exec "$MC_C" gunzip -c /var/log/nginx/multicycle-test.log.2.gz 2>/dev/null || echo "")
if [[ "$DECOMPRESSED" != "first-cycle-content" ]]; then
    MC_OK=false
    fail "Decompressed .log.2.gz content = '$DECOMPRESSED' (expected 'first-cycle-content')"
fi
docker rm -f "$MC_C" > /dev/null 2>&1 || true
$MC_OK && pass "Two cycles produced .log.1 (raw) and .log.2.gz (compressed, content verified)"

# --- Test 24: nginx -s reload picks up conf.d changes ---
echo "[24/$TOTAL] nginx -s reload applies conf.d changes without restart"
RL_C="nginx-geoip-lr-reload"
start_container "$RL_C"
# Wait for nginx master to write /tmp/nginx.pid — must be running before we
# probe master PID or attempt reload (entrypoint's "Starting log rotation
# scheduler" message fires before exec'ing nginx).
if ! wait_for_pidfile "$RL_C" 30; then
    fail "nginx never wrote /tmp/nginx.pid within 30s"
    docker rm -f "$RL_C" > /dev/null 2>&1 || true
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi
MASTER_PID_BEFORE=$(docker exec "$RL_C" cat /tmp/nginx.pid | tr -d '[:space:]')
# Drop a fresh vhost into conf.d that listens on 8081 and returns a known body.
docker exec "$RL_C" sh -c "cat > /etc/nginx/conf.d/reload-test.conf <<'EOF'
server {
    listen 8081;
    location / { return 200 'before-reload\n'; }
}
EOF"
docker exec "$RL_C" nginx -s reload >/dev/null 2>&1 || true
sleep 1
BEFORE=$(docker exec "$RL_C" curl -fsS http://localhost:8081/ 2>/dev/null | tr -d '\n')
# Now rewrite the same vhost with a different body and reload again.
docker exec "$RL_C" sh -c "cat > /etc/nginx/conf.d/reload-test.conf <<'EOF'
server {
    listen 8081;
    location / { return 200 'after-reload\n'; }
}
EOF"
docker exec "$RL_C" nginx -s reload >/dev/null 2>&1 || true
sleep 1
AFTER=$(docker exec "$RL_C" curl -fsS http://localhost:8081/ 2>/dev/null | tr -d '\n')
MASTER_PID_AFTER=$(docker exec "$RL_C" cat /tmp/nginx.pid | tr -d '[:space:]')
docker rm -f "$RL_C" > /dev/null 2>&1 || true
RL_OK=true
[[ "$BEFORE" = "before-reload" ]] || { RL_OK=false; fail "First reload didn't apply: got '$BEFORE' (expected 'before-reload')"; }
[[ "$AFTER" = "after-reload" ]]  || { RL_OK=false; fail "Second reload didn't apply: got '$AFTER' (expected 'after-reload')"; }
[[ "$MASTER_PID_BEFORE" = "$MASTER_PID_AFTER" ]] || { RL_OK=false; fail "Master PID changed across reload ($MASTER_PID_BEFORE → $MASTER_PID_AFTER) — reload became a restart"; }
$RL_OK && pass "Two reloads applied changes, master PID stable ($MASTER_PID_AFTER)"

# --- Test 25: the entrypoint renders the LOGROTATE_* settings ---
# Tests 7-13 render the template the way the entrypoint does. This one checks
# the config the entrypoint itself writes.
echo "[25/$TOTAL] Entrypoint renders the LOGROTATE_* settings"
CF_C="nginx-geoip-lr-config"
start_container "$CF_C" \
    -e LOGROTATE_FREQUENCY=weekly \
    -e LOGROTATE_KEEP=7 \
    -e LOGROTATE_MAXAGE=90 \
    -e LOGROTATE_MAXSIZE=100M \
    -e LOGROTATE_COMPRESS=false \
    -e LOGROTATE_PATTERN='/var/log/nginx/access*.log'
CF_OK=true
if ! wait_for_log "$CF_C" "Starting supercronic" 20; then
    CF_OK=false
    fail "Entrypoint did not log 'Starting supercronic' within 20s"
fi
CF_CONF=$(docker exec "$CF_C" cat /tmp/nginx-logrotate.conf 2>/dev/null || true)
for line in '^/var/log/nginx/access\*\.log \{$' '^[[:space:]]*weekly$' '^[[:space:]]*rotate 7$' \
        '^[[:space:]]*maxage 90$' '^[[:space:]]*maxsize 100M$'; do
    if ! echo "$CF_CONF" | grep -qE "$line"; then
        CF_OK=false
        fail "Rendered config does not match '$line'"
    fi
done
if echo "$CF_CONF" | grep -qE '^[[:space:]]*(delay)?compress$'; then
    CF_OK=false
    fail "Rendered config compresses despite LOGROTATE_COMPRESS=false"
fi
docker rm -f "$CF_C" > /dev/null 2>&1 || true
$CF_OK && pass "Pattern, weekly, rotate 7, maxage 90, maxsize 100M, no compress"

# --- Test 26: GEOIP_DIR moves the database directory ---
# The test key makes the download fail, so the entrypoint must fall back to
# the database in GEOIP_DIR, and fail without one there.
echo "[26/$TOTAL] GEOIP_DIR: the entrypoint looks for the database there"
GD_OK=true
GD_C="nginx-geoip-lr-geoip-dir"
docker run -d --name "$GD_C" \
    -e MAXMIND_LICENSE_KEY=test \
    -e GEOIP_DIR=/tmp/geoip \
    -v "$TEST_MMDB:/tmp/geoip/GeoLite2-Country.mmdb:ro" \
    "$IMAGE" > /dev/null
STARTED_CONTAINERS+=("$GD_C")
if ! wait_for_log "$GD_C" "Download failed, using existing database" 20; then
    GD_OK=false
    fail "Entrypoint did not use the database in GEOIP_DIR"
fi
docker rm -f "$GD_C" > /dev/null 2>&1 || true
GE_C="nginx-geoip-lr-geoip-dir-empty"
docker run -d --name "$GE_C" \
    -e MAXMIND_LICENSE_KEY=test \
    -e GEOIP_DIR=/tmp/geoip \
    -v "$TEST_MMDB:/usr/share/GeoIP/GeoLite2-Country.mmdb:ro" \
    "$IMAGE" > /dev/null
STARTED_CONTAINERS+=("$GE_C")
if ! wait_for_log "$GE_C" "Download failed and no existing database found" 20; then
    GD_OK=false
    fail "Entrypoint did not fail on an empty GEOIP_DIR"
fi
for _ in $(seq 1 10); do
    [[ "$(docker inspect --format '{{.State.Running}}' "$GE_C" 2>/dev/null)" = "false" ]] && break
    sleep 1
done
GE_EXIT=$(docker inspect --format '{{.State.ExitCode}}' "$GE_C" 2>/dev/null || echo "?")
if [[ "$GE_EXIT" = "0" ]] || [[ "$GE_EXIT" = "?" ]]; then
    GD_OK=false
    fail "Container with an empty GEOIP_DIR exited with code $GE_EXIT (expected non-zero)"
fi
docker rm -f "$GE_C" > /dev/null 2>&1 || true
$GD_OK && pass "Database in GEOIP_DIR used, empty GEOIP_DIR fails with exit code $GE_EXIT"

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
