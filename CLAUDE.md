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
  entrypoint.sh                     # Custom entrypoint: GeoIP download, daily updater, FIFO log filter
  update-geoip.sh                   # Downloads GeoLite2-Country.mmdb from MaxMind
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
    test-logrotate.sh               # Structural + template render/validation tests (12 tests)
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

### GeoIP Update Scheduling
Background shell loop calculates seconds until `GEOIP_UPDATE_TIME`, sleeps, runs update, sleeps 60s to avoid double-execution. Uses `date -d` (GNU) with `date -j` (BSD) fallback.

### Log Rotation Scheduling
Triggered by [supercronic](https://github.com/aptible/supercronic) — a cron daemon designed for non-root containers (vanilla `cron` requires root and a writable `/var/spool/cron`). The entrypoint renders `/tmp/nginx-logrotate.conf` from `/usr/local/share/nginx-geoip/logrotate.tpl` via `envsubst` (whitelisted vars only), writes a one-line crontab to `/tmp/nginx-crontab` from `LOGROTATE_CRON`, and starts `supercronic -quiet` in the background. The state file `/var/log/nginx/.logrotate-state` lives in the volume so rotation timing survives container restarts. Postrotate sends `nginx -s reopen` (SIGUSR1 via `/tmp/nginx.pid`). `delaycompress` defers gzip by one cycle to avoid racing nginx's still-open fd. Both `supercronic` and `logrotate` run as the unprivileged `nginx` user — files in `/var/log/nginx` are already `chown nginx:nginx` from the Dockerfile.

`LOGROTATE_CRON` controls *when* logrotate is invoked; `LOGROTATE_FREQUENCY` (`daily`/`weekly`/`monthly`) controls the minimum interval logrotate enforces internally via the state file. Cron firing more often than frequency is a no-op; cron firing less often skips rotations.

`LOGROTATE_MAXAGE` (default `30`) deletes rotated archives older than N days by file mtime, independent of `LOGROTATE_KEEP`. This handles the corner case where an empty live `*.log` (no traffic to a vhost) makes `notifempty` skip the rotation entirely — without `maxage`, `.log.1` would never advance to `.log.2.gz` and never be cleaned up.

## Build, Test & Release

```bash
make build                        # build with default nginx version
make build NGINX_VERSION=1.29.0   # override nginx version
make test                         # build + integration tests + logrotate tests
make test-integration             # 16 tests against nginx/GeoIP/vhosts (docker compose)
make test-logrotate               # 15 tests for the log rotation pipeline
make lint                         # shellcheck + hadolint
make scan                         # build + trivy vulnerability scan

# Release: v<NGINX_VERSION>-<REVISION> tag triggers CI build + test + push to ghcr.io.
# Push to main/PRs: build + test only, no push to registry.
# renovate: nginx
git tag v1.30.0-1 && git push origin v1.30.0-1
```

## Environment Variables (runtime)

| Variable | Required | Default | Notes |
|----------|----------|---------|-------|
| `MAXMIND_LICENSE_KEY` | yes | - | Container fails without it |
| `GEOIP_UPDATE_TIME` | no | `03:00` | HH:MM format, validated at startup |
| `GEOIP_DIR` | no | `/usr/share/GeoIP` | |
| `LOGROTATE_ENABLED` | no | `true` | `false` skips supercronic entirely |
| `LOGROTATE_CRON` | no | `30 0 * * *` | Cron expression for invoking logrotate |
| `LOGROTATE_FREQUENCY` | no | `daily` | logrotate minimum interval: `daily` \| `weekly` \| `monthly` |
| `LOGROTATE_KEEP` | no | `14` | Number of rotated archives kept |
| `LOGROTATE_MAXAGE` | no | `30` | Days after which rotated archives are deleted by mtime |
| `LOGROTATE_COMPRESS` | no | `true` | Enables `compress` + `delaycompress` |
| `LOGROTATE_PATTERN` | no | `/var/log/nginx/*.log` | Glob passed to logrotate |

## Commit Messages

Use conventional commits: `feat:`, `fix:`, `chore:`.
