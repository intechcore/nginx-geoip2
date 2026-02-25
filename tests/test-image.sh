#!/bin/bash
set -euo pipefail

# Smoke tests for nginx-geoip Docker image.
# Usage: ./tests/test-image.sh [IMAGE_NAME]
#
# Requires MAXMIND_LICENSE_KEY env var for full tests (GeoIP download).
# Without it, only structural tests run (module loading, nginx config, healthcheck).

IMAGE="${1:-nginx-geoip2:latest}"
CONTAINER_NAME="nginx-geoip-test-$$"
PASS=0
FAIL=0

cleanup() {
    echo ""
    echo "--- Cleanup ---"
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
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

echo "=== Smoke tests for $IMAGE ==="
echo ""

# --- Test 1: Image exists ---
echo "[1/6] Image exists"
if docker image inspect "$IMAGE" > /dev/null 2>&1; then
    pass "Image $IMAGE found"
else
    fail "Image $IMAGE not found — build it first"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Test 2: GeoIP2 module is present ---
echo "[2/6] GeoIP2 module binary exists"
if docker run --rm --entrypoint "" "$IMAGE" test -f /usr/lib/nginx/modules/ngx_http_geoip2_module.so; then
    pass "ngx_http_geoip2_module.so exists"
else
    fail "ngx_http_geoip2_module.so not found"
fi

# --- Test 3: nginx -t with module loaded ---
echo "[3/6] nginx config test with GeoIP2 module"
CONFIG_OUTPUT=$(docker run --rm --entrypoint "" "$IMAGE" sh -c '
    echo "load_module modules/ngx_http_geoip2_module.so;" > /tmp/test.conf
    cat /etc/nginx/nginx.conf >> /tmp/test.conf
    nginx -t -c /tmp/test.conf 2>&1
' 2>&1) || true
if echo "$CONFIG_OUTPUT" | grep -q "syntax is ok"; then
    pass "nginx -t passes with GeoIP2 module loaded"
else
    fail "nginx -t failed: $CONFIG_OUTPUT"
fi

# --- Test 4: nginx serves HTTP ---
echo "[4/6] nginx responds to HTTP requests"
docker run -d --name "$CONTAINER_NAME" \
    --entrypoint "" \
    "$IMAGE" \
    nginx -g "daemon off;" > /dev/null 2>&1

# Wait for nginx to be ready
READY=false
for i in $(seq 1 10); do
    if docker exec "$CONTAINER_NAME" curl -sf http://localhost/ > /dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 1
done

if $READY; then
    pass "nginx responds on port 80"
else
    fail "nginx did not respond within 10s"
    echo "  Container logs:"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -5 | sed 's/^/    /'
fi

docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1

# --- Test 5: HEALTHCHECK defined ---
echo "[5/6] HEALTHCHECK instruction present"
HC=$(docker inspect --format='{{.Config.Healthcheck}}' "$IMAGE" 2>/dev/null || echo "")
if [ -n "$HC" ] && [ "$HC" != "<nil>" ]; then
    pass "HEALTHCHECK is defined"
else
    fail "HEALTHCHECK not found in image"
fi

# --- Test 6: Full entrypoint with GeoIP download (requires MAXMIND_LICENSE_KEY) ---
echo "[6/6] Full entrypoint: GeoIP download + nginx startup"
if [ -z "${MAXMIND_LICENSE_KEY:-}" ]; then
    echo "  SKIP: MAXMIND_LICENSE_KEY not set (set it to test GeoIP download)"
else
    docker run -d --name "$CONTAINER_NAME" \
        -e MAXMIND_LICENSE_KEY="$MAXMIND_LICENSE_KEY" \
        "$IMAGE" > /dev/null 2>&1

    # Wait for container to start and download GeoIP db
    GEOIP_OK=false
    for i in $(seq 1 30); do
        if docker exec "$CONTAINER_NAME" test -f /usr/share/GeoIP/GeoLite2-Country.mmdb 2>/dev/null; then
            GEOIP_OK=true
            break
        fi
        sleep 1
    done

    if $GEOIP_OK; then
        # Also verify nginx is responding through the entrypoint
        NGINX_OK=false
        for i in $(seq 1 10); do
            if docker exec "$CONTAINER_NAME" curl -sf http://localhost/ > /dev/null 2>&1; then
                NGINX_OK=true
                break
            fi
            sleep 1
        done

        if $NGINX_OK; then
            pass "Full entrypoint works: GeoIP downloaded, nginx serving"
        else
            fail "GeoIP downloaded but nginx not responding"
            docker logs "$CONTAINER_NAME" 2>&1 | tail -10 | sed 's/^/    /'
        fi
    else
        fail "GeoIP database not downloaded within 30s"
        docker logs "$CONTAINER_NAME" 2>&1 | tail -10 | sed 's/^/    /'
    fi

    docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
