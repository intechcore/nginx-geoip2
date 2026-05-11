.PHONY: build test test-integration test-logrotate lint scan clean

# renovate: nginx
NGINX_VERSION ?= 1.30.0
IMAGE_NAME    ?= nginx-geoip2
IMAGE_TAG     ?= $(NGINX_VERSION)

build:
	docker build --build-arg NGINX_VERSION=$(NGINX_VERSION) -t $(IMAGE_NAME):$(IMAGE_TAG) .

test: build test-integration test-logrotate

test-integration:
	./tests/integration/test-integration.sh $(IMAGE_NAME):$(IMAGE_TAG)

test-logrotate:
	./tests/logrotate/test-logrotate.sh $(IMAGE_NAME):$(IMAGE_TAG)

lint:
	shellcheck scripts/*.sh tests/integration/*.sh tests/logrotate/*.sh update_geoip_db.sh
	docker run --rm -i hadolint/hadolint < Dockerfile

scan: build
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasecurity/trivy image --severity CRITICAL,HIGH --ignore-unfixed $(IMAGE_NAME):$(IMAGE_TAG)

clean:
	docker rmi $(IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || true
