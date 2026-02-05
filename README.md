# nginx-geoip

Nginx Docker image with GeoIP2 module for country-based access control.

## Quick Start

### Using Pre-built Image

```yaml
# docker-compose.yml
services:
  nginx:
    image: ghcr.io/intechcore/nginx-geoip:1.28.1
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./GeoLite2-Country.mmdb:/usr/share/GeoIP/GeoLite2-Country.mmdb:ro
```

### Building Locally

```bash
./build.sh           # builds nginx-geoip2:1.28.1
./build.sh 1.29.0    # builds specific nginx version
```

## Nginx Configuration

### Load the Module

Add to the top of `nginx.conf`:

```nginx
load_module modules/ngx_http_geoip2_module.so;
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

### Download GeoLite2 Database

1. Register at [MaxMind](https://www.maxmind.com/en/geolite2/signup)
2. Generate a license key
3. Run:

```bash
MAXMIND_LICENSE_KEY=your_key ./update_geoip_db.sh
```

### Auto-update with Cron

```bash
# Weekly update
0 0 * * 0 MAXMIND_LICENSE_KEY=xxx /path/to/update_geoip_db.sh
```

## Available Tags

| Tag | Description |
|-----|-------------|
| `1.28.1` | Nginx 1.28.1 with GeoIP2 module |
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

## License

MIT
