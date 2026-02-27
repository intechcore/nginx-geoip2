.PHONY: build test lint scan clean

NGINX_VERSION ?= 1.29.5
IMAGE_NAME    ?= nginx-geoip2
IMAGE_TAG     ?= $(NGINX_VERSION)

build:
	docker build --build-arg NGINX_VERSION=$(NGINX_VERSION) -t $(IMAGE_NAME):$(IMAGE_TAG) .

test: build
	./tests/test-image.sh $(IMAGE_NAME):$(IMAGE_TAG)

lint:
	shellcheck scripts/*.sh tests/*.sh build.sh update_geoip_db.sh
	docker run --rm -i hadolint/hadolint < Dockerfile

scan: build
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasecurity/trivy image --severity CRITICAL,HIGH --ignore-unfixed $(IMAGE_NAME):$(IMAGE_TAG)

clean:
	docker rmi $(IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || true
