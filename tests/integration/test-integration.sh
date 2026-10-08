#!/bin/bash
set -euo pipefail

# Tests for nginx-geoip Docker image.
# Includes structural checks (image, module, healthcheck) and end-to-end integration tests.
#
# Usage: ./tests/integration/test-integration.sh [IMAGE_NAME:TAG]
#
# Requires: docker compose, curl
#
# Uses MaxMind GeoLite2-Country-Test.mmdb (Apache 2.0 license) bundled in fixtures.
# Test IPs: 2.125.160.216=GB (allowed), 89.160.20.112=SE (blocked), 216.160.83.56=US (blocked).

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
TOTAL=20

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

# Opt-in coverage: tests/coverage.sh sets COVERAGE_DIR and passes the coverage
# image. The override file then mounts that directory at /cov for the traces.
compose() {
    local files=(-f "$SCRIPT_DIR/docker-compose.yml")
    if [[ -n "${COVERAGE_DIR:-}" ]]; then
        files+=(-f "$SCRIPT_DIR/docker-compose.coverage.yml")
    fi
    IMAGE_NAME="$IMAGE_NAME" IMAGE_TAG="$IMAGE_TAG" docker compose "${files[@]}" "$@"
}

cleanup() {
    echo ""
    echo "--- Cleanup ---"
    cd "$SCRIPT_DIR"
    compose down -v 2>/dev/null || true
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
        if [[ -n "$host" ]]; then
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
    compose logs 2>&1 | tail -20 | sed 's/^/    /'
    return 1
}

echo "=== Tests for $IMAGE ==="
echo ""

# ============================================================
# Structural checks (no running container needed)
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

# --- Test 2: GeoIP2 module present ---
echo "[2/$TOTAL] GeoIP2 module binary exists"
if docker run --rm --entrypoint "" "$IMAGE" test -f /usr/lib/nginx/modules/ngx_http_geoip2_module.so; then
    pass "ngx_http_geoip2_module.so exists"
else
    fail "ngx_http_geoip2_module.so not found"
fi

# --- Test 3: HEALTHCHECK runs container-healthcheck ---
echo "[3/$TOTAL] HEALTHCHECK runs container-healthcheck"
HC=$(docker inspect --format='{{json .Config.Healthcheck.Test}}' "$IMAGE" 2>/dev/null || echo "")
if [[ "$HC" = '["CMD","container-healthcheck"]' ]]; then
    pass "HEALTHCHECK is $HC"
else
    fail "HEALTHCHECK is '$HC', expected [\"CMD\",\"container-healthcheck\"]"
fi

# --- Test 17: the healthcheck binary is present ---
echo "[17/$TOTAL] container-healthcheck binary present"
if HC_VERSION=$(docker run --rm --entrypoint "" "$IMAGE" container-healthcheck --version 2>&1); then
    pass "container-healthcheck $HC_VERSION"
else
    fail "container-healthcheck does not run: $HC_VERSION"
fi

# ============================================================
# Integration tests (containers with test fixtures)
# ============================================================

echo ""
echo "Starting test environment..."
cd "$SCRIPT_DIR"
compose up -d

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

# --- Test 18: the running container turns healthy ---
# Port 8080 redirects to HTTPS here. A redirect is an answer, as it was for curl -f.
echo "[18/$TOTAL] The healthcheck reports the container healthy"
HEALTH="starting"
for _i in $(seq 1 30); do
    HEALTH=$(docker inspect --format='{{.State.Health.Status}}' nginx-integration-test 2>/dev/null || echo "missing")
    [[ "$HEALTH" = "starting" ]] || break
    sleep 1
done
HEALTH_LOG=$(docker inspect --format='{{range .State.Health.Log}}{{.Output}}{{end}}' nginx-integration-test 2>/dev/null || echo "")
if [[ "$HEALTH" = "healthy" ]] && [[ "$HEALTH_LOG" == *"301"* ]]; then
    pass "healthy, nginx answered 301"
else
    fail "health is '$HEALTH', log: $HEALTH_LOG"
fi

# --- Test 19: HEALTHCHECK_PATH sets the path the healthcheck asks ---
echo "[19/$TOTAL] HEALTHCHECK_PATH sets the path"
if docker exec -e HEALTHCHECK_PATH=/healthz-contract nginx-integration-test container-healthcheck > /dev/null 2>&1 \
        && docker logs nginx-integration-test 2>&1 | grep -q "GET /healthz-contract"; then
    pass "the healthcheck asked /healthz-contract"
