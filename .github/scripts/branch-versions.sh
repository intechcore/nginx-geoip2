#!/usr/bin/env bash
# Prints the versions of one nginx branch from nginx-branches.env as
# key=value lines, for $GITHUB_OUTPUT.
#
#   .github/scripts/branch-versions.sh mainline|stable
#
#   nginx=1.31.6
#   module=ghcr.io/intechcore/ngx_http_geoip2_module:1.31.6-13@sha256:...
set -euo pipefail

branch=${1:?usage: branch-versions.sh mainline|stable}
case "$branch" in
  mainline) prefix=MAINLINE ;;
  stable) prefix=STABLE ;;
  *)
    echo "unknown branch: $branch" >&2
    exit 1
    ;;
esac

# shellcheck disable=SC1091 # plain VAR=value lines, nothing to follow
. "$(dirname "$0")/../../nginx-branches.env"
nginx_var="${prefix}_NGINX"
module_var="${prefix}_GEOIP2_MODULE"

echo "nginx=${!nginx_var}"
echo "module=${!module_var}"
