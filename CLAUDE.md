# CLAUDE.md — nginx-geoip

## Project

Nginx Docker image with dynamically compiled GeoIP2 module and automatic MaxMind database updates.

**Registry:** `ghcr.io/intechcore/nginx-geoip`
**GitHub:** `git@github.com:intechcore/nginx-geoip.git`

## File Structure

```
Dockerfile                          # Multi-stage: build GeoIP2 module → final nginx image
Makefile                            # Local dev: make build, test, lint, scan, clean
scripts/
  entrypoint.sh                     # Custom entrypoint: env contracts, initial GeoIP/UptimeRobot fetch, build crontab, start supercronic, FIFO log filter
  update-geoip.sh                   # Downloads GeoLite2-Country.mmdb from MaxMind
  geoip-cron.sh                     # supercronic wrapper around update-geoip.sh with [GeoIP] log prefix
  update-uptimerobot.sh             # Fetches UptimeRobot IP list, renders geo $is_uptimerobot block, reloads nginx on diff
  uptimerobot-cron.sh               # supercronic wrapper around update-uptimerobot.sh with [UptimeRobot] log prefix
  uptimerobot.map.baseline          # Shipped baseline geo block (default 0; only) — installed on cold volume
  logrotate-cron.sh                 # supercronic wrapper around logrotate with [LogRotate] log prefix
  logrotate.tpl                     # envsubst template for /etc/logrotate.d/nginx
tests/integration/
    docker-compose.yml              # Two containers: nginx + Python echo backend
    test-integration.sh             # Structural + integration tests (16 tests)
    fixtures/                       # Anonymized nginx configs for testing
      nginx.conf                    # Main config with GeoIP2 module + set_real_ip_from
      GeoLite2-Country-Test.mmdb    # MaxMind test DB (Apache 2.0), 18 KB
      backend/server.py             # Python echo backend for reverse proxy verification
      conf.d/                       # Rate limits, redirect, maps, includes, vhosts
tests/logrotate/
    test-logrotate.sh               # Structural, render, live-container, reliability tests (24 tests)
tests/uptimerobot/
    test-uptimerobot.sh             # Structural + render + idempotency + fail-open tests (8 tests)
    fixtures/                       # Test IP lists (good, alternate, garbage) served via file://
.github/workflows/
  docker-publish.yml                # CI: build + test (+ push on v* tags only)
  lint.yml                          # CI: shellcheck + hadolint
  security.yml                      # CI: Trivy image vulnerability scan
  release.yml                       # CI: GitHub Release on v* tag push
```

## Key Architecture Decisions

### Non-root Container
Base image is `nginxinc/nginx-unprivileged` — runs as UID 101 (`nginx`). Listens on port 8080 (HTTP) instead of 80. The Dockerfile switches to `USER root` for `apt-get` and module installation, then back to `USER nginx`. The GeoIP directory is `chown`ed to `nginx:nginx` so the entrypoint can download databases.

### Logging via Named Pipe (FIFO)
All nginx output (stdout/stderr) is redirected through a named pipe (`/tmp/nginx-log-pipe`). A background reader adds unified timestamps and reformats lines:
- nginx error_log: original timestamp stripped, replaced with ours
- `/docker-entrypoint.sh:` and `NN-*.sh:` prefixes: replaced with `[nginx]`
- Everything else: timestamp prepended as-is

nginx remains PID 1 via `exec` (proper signal handling). The GeoIP updater writes to original stdout (before FIFO redirect), so its messages bypass the filter but already have timestamps from `log_updater()`.

