.PHONY: build test test-integration test-logrotate test-uptimerobot lint scan clean

# renovate: nginx
NGINX_VERSION ?= 1.31.6
IMAGE_NAME    ?= nginx-geoip2
IMAGE_TAG     ?= $(NGINX_VERSION)

build:
	docker build \
		--build-arg NGINX_VERSION=$(NGINX_VERSION) \
		--build-arg GIT_SHA=$$(git rev-parse HEAD 2>/dev/null || echo unknown) \
		--build-arg BUILD_DATE=$$(date -u +%Y-%m-%dT%H:%M:%SZ) \
		-t $(IMAGE_NAME):$(IMAGE_TAG) .

test: build test-integration test-logrotate test-uptimerobot

test-integration:
	./tests/integration/test-integration.sh $(IMAGE_NAME):$(IMAGE_TAG)

test-logrotate:
	./tests/logrotate/test-logrotate.sh $(IMAGE_NAME):$(IMAGE_TAG)

test-uptimerobot:
	./tests/uptimerobot/test-uptimerobot.sh $(IMAGE_NAME):$(IMAGE_TAG)

lint:
	shellcheck scripts/*.sh tests/integration/*.sh tests/logrotate/*.sh tests/uptimerobot/*.sh update_geoip_db.sh
	docker run --rm -i hadolint/hadolint < Dockerfile

scan: build
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasecurity/trivy image --severity CRITICAL,HIGH --ignore-unfixed $(IMAGE_NAME):$(IMAGE_TAG)

clean:
	docker rmi $(IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || true