else
    fail "no request for /healthz-contract in the nginx log"
fi

# --- Test 20: HEALTHCHECK_PORT sets the port the healthcheck asks ---
# Plain HTTP on the TLS port gets 400 from nginx, which fails the check.
echo "[20/$TOTAL] HEALTHCHECK_PORT sets the port"
if HC_OUT=$(docker exec -e HEALTHCHECK_PORT=8443 nginx-integration-test container-healthcheck 2>&1); then
    fail "the healthcheck passed on the TLS port: $HC_OUT"
elif [[ "$HC_OUT" == *"400"* ]]; then
    pass "the healthcheck asked port 8443 and failed on its 400"
else
    fail "unexpected output: $HC_OUT"
fi

# --- Test 4: HTTP→HTTPS redirect ---
echo "[4/$TOTAL] HTTP to HTTPS redirect"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$BASE_HTTP/")
if [[ "$HTTP_CODE" = "301" ]]; then
    LOCATION=$(curl -sI --connect-timeout 5 "$BASE_HTTP/" 2>&1 | grep -i "^location:" | tr -d '\r')
    if echo "$LOCATION" | grep -qi "https://"; then
        pass "HTTP returns 301 redirect to HTTPS"
    else
        fail "HTTP returns 301 but Location does not point to HTTPS: $LOCATION"
    fi
else
    fail "HTTP returns $HTTP_CODE (expected 301)"
fi

# --- Test 5: Security headers ---
echo "[5/$TOTAL] Security headers present"
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

# --- Test 6: Reverse proxy forwards to backend ---
echo "[6/$TOTAL] Reverse proxy forwards requests to backend"
RESPONSE=$(kurl -H "Host: app.test.example.com" -H "X-Test-IP: 10.0.0.5" "$BASE_HTTPS/" 2>&1) || RESPONSE=""
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

# --- Test 7: Debug endpoint returns JSON ---
echo "[7/$TOTAL] Debug endpoint returns JSON"
DEBUG_RESPONSE=$(kurl -H "Host: app.test.example.com" -H "X-Test-IP: 10.0.0.5" "$BASE_HTTPS/debug" 2>&1) || DEBUG_RESPONSE=""
if echo "$DEBUG_RESPONSE" | grep -q '"ip"'; then
    if echo "$DEBUG_RESPONSE" | grep -q '"access_allowed"'; then
        pass "Debug endpoint returns JSON with access control variables"
    else
        fail "Debug endpoint missing access_allowed field"
    fi
else
    fail "Debug endpoint did not return expected JSON"
fi

# --- Test 8: Private network detection ---
echo "[8/$TOTAL] Private network detection"
if echo "$DEBUG_RESPONSE" | grep -q '"lan": "1"'; then
    pass "Docker network detected as private network (lan=1)"
else
    # From Docker, we're on 172.x.x.x which should match private_networks
    LAN_VALUE=$(echo "$DEBUG_RESPONSE" | grep '"lan"' | head -1)
    fail "Private network not detected. Got: $LAN_VALUE"
fi

# --- Test 9: Per-vhost access control ---
echo "[9/$TOTAL] Per-vhost access control"
VHOSTS_OK=true
for host in app.test.example.com svn.test.example.com git.test.example.com; do
    HTTP_CODE=$(kurl_code -H "Host: $host" -H "X-Test-IP: 10.0.0.5" "$BASE_HTTPS/")
    if [[ "$HTTP_CODE" = "200" ]]; then
        : # ok
    else
        VHOSTS_OK=false
        fail "vhost $host returned $HTTP_CODE (expected 200)"
    fi
done
if $VHOSTS_OK; then
    pass "All 3 vhosts accessible from private network"
fi

# --- Test 10: Security blocking ---
echo "[10/$TOTAL] Security blocking"
PHP_CODE=$(kurl_code -H "Host: app.test.example.com" "$BASE_HTTPS/test.php")
ACTUATOR_CODE=$(kurl_code -H "Host: app.test.example.com" "$BASE_HTTPS/actuator")

BLOCK_OK=true
# .php returns 444 (nginx closes connection, curl sees it as 000 or empty)
if [[ "$PHP_CODE" = "000" ]] || [[ "$PHP_CODE" = "444" ]]; then
    : # ok — nginx drops connection
