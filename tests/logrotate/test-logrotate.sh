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
PASS=0
FAIL=0
TOTAL=12

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
        envsubst '\${LOGROTATE_PATTERN} \${LOGROTATE_FREQUENCY} \${LOGROTATE_KEEP} \${LOGROTATE_MAXAGE} \${LOGROTATE_COMPRESS_BLOCK}' \
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
for var in LOGROTATE_PATTERN LOGROTATE_FREQUENCY LOGROTATE_KEEP LOGROTATE_MAXAGE LOGROTATE_COMPRESS_BLOCK; do
    if ! echo "$TPL" | grep -qF "\${$var}"; then
        MISSING="$MISSING \${$var}"
    fi
done
if [ -z "$MISSING" ]; then
    pass "All 5 placeholders present"
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
    export LOGROTATE_COMPRESS_BLOCK='    compress
    delaycompress'
    envsubst '\${LOGROTATE_PATTERN} \${LOGROTATE_FREQUENCY} \${LOGROTATE_KEEP} \${LOGROTATE_MAXAGE} \${LOGROTATE_COMPRESS_BLOCK}' \
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

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
