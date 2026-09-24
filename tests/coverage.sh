#!/usr/bin/env bash
# Measures the line coverage of the scripts in scripts/. Runs the four test
# suites against the coverage image and turns the recorded traces into kcov
# reports.
#
#   tests/coverage.sh <coverage image> <output directory>
#
# Build the image with: docker build --target coverage -t <image> .
#
# The output directory gets coverage.xml (SonarQube generic format, paths
# relative to the repository), coverage.txt (lines per script) and kcov/ (the
# HTML report of kcov).
set -euo pipefail

IMAGE=${1:?usage: tests/coverage.sh <coverage image> <output directory>}
OUT=${2:?usage: tests/coverage.sh <coverage image> <output directory>}
TESTS="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
TRACES="$(mktemp -d)"
# The container user 101 writes the traces, so the directory is open to all.
chmod 0777 "$TRACES"
trap 'docker run --rm -v "$TRACES:/cov" --entrypoint sh "$IMAGE" -c "rm -f /cov/*.trace"; rmdir "$TRACES"' EXIT

export COVERAGE_DIR="$TRACES"
"$TESTS/integration/test-integration.sh" "$IMAGE"
"$TESTS/logrotate/test-logrotate.sh" "$IMAGE"
"$TESTS/uptimerobot/test-uptimerobot.sh" "$IMAGE"
"$TESTS/geoip/test-geoip.sh" "$IMAGE"

echo ""
echo "=== Coverage report ==="
rm -rf "$OUT/kcov"
docker run --rm --user "$(id -u):$(id -g)" -v "$TRACES:/cov:ro" -v "$OUT:/out" \
    --entrypoint bash "$IMAGE" -c '
set -euo pipefail
mkdir -p /tmp/runs
# One kcov run per trace. The replay parser feeds the recorded trace to kcov
# instead of running the script again. The file name is <script>-<pid>-<time>.
for trace in /cov/*.trace; do
    run=$(basename "$trace" .trace)
    COV_TRACE=$trace kcov --bash-parser=/usr/local/lib/nginx-geoip/trace-replay.sh \
        --include-path=/src/scripts "/tmp/runs/$run" "/src/scripts/${run%-*-*}.sh"
done
kcov --merge /out/kcov /tmp/runs/*
# /src/scripts in the image is scripts/ in the repository.
sed "s|path=\"/src/scripts/|path=\"scripts/|" /out/kcov/kcov-merged/sonarqube.xml > /out/coverage.xml
'

# Lines per script, from the SonarQube report.
awk -F'"' '
    /<file path=/ { file = $2; order[++n] = file }
    /<lineToCover/ { total[file]++; if ($4 == "true") covered[file]++ }
    END {
        printf "%-30s %8s %8s\n", "script", "lines", "covered"
        for (i = 1; i <= n; i++) {
            f = order[i]
            all += total[f]; hit += covered[f]
            printf "%-30s %8d %7.1f%%\n", f, total[f], 100 * covered[f] / total[f]
        }
        printf "%-30s %8d %7.1f%%\n", "total", all, 100 * hit / all
    }' "$OUT/coverage.xml" | tee "$OUT/coverage.txt"
