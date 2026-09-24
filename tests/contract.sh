#!/usr/bin/env bash
# Checks the configuration contract: every variable in the "Environment
# Variables" table of README.md appears in at least one test suite.
#
#   tests/contract.sh
#
# A variable that no test in CI can cover goes into tests/contract-allowlist.txt
# with the reason: "<VARIABLE> <reason>". Prints the uncovered variables and
# exits non-zero if there are any.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$ROOT/README.md"
ALLOWLIST="$ROOT/tests/contract-allowlist.txt"

# First column of the table rows under the heading, for example `GEOIP_DIR`.
variables=$(awk '
    /^## / { in_section = ($0 == "## Environment Variables") }
    in_section && /^\| `[A-Z0-9_]+` \|/ {
        split($0, cells, "`")
        print cells[2]
    }' "$README")

if [[ -z "$variables" ]]; then
    echo "No variables found in the Environment Variables table of README.md"
    exit 1
fi

allowed=""
if [[ -f "$ALLOWLIST" ]]; then
    allowed=$(grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST" | awk '{print $1}')
fi

total=0
covered=0
missing=()
while IFS= read -r var; do
    total=$((total + 1))
    if grep -qw -- "$var" <<< "$allowed"; then
        echo "  allowed: $var"
    elif grep -qw -- "$var" "$ROOT"/tests/*/test-*.sh; then
        covered=$((covered + 1))
    else
        missing+=("$var")
    fi
done <<< "$variables"

echo "Contract: $covered of $total documented variables covered by the tests"
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Not covered by any test in tests/*/test-*.sh:"
    printf '  %s\n' "${missing[@]}"
    exit 1
fi
