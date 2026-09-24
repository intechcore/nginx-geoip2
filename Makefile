.PHONY: build test test-integration test-logrotate test-uptimerobot contract lint scan clean

# Versions of both nginx branches. Build one with BRANCH=mainline|stable.
include nginx-branches.env

BRANCH ?= mainline
ifeq ($(BRANCH),stable)
NGINX_VERSION ?= $(STABLE_NGINX)
GEOIP2_MODULE ?= $(STABLE_GEOIP2_MODULE)
else ifeq ($(BRANCH),mainline)
NGINX_VERSION ?= $(MAINLINE_NGINX)
GEOIP2_MODULE ?= $(MAINLINE_GEOIP2_MODULE)
else
$(error BRANCH must be mainline or stable, not $(BRANCH))
endif

IMAGE_NAME    ?= nginx-geoip2
IMAGE_TAG     ?= $(NGINX_VERSION)

build:
	docker build \
		--build-arg NGINX_VERSION=$(NGINX_VERSION) \
		--build-arg GEOIP2_MODULE=$(GEOIP2_MODULE) \
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

contract:
	./tests/contract.sh

lint:
	shellcheck scripts/*.sh tests/*.sh tests/*/*.sh update_geoip_db.sh .github/scripts/*.sh
	./tests/contract.sh
	docker run --rm -i hadolint/hadolint < Dockerfile

scan: build
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasecurity/trivy image --severity CRITICAL,HIGH --ignore-unfixed $(IMAGE_NAME):$(IMAGE_TAG)

clean:
	docker rmi $(IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || true
