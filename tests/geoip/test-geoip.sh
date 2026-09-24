#!/bin/bash
set -euo pipefail

# Tests for the GeoIP database updater: update-geoip.sh, the geoip-cron.sh
# wrapper and the initial download in the entrypoint.
#
# Usage: ./tests/geoip/test-geoip.sh [IMAGE_NAME:TAG]
#
# The tests never reach MaxMind. tests/fake-bin/curl comes first on PATH and
# answers with archives built from the test database of the integration suite.
# The license key is a dummy value.

IMAGE="${1:-nginx-geoip2:latest}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FAKE_BIN="$SCRIPT_DIR/../fake-bin"
TEST_MMDB="$SCRIPT_DIR/../integration/fixtures/GeoLite2-Country-Test.mmdb"
DUMMY_KEY="dummy-license-key-for-tests"
IMAGE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
PASS=0
FAIL=0
TOTAL=8

# Opt-in coverage: tests/coverage.sh sets COVERAGE_DIR and passes the coverage
# image. Each container then mounts that directory at /cov for the traces.
docker_run() {
    if [[ -n "${COVERAGE_DIR:-}" ]]; then
        docker run -v "$COVERAGE_DIR:/cov" "$@"
    else
        docker run "$@"
    fi
}

# Archives served by the fake curl, built once per run.
ARCHIVES="$(mktemp -d)"
STARTED_CONTAINERS=()
cleanup() {
    for c in "${STARTED_CONTAINERS[@]:-}"; do
        [[ -n "$c" ]] && docker rm -f "$c" > /dev/null 2>&1 || true
    done
    rm -rf "$ARCHIVES"
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

# Run a shell snippet in a fresh container with the fake curl first on PATH,
# the archives in /archives and the test database in /test.mmdb.
in_image() {
    docker_run --rm --entrypoint /bin/sh \
        -e PATH="/fake-bin:$IMAGE_PATH" \
        -e MAXMIND_LICENSE_KEY="$DUMMY_KEY" \
        -v "$FAKE_BIN:/fake-bin:ro" \
        -v "$ARCHIVES:/archives:ro" \
        -v "$TEST_MMDB:/test.mmdb:ro" \
        "$IMAGE" -c "$1"
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

echo "=== GeoIP updater tests for $IMAGE ==="
echo ""

# --- Test 1: image exists ---
echo "[1/$TOTAL] Image exists"
if docker image inspect "$IMAGE" > /dev/null 2>&1; then
    pass "Image $IMAGE found"
else
    fail "Image $IMAGE not found, build it first"
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

# The archives: a good one in the layout of MaxMind, one below the 1024 byte
# floor, and one of sufficient size without the database.
chmod 0777 "$ARCHIVES"
docker run --rm --user "$(id -u):$(id -g)" --entrypoint /bin/sh \
    -v "$ARCHIVES:/out" -v "$TEST_MMDB:/test.mmdb:ro" "$IMAGE" -c '
    set -e
    mkdir -p /tmp/good/GeoLite2-Country_20260922 /tmp/no-db
    cp /test.mmdb /tmp/good/GeoLite2-Country_20260922/GeoLite2-Country.mmdb
    tar -czf /out/good.tar.gz -C /tmp/good GeoLite2-Country_20260922
    head -c 4096 /dev/urandom > /tmp/no-db/README.txt
    tar -czf /out/no-db.tar.gz -C /tmp/no-db README.txt
    printf "not an archive" | gzip > /out/small.tar.gz
'
chmod 0755 "$ARCHIVES"
chmod 0644 "$ARCHIVES"/*

# A failed update must leave the database in place. The error cases start
# with a marker file as the database and compare it afterwards.
KEEP_DB='
    mkdir -p /tmp/geoip
    echo previous-database > /tmp/geoip/GeoLite2-Country.mmdb
    export GEOIP_DIR=/tmp/geoip
'
DB_KEPT='[ "$(cat /tmp/geoip/GeoLite2-Country.mmdb)" = previous-database ] && echo KEPT'

# --- Test 2: a good archive installs the database ---
echo "[2/$TOTAL] update-geoip.sh installs the database from the archive into GEOIP_DIR"
OUT=$(in_image '
    export GEOIP_DIR=/tmp/geoip FAKE_CURL_BODY=/archives/good.tar.gz FAKE_CURL_LOG=/tmp/url
    /usr/local/bin/update-geoip.sh && echo EXIT_OK
    cmp -s /test.mmdb /tmp/geoip/GeoLite2-Country.mmdb && echo SAME_DB
    url=$(cat /tmp/url)
    case "$url" in
        "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=$MAXMIND_LICENSE_KEY&suffix=tar.gz") echo URL_OK ;;
    esac
' 2>&1) || true
if grep -qx EXIT_OK <<< "$OUT" && grep -qx SAME_DB <<< "$OUT" && grep -qx URL_OK <<< "$OUT" \
        && grep -qF "[GeoIP] Database updated: /tmp/geoip/GeoLite2-Country.mmdb" <<< "$OUT"; then
    pass "Database extracted to GEOIP_DIR, request sent to the MaxMind download URL"
else
    fail "Update from a good archive failed:"
    sed 's/^/    /' <<< "$OUT"
fi

# --- Test 3: the cron wrapper reports a successful update ---
echo "[3/$TOTAL] geoip-cron.sh reports a successful update"
OUT=$(in_image '
    export GEOIP_DIR=/tmp/geoip FAKE_CURL_BODY=/archives/good.tar.gz
    /usr/local/bin/geoip-cron.sh
' 2>&1) || true
if grep -qF "[GeoIP] Running scheduled update..." <<< "$OUT" \
        && grep -qF "[GeoIP] Update completed successfully" <<< "$OUT"; then
    pass "Wrapper logs the run and the success"
else
    fail "Wrapper output unexpected:"
    sed 's/^/    /' <<< "$OUT"
fi

# --- Test 4: an HTTP error keeps the database ---
echo "[4/$TOTAL] An HTTP error fails the update and keeps the database"
OUT=$(in_image "$KEEP_DB"'
    if FAKE_CURL_CODE=401 /usr/local/bin/update-geoip.sh; then echo UNEXPECTED_OK; fi
    '"$DB_KEPT" 2>&1) || true
if grep -qx KEPT <<< "$OUT" && ! grep -qx UNEXPECTED_OK <<< "$OUT" \
        && grep -qF "ERROR: Download failed (HTTP 401)" <<< "$OUT"; then
    pass "HTTP 401 reported, previous database kept"
else
    fail "HTTP error not handled:"
    sed 's/^/    /' <<< "$OUT"
fi

# --- Test 5: a truncated archive keeps the database ---
echo "[5/$TOTAL] An archive below 1024 bytes fails the update and keeps the database"
OUT=$(in_image "$KEEP_DB"'
    if FAKE_CURL_BODY=/archives/small.tar.gz /usr/local/bin/update-geoip.sh; then echo UNEXPECTED_OK; fi
    '"$DB_KEPT" 2>&1) || true
if grep -qx KEPT <<< "$OUT" && ! grep -qx UNEXPECTED_OK <<< "$OUT" \
        && grep -qF "ERROR: Downloaded archive is too small" <<< "$OUT"; then
    pass "Small archive rejected, previous database kept"
else
    fail "Small archive not rejected:"
    sed 's/^/    /' <<< "$OUT"
fi

# --- Test 6: an archive without the database keeps the database ---
echo "[6/$TOTAL] An archive without GeoLite2-Country.mmdb fails the update and keeps the database"
OUT=$(in_image "$KEEP_DB"'
    if FAKE_CURL_BODY=/archives/no-db.tar.gz /usr/local/bin/update-geoip.sh; then echo UNEXPECTED_OK; fi
    '"$DB_KEPT" 2>&1) || true
if grep -qx KEPT <<< "$OUT" && ! grep -qx UNEXPECTED_OK <<< "$OUT" \
        && grep -qF "ERROR: GeoLite2-Country.mmdb not found in archive" <<< "$OUT"; then
    pass "Archive without the database rejected, previous database kept"
else
    fail "Archive without the database not rejected:"
    sed 's/^/    /' <<< "$OUT"
fi

# --- Test 7: the updater refuses to run without a license key ---
echo "[7/$TOTAL] update-geoip.sh fails without MAXMIND_LICENSE_KEY and sends no request"
OUT=$(in_image '
    export FAKE_CURL_BODY=/archives/good.tar.gz FAKE_CURL_LOG=/tmp/url
    if MAXMIND_LICENSE_KEY= /usr/local/bin/update-geoip.sh; then echo UNEXPECTED_OK; fi
    [ -e /tmp/url ] || echo NO_REQUEST
' 2>&1) || true
if grep -qx NO_REQUEST <<< "$OUT" && ! grep -qx UNEXPECTED_OK <<< "$OUT" \
        && grep -qF "ERROR: MAXMIND_LICENSE_KEY is not set" <<< "$OUT"; then
    pass "Missing key reported, no download attempted"
else
    fail "Missing key not handled:"
    sed 's/^/    /' <<< "$OUT"
fi

# --- Test 8: the entrypoint downloads the database on a cold start ---
echo "[8/$TOTAL] Entrypoint downloads the database when none exists and starts nginx"
CS_C="nginx-geoip-geoip-cold-start"
docker_run -d --name "$CS_C" \
    -e PATH="/fake-bin:$IMAGE_PATH" \
    -e MAXMIND_LICENSE_KEY="$DUMMY_KEY" \
    -e FAKE_CURL_BODY=/archives/good.tar.gz \
    -e UPTIMEROBOT_ENABLED=false \
    -v "$FAKE_BIN:/fake-bin:ro" \
    -v "$ARCHIVES:/archives:ro" \
    -v "$TEST_MMDB:/test.mmdb:ro" \
    "$IMAGE" > /dev/null
STARTED_CONTAINERS+=("$CS_C")
CS_OK=true
if ! wait_for_log "$CS_C" "[GeoIP] Database updated: /usr/share/GeoIP/GeoLite2-Country.mmdb" 20; then
    CS_OK=false
    fail "Entrypoint did not download the database within 20s"
fi
SERVED=false
for _ in $(seq 1 30); do
    if docker exec "$CS_C" /usr/bin/curl -fsS -o /dev/null http://localhost:8080/ 2>/dev/null; then
        SERVED=true
        break
    fi
    sleep 1
done
if ! $SERVED; then
    CS_OK=false
    fail "nginx did not serve within 30s after the download"
fi
if ! docker exec "$CS_C" cmp -s /test.mmdb /usr/share/GeoIP/GeoLite2-Country.mmdb; then
    CS_OK=false
    fail "Installed database differs from the served archive"
fi
docker rm -f "$CS_C" > /dev/null 2>&1 || true
$CS_OK && pass "Database downloaded on a cold start, nginx serving"

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
