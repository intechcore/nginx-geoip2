# nginx base image and GeoIP2 module of one nginx branch, both pinned by the
# digest of their multi-arch index. CI and the Makefile pass them from
# nginx-branches.env. The defaults are the mainline branch, so a plain docker
# build works too. The module is built and tested for one nginx version by
# https://github.com/intechcore/ngx_http_geoip2_module and loads only into that
# version, so its tag must start with the nginx version of the image.
# renovate: branch=mainline nginx
ARG NGINX_IMAGE=nginx:1.31.6-trixie@sha256:908dc23e643a1447dbfb2e189ed268bfde6a51a5bf9a34d3dd3440a24f58ccf7
# renovate: branch=mainline module
ARG GEOIP2_MODULE=ghcr.io/intechcore/ngx_http_geoip2_module:1.31.6-14@sha256:6ceeadb83309e4ec5826673614c11f4bae3d365697ccb080332fd10c0456fc0d

# The nginx version comes from the image tag:
# nginx:1.31.6-trixie@sha256:... gives 1.31.6.
ARG NGINX_TAG=${NGINX_IMAGE#*:}
ARG NGINX_VERSION=${NGINX_TAG%%-*}

FROM ${GEOIP2_MODULE} AS geoip2

# nginx image with the GeoIP2 module (non-root). The final stage at the end
# is this image unchanged.
FROM ${NGINX_IMAGE} AS image

# Fail early with a clear message when the module was built for another nginx
# version. NGINX_VERSION here is the ENV of the official nginx image.
ARG GEOIP2_MODULE
RUN case "${GEOIP2_MODULE}" in \
        *:"${NGINX_VERSION}"-*) ;; \
        *) echo "GEOIP2_MODULE ${GEOIP2_MODULE} does not match nginx ${NGINX_VERSION}" >&2; exit 1 ;; \
    esac

COPY --from=geoip2 /ngx_http_geoip2_module.so /usr/lib/nginx/modules/

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
    curl -fsSL --proto '=https' --tlsv1.2 -o /usr/local/bin/supercronic \
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
# tooling for traceability. NGINX_VERSION is declared here, so the labels
# take the version from the NGINX_IMAGE tag and not the ENV of the base image
# by chance. The base digest is the pinned one. The weekly rebuild compares it
# with nginx-branches.env to find a base image that Renovate updated.
ARG NGINX_VERSION
ARG NGINX_IMAGE
LABEL org.opencontainers.image.title="nginx-geoip2" \
      org.opencontainers.image.description="Nginx with GeoIP2 module, MaxMind auto-update, supercronic log rotation" \
      org.opencontainers.image.source="https://github.com/intechcore/nginx-geoip2" \
      org.opencontainers.image.documentation="https://github.com/intechcore/nginx-geoip2/blob/main/README.md" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="Intechcore GmbH" \
      org.opencontainers.image.version="${NGINX_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.base.name="docker.io/library/${NGINX_IMAGE%@*}" \
      org.opencontainers.image.base.digest="${NGINX_IMAGE#*@}" \
      io.intechcore.geoip2-module="${GEOIP2_MODULE}"

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

# Coverage variant, used by `make coverage` and the sonar job in CI only.
# Each script runs with bash and records its trace to a new file in /cov, see
# tests/coverage/trace-run.sh. kcov turns the traces into a report, see
# tests/coverage.sh. /bin/sh is bash here, so the scripts run with the shell
# that kcov traces. The originals move to /src/scripts, their repository path.
FROM image AS coverage
USER 0
# DL4005: /bin/sh must be bash for the scripts at run time, not for RUN.
# hadolint ignore=DL3008,DL4005
RUN apt-get update && \
    apt-get install -y --no-install-recommends bash kcov && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf bash /bin/sh
COPY scripts/*.sh /src/scripts/
COPY tests/coverage/trace-run.sh tests/coverage/trace-env.sh tests/coverage/trace-replay.sh /usr/local/lib/nginx-geoip/
RUN for script in docker-entrypoint-geoip.sh update-geoip.sh geoip-cron.sh \
            update-uptimerobot.sh uptimerobot-cron.sh logrotate-cron.sh; do \
        ln -sf /usr/local/lib/nginx-geoip/trace-run.sh "/usr/local/bin/$script"; \
    done && \
    mkdir /cov && \
    chown 101:101 /cov
USER 101:101

# The published image: the default target of a build.
FROM image
