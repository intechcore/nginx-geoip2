#!/bin/bash
set -euo pipefail

# Tests for the GeoIP database updater: update-geoip.sh, the geoip-cron.sh
# wrapper, the initial download in the entrypoint and the extra editions of
# GEOIP_EXTRA_EDITIONS.
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
TOTAL=15

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
# floor, one of sufficient size without the database, one that is no gzip
# at all, and one with GeoLite2-Country and GeoLite2-ASN. The fake curl sends
# the same body for every edition, so each edition takes its own file from it.
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
    head -c 4096 /dev/urandom > /out/corrupt.tar.gz
    mkdir -p /tmp/multi/GeoLite2-Country_20260922 /tmp/multi/GeoLite2-ASN_20260922
    cp /test.mmdb /tmp/multi/GeoLite2-Country_20260922/GeoLite2-Country.mmdb
    cp /test.mmdb /tmp/multi/GeoLite2-ASN_20260922/GeoLite2-ASN.mmdb
    tar -czf /out/multi.tar.gz -C /tmp/multi GeoLite2-Country_20260922 GeoLite2-ASN_20260922
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
    [ "$(ls -A /tmp/geoip)" = GeoLite2-Country.mmdb ] && echo ONLY_COUNTRY
    url=$(cat /tmp/url)
    case "$url" in
        "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=$MAXMIND_LICENSE_KEY&suffix=tar.gz") echo URL_OK ;;
    esac
' 2>&1) || true
if grep -qx EXIT_OK <<< "$OUT" && grep -qx SAME_DB <<< "$OUT" && grep -qx URL_OK <<< "$OUT" \
        && grep -qx ONLY_COUNTRY <<< "$OUT" \
        && grep -qF "[GeoIP] Database updated: /tmp/geoip/GeoLite2-Country.mmdb" <<< "$OUT"; then
    pass "Database extracted to GEOIP_DIR, one request to the MaxMind download URL, no extra edition"
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

# The extra edition cases start with marker files for both databases.
KEEP_BOTH="$KEEP_DB"'
    echo previous-asn > /tmp/geoip/GeoLite2-ASN.mmdb
'
ASN_KEPT='[ "$(cat /tmp/geoip/GeoLite2-ASN.mmdb)" = previous-asn ] && echo ASN_KEPT'
NO_STAGED='[ -z "$(find /tmp/geoip -name ".*.tmp*")" ] && echo NO_STAGED'

