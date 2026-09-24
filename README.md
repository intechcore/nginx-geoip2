# nginx-geoip2

[![CI](https://github.com/intechcore/nginx-geoip2/actions/workflows/ci.yml/badge.svg)](https://github.com/intechcore/nginx-geoip2/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/intechcore/nginx-geoip2/badge)](https://scorecard.dev/viewer/?uri=github.com/intechcore/nginx-geoip2)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/14795/badge)](https://www.bestpractices.dev/projects/14795)
[![Release](https://img.shields.io/github/v/release/intechcore/nginx-geoip2)](https://github.com/intechcore/nginx-geoip2/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=intechcore_nginx-geoip2&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=intechcore_nginx-geoip2)
[![Coverage](https://sonarcloud.io/api/project_badges/measure?project=intechcore_nginx-geoip2&metric=coverage)](https://sonarcloud.io/summary/new_code?id=intechcore_nginx-geoip2)

Nginx Docker image with GeoIP2 module for country-based access control. Automatically downloads and updates the MaxMind GeoLite2-Country database.

## Quick Start

```yaml
# docker-compose.yml
services:
  nginx:
    # renovate: image=ghcr.io/intechcore/nginx-geoip2
    image: ghcr.io/intechcore/nginx-geoip2:1.31.6-4
    ports:
      - "80:80"
      - "443:443"
    environment:
      - MAXMIND_LICENSE_KEY=your_license_key  # required
      - GEOIP_UPDATE_CRON=0 3 * * *           # optional, default '0 3 * * *'
      - LOGROTATE_CRON=30 0 * * *             # optional, default '30 0 * * *'
      - LOGROTATE_KEEP=14                     # optional, default 14
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - geoip-data:/usr/share/GeoIP    # persist database across restarts
      - nginx-logs:/var/log/nginx      # persist logs + rotation state

volumes:
  geoip-data:
  nginx-logs:
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MAXMIND_LICENSE_KEY` | - | **Required.** MaxMind license key |
| `GEOIP_UPDATE_CRON` | `0 3 * * *` | Cron expression for the GeoIP refresh job |
| `GEOIP_DIR` | `/usr/share/GeoIP` | Directory for GeoIP database |
| `LOGROTATE_ENABLED` | `true` | Set to `false` to skip the supercronic scheduler |
| `LOGROTATE_CRON` | `30 0 * * *` | Cron expression — when supercronic invokes logrotate |
| `LOGROTATE_FREQUENCY` | `daily` | logrotate minimum interval: `daily` \| `weekly` \| `monthly` |
| `LOGROTATE_KEEP` | `14` | Number of rotated archives to keep |
| `LOGROTATE_MAXAGE` | `30` | Days after which rotated archives are deleted by mtime |
| `LOGROTATE_MAXSIZE` | (unset) | Rotate before next cron if file exceeds size (e.g. `5G`); empty disables |
| `LOGROTATE_COMPRESS` | `true` | Gzip rotated files (`compress` + `delaycompress`) |
| `LOGROTATE_PATTERN` | `/var/log/nginx/*.log` | Glob of log files to rotate |
| `UPTIMEROBOT_ENABLED` | `true` | Set to `false` to skip both the initial fetch and the cron entry |
| `UPTIMEROBOT_UPDATE_CRON` | `15 4 * * *` | Cron expression for refreshing the UptimeRobot IP list |
| `UPTIMEROBOT_DIR` | `/etc/nginx/uptimerobot` | Directory holding the rendered `uptimerobot.map.conf` |
| `UPTIMEROBOT_URL` | `https://uptimerobot.com/inc/files/ips/IPv4andIPv6.txt` | Source list URL |

## Logging

All output uses a unified timestamp format:

```
2026-02-06 09:39:36 [Entrypoint] Downloading initial GeoIP database...
2026-02-06 09:39:36 [GeoIP] Downloading GeoLite2-Country database...
2026-02-06 09:39:37 [GeoIP] Database updated: /usr/share/GeoIP/GeoLite2-Country.mmdb (9.2 MB)
2026-02-06 09:39:37 [Entrypoint] Scheduling: GeoIP updater (cron='0 3 * * *')
2026-02-06 09:39:37 [Entrypoint] Scheduling: log rotator (cron='30 0 * * *', frequency=daily, keep=14, maxage=30, maxsize='none', compress=true)
2026-02-06 09:39:37 [Entrypoint] Starting supercronic
2026-02-06 09:39:37 [Entrypoint] Handing off to nginx entrypoint
2026-02-06 09:39:37 [nginx] Configuration complete; ready for start up
# at 03:00 every day:
2026-02-07 03:00:00 [GeoIP] Running scheduled update...
2026-02-07 03:00:01 [GeoIP] Database updated: /usr/share/GeoIP/GeoLite2-Country.mmdb (9.2 MB)
2026-02-07 03:00:01 [GeoIP] Update completed successfully
```

Nginx error log timestamps are replaced with the unified format. The error log stays on stderr. This applies to the default `error_log /var/log/nginx/error.log`: the entrypoint links that file to the filter. An `error_log /dev/stderr` directive bypasses the filter and keeps the nginx timestamp. For access logs, use a custom `log_format` without timestamp (the entrypoint filter adds it):

```nginx
log_format geoip '[access] $remote_addr $geoip2_data_country_code '
                  '"$request" $status $body_bytes_sent '
                  '"$http_referer" "$http_user_agent"';
access_log /dev/stdout geoip;
```

This produces:

```
2026-02-06 19:05:30 [access] 172.17.0.1 CH "GET / HTTP/1.1" 200 615 "-" "curl/7.88.1"
2026-02-06 19:05:30 [error] 29#29: *1 open() "/usr/share/nginx/html/favicon.ico" failed (2: No such file or directory)
```

## Log Rotation

[supercronic](https://github.com/aptible/supercronic) (a cron daemon for non-root containers) invokes `logrotate` on the schedule given by `LOGROTATE_CRON` (default `30 0 * * *` — every day at 00:30). The logrotate config is rendered at startup from a template using `LOGROTATE_PATTERN`, `LOGROTATE_FREQUENCY`, `LOGROTATE_KEEP`, `LOGROTATE_MAXAGE`, and `LOGROTATE_COMPRESS`. After rotation, nginx is signalled with `nginx -s reopen` (SIGUSR1) so it switches to fresh log files.

`LOGROTATE_MAXAGE` (default 30 days) deletes rotated archives older than N days by mtime — this handles the corner case where a vhost stops receiving traffic: its live `.log` stays empty, `notifempty` skips rotation, and without `maxage` the existing `.log.1` would never advance to `.log.2.gz` and never be cleaned up.

Rotation only triggers if you write nginx logs to real files in `/var/log/nginx/` (e.g. `access_log /var/log/nginx/<vhost>.access.log;`). The default symlinks to stdout/stderr are skipped by logrotate.

`LOGROTATE_CRON` controls *when* logrotate runs; `LOGROTATE_FREQUENCY` controls the minimum interval logrotate enforces internally. Cron firing more often than frequency is a no-op (logrotate skips). Cron firing less often skips rotations.

`LOGROTATE_MAXSIZE` (default: unset) is a safety net for traffic spikes — when set (e.g. `5G`), logrotate will rotate a file that exceeds this size at the next cron fire even if `LOGROTATE_FREQUENCY` hasn't elapsed. With cron firing every minute (`* * * * *`), this effectively caps single-file size.

Mount `/var/log/nginx` as a named volume to persist both the logs and the rotation state file (`/var/log/nginx/.logrotate-state`) across container restarts — otherwise rotation timing resets on every restart.

To disable entirely, set `LOGROTATE_ENABLED=false`.

## Nginx Configuration

### Load the Module

Add to the top of `nginx.conf`:

```nginx
load_module /usr/lib/nginx/modules/ngx_http_geoip2_module.so;
```

### GeoIP2 Country Filtering

```nginx
http {
    geoip2 /usr/share/GeoIP/GeoLite2-Country.mmdb {
        auto_reload 60m;
        $geoip2_data_country_code country iso_code;
        $geoip2_data_country_name country names en;
    }

    map $geoip2_data_country_code $allowed_country {
        default no;
        CH yes;  # Switzerland
        DE yes;  # Germany
        AT yes;  # Austria
    }

    server {
        listen 80;

        if ($allowed_country = no) {
            return 403;
        }

        location / {
            # ...
        }
    }
}
```

## UptimeRobot IP List

The image keeps an auto-updated nginx `geo` block of UptimeRobot monitoring IPs at `/etc/nginx/uptimerobot/uptimerobot.map.conf`. supercronic runs `/usr/local/bin/update-uptimerobot.sh` daily (default `15 4 * * *`) which fetches the official list from `https://uptimerobot.com/inc/files/ips/IPv4andIPv6.txt`, validates each line as IPv4/IPv6/CIDR, and re-renders the file. nginx is sent `nginx -s reload` only when the rendered content changed (sha256 diff).

The shipped baseline contains only `default 0;` — `$is_uptimerobot` resolves to 0 for everyone until the first successful fetch replaces it. This means the container always starts, even on a cold volume with no network (fail-open in the boot sense, matches-nobody in the access-control sense).

To use it, include the file from your `http {}` block and refer to `$is_uptimerobot` in your vhosts:

```nginx
http {
    include /etc/nginx/uptimerobot/uptimerobot.map.conf;

    server {
        # ...
        set $is_allowed 0;
        if ($is_uptimerobot = 1) { set $is_allowed 1; }
        if ($is_allowed = 0) { return 403; }
    }
}
```

To disable entirely, set `UPTIMEROBOT_ENABLED=false`. In that case nothing fetches the list, and the file stays at the baseline (so `if ($is_uptimerobot = 1)` is always false). To pin the list yourself, set `UPTIMEROBOT_ENABLED=false` and bind-mount your own `uptimerobot.map.conf` into `/etc/nginx/uptimerobot/`.

Persist `/etc/nginx/uptimerobot` as a named volume if you want the latest fetched list to survive container restarts (otherwise a fresh container starts from the in-image baseline and re-fetches on first boot).

## Troubleshooting

Common symptoms and where to look:

### Container exits immediately

| Log line | Cause | Fix |
|---|---|---|
| `[Entrypoint] ERROR: MAXMIND_LICENSE_KEY environment variable is required` | env var missing | set `MAXMIND_LICENSE_KEY` to your MaxMind license key |
| `[Entrypoint] ERROR: Invalid crontab — supercronic -test failed` | `GEOIP_UPDATE_CRON` or `LOGROTATE_CRON` is not a valid cron expression | check the rendered crontab dumped after the error and fix the expression |
| `open() "/run/nginx.pid" failed (13: Permission denied)` | container running an old image without the pid-path fix | upgrade to `≥ v1.30.0-2` |

### Logs not rotating

| Observation | Cause | Note |
|---|---|---|
| `.log.1` created but never becomes `.log.2.gz` | live `.log` is empty (no traffic to this vhost), `notifempty` skips rotation, archive doesn't advance | use `LOGROTATE_MAXAGE` (default 30 days) to clean these up by mtime |
| First day after deploy: file appears in state but `.log.1` not created | logrotate's documented first-encounter behaviour — defers initial rotation by one cycle | wait one cycle, or pre-populate the state file (tests do this) |
| `access.log` / `error.log` skipped with "is symbolic link" warning | the base image's defaults are symlinks to `/dev/stdout`/`/dev/stderr` | this is intentional; logrotate refuses symlinks for security |
| Rotation seems to not fire at all | check `LOGROTATE_ENABLED=true` and look for `[Entrypoint] Starting log rotation scheduler` in container logs | `LOGROTATE_ENABLED=false` will log `Log rotation disabled` instead |

### Healthcheck stuck

The default `HEALTHCHECK` does `curl -f http://localhost:8080/` and expects 200. The image's default `nginx.conf` serves the welcome page on `/`. If you mount a custom config that does not return 200 on `/` (e.g. strict geo-filtering with no public fallback), the healthcheck will go `unhealthy`. Either provide a public `/healthz` location returning 200 always, or override `HEALTHCHECK` in your compose file.

### What's in this image?

```
docker exec <container> env | grep NGINX_GEOIP
docker inspect <image> --format '{{json .Config.Labels}}' | jq
```

Both surface the Git SHA (`NGINX_GEOIP_REVISION`) and build timestamp.

## Building Locally

```bash
make build                        # build the mainline branch (default)
make build BRANCH=stable          # build the stable branch
make test                         # build + integration, logrotate, uptimerobot and geoip tests
make test BRANCH=stable           # the same for stable
make test-integration             # 16 tests against nginx/GeoIP/vhosts (docker compose)
make test-logrotate               # 30 tests for the log rotation pipeline
make test-uptimerobot             # 14 tests for the UptimeRobot IP-list updater
make test-geoip                   # 8 tests for the GeoIP database updater
make coverage                     # line coverage of scripts/, report in build/
make contract                     # every README variable appears in a test
make lint                         # shellcheck + branch versions + contract + hadolint
make scan                         # build + trivy vulnerability scan
```

The versions of both branches live in `nginx-branches.env`. `make build` passes them to the
Dockerfile as `NGINX_IMAGE` and `GEOIP2_MODULE`.

## GeoIP Database

### Getting MaxMind License Key

1. Register at [MaxMind](https://www.maxmind.com/en/geolite2/signup)
2. Go to Account > Manage License Keys
3. Generate a new license key

## nginx Branches

The image is built for both nginx branches, as the official nginx image is:

| Branch | nginx | Tags |
|---|---|---|
| mainline | odd minor version, for example 1.31.6 | `<nginx>-<n>`, `<nginx>`, `mainline`, `latest` |
| stable | even minor version, for example 1.30.5 | `<nginx>-<n>`, `<nginx>`, `stable` |

`nginx-branches.env` holds the nginx base image and the GeoIP2 module build of each branch. Both
are pinned by the digest of their multi-arch index, for example
`nginx:1.31.6-trixie@sha256:<digest>`. The nginx version comes from the image tag. The Dockerfile
ARG defaults `NGINX_IMAGE` and `GEOIP2_MODULE` are the mainline values.

Renovate keeps both current, one PR per branch. It proposes a new nginx image tag, a new digest
when Docker Hub rebuilds the image under the same tag, and a new module build. A stable update
never moves to a mainline version, and the other way round.

A module loads only into the nginx version it was built for. `.github/scripts/branch-versions.sh`
checks that the image and the module of a branch hold the same nginx version, and the lint job
runs it for both branches. A new nginx version often arrives before the module for it. Its PR
stays red until `intechcore/ngx_http_geoip2_module` publishes the module and Renovate adds it to
the same PR.

## Releasing New Versions

Releases are automatic, see [Automatic Releases](#automatic-releases). To release by hand, run
the **Release** workflow (`workflow_dispatch`) and choose the branch. It builds and tests
the image on amd64 and arm64, each on its own job, pushes exactly the tested images, and joins
them into one multi-arch image with the tags of that branch. `<n>` counts the
builds for one nginx version. The GitHub release of a mainline build is marked as latest.

The release notes are written for people, not copied from the git log. They start with the
rebuild reason or the nginx update, then the `CHANGELOG.md` entries added since the previous
release of the branch. A table lists nginx, the base image and the GeoIP2 module with their
digests. The commits follow in a collapsed block. `.github/scripts/release-notes.sh` writes them.

Push to `main` and pull requests only build and test both branches, without pushing to the
registry.

### Verify an image

Each release carries signed attestations. The build provenance proves which workflow of this
repository built the image, and from which commit:

```sh
gh attestation verify oci://ghcr.io/intechcore/nginx-geoip2:1.31.6-3 --owner intechcore
```

The SBOM (SPDX) lists the packages in the image. It belongs to the image of one platform, so
check it on the digest of that platform, from `docker buildx imagetools inspect`:

```sh
docker buildx imagetools inspect ghcr.io/intechcore/nginx-geoip2:1.31.6-3
gh attestation verify oci://ghcr.io/intechcore/nginx-geoip2@sha256:<platform digest> \
  --owner intechcore --predicate-type https://spdx.dev/Document/v2.3
```

### Automatic Releases

Every input change on `main` releases by itself. Docker Hub rebuilds `nginx:<version>-trixie` under the same tag, for example for Debian security fixes. Renovate then updates the pinned digest in `nginx-branches.env`, and CI tests the new base. A new nginx version or module build arrives the same way.

The `Rebuild` workflow checks the published image of each branch. It runs every Monday at 05:00 UTC, and on each push to `main` that changes `Dockerfile`, `nginx-branches.env` or `scripts/`. It releases the next build (`1.31.6-1` → `1.31.6-2`, the first build of a new nginx version gets `-1`) in these cases:

- `nginx-branches.env` pins a newer nginx than the image with the branch tag. A merged Renovate update of the nginx version releases without a manual step.
- The base image digest pinned in `nginx-branches.env` differs from the `org.opencontainers.image.base.digest` label of the published image. Renovate updated the digest.
- Trivy finds fixable CRITICAL or HIGH vulnerabilities in the published image.
- The GeoIP2 module in `nginx-branches.env` differs from the `io.intechcore.geoip2-module` label of the published image. Renovate bumped the module build, for example with a fix.
- `Dockerfile` or a file in `scripts/` changed since the commit in the `org.opencontainers.image.revision` label of the published image. The ARG defaults of the Dockerfile repeat the mainline pins and do not count.

It never releases an nginx version lower than the one of the branch tag. A branch without any image does not start by itself: run the Release workflow by hand for its first build.

One check and release per branch runs at a time. A check that waits compares with the image the previous run released, so a burst of pushes never publishes the same change twice.

A rebuild runs without the layer cache, so `apt-get upgrade` picks up current packages. The release notes state the reason, with the CVE, package and fixed version of each Trivy finding.

## Testing

Tests verify image structure and end-to-end functionality (run automatically in CI):

```bash
make test    # build + run all tests (requires: docker compose, curl)
```

Checks image structure (GeoIP2 module, healthcheck), then starts nginx with a Python echo backend and verifies: HTTPS redirect, security headers, reverse proxy, rate limiting, security blocking, per-vhost access control, and large body uploads.

### Test coverage

```bash
make coverage                     # mainline; BRANCH=stable for the other branch
```

`make coverage` builds the `coverage` target of the Dockerfile and runs the four suites against it. In that image each script records a bash trace to `/cov`. `tests/coverage.sh` turns the traces into kcov reports and merges them. The results are in `build/`: `coverage.txt` (lines per script), `coverage.xml` (SonarQube format) and `kcov/index.html`. CI runs it for mainline and sends the report to SonarCloud. The published image is the default target and has no coverage code.

No test reaches an external service. Every container the suites start puts `tests/fake-bin/curl` first on `PATH`, a test double that answers with a fixture or an HTTP error, and uses a dummy license key. By default it answers 401, as MaxMind does for an invalid key. Local URLs (`file://`, `localhost`) go to the real curl.

`tests/contract.sh` checks that every variable in the Environment Variables table appears in a test suite. The `lint` job runs it.

## Architecture

- **Multi-arch:** `linux/amd64`, `linux/arm64`
- **Base image:** `nginx:<version>-trixie` (Debian), mainline and stable, pinned by the digest of its multi-arch index
- **Module:** [intechcore/ngx_http_geoip2_module](https://github.com/intechcore/ngx_http_geoip2_module), a maintained fork of [leev/ngx_http_geoip2_module](https://github.com/leev/ngx_http_geoip2_module) with the `auto_reload` fixes. The image copies the prebuilt module from `ghcr.io/intechcore/ngx_http_geoip2_module:<nginx>-<n>`, pinned by the digest of its multi-arch index.
- **Auto-update:** Downloads GeoIP database on startup and refreshes daily
- **Log rotation:** `logrotate` triggered by [supercronic](https://github.com/aptible/supercronic) on a configurable cron schedule
- **Logging:** All output (entrypoint, nginx, GeoIP updater, supercronic) has unified `YYYY-MM-DD HH:MM:SS [source]` timestamps via named pipe filter

## Disclaimer

This image is provided "as is", without warranty of any kind, as the [LICENSE](LICENSE) states.
Use it at your own risk. Intechcore GmbH is not liable for damage from its use, as far as the law
allows. It is published free of charge, outside of any commercial offering, with no obligation to
support it. Security reports are welcome, see [SECURITY.md](SECURITY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities privately, see [SECURITY.md](SECURITY.md).

## License

MIT
