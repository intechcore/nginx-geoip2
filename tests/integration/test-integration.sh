#!/bin/bash
set -euo pipefail

# Integration tests for nginx-geoip Docker image.
# Usage: ./tests/integration/test-integration.sh [IMAGE_NAME:TAG]
#
# Requires: docker compose, curl
#
# Optional:
#   GEOIP_DB=path/to/GeoLite2-Country.mmdb  — uses real GeoIP database
#   Without it, a placeholder is created and GeoIP-dependent tests are skipped.

IMAGE="${1:-nginx-geoip2:latest}"
IMAGE_NAME="${IMAGE%%:*}"
IMAGE_TAG="${IMAGE##*:}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HTTP_PORT="${NGINX_TEST_HTTP_PORT:-18080}"
HTTPS_PORT="${NGINX_TEST_HTTPS_PORT:-18443}"
BASE_HTTP="http://localhost:${HTTP_PORT}"
BASE_HTTPS="https://localhost:${HTTPS_PORT}"
PASS=0
FAIL=0

# curl wrapper for HTTPS requests (insecure for self-signed certs)
kurl() {
    curl -sf --insecure --connect-timeout 5 "$@"
}

# curl wrapper that returns HTTP status code (does not fail on non-2xx)
kurl_code() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --insecure --connect-timeout 5 "$@" 2>/dev/null) || true
    echo "${code:-000}"
}

cleanup() {
    echo ""
    echo "--- Cleanup ---"
    cd "$SCRIPT_DIR"
    IMAGE_NAME="$IMAGE_NAME" IMAGE_TAG="$IMAGE_TAG" GEOIP_DB="$GEOIP_DB" docker compose down -v 2>/dev/null || true
    # Clean up placeholder if we created it
    if [ -f "$SCRIPT_DIR/fixtures/GeoLite2-Country.mmdb" ] && [ ! -s "$SCRIPT_DIR/fixtures/GeoLite2-Country.mmdb" ]; then
        rm -f "$SCRIPT_DIR/fixtures/GeoLite2-Country.mmdb"
    fi
}
trap cleanup EXIT