# --- Test 9: an extra edition goes next to the country database ---
echo "[9/$TOTAL] GEOIP_EXTRA_EDITIONS installs GeoLite2-ASN.mmdb next to GeoLite2-Country.mmdb"
OUT=$(in_image '
    export GEOIP_DIR=/tmp/geoip FAKE_CURL_BODY=/archives/multi.tar.gz FAKE_CURL_LOG=/tmp/url
    export GEOIP_EXTRA_EDITIONS=GeoLite2-ASN
    /usr/local/bin/update-geoip.sh && echo EXIT_OK
    cmp -s /test.mmdb /tmp/geoip/GeoLite2-Country.mmdb && echo SAME_COUNTRY
    cmp -s /test.mmdb /tmp/geoip/GeoLite2-ASN.mmdb && echo SAME_ASN
    [ "$(sed -n 2p /tmp/url)" = "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-ASN&license_key=$MAXMIND_LICENSE_KEY&suffix=tar.gz" ] && echo URL_OK
    '"$NO_STAGED" 2>&1) || true
if grep -qx EXIT_OK <<< "$OUT" && grep -qx SAME_COUNTRY <<< "$OUT" && grep -qx SAME_ASN <<< "$OUT" \
        && grep -qx URL_OK <<< "$OUT" && grep -qx NO_STAGED <<< "$OUT" \
        && grep -qF "[GeoIP] Database updated: /tmp/geoip/GeoLite2-ASN.mmdb" <<< "$OUT" \
        && ! grep -qF "$DUMMY_KEY" <<< "$OUT"; then
    pass "Both databases installed, ASN requested by its edition ID, key not printed"
else
    fail "Extra edition not installed:"
    sed 's/^/    /' <<< "$OUT"
fi

# --- Test 10: invalid edition names are skipped and never requested ---
echo "[10/$TOTAL] Invalid edition names in GEOIP_EXTRA_EDITIONS are skipped without a request"
OUT=$(in_image '
    export GEOIP_DIR=/tmp/geoip FAKE_CURL_BODY=/archives/multi.tar.gz FAKE_CURL_LOG=/tmp/url
    export GEOIP_EXTRA_EDITIONS="../evil GeoLite2-ASN a&license_key=x *"
    # A file named decoy in the working directory: a glob of * would request it.
    mkdir -p /tmp/geoip && cd /tmp/geoip && touch decoy
    /usr/local/bin/update-geoip.sh && echo EXIT_OK
    [ "$(wc -l < /tmp/url)" -eq 2 ] && echo TWO_REQUESTS
    grep -q "edition_id=GeoLite2-ASN&" /tmp/url && echo ASN_REQUESTED
    [ -f /tmp/geoip/GeoLite2-ASN.mmdb ] && echo ASN_INSTALLED
    [ -e /tmp/evil.mmdb ] || echo NO_TRAVERSAL
' 2>&1) || true
if grep -qx EXIT_OK <<< "$OUT" && grep -qx TWO_REQUESTS <<< "$OUT" \
        && grep -qx ASN_REQUESTED <<< "$OUT" && grep -qx ASN_INSTALLED <<< "$OUT" \
        && grep -qx NO_TRAVERSAL <<< "$OUT" \
        && grep -qF "WARNING: Skipping invalid edition name '../evil'" <<< "$OUT" \
        && grep -qF "WARNING: Skipping invalid edition name 'a&license_key=x'" <<< "$OUT" \
        && grep -qF "WARNING: Skipping invalid edition name '*'" <<< "$OUT"; then
    pass "Invalid names skipped with a warning, valid edition still installed"
else
    fail "Invalid edition names not rejected:"
    sed 's/^/    /' <<< "$OUT"
fi

# --- Test 11: a failed extra edition keeps its file and the country update ---
echo "[11/$TOTAL] A failed extra edition keeps its previous file, the country update and the exit code"
OUT=$(in_image "$KEEP_BOTH"'
    export FAKE_CURL_BODY=/archives/good.tar.gz GEOIP_EXTRA_EDITIONS=GeoLite2-ASN
    /usr/local/bin/update-geoip.sh && echo EXIT_OK
    cmp -s /test.mmdb /tmp/geoip/GeoLite2-Country.mmdb && echo SAME_COUNTRY
    '"$ASN_KEPT"'
    /usr/local/bin/geoip-cron.sh
' 2>&1) || true
if grep -qx EXIT_OK <<< "$OUT" && grep -qx SAME_COUNTRY <<< "$OUT" && grep -qx ASN_KEPT <<< "$OUT" \
        && grep -qF "WARNING: GeoLite2-ASN.mmdb not found in archive" <<< "$OUT" \
        && grep -qF "WARNING: GeoLite2-ASN update failed, keeping the previous file" <<< "$OUT" \
        && grep -qF "[GeoIP] Update completed successfully" <<< "$OUT" \
        && ! grep -qF "ERROR" <<< "$OUT"; then
    pass "Country updated, ASN kept with a warning, update and cron run succeed"
else
    fail "Failed extra edition broke the update:"
    sed 's/^/    /' <<< "$OUT"
fi

# --- Test 12: an archive that is no gzip keeps both databases ---
echo "[12/$TOTAL] An archive that does not extract fails the country update and keeps both databases"
OUT=$(in_image "$KEEP_BOTH"'
    export FAKE_CURL_BODY=/archives/corrupt.tar.gz GEOIP_EXTRA_EDITIONS=GeoLite2-ASN
    if /usr/local/bin/update-geoip.sh; then echo UNEXPECTED_OK; fi
    '"$DB_KEPT"'
    '"$ASN_KEPT" 2>&1) || true
if grep -qx KEPT <<< "$OUT" && grep -qx ASN_KEPT <<< "$OUT" && ! grep -qx UNEXPECTED_OK <<< "$OUT" \
        && grep -qF "ERROR: Cannot extract the GeoLite2-Country archive" <<< "$OUT" \
        && grep -qF "WARNING: Cannot extract the GeoLite2-ASN archive" <<< "$OUT"; then
    pass "Country failure reported as error, ASN as warning, both databases kept"
else
    fail "Corrupt archive not handled:"
    sed 's/^/    /' <<< "$OUT"
fi

# --- Test 13: a read-only GEOIP_DIR keeps both databases ---
echo "[13/$TOTAL] A read-only GEOIP_DIR fails the install and keeps both databases"
OUT=$(in_image "$KEEP_BOTH"'
    export FAKE_CURL_BODY=/archives/multi.tar.gz GEOIP_EXTRA_EDITIONS=GeoLite2-ASN
    chmod 0555 /tmp/geoip
    if /usr/local/bin/update-geoip.sh; then echo UNEXPECTED_OK; fi
    '"$DB_KEPT"'
    '"$ASN_KEPT"'
    '"$NO_STAGED" 2>&1) || true
if grep -qx KEPT <<< "$OUT" && grep -qx ASN_KEPT <<< "$OUT" && grep -qx NO_STAGED <<< "$OUT" \
        && ! grep -qx UNEXPECTED_OK <<< "$OUT" \
        && grep -qF "ERROR: Cannot install /tmp/geoip/GeoLite2-Country.mmdb" <<< "$OUT" \
        && grep -qF "WARNING: Cannot install /tmp/geoip/GeoLite2-ASN.mmdb" <<< "$OUT"; then
    pass "Install failure reported, both databases kept, no staged file left"
else
    fail "Read-only GEOIP_DIR not handled:"
    sed 's/^/    /' <<< "$OUT"
fi

# --- Test 14: the entrypoint installs extra editions and starts despite a failed one ---
echo "[14/$TOTAL] Entrypoint installs GeoLite2-ASN, warns on a failed edition and starts nginx"
EX_C="nginx-geoip-geoip-extra-editions"
docker_run -d --name "$EX_C" \
    -e PATH="/fake-bin:$IMAGE_PATH" \
    -e MAXMIND_LICENSE_KEY="$DUMMY_KEY" \
    -e FAKE_CURL_BODY=/archives/multi.tar.gz \
    -e GEOIP_EXTRA_EDITIONS="GeoLite2-ASN GeoLite2-City" \
    -e UPTIMEROBOT_ENABLED=false \
    -v "$FAKE_BIN:/fake-bin:ro" \
    -v "$ARCHIVES:/archives:ro" \
    -v "$TEST_MMDB:/test.mmdb:ro" \
    "$IMAGE" > /dev/null
STARTED_CONTAINERS+=("$EX_C")
EX_OK=true
if ! wait_for_log "$EX_C" "[GeoIP] WARNING: GeoLite2-City update failed, keeping the previous file" 20; then
    EX_OK=false
    fail "Entrypoint did not report the failed GeoLite2-City within 20s"
fi
SERVED=false
for _ in $(seq 1 30); do
    if docker exec "$EX_C" /usr/bin/curl -fsS -o /dev/null http://localhost:8080/ 2>/dev/null; then
        SERVED=true
        break
    fi
    sleep 1
done
if ! $SERVED; then
    EX_OK=false
    fail "nginx did not serve within 30s with a failed extra edition"
fi
for db in GeoLite2-Country GeoLite2-ASN; do
    if ! docker exec "$EX_C" cmp -s /test.mmdb "/usr/share/GeoIP/$db.mmdb"; then
        EX_OK=false
        fail "$db.mmdb missing or different in /usr/share/GeoIP"
    fi
done
if grep -qF "[Entrypoint] WARNING: Download failed" < <(docker logs "$EX_C" 2>&1); then
    EX_OK=false
    fail "Entrypoint treated the failed extra edition as a failed download"
fi
docker rm -f "$EX_C" > /dev/null 2>&1 || true
$EX_OK && pass "Country and ASN installed, GeoLite2-City warned, nginx serving"

# --- Test 15: a leftover at the old fixed staging path does not block the install ---
echo "[15/$TOTAL] A leftover .GeoLite2-Country.mmdb.tmp directory does not block the install"
OUT=$(in_image '
    export GEOIP_DIR=/tmp/geoip FAKE_CURL_BODY=/archives/good.tar.gz
    mkdir -p /tmp/geoip/.GeoLite2-Country.mmdb.tmp
    /usr/local/bin/update-geoip.sh && echo EXIT_OK
    [ -f /tmp/geoip/GeoLite2-Country.mmdb ] && cmp -s /test.mmdb /tmp/geoip/GeoLite2-Country.mmdb && echo SAME_DB
    [ -d /tmp/geoip/.GeoLite2-Country.mmdb.tmp ] && echo LEFTOVER_UNTOUCHED
    [ -z "$(find /tmp/geoip -name ".GeoLite2-Country.mmdb.tmp.*")" ] && echo NO_STAGED
' 2>&1) || true
if grep -qx EXIT_OK <<< "$OUT" && grep -qx SAME_DB <<< "$OUT" \
        && grep -qx LEFTOVER_UNTOUCHED <<< "$OUT" && grep -qx NO_STAGED <<< "$OUT"; then
    pass "Unique staging file used, database installed, foreign path untouched"
else
    fail "A file at the fixed staging path broke the install:"
    sed 's/^/    /' <<< "$OUT"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
