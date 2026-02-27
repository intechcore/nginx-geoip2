# Migration: switch to non-root (nginx-unprivileged)

## What changed in the image

| Parameter | Before | After |
|-----------|--------|-------|
| Base image | `nginx:VERSION` | `nginxinc/nginx-unprivileged:VERSION` |
| User | `root` (UID 0) | `nginx` (UID 101) |
| HTTP port inside container | 80 | **8080** |
| PID file | `/var/run/nginx.pid` | `/tmp/nginx.pid` |
| Temp directories | `/var/cache/nginx/*` | `/tmp/*_temp` (proxy, client, fastcgi, uwsgi, scgi) |

Scripts `entrypoint.sh` and `update-geoip.sh` are unchanged. The FIFO pipe already used `/tmp`, and the GeoIP directory is now `chown nginx:nginx` in the Dockerfile.

---

## Migration checklist

### 1. `nginx.conf`

**Remove** the `user` directive:

```diff
- user  nginx;
  worker_processes  auto;
```

> nginx-unprivileged already runs as `nginx` (UID 101) — the `user` directive is unnecessary and will produce a warning (switching to same user) or a fatal error (switching to root).

**Change** the PID file path:

```diff
- pid  /var/run/nginx.pid;
+ pid  /tmp/nginx.pid;
```

> `/var/run/` is not writable by UID 101.

### 2. Ports: `listen` directives

An unprivileged user cannot bind to ports below 1024.

**HTTP** (all `server` blocks with `listen 80`):

```diff
- listen  80;
+ listen  8080;
```

```diff
- listen  80 default_server;
+ listen  8080 default_server;
```

**HTTPS** (all `server` blocks with `listen 443`):

```diff
- listen  443 ssl;
+ listen  8443 ssl;
```

```diff
- listen  443 ssl http2;
+ listen  8443 ssl http2;
```

### 3. SSL certificates

If certificates are mounted into `/etc/nginx/certs/` or another root-only directory, move them to a location writable by UID 101:

```diff
- ssl_certificate      /etc/nginx/certs/example.pem;
- ssl_certificate_key  /etc/nginx/certs/example.key;
+ ssl_certificate      /tmp/certs/example.pem;
+ ssl_certificate_key  /tmp/certs/example.key;
```

**Or** mount certificates read-only:

```yaml
volumes:
  - ./certs:/etc/nginx/certs:ro
```

With `:ro` the `/etc/nginx/certs/` path **works fine** — nginx only reads the files. Changing paths is only required if volumes are mounted read-write and need write access (e.g., certbot renewal).

### 4. Docker Compose: port mapping

```diff
  ports:
-   - "80:80"
-   - "443:443"
+   - "80:8080"
+   - "443:8443"
```

External ports stay the same (80, 443) — only the internal container port changes.

### 5. Healthcheck

If the healthcheck runs from outside the container — no changes needed (external ports unchanged). If it runs inside the container:

```diff
- curl -f http://localhost/
+ curl -f http://localhost:8080/
```

The Dockerfile HEALTHCHECK is already updated in the new image.

### 6. Temp directories (if overridden)

Nginx-unprivileged defaults to `/tmp/*_temp` instead of `/var/cache/nginx/*`. If your configs explicitly set `proxy_temp_path`, `client_body_temp_path`, etc. — either remove them (defaults are already in `/tmp`) or update:

```diff
- proxy_temp_path       /var/cache/nginx/proxy_temp;
- client_body_temp_path /var/cache/nginx/client_temp;
+ proxy_temp_path       /tmp/proxy_temp;
+ client_body_temp_path /tmp/client_temp;
```

### 7. Writable volume mounts

Any directories nginx writes to at runtime must be accessible by UID 101. Check:

- Cache directories (`proxy_cache_path`)
- Log directories (if not stdout/stderr)
- Upload directories

Fix with `chown 101:101` on the host, or use an init container in Kubernetes:

```yaml
initContainers:
  - name: fix-permissions
    image: busybox
    command: ["sh", "-c", "chown -R 101:101 /cache"]
    volumeMounts:
      - name: cache
        mountPath: /cache
```

---

## What does NOT change

- `scripts/entrypoint.sh` — FIFO already uses `/tmp`, no root operations
- `scripts/update-geoip.sh` — writes to `$GEOIP_DIR`, owned by `nginx` (Dockerfile)
- `MAXMIND_LICENSE_KEY`, `GEOIP_UPDATE_TIME`, `GEOIP_DIR` — env vars unchanged
- `load_module` — module path remains `/usr/lib/nginx/modules/`
- `set_real_ip_from`, `real_ip_header`, `geoip2` directives — unchanged

---

## Post-migration verification

```bash
# Container runs as unprivileged user
docker exec <container> id
# uid=101(nginx) gid=101(nginx) groups=101(nginx)

# nginx config is valid
docker exec <container> nginx -t

# HTTP responds (via external port)
curl -I http://localhost/

# GeoIP database is loaded
docker exec <container> ls -la /usr/share/GeoIP/GeoLite2-Country.mmdb
```

---

## Rollback

To revert — switch the image tag to the previous version and restore `nginx.conf`:

1. Add `user nginx;`
2. `pid /var/run/nginx.pid;`
3. `listen 80` / `listen 443 ssl`
4. Port mapping `80:80`, `443:443`
