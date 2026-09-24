# shellcheck shell=bash
# Coverage image only. bash reads this file through BASH_ENV before it runs
# the script, see trace-run.sh. It sends the trace to COV_TRACE, one line per
# command in the kcov format kcov@<file>@<line>@. Child processes do not
# inherit the setup, each script started later records its own trace.
exec 19>> "$COV_TRACE"
BASH_XTRACEFD=19
PS4='kcov@${BASH_SOURCE}@${LINENO}@'
unset BASH_ENV COV_TRACE
set -x
