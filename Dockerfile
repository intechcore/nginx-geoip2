ARG NGINX_VERSION=1.28.1

# Stage 1: Build GeoIP2 module
FROM debian:bullseye AS builder

ARG NGINX_VERSION

RUN apt-get update && \
    apt-get install -y \
        build-essential \
        ca-certificates \
        curl \
        git \
        libmaxminddb-dev \
        libpcre3-dev \
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
    apt-get install -y --no-install-recommends libmaxminddb0 && \
    rm -rf /var/lib/apt/lists/*

# GeoIP database will be mounted at runtime
# Example: -v /path/to/GeoLite2-Country.mmdb:/usr/share/GeoIP/GeoLite2-Country.mmdb