pass() {
    PASS=$((PASS + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1"
}

wait_for_service() {
    local url="$1"
    local timeout="${2:-30}"
    local host="${3:-}"
    for _i in $(seq 1 "$timeout"); do
        if [ -n "$host" ]; then
            if kurl -H "Host: $host" "$url" > /dev/null 2>&1; then
                return 0
            fi
        else
            if kurl "$url" > /dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 1
    done
    echo "  Service did not become ready within ${timeout}s"
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" logs 2>&1 | tail -20 | sed 's/^/    /'
    return 1
}

echo "=== Integration tests for $IMAGE ==="
echo ""

# --- Resolve GeoIP database ---
# Check common locations: explicit env var, project root, or create placeholder
if [ -n "${GEOIP_DB:-}" ] && [ -f "${GEOIP_DB}" ]; then
    echo "Using GeoIP database: $GEOIP_DB"
elif [ -f "$SCRIPT_DIR/../../GeoLite2-Country.mmdb" ]; then
    GEOIP_DB="$(cd "$SCRIPT_DIR/../.." && pwd)/GeoLite2-Country.mmdb"
    echo "Using GeoIP database: $GEOIP_DB"
else
    # Create a minimal placeholder — nginx will start but geoip2 lookups return empty
    echo "No GeoIP database found — creating placeholder (GeoIP tests will be skipped)"
    # Use the mmdb from the running container if available, otherwise create empty placeholder
    GEOIP_DB="$SCRIPT_DIR/fixtures/GeoLite2-Country.mmdb"
    docker run --rm --entrypoint "" "$IMAGE" sh -c 'cat /usr/share/GeoIP/GeoLite2-Country.mmdb 2>/dev/null' > "$GEOIP_DB" 2>/dev/null || true
    if [ ! -s "$GEOIP_DB" ]; then
        # Cannot extract from image either — disable geoip2 in nginx config
        echo "Could not extract mmdb from image — GeoIP module tests will be skipped"
        echo '# GeoIP disabled for testing (no database available)' > "$SCRIPT_DIR/fixtures/conf.d/includes/geoip2.nginx"
        touch "$GEOIP_DB"
    fi
fi
export GEOIP_DB

# --- Start services ---
echo ""
echo "Starting test environment..."
cd "$SCRIPT_DIR"
IMAGE_NAME="$IMAGE_NAME" IMAGE_TAG="$IMAGE_TAG" GEOIP_DB="$GEOIP_DB" docker compose up -d

echo "Waiting for nginx to be ready..."
if ! wait_for_service "$BASE_HTTPS" 30 "app.test.example.com"; then
    # Try HTTP fallback
    if ! wait_for_service "$BASE_HTTP" 10; then
        fail "nginx did not start"
        echo ""
        echo "=== Results: $PASS passed, $FAIL failed ==="
        exit 1
    fi
fi
echo ""

# --- Test 1: HTTP→HTTPS redirect ---
echo "[1/10] HTTP to HTTPS redirect"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$BASE_HTTP/")
if [ "$HTTP_CODE" = "301" ]; then
    LOCATION=$(curl -sI --connect-timeout 5 "$BASE_HTTP/" 2>&1 | grep -i "^location:" | tr -d '\r')
    if echo "$LOCATION" | grep -qi "https://"; then
        pass "HTTP returns 301 redirect to HTTPS"
    else
        fail "HTTP returns 301 but Location does not point to HTTPS: $LOCATION"
    fi
else
    fail "HTTP returns $HTTP_CODE (expected 301)"
fi

# --- Test 2: Security headers ---
echo "[2/10] Security headers present"
HEADERS=$(curl -sI --insecure --connect-timeout 5 -H "Host: app.test.example.com" "$BASE_HTTPS/" 2>&1)
ALL_HEADERS=true
for header in "strict-transport-security" "x-content-type-options" "x-frame-options"; do
    if echo "$HEADERS" | grep -qi "^${header}:"; then
        : # ok
    else
        ALL_HEADERS=false
        fail "Missing header: $header"
    fi
done
if $ALL_HEADERS; then
    pass "HSTS, X-Content-Type-Options, X-Frame-Options present"
fi

# --- Test 3: Reverse proxy forwards to backend ---
echo "[3/10] Reverse proxy forwards requests to backend"
RESPONSE=$(kurl -H "Host: app.test.example.com" "$BASE_HTTPS/" 2>&1) || RESPONSE=""
if echo "$RESPONSE" | grep -q '"method"'; then
    # Check forwarded headers
    HAS_REAL_IP=false
    HAS_FORWARDED=false
    HAS_PROTO=false
    if echo "$RESPONSE" | grep -qi '"X-Real-IP"'; then HAS_REAL_IP=true; fi
    if echo "$RESPONSE" | grep -qi '"X-Forwarded-For"'; then HAS_FORWARDED=true; fi
    if echo "$RESPONSE" | grep -qi '"X-Forwarded-Proto"'; then HAS_PROTO=true; fi

    if $HAS_REAL_IP && $HAS_FORWARDED && $HAS_PROTO; then
        pass "Proxy forwards X-Real-IP, X-Forwarded-For, X-Forwarded-Proto"
    else
        fail "Missing proxy headers (real_ip=$HAS_REAL_IP, forwarded=$HAS_FORWARDED, proto=$HAS_PROTO)"
    fi
else
    fail "Backend did not return expected JSON response"
fi

# --- Test 4: Debug endpoint returns JSON ---
echo "[4/10] Debug endpoint returns JSON"
DEBUG_RESPONSE=$(kurl -H "Host: app.test.example.com" "$BASE_HTTPS/debug" 2>&1) || DEBUG_RESPONSE=""
if echo "$DEBUG_RESPONSE" | grep -q '"ip"'; then
    if echo "$DEBUG_RESPONSE" | grep -q '"access_allowed"'; then
        pass "Debug endpoint returns JSON with access control variables"
    else
        fail "Debug endpoint missing access_allowed field"
    fi
else
    fail "Debug endpoint did not return expected JSON"
fi

# --- Test 5: Private network detection ---
echo "[5/10] Private network detection"
if echo "$DEBUG_RESPONSE" | grep -q '"lan": "1"'; then
    pass "Docker network detected as private network (lan=1)"
else
    # From Docker, we're on 172.x.x.x which should match private_networks
    LAN_VALUE=$(echo "$DEBUG_RESPONSE" | grep '"lan"' | head -1)
    fail "Private network not detected. Got: $LAN_VALUE"
fi

# --- Test 6: Per-vhost access control ---
echo "[6/10] Per-vhost access control"
VHOSTS_OK=true
for host in app.test.example.com svn.test.example.com git.test.example.com; do
    HTTP_CODE=$(kurl_code -H "Host: $host" "$BASE_HTTPS/")
    if [ "$HTTP_CODE" = "200" ]; then
        : # ok
    else
        VHOSTS_OK=false
        fail "vhost $host returned $HTTP_CODE (expected 200)"
    fi
done
if $VHOSTS_OK; then
    pass "All 3 vhosts accessible from private network"
fi

# --- Test 7: Security blocking ---
echo "[7/10] Security blocking"
PHP_CODE=$(kurl_code -H "Host: app.test.example.com" "$BASE_HTTPS/test.php")
ACTUATOR_CODE=$(kurl_code -H "Host: app.test.example.com" "$BASE_HTTPS/actuator")

BLOCK_OK=true
# .php returns 444 (nginx closes connection, curl sees it as 000 or empty)
if [ "$PHP_CODE" = "000" ] || [ "$PHP_CODE" = "444" ]; then
    : # ok — nginx drops connection
else
    BLOCK_OK=false
    fail ".php returned $PHP_CODE (expected connection drop/444)"
fi
if [ "$ACTUATOR_CODE" = "404" ]; then
    : # ok
else
    BLOCK_OK=false
    fail "/actuator returned $ACTUATOR_CODE (expected 404)"
fi
if $BLOCK_OK; then
    pass ".php blocked (connection dropped), /actuator returns 404"
fi

# --- Test 8: Rate limiting ---
echo "[8/10] Rate limiting"
# Send burst of requests to /login — should eventually get 503 (limit_req_status defaults to 503)
RATE_LIMITED=false
for _i in $(seq 1 30); do
    HTTP_CODE=$(kurl_code -H "Host: app.test.example.com" "$BASE_HTTPS/login")
    if [ "$HTTP_CODE" = "503" ]; then
        RATE_LIMITED=true
        break
    fi
done
if $RATE_LIMITED; then
    pass "Rate limiting triggers 503 on /login burst"
else
    fail "Rate limiting did not trigger on /login after 30 requests"
fi

# --- Test 9: Large body on SVN vhost ---
echo "[9/10] Large body upload on SVN vhost (client_max_body_size 0)"
# Generate 2MB payload and POST to svn vhost
LARGE_CODE=$(dd if=/dev/zero bs=1024 count=2048 2>/dev/null | curl -s -o /dev/null -w "%{http_code}" \
    --insecure --connect-timeout 10 -X POST \
    -H "Host: svn.test.example.com" -H "Content-Type: application/octet-stream" \
    --data-binary @- "$BASE_HTTPS/" 2>&1) || LARGE_CODE="000"
if [ "$LARGE_CODE" = "200" ]; then
    pass "SVN vhost accepts large body (2MB)"
else
    fail "SVN vhost returned $LARGE_CODE for 2MB body (expected 200)"
fi

# --- Test 10: GeoIP module loaded, nginx config valid ---
echo "[10/10] GeoIP module loaded and nginx config valid"
CONFIG_TEST=$(docker exec nginx-integration-test nginx -t 2>&1) || CONFIG_TEST=""
if echo "$CONFIG_TEST" | grep -q "syntax is ok"; then
    pass "nginx -t passes (config valid, GeoIP module loaded)"
else
    fail "nginx -t failed: $CONFIG_TEST"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
