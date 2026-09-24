.PHONY: build test test-integration test-logrotate test-uptimerobot coverage contract lint scan clean

# Versions of both nginx branches. Build one with BRANCH=mainline|stable.
include nginx-branches.env

BRANCH ?= mainline
ifeq ($(BRANCH),stable)
NGINX_IMAGE ?= $(STABLE_NGINX_IMAGE)
GEOIP2_MODULE ?= $(STABLE_GEOIP2_MODULE)
else ifeq ($(BRANCH),mainline)
NGINX_IMAGE ?= $(MAINLINE_NGINX_IMAGE)
GEOIP2_MODULE ?= $(MAINLINE_GEOIP2_MODULE)
else
$(error BRANCH must be mainline or stable, not $(BRANCH))
endif
# The nginx version from the image tag: nginx:1.31.6-trixie@sha256:... gives 1.31.6.
NGINX_VERSION := $(firstword $(subst -, ,$(patsubst nginx:%,%,$(NGINX_IMAGE))))

IMAGE_NAME    ?= nginx-geoip2
IMAGE_TAG     ?= $(NGINX_VERSION)

# Local lint and scan tools, pinned by digest. Renovate keeps them current.
# renovate: datasource=docker depName=hadolint/hadolint
HADOLINT_IMAGE   ?= hadolint/hadolint:v2.15.1@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d
# renovate: datasource=docker depName=aquasec/trivy
TRIVY_IMAGE      ?= aquasec/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969

build:
	docker build \
		--build-arg NGINX_IMAGE=$(NGINX_IMAGE) \
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

# Line coverage of the scripts: build/coverage.txt, build/coverage.xml and
# the HTML report in build/kcov.
coverage:
	docker build --target coverage \
		--build-arg NGINX_IMAGE=$(NGINX_IMAGE) \
		--build-arg GEOIP2_MODULE=$(GEOIP2_MODULE) \
		-t $(IMAGE_NAME):coverage .
	./tests/coverage.sh $(IMAGE_NAME):coverage build

contract:
	./tests/contract.sh

lint:
	shellcheck scripts/*.sh tests/*.sh tests/*/*.sh update_geoip_db.sh .github/scripts/*.sh
	.github/scripts/branch-versions.sh mainline
	.github/scripts/branch-versions.sh stable
	./tests/contract.sh
	docker run --rm -i $(HADOLINT_IMAGE) < Dockerfile

scan: build
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock $(TRIVY_IMAGE) image --severity CRITICAL,HIGH --ignore-unfixed $(IMAGE_NAME):$(IMAGE_TAG)

clean:
	docker rmi $(IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || true