else
    BLOCK_OK=false
    fail ".php returned $PHP_CODE (expected connection drop/444)"
fi
if [[ "$ACTUATOR_CODE" = "404" ]]; then
    : # ok
else
    BLOCK_OK=false
    fail "/actuator returned $ACTUATOR_CODE (expected 404)"
fi
if $BLOCK_OK; then
    pass ".php blocked (connection dropped), /actuator returns 404"
fi

# --- Test 11: Rate limiting ---
echo "[11/$TOTAL] Rate limiting"
# Send burst of requests to /login — should eventually get 503 (limit_req_status defaults to 503)
RATE_LIMITED=false
for _i in $(seq 1 30); do
    HTTP_CODE=$(kurl_code -H "Host: app.test.example.com" -H "X-Test-IP: 10.0.0.5" "$BASE_HTTPS/login")
    if [[ "$HTTP_CODE" = "503" ]]; then
        RATE_LIMITED=true
        break
    fi
done
if $RATE_LIMITED; then
    pass "Rate limiting triggers 503 on /login burst"
else
    fail "Rate limiting did not trigger on /login after 30 requests"
fi

# --- Test 12: Large body on SVN vhost ---
echo "[12/$TOTAL] Large body upload on SVN vhost (client_max_body_size 0)"
# Generate 2MB payload and POST to svn vhost
LARGE_CODE=$(dd if=/dev/zero bs=1024 count=2048 2>/dev/null | curl -s -o /dev/null -w "%{http_code}" \
    --insecure --connect-timeout 10 -X POST \
    -H "Host: svn.test.example.com" -H "X-Test-IP: 10.0.0.5" -H "Content-Type: application/octet-stream" \
    --data-binary @- "$BASE_HTTPS/" 2>&1) || LARGE_CODE="000"
if [[ "$LARGE_CODE" = "200" ]]; then
    pass "SVN vhost accepts large body (2MB)"
else
    fail "SVN vhost returned $LARGE_CODE for 2MB body (expected 200)"
fi

# ============================================================
# GeoIP country filtering tests
# Uses X-Test-IP header + set_real_ip_from to simulate different source IPs.
# Test database: GeoLite2-Country-Test.mmdb (MaxMind, Apache 2.0)
#   2.125.160.216 = GB (in geo_country_allow list)
#   89.160.20.112 = SE (NOT in any allow list)
#   216.160.83.56 = US (NOT in any allow list)
# ============================================================

# --- Test 13: Allowed country (GB) passes geo filter ---
echo "[13/$TOTAL] GeoIP: allowed country (GB) passes geo filter"
GB_CODE=$(kurl_code -H "Host: app.test.example.com" -H "X-Test-IP: 2.125.160.216" "$BASE_HTTPS/")
if [[ "$GB_CODE" = "200" ]]; then
    pass "GB IP (2.125.160.216) returns 200"
else
    fail "GB IP returned $GB_CODE (expected 200)"
fi

# --- Test 14: Blocked country (SE) denied by geo filter ---
echo "[14/$TOTAL] GeoIP: blocked country (SE) denied by geo filter"
SE_CODE=$(kurl_code -H "Host: app.test.example.com" -H "X-Test-IP: 89.160.20.112" "$BASE_HTTPS/")
if [[ "$SE_CODE" = "403" ]]; then
    pass "SE IP (89.160.20.112) returns 403"
else
    fail "SE IP returned $SE_CODE (expected 403)"
fi

# --- Test 15: Blocked country (US) denied by geo filter ---
echo "[15/$TOTAL] GeoIP: blocked country (US) denied by geo filter"
US_CODE=$(kurl_code -H "Host: app.test.example.com" -H "X-Test-IP: 216.160.83.56" "$BASE_HTTPS/")
if [[ "$US_CODE" = "403" ]]; then
    pass "US IP (216.160.83.56) returns 403"
else
    fail "US IP returned $US_CODE (expected 403)"
fi

# --- Test 16: GeoIP module loaded, nginx config valid ---
echo "[16/$TOTAL] GeoIP module loaded and nginx config valid"
CONFIG_TEST=$(docker exec nginx-integration-test nginx -t 2>&1) || CONFIG_TEST=""
if echo "$CONFIG_TEST" | grep -q "syntax is ok"; then
    pass "nginx -t passes (config valid, GeoIP module loaded)"
else
    fail "nginx -t failed: $CONFIG_TEST"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
