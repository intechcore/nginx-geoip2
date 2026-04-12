# nginx-geoip

Nginx Docker image with GeoIP2 module for country-based access control. Automatically downloads and updates the MaxMind GeoLite2-Country database.

## Quick Start

```yaml
# docker-compose.yml
services:
  nginx:
    # renovate: image=ghcr.io/intechcore/nginx-geoip
    image: ghcr.io/intechcore/nginx-geoip:1.29.8-1
    ports:
      - "80:80"
      - "443:443"
    environment:
      - MAXMIND_LICENSE_KEY=your_license_key  # required
      - GEOIP_UPDATE_TIME=03:00               # optional, default 03:00
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - geoip-data:/usr/share/GeoIP  # persist database across restarts

volumes:
  geoip-data:
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MAXMIND_LICENSE_KEY` | - | **Required.** MaxMind license key |
| `GEOIP_UPDATE_TIME` | `03:00` | Daily update time (HH:MM, validated on startup) |
| `GEOIP_DIR` | `/usr/share/GeoIP` | Directory for GeoIP database |

## Logging

All output uses a unified timestamp format:

```
2026-02-06 09:39:36 [Entrypoint] Downloading initial GeoIP database...
2026-02-06 09:39:36 [GeoIP] Downloading GeoLite2-Country database...
2026-02-06 09:39:37 [GeoIP] Database updated: /usr/share/GeoIP/GeoLite2-Country.mmdb (9.2 MB)
2026-02-06 09:39:37 [Entrypoint] Starting GeoIP daily updater (scheduled at 03:00)
2026-02-06 09:39:37 [Entrypoint] Handing off to nginx entrypoint
2026-02-06 09:39:37 [GeoIP Updater] Next update in 17h 20m (at 03:00)
2026-02-06 09:39:37 [nginx] Configuration complete; ready for start up
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

## Building Locally

```bash
# renovate: nginx
make build                        # builds nginx-geoip2:1.29.8
make build NGINX_VERSION=1.29.0   # builds specific nginx version
make test                         # build + run smoke tests
make lint                         # shellcheck + hadolint
make scan                         # build + trivy vulnerability scan
```

## GeoIP Database

### Getting MaxMind License Key

1. Register at [MaxMind](https://www.maxmind.com/en/geolite2/signup)
2. Go to Account > Manage License Keys
3. Generate a new license key

## Releasing New Versions

Create a git tag to trigger a build and push to registry. The tag suffix (`-N`) is the image revision, the nginx version is extracted automatically:

```bash
git tag v1.29.5-1
git push origin v1.29.5-1
# → builds, tests, and pushes ghcr.io/intechcore/nginx-geoip:1.29.5-1 with nginx 1.29.5
```

Push to `main` and PRs only run build + smoke tests without pushing to registry.

## Testing

Tests verify image structure and end-to-end functionality (run automatically in CI):

```bash
make test    # build + run all tests (requires: docker compose, curl)
```

Checks image structure (GeoIP2 module, healthcheck), then starts nginx with a Python echo backend and verifies: HTTPS redirect, security headers, reverse proxy, rate limiting, security blocking, per-vhost access control, and large body uploads.

## Architecture

- **Multi-arch:** `linux/amd64`, `linux/arm64`
- **Base image:** `nginx:<version>` (Debian)
- **Module:** [ngx_http_geoip2_module](https://github.com/leev/ngx_http_geoip2_module)
- **Auto-update:** Downloads GeoIP database on startup and refreshes daily
- **Logging:** All output (entrypoint, nginx, GeoIP updater) has unified `YYYY-MM-DD HH:MM:SS [source]` timestamps via named pipe filter

## License

MIT
