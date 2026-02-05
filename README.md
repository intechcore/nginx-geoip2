# nginx-geoip

Nginx Docker image with GeoIP2 module for country-based access control.

## Quick Start

### Using Pre-built Image

The image automatically downloads and updates the GeoIP database on startup:

```yaml
# docker-compose.yml
services:
  nginx:
    image: ghcr.io/intechcore/nginx-geoip:1.28.2
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

**Note:** `MAXMIND_LICENSE_KEY` is required. Container will fail to start without it.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MAXMIND_LICENSE_KEY` | - | **Required.** MaxMind license key |
| `GEOIP_UPDATE_TIME` | `03:00` | Daily update time (HH:MM format) |
| `GEOIP_DIR` | `/usr/share/GeoIP` | Directory for GeoIP database |

## Building Locally

```bash
./build.sh           # builds nginx-geoip2:1.28.2
./build.sh 1.29.0    # builds specific nginx version
```

## Nginx Configuration

### Load the Module

Add to the top of `nginx.conf`:

```nginx
load_module /usr/lib/nginx/modules/ngx_http_geoip2_module.so;
```

### GeoIP2 Configuration

```nginx
http {
    # Load GeoIP database
    geoip2 /usr/share/GeoIP/GeoLite2-Country.mmdb {
        auto_reload 60m;
        $geoip2_country_code country iso_code;
        $geoip2_country_name country names en;
    }

    # Allow only specific countries
    map $geoip2_country_code $allowed_country {
        default no;
        CH yes;  # Switzerland
        DE yes;  # Germany
        AT yes;  # Austria
    }

    server {
        listen 80;

        # Block disallowed countries
        if ($allowed_country = no) {
            return 403;
        }

        location / {
            # ...
        }
    }
}
```

### Logging Country Information

```nginx
log_format geoip '$remote_addr - $remote_user [$time_local] '
                 '"$request" $status $body_bytes_sent '
                 '"$http_referer" "$http_user_agent" '
                 'country=$geoip2_country_code';

access_log /var/log/nginx/access.log geoip;
```

## GeoIP Database

### Getting MaxMind License Key

1. Register at [MaxMind](https://www.maxmind.com/en/geolite2/signup)
2. Go to Account → Manage License Keys
3. Generate a new license key

### Manual Download

```bash
MAXMIND_LICENSE_KEY=your_key ./update_geoip_db.sh
```

## Available Tags

| Tag | Description |
|-----|-------------|
| `1.28.2` | Nginx 1.28.2 with GeoIP2 module |
| `main` | Latest build from main branch |

## Building New Version

Create a git tag matching the nginx version:

```bash
git tag v1.29.0
git push origin v1.29.0
```

GitHub Actions will automatically build and publish `ghcr.io/intechcore/nginx-geoip:1.29.0`.

## Architecture

- Multi-arch: `linux/amd64`, `linux/arm64`
- Base image: `nginx:<version>`
- Module: [ngx_http_geoip2_module](https://github.com/leev/ngx_http_geoip2_module)
- Auto-update: Downloads GeoIP database on startup and refreshes daily

## License

MIT
