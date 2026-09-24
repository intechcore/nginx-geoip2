#!/bin/sh
# Coverage image only. tests/coverage.sh passes this file to kcov as the
# bash parser. Instead of running the script it writes a recorded trace to the
# trace descriptor of kcov. kcov first asks the parser for its version.
if [ "${1:-}" = -c ]; then
    exec bash "$@"
fi
cat "$COV_TRACE" >&"$KCOV_BASH_XTRACEFD"
