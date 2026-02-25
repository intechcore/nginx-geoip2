ARG NGINX_VERSION=1.29.5

# Stage 1: Build GeoIP2 module
FROM debian:stable AS builder

ARG NGINX_VERSION

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y \
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

RUN wget http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz && \
    tar zxvf nginx-${NGINX_VERSION}.tar.gz

RUN git clone https://github.com/leev/ngx_http_geoip2_module.git

WORKDIR /build/nginx-${NGINX_VERSION}

RUN ./configure --with-compat --add-dynamic-module=../ngx_http_geoip2_module && \
    make modules

# Stage 2: Final nginx image with GeoIP2 module
FROM nginx:${NGINX_VERSION}

COPY --from=builder /build/nginx-${NGINX_VERSION}/objs/ngx_http_geoip2_module.so /usr/lib/nginx/modules/

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libmaxminddb0 \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Add GeoIP update scripts
COPY scripts/update-geoip.sh /usr/local/bin/update-geoip.sh
COPY scripts/entrypoint.sh /usr/local/bin/docker-entrypoint-geoip.sh
RUN chmod +x /usr/local/bin/update-geoip.sh /usr/local/bin/docker-entrypoint-geoip.sh

# Create GeoIP directory
RUN mkdir -p /usr/share/GeoIP

ENV GEOIP_DIR=/usr/share/GeoIP
ENV GEOIP_UPDATE_TIME=03:00

ENTRYPOINT ["/usr/local/bin/docker-entrypoint-geoip.sh"]
CMD ["nginx", "-g", "daemon off;"]
