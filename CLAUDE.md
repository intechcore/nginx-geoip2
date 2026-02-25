# CLAUDE.md — nginx-geoip

## Project

Nginx Docker image with dynamically compiled GeoIP2 module and automatic MaxMind database updates.

**Registry:** `ghcr.io/intechcore/nginx-geoip`
**GitHub:** `git@github.com:intechcore/nginx-geoip.git`

## File Structure

```
Dockerfile                          # Multi-stage: build GeoIP2 module → final nginx image
build.sh                            # Local Docker build (./build.sh [NGINX_VERSION])
scripts/
  entrypoint.sh                     # Custom entrypoint: GeoIP download, daily updater, FIFO log filter
  update-geoip.sh                   # Downloads GeoLite2-Country.mmdb from MaxMind
tests/
  test-image.sh                     # Smoke tests for built Docker image
.github/workflows/
  docker-publish.yml                # CI: build + test (+ push on v* tags only)
```

## Key Architecture Decisions

### Logging via Named Pipe (FIFO)
All nginx output (stdout/stderr) is redirected through a named pipe (`/tmp/nginx-log-pipe`). A background reader adds unified timestamps and reformats lines:
- nginx error_log: original timestamp stripped, replaced with ours
- `/docker-entrypoint.sh:` and `NN-*.sh:` prefixes: replaced with `[nginx]`
- Everything else: timestamp prepended as-is

nginx remains PID 1 via `exec` (proper signal handling). The GeoIP updater writes to original stdout (before FIFO redirect), so its messages bypass the filter but already have timestamps from `log_updater()`.

### GeoIP Update Scheduling
Background shell loop calculates seconds until `GEOIP_UPDATE_TIME`, sleeps, runs update, sleeps 60s to avoid double-execution. Uses `date -d` (GNU) with `date -j` (BSD) fallback.

## Build, Test & Release

```bash
# Local build
./build.sh              # nginx 1.29.5
./build.sh 1.29.0       # specific version

# Run smoke tests
./tests/test-image.sh nginx-geoip2:1.29.5
# With GeoIP download test:
MAXMIND_LICENSE_KEY=key ./tests/test-image.sh nginx-geoip2:1.29.5

# Release: v* tag triggers CI build + test + push to ghcr.io
git tag v1.29.5-1
git push origin v1.29.5-1
# Tag suffix (-N) is image revision. Nginx version extracted as TAG minus suffix.
# Push to main/PRs: build + test only, no push to registry.
```

## Environment Variables (runtime)

| Variable | Required | Default | Notes |
|----------|----------|---------|-------|
| `MAXMIND_LICENSE_KEY` | yes | - | Container fails without it |
| `GEOIP_UPDATE_TIME` | no | `03:00` | HH:MM format, validated at startup |
| `GEOIP_DIR` | no | `/usr/share/GeoIP` | |

## Commit Messages

Use conventional commits: `feat:`, `fix:`, `chore:`.
