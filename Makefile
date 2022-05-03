# Copyright 2021 The cert-manager Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

BINDIR ?= $(CURDIR)/bin
ARCH   ?= $(shell go env GOARCH)
HELM_VERSION ?= 3.4.1
IMAGE_PLATFORMS ?= linux/amd64,linux/arm64,linux/arm/v7,linux/ppc64le

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
	OS := linux
endif
ifeq ($(UNAME_S),Darwin)
	OS := darwin
endif

help:  ## display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: help build docker_build test depend verify all clean generate helm-docs

all: verify build image ## runs test, build and image build

clean: ## clean all bin data
	rm -rf ./bin

build: depend ## build cert-manager-csi-driver
	GO111MODULE=on CGO_ENABLED=0 go build -v -o ./bin/cert-manager-csi-driver ./cmd/.

verify: test ## verify codebase

test: helm-docs boilerplate ## offline test cert-manager-csi-driver
	go test -v ./pkg/...

boilerplate: ## verify boilerplate headers
	./hack/verify-boilerplate.sh

helm-docs: depend ## verify chart README.md
	./hack/verify-helm-docs.sh

# image will only build and store the image locally, targeted in OCI format.
# To actually push an image to the public repo, replace the `--output` flag and
# arguments to `--push`.
.PHONY: image
image: ## build cert-manager-csi-driver docker image targeting all supported platforms
	docker buildx build --platform=$(IMAGE_PLATFORMS) -t quay.io/jetstack/cert-manager-csi-driver:v0.2.0 --output type=oci,dest=./bin/cert-manager-csi-driver-oci .

e2e: depend ## run end to end tests
	./test/run.sh

depend: $(BINDIR) $(BINDIR)/helm $(BINDIR)/helm-docs

$(BINDIR):
	mkdir -p $(BINDIR)

$(BINDIR)/helm:
	curl -o $(BINDIR)/helm.tar.gz -LO "https://get.helm.sh/helm-v$(HELM_VERSION)-$(OS)-$(ARCH).tar.gz"
	tar -C $(BINDIR) -xzf $(BINDIR)/helm.tar.gz
	cp $(BINDIR)/$(OS)-$(ARCH)/helm $(BINDIR)/helm
	rm -r $(BINDIR)/$(OS)-$(ARCH) $(BINDIR)/helm.tar.gz

$(BINDIR)/helm-docs:
	go build -o $(BINDIR)/helm-docs github.com/norwoodj/helm-docs/cmd/helm-docs
