# Security policy

## Reporting a vulnerability

Report a vulnerability privately through GitHub:
https://github.com/intechcore/nginx-geoip2/security/advisories/new
(the **Security** tab, **Report a vulnerability**). Do not open a public issue for it.

We answer within a week. The fix goes into the next release, and its release notes name it.

## Supported versions

Only the latest image of each branch, `ghcr.io/intechcore/nginx-geoip2:mainline` (also `latest`)
and `ghcr.io/intechcore/nginx-geoip2:stable`, gets fixes. Automatic releases pick up fixed
packages and base image updates.

## Scope

The image: the Dockerfile, the scripts in `scripts/`, the tests and the workflows. The GeoIP2
module has its own repository and policy: https://github.com/intechcore/ngx_http_geoip2_module.

Vulnerabilities in upstream software (nginx, MaxMind libmaxminddb, supercronic, the Debian
packages and the `nginx:<version>-trixie` base image) belong to the upstream project. Tell us as
well if this project is affected, so we can release a fix when the upstream fix is out.
