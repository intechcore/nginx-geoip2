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

# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        libmaxminddb0 \
        curl \
        ca-certificates \
        gettext-base \
        logrotate \
    && rm -rf /var/lib/apt/lists/*

# Install supercronic (cron replacement designed for non-root containers)
ARG SUPERCRONIC_VERSION=v0.2.45
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSLo /usr/local/bin/supercronic \
        "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${ARCH}" && \
    chmod 0755 /usr/local/bin/supercronic

# Configure for non-root operation
RUN sed -i 's|^pid .*;|pid /tmp/nginx.pid;|' /etc/nginx/nginx.conf && \
    sed -i '/^http {/a \    proxy_temp_path /tmp/proxy_temp;\n    client_body_temp_path /tmp/client_temp;\n    fastcgi_temp_path /tmp/fastcgi_temp;\n    uwsgi_temp_path /tmp/uwsgi_temp;\n    scgi_temp_path /tmp/scgi_temp;' /etc/nginx/nginx.conf && \
    sed -i 's|listen\s*80;|listen 8080;|g' /etc/nginx/conf.d/default.conf && \
    chown -R nginx:nginx /var/cache/nginx /var/log/nginx /etc/nginx/conf.d

# Add GeoIP update scripts
COPY scripts/update-geoip.sh /usr/local/bin/update-geoip.sh
COPY scripts/entrypoint.sh /usr/local/bin/docker-entrypoint-geoip.sh
COPY scripts/logrotate.tpl /usr/local/share/nginx-geoip/logrotate.tpl
RUN chmod +x /usr/local/bin/update-geoip.sh /usr/local/bin/docker-entrypoint-geoip.sh && \
    mkdir -p /usr/share/GeoIP && \
    chown nginx:nginx /usr/share/GeoIP

USER nginx

ENV GEOIP_DIR=/usr/share/GeoIP
ENV GEOIP_UPDATE_TIME=03:00

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/ || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint-geoip.sh"]
CMD ["nginx", "-g", "daemon off;"]
