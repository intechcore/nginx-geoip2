#!/bin/sh
# Coverage image only. Each script in /usr/local/bin is a link to this file.
# It runs the original from /src/scripts with bash and the same arguments,
# and records the bash trace in the format of kcov. tests/coverage.sh turns
# the traces into kcov reports.
#
# kcov does not run here. It pipes the stdout of the script and writes its
# report only after every holder of its trace pipe has exited. The entrypoint
# leaves nginx, supercronic and the log reader running. Under kcov, nginx would
# not be PID 1 and a stopped container would leave no report. A trace file
# needs no process around it and survives a killed container.
set -eu

name=$(basename "$0")
if [ "$name" = docker-entrypoint-geoip.sh ]; then
    name=entrypoint.sh
fi

# One file per process: several processes and containers write at once.
COV_TRACE="/cov/${name%.sh}-$$-$(date +%s%N).trace"
export COV_TRACE
BASH_ENV=/usr/local/lib/nginx-geoip/trace-env.sh exec bash "/src/scripts/$name" "$@"
