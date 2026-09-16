ARG NGINX_VERSION

# Stage 1: Build GeoIP2 module
FROM debian:stable AS builder

ARG NGINX_VERSION

# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        libmaxminddb-dev \
        libpcre2-dev \
        libssl-dev \
        wget \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN wget -q "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" && \
    tar zxf "nginx-${NGINX_VERSION}.tar.gz" && \
    git clone https://github.com/leev/ngx_http_geoip2_module.git

WORKDIR /build/nginx-${NGINX_VERSION}

RUN ./configure --with-compat --add-dynamic-module=../ngx_http_geoip2_module && \
    make modules

# Stage 2: Final nginx image with GeoIP2 module (non-root)
FROM nginx:${NGINX_VERSION}-trixie

COPY --from=builder /build/nginx-${NGINX_VERSION}/objs/ngx_http_geoip2_module.so /usr/lib/nginx/modules/

# `anacron` is named on purpose. logrotate declares
# `Depends: cron | anacron | cron-daemon | systemd-sysv` and apt resolves the
# first alternative, which drags in cron, systemd, libsystemd-shared,
# libapparmor1 and adduser — about 40 MiB of init system this image never runs,
# because supercronic invokes logrotate directly. Naming anacron satisfies the
# same dependency with 3 packages instead of 9. Nothing schedules anacron here.
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        libmaxminddb0 \
        curl \
        ca-certificates \
        gettext-base \
        logrotate \
        anacron \
    && rm -rf /var/lib/apt/lists/*

# Install supercronic (cron replacement designed for non-root containers).
# Upstream publishes bare binaries — no checksum file, no build attestation —
# so there is no hash Renovate could refresh alongside the version. Instead the
# build asserts the downloaded binary runs and reports the version we asked
# for, which catches a truncated download, an error page, or a wrong asset.
# renovate: datasource=github-releases depName=aptible/supercronic
ARG SUPERCRONIC_VERSION=v0.2.49
RUN ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
        amd64|arm64) ;; \
        *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSLo /usr/local/bin/supercronic \
        "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${ARCH}" && \
    chmod 0755 /usr/local/bin/supercronic && \
    if [ "$(supercronic -version)" != "$SUPERCRONIC_VERSION" ]; then \
        echo "supercronic version mismatch: expected $SUPERCRONIC_VERSION" >&2; \
        exit 1; \
    fi

# Configure for non-root operation. Strip the `user nginx;` directive — it
# is ignored when the master process isn't root anyway and prints a noisy
# startup warning.
RUN sed -i 's|^pid .*;|pid /tmp/nginx.pid;|' /etc/nginx/nginx.conf && \
    sed -i '/^user /d' /etc/nginx/nginx.conf && \
    sed -i '/^http {/a \    proxy_temp_path /tmp/proxy_temp;\n    client_body_temp_path /tmp/client_temp;\n    fastcgi_temp_path /tmp/fastcgi_temp;\n    uwsgi_temp_path /tmp/uwsgi_temp;\n    scgi_temp_path /tmp/scgi_temp;' /etc/nginx/nginx.conf && \
    sed -i 's|listen\s*80;|listen 8080;|g' /etc/nginx/conf.d/default.conf && \
    chown -R nginx:nginx /var/cache/nginx /var/log/nginx /etc/nginx/conf.d

# Entrypoint + scripts invoked by supercronic at scheduled times.
COPY scripts/update-geoip.sh           /usr/local/bin/update-geoip.sh
COPY scripts/geoip-cron.sh             /usr/local/bin/geoip-cron.sh
COPY scripts/update-uptimerobot.sh     /usr/local/bin/update-uptimerobot.sh
COPY scripts/uptimerobot-cron.sh       /usr/local/bin/uptimerobot-cron.sh
COPY scripts/logrotate-cron.sh         /usr/local/bin/logrotate-cron.sh
COPY scripts/entrypoint.sh             /usr/local/bin/docker-entrypoint-geoip.sh
COPY scripts/logrotate.tpl             /usr/local/share/nginx-geoip/logrotate.tpl
COPY scripts/uptimerobot.map.baseline  /usr/local/share/nginx-geoip/uptimerobot.map.baseline
RUN chmod +x /usr/local/bin/update-geoip.sh \
        /usr/local/bin/geoip-cron.sh \
        /usr/local/bin/update-uptimerobot.sh \
        /usr/local/bin/uptimerobot-cron.sh \
        /usr/local/bin/logrotate-cron.sh \
        /usr/local/bin/docker-entrypoint-geoip.sh && \
    mkdir -p /usr/share/GeoIP /etc/nginx/uptimerobot && \
    chown nginx:nginx /usr/share/GeoIP /etc/nginx/uptimerobot

# Pin numeric UID:GID so the image still functions correctly if upstream
# nginx ever changes the symbolic `nginx` user (e.g. switches IDs). Existing
# bind-mounts owned by 101:101 keep working regardless of /etc/passwd shifts.
USER 101:101

# Build-time metadata passed in via --build-arg in CI (and the Makefile for
# local builds). Defaults to "unknown" so the build still succeeds without
# them being set explicitly.
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown
ENV NGINX_GEOIP_REVISION=${GIT_SHA}
ENV NGINX_GEOIP_BUILD_DATE=${BUILD_DATE}

# OCI image labels — surface in `docker inspect`, ghcr.io UI, and downstream
# tooling for traceability.
LABEL org.opencontainers.image.title="nginx-geoip" \
      org.opencontainers.image.description="Nginx with GeoIP2 module, MaxMind auto-update, supercronic log rotation" \
      org.opencontainers.image.source="https://github.com/intechcore/nginx-geoip" \
      org.opencontainers.image.documentation="https://github.com/intechcore/nginx-geoip/blob/main/README.md" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${NGINX_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}"

ENV GEOIP_DIR=/usr/share/GeoIP
ENV UPTIMEROBOT_DIR=/etc/nginx/uptimerobot

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["/bin/sh", "-c", "curl -f http://localhost:8080/ || exit 1"]

# SIGQUIT triggers a graceful shutdown in nginx (drain connections, then exit).
# Default SIGTERM does a fast shutdown that may drop in-flight requests.
STOPSIGNAL SIGQUIT

ENTRYPOINT ["/usr/local/bin/docker-entrypoint-geoip.sh"]
CMD ["nginx", "-g", "daemon off;"]
