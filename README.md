# nginx-geoip

Nginx Docker image with GeoIP2 module for country-based access control. Automatically downloads and updates the MaxMind GeoLite2-Country database.

## Quick Start

```yaml
# docker-compose.yml
services:
  nginx:
    # renovate: image=ghcr.io/intechcore/nginx-geoip
    image: ghcr.io/intechcore/nginx-geoip:1.31.6-2
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

Nginx error log timestamps are replaced with the unified format. For access logs, use a custom `log_format` without timestamp (the entrypoint filter adds it):

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
make test                         # build + integration tests + logrotate tests + uptimerobot tests
make test BRANCH=stable           # the same for stable
make test-integration             # 16 tests against nginx/GeoIP/vhosts (docker compose)
make test-logrotate               # 24 tests for the log rotation pipeline
make test-uptimerobot             #  8 tests for the UptimeRobot IP-list updater
make lint                         # shellcheck + hadolint
make scan                         # build + trivy vulnerability scan
```

The versions of both branches live in `nginx-branches.env`. `make build` passes them to the
Dockerfile as `NGINX_VERSION` and `GEOIP2_MODULE`.

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

`nginx-branches.env` holds the nginx version and the GeoIP2 module build of each branch.
Renovate keeps both current, one PR per branch. The nginx version follows the tags of the
module image, so a new nginx version arrives only when a module for it exists. A stable update
never moves to a mainline version, and the other way round.

## Releasing New Versions

Run the **Release** workflow (`workflow_dispatch`) and choose the branch. It builds the image,
runs all three test suites, and pushes the tags of that branch to ghcr.io. `<n>` counts the
builds for one nginx version. The GitHub release of a mainline build is marked as latest.

Push to `main` and pull requests only build and test both branches, without pushing to the
registry.

### Automatic Rebuilds

Docker Hub rebuilds `nginx:<version>-trixie` under the same tag, for example for Debian security fixes. Renovate does not see these rebuilds.

The `Rebuild` workflow checks the published image of each branch every Monday at 05:00 UTC. It releases the next revision (`1.31.6-1` → `1.31.6-2`) in three cases:

- The upstream base image digest differs from the `org.opencontainers.image.base.digest` label of the published image.
- Trivy finds fixable CRITICAL or HIGH vulnerabilities in the published image.
- The GeoIP2 module in `nginx-branches.env` differs from the `io.intechcore.geoip2-module` label of the published image. Renovate bumped the module build, for example with a fix.

A rebuild runs without the layer cache, so `apt-get upgrade` picks up current packages. The release notes state the reason. A new nginx version that is not released yet is skipped, release it by hand.

## Testing

Tests verify image structure and end-to-end functionality (run automatically in CI):

```bash
make test    # build + run all tests (requires: docker compose, curl)
```

Checks image structure (GeoIP2 module, healthcheck), then starts nginx with a Python echo backend and verifies: HTTPS redirect, security headers, reverse proxy, rate limiting, security blocking, per-vhost access control, and large body uploads.

## Architecture

- **Multi-arch:** `linux/amd64`, `linux/arm64`
- **Base image:** `nginx:<version>-trixie` (Debian), mainline and stable
- **Module:** [intechcore/ngx_http_geoip2_module](https://github.com/intechcore/ngx_http_geoip2_module), a maintained fork of [leev/ngx_http_geoip2_module](https://github.com/leev/ngx_http_geoip2_module) with the `auto_reload` fixes. The image copies the prebuilt module from `ghcr.io/intechcore/ngx_http_geoip2_module:<nginx>-<n>`, pinned by the digest of its multi-arch index.
- **Auto-update:** Downloads GeoIP database on startup and refreshes daily
- **Log rotation:** `logrotate` triggered by [supercronic](https://github.com/aptible/supercronic) on a configurable cron schedule
- **Logging:** All output (entrypoint, nginx, GeoIP updater, supercronic) has unified `YYYY-MM-DD HH:MM:SS [source]` timestamps via named pipe filter

## License

MIT
