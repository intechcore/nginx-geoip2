#!/usr/bin/env bash
# Prints the versions of one nginx branch from nginx-branches.env as
# key=value lines, for $GITHUB_OUTPUT. The nginx version and the base digest
# come from the pinned image reference.
#
#   .github/scripts/branch-versions.sh mainline|stable
#
#   image=nginx:1.31.6-trixie@sha256:...
#   nginx=1.31.6
#   base_digest=sha256:...
#   module=ghcr.io/intechcore/ngx_http_geoip2_module:1.31.6-13@sha256:...
#
# Fails when the module was built for another nginx version than the image
# holds: a dynamic module loads only into its own nginx version.
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
image_var="${prefix}_NGINX_IMAGE"
module_var="${prefix}_GEOIP2_MODULE"
image=${!image_var}
module=${!module_var}

image_pattern='^nginx:([0-9]+\.[0-9]+\.[0-9]+)-trixie@(sha256:[0-9a-f]{64})$'
if [[ ! $image =~ $image_pattern ]]; then
    echo "${image_var} is not nginx:<version>-trixie@sha256:<digest>: '${image}'" >&2
    exit 1
fi
nginx=${BASH_REMATCH[1]}
digest=${BASH_REMATCH[2]}

module_pattern='^ghcr\.io/intechcore/ngx_http_geoip2_module:([0-9]+\.[0-9]+\.[0-9]+)-[0-9]+@sha256:[0-9a-f]{64}$'
if [[ ! $module =~ $module_pattern ]]; then
    echo "${module_var} is not ghcr.io/intechcore/ngx_http_geoip2_module:<nginx>-<n>@sha256:<digest>: '${module}'" >&2
    exit 1
fi
if [[ ${BASH_REMATCH[1]} != "$nginx" ]]; then
    echo "${branch}: the image holds nginx ${nginx}, the module is built for nginx ${BASH_REMATCH[1]}." >&2
    echo "Wait for the module of nginx ${nginx}. Renovate adds it to the same pull request." >&2
    exit 1
fi

echo "image=${image}"
echo "nginx=${nginx}"
echo "base_digest=${digest}"
echo "module=${module}"