### Periodic Job Scheduling
All periodic jobs (GeoIP database refresh, UptimeRobot IP-list refresh, log rotation) are driven by a single [supercronic](https://github.com/aptible/supercronic) instance — a cron daemon designed for non-root containers (vanilla `cron` requires root and a writable `/var/spool/cron`). The entrypoint builds a combined crontab at `/tmp/nginx-crontab` with up to three entries:

```
$GEOIP_UPDATE_CRON       /usr/local/bin/geoip-cron.sh
$UPTIMEROBOT_UPDATE_CRON /usr/local/bin/uptimerobot-cron.sh  (omitted if UPTIMEROBOT_ENABLED=false)
$LOGROTATE_CRON          /usr/local/bin/logrotate-cron.sh    (omitted if LOGROTATE_ENABLED=false)
```

Each job is invoked through a thin shell wrapper (`scripts/geoip-cron.sh`, `scripts/uptimerobot-cron.sh`, `scripts/logrotate-cron.sh`) that emits timestamped `[GeoIP] …`, `[UptimeRobot] …`, or `[LogRotate] …` lines around the actual command. supercronic runs with `-quiet -passthrough-logs` so its own JSON-ish job metadata stays out of the container logs and only the wrapper output appears.

The logrotate config is rendered at startup from `/usr/local/share/nginx-geoip/logrotate.tpl` via `envsubst` (whitelisted vars only). The state file `/var/log/nginx/.logrotate-state` lives in the volume so rotation timing survives container restarts. Postrotate sends `nginx -s reopen` (SIGUSR1 via `/tmp/nginx.pid`). `delaycompress` defers gzip by one cycle to avoid racing nginx's still-open fd. supercronic, both wrapper scripts, and logrotate all run as the unprivileged `nginx` user — files in `/var/log/nginx` are already `chown nginx:nginx` from the Dockerfile.

Generated crontab is validated with `supercronic -test` before launching the daemon — an invalid cron expression in `GEOIP_UPDATE_CRON`, `UPTIMEROBOT_UPDATE_CRON`, or `LOGROTATE_CRON` fails the container start with `[Entrypoint] ERROR: Invalid crontab` rather than leaving us with a healthy-looking container whose background scheduler crashed silently.

### UptimeRobot IP-List Updater
`scripts/update-uptimerobot.sh` fetches the official IP list from `UPTIMEROBOT_URL` (default `https://uptimerobot.com/inc/files/ips/IPv4andIPv6.txt`), validates each non-comment line as IPv4/IPv6/CIDR, and renders an nginx `geo $is_uptimerobot { default 0; <ip> 1; … }` block into `$UPTIMEROBOT_DIR/uptimerobot.map.conf`. The downstream nginx config is expected to `include` this file from its `http {}` block. Reload uses `kill -HUP $(cat /tmp/nginx.pid)` after `nginx -t` succeeds, and only when the rendered file's sha256 differs from the previous version — avoids reloading on every cron fire when the upstream list hasn't moved.

The variable name `$is_uptimerobot` is fixed by the baseline and by the legacy static map in `intechcore/services`. Don't rename it without coordinating both sides.

Failure policy is fail-open in the boot sense:
- Initial fetch in the entrypoint runs after the baseline is installed; failure leaves the baseline in place and the container starts normally.
- Cron-time failure leaves the previous rendered file in place. nginx keeps using the last good list until the next successful fetch.

A baseline file (`scripts/uptimerobot.map.baseline`) is shipped in the image at `/usr/local/share/nginx-geoip/uptimerobot.map.baseline` and contains only `default 0;`. The entrypoint installs it into `$UPTIMEROBOT_DIR/uptimerobot.map.conf` if no file exists yet — typically on a cold named volume. Until the first successful fetch replaces it, `$is_uptimerobot` is 0 for every client.

`LOGROTATE_CRON` controls *when* logrotate is invoked; `LOGROTATE_FREQUENCY` (`daily`/`weekly`/`monthly`) controls the minimum interval logrotate enforces internally via the state file. Cron firing more often than frequency is a no-op; cron firing less often skips rotations.

`LOGROTATE_MAXAGE` (default `30`) deletes rotated archives older than N days by file mtime, independent of `LOGROTATE_KEEP`. This handles the corner case where an empty live `*.log` (no traffic to a vhost) makes `notifempty` skip the rotation entirely — without `maxage`, `.log.1` would never advance to `.log.2.gz` and never be cleaned up.

## Build, Test & Release

```bash
make build                        # build with default nginx version
make build NGINX_VERSION=1.29.0   # override nginx version
make test                         # build + integration tests + logrotate tests + uptimerobot tests
make test-integration             # 16 tests against nginx/GeoIP/vhosts (docker compose)
make test-logrotate               # 24 tests for the log rotation pipeline
make test-uptimerobot             #  8 tests for the UptimeRobot IP-list updater
make lint                         # shellcheck + hadolint
make scan                         # build + trivy vulnerability scan

# Release: v<NGINX_VERSION>-<REVISION> tag triggers CI build + test + push to ghcr.io.
# Push to main/PRs: build + test only, no push to registry.
# renovate: nginx
git tag v1.31.2-1 && git push origin v1.30.0-1
```

## Environment Variables (runtime)

| Variable | Required | Default | Notes |
|----------|----------|---------|-------|
| `MAXMIND_LICENSE_KEY` | yes | - | Container fails without it |
| `GEOIP_UPDATE_CRON` | no | `0 3 * * *` | Cron expression for the GeoIP refresh job |
| `GEOIP_DIR` | no | `/usr/share/GeoIP` | |
| `LOGROTATE_ENABLED` | no | `true` | `false` skips supercronic entirely |
| `LOGROTATE_CRON` | no | `30 0 * * *` | Cron expression for invoking logrotate |
| `LOGROTATE_FREQUENCY` | no | `daily` | logrotate minimum interval: `daily` \| `weekly` \| `monthly` |
| `LOGROTATE_KEEP` | no | `14` | Number of rotated archives kept |
| `LOGROTATE_MAXAGE` | no | `30` | Days after which rotated archives are deleted by mtime |
| `LOGROTATE_MAXSIZE` | no | (unset) | Rotate before cron fires if file exceeds this size (e.g. `5G`). Empty disables. |
| `LOGROTATE_COMPRESS` | no | `true` | Enables `compress` + `delaycompress` |
| `LOGROTATE_PATTERN` | no | `/var/log/nginx/*.log` | Glob passed to logrotate |
| `UPTIMEROBOT_ENABLED` | no | `true` | `false` skips initial fetch and the cron entry |
| `UPTIMEROBOT_UPDATE_CRON` | no | `15 4 * * *` | Cron expression for IP-list refresh |
| `UPTIMEROBOT_DIR` | no | `/etc/nginx/uptimerobot` | Directory for rendered `uptimerobot.map.conf` |
| `UPTIMEROBOT_URL` | no | `https://uptimerobot.com/inc/files/ips/IPv4andIPv6.txt` | Source list URL |

## Commit Messages

Use conventional commits: `feat:`, `fix:`, `chore:`.
