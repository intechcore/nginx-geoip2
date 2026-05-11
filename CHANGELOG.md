# Changelog

All notable changes to this image are recorded here. The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Image tags follow `vNGINX_VERSION-REVISION`. `REVISION` increments on image-level changes (entrypoint, dependencies, hardening, tests). `NGINX_VERSION` follows upstream `nginx:<version>-trixie` releases.

## [Unreleased]

### Added
- `LOGROTATE_MAXAGE` env var (default `30`) — deletes rotated archives older than N days by mtime, independent of `LOGROTATE_KEEP`. Closes the corner case where a vhost stops receiving traffic and `notifempty` prevents the existing `.log.1` from ever advancing to `.log.2.gz`.
- `LOGROTATE_MAXSIZE` env var (default unset) — rotates a matching file at the next cron fire if it exceeds the given size, even before the configured frequency elapses. Safety net against traffic spikes between cron fires.
- OCI image labels (`org.opencontainers.image.{title,description,source,documentation,licenses,version,revision,created}`) populated from build args.
- Runtime env vars `NGINX_GEOIP_REVISION` (Git SHA) and `NGINX_GEOIP_BUILD_DATE` for runtime version identification via `docker exec X env`.
- `STOPSIGNAL SIGQUIT` — `docker stop` now performs a graceful nginx shutdown (drain connections), not a fast SIGTERM shutdown.
- SHA-256 verification of the `supercronic` binary download, per architecture, fails the build if upstream artefacts ever change.
- 24-test logrotate suite covering structural checks, template rendering, supercronic & logrotate validation, end-to-end live rotation, container lifecycle (healthcheck, graceful shutdown, state persistence), env-var contracts (`MAXMIND_LICENSE_KEY` required, `GEOIP_UPDATE_TIME` validated), image size threshold, multi-cycle rotation with gzip verification, and `nginx -s reload` correctness.
- Multi-arch CI matrix: `Build and Test` now runs for both `linux/amd64` (native) and `linux/arm64` (QEMU emulation) on every push and PR.

### Changed
- `USER nginx` → `USER 101:101` to lock numeric identity against upstream user-id drift.
- Integration test fixture (`tests/integration/fixtures/nginx.conf`) trusts `X-Test-IP` from any source, making the suite portable across Docker networking models (Docker Desktop on macOS forwards traffic such that nginx sees the host's public IP). Tests that need "private network" semantics now send `X-Test-IP: 10.0.0.5` explicitly. CI on Linux still sees identical results.
- Renovate `customManagers` extended: `git tag` example in README/CLAUDE is now auto-bumped on nginx version updates; `CLAUDE.md` added to managed file patterns.
- Release-example sections in README and CLAUDE collapsed to a single canonical line so the version string can't drift across multiple occurrences.

### Fixed
- Dockerfile sed for the pid path now matches the nginx-trixie default `/run/nginx.pid` (previously only matched the older `/var/run/nginx.pid`). Without this fix, any container running with the baked-in `nginx.conf` (no user-mounted override) died with `open() "/run/nginx.pid" failed (13: Permission denied)`. Production users mounting their own config did not hit this.

## [1.30.0-1] — 2026-05-10

### Added
- In-container log rotation via `supercronic` + `logrotate` + `envsubst`:
  - `supercronic` (`v0.2.45`) installed as the cron daemon — works as the unprivileged `nginx` user (vanilla cron requires root).
  - `logrotate` config rendered at entrypoint time from `scripts/logrotate.tpl` via `envsubst`, using whitelisted env vars: `LOGROTATE_PATTERN`, `LOGROTATE_FREQUENCY`, `LOGROTATE_KEEP`, `LOGROTATE_COMPRESS`.
  - State file at `/var/log/nginx/.logrotate-state` (volume-persistent) so rotation timing survives container restarts.
  - Postrotate signals nginx via `nginx -s reopen` (SIGUSR1 to `/tmp/nginx.pid`). `delaycompress` defers gzip by one cycle to avoid racing nginx's still-open fd.
- Env vars (defaults shown):
  - `LOGROTATE_ENABLED=true` — master switch
  - `LOGROTATE_CRON="30 0 * * *"` — when supercronic invokes logrotate
  - `LOGROTATE_FREQUENCY=daily` — minimum interval logrotate enforces
  - `LOGROTATE_KEEP=14` — number of rotated archives retained
  - `LOGROTATE_COMPRESS=true` — gzip rotated files
  - `LOGROTATE_PATTERN="/var/log/nginx/*.log"` — glob to rotate

### Changed
- Base image bumped to `nginx:1.30.0-trixie` (was `1.29.5-trixie`).

## [1.29.5-1] — earlier

Previous baseline. See git log for changes before the logrotate feature.
