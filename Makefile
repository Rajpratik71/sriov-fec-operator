# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2020-2022 Intel Corporation

# Default k8s command-line tool exec
export CLI_EXEC?=oc
# Container format for podman. Required to build containers with "ManifestType": "application/vnd.oci.image.manifest.v2+json",
export BUILDAH_FORMAT=docker
# Current Operator version
VERSION ?= 2.5.0
# Supported channels
CHANNELS ?= stable
# Default channel
DEFAULT_CHANNEL ?= stable

# Operator image registry
IMAGE_REGISTRY ?= registry.connect.redhat.com/intel
CONTAINER_TOOL ?= podman

FUZZ_TIME?=10m

# Add suffix directly to IMAGE_REGISTRY to enable empty registry(local images)
ifneq ($(and $(strip $(IMAGE_REGISTRY)), $(filter-out %/, $(IMAGE_REGISTRY))),)
override IMAGE_REGISTRY:=$(addsuffix /,$(IMAGE_REGISTRY))
endif
# tls verify flag for pushing images
TLS_VERIFY ?= false

REQUIRED_OPERATOR_SDK_VERSION ?= v1.22.2

IMAGE_TAG_BASE ?= $(IMAGE_REGISTRY)sriov-fec
BUNDLE_IMG ?= $(IMAGE_TAG_BASE)-bundle:v$(VERSION)

# Options for 'image-bundle'
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

IMG_VERSION := v$(VERSION)

OS = $(shell go env GOOS)
ARCH = $(shell go env GOARCH)

# Images URLs to use for all building/pushing image targets
export SRIOV_FEC_OPERATOR_IMAGE ?= $(IMAGE_REGISTRY)sriov-fec-operator:$(IMG_VERSION)
export SRIOV_FEC_DAEMON_IMAGE ?= $(IMAGE_REGISTRY)sriov-fec-daemon:$(IMG_VERSION)
export SRIOV_FEC_LABELER_IMAGE ?= $(IMAGE_REGISTRY)n3000-labeler:$(IMG_VERSION)

ifeq ($(CONTAINER_TOOL),podman)
 export SRIOV_FEC_NETWORK_DEVICE_PLUGIN_IMAGE ?= registry.redhat.io/openshift4/ose-sriov-network-device-plugin:v4.10 #TBD
 export KUBE_RBAC_PROXY_IMAGE ?= registry.redhat.io/openshift4/ose-kube-rbac-proxy@sha256:b5786bbbef725badf3dfcc2c2c7a86ead5ebb584c978c47aae8b9a62e241b80d
else
 export SRIOV_FEC_NETWORK_DEVICE_PLUGIN_IMAGE ?= quay.io/openshift/origin-sriov-network-device-plugin:4.11
 export KUBE_RBAC_PROXY_IMAGE ?= gcr.io/kubebuilder/kube-rbac-proxy:v0.11.0
endif

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# This is a requirement for 'setup-envtest.sh' in the test target.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: all
all: manager daemon labeler

# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.24
ENVTEST = $(shell pwd)/bin/setup-envtest
.PHONY: envtest
envtest: ## Download envtest-setup locally if necessary.
	rm -f $(ENVTEST)
	$(call go-get-tool,$(ENVTEST),sigs.k8s.io/controller-runtime/tools/setup-envtest@latest)

.PHONY: test
test: manifests generate fmt vet envtest ## Run tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) -p path)" SRIOV_FEC_NAMESPACE=default go test ./... -coverprofile cover.out


TEST_PACKAGES := $(shell find . -name "*_test.go")

.PHONY: fuzz
fuzz:
	@for pkg in ${TEST_PACKAGES} ; do            \
		for target in `grep -oh -EI 'Fuzz([A-Z][a-z]*)+' $$pkg` ; do     \
			echo "Executing $$pkg#$$target";     \
			KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) -p path)" SRIOV_FEC_NAMESPACE=default go test -fuzz=$$target $$pkg/.. -fuzztime=${FUZZ_TIME} || true; \
		done                              \
	done

# Build manager binary
.PHONY: manager
manager: generate fmt vet
	go build -race -o bin/manager main.go

#Build daemon binary
.PHONY: daemon
daemon: generate fmt vet
	go build -race -o bin/daemon cmd/daemon/main.go

#Build labeler binary
.PHONY: labeler
labeler: generate fmt vet
	go build -race -o bin/labeler cmd/labeler/main.go

# Run against the configured Kubernetes cluster in ~/.kube/config
.PHONY: run
run: generate fmt vet manifests
	go run ./main.go

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

# Install CRDs into a cluster
.PHONY: install
install: manifests kustomize
	$(KUSTOMIZE) build config/crd | $(CLI_EXEC) apply -f -

# Uninstall CRDs from a cluster
.PHONY: uninstall
uninstall: manifests kustomize
	$(KUSTOMIZE) build config/crd | $(CLI_EXEC) delete --ignore-not-found=$(ignore-not-found) -f -

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
.PHONY: deploy
deploy: manifests kustomize
	cd config/manager && $(KUSTOMIZE) edit set image sriov-fec-operator=$(SRIOV_FEC_OPERATOR_IMAGE)
	$(KUSTOMIZE) build config/default | envsubst | $(CLI_EXEC) apply -f -

# Generate manifests e.g. CRD, RBAC etc.
.PHONY: manifests
manifests: controller-gen
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases
	FOLDER=. COPYRIGHT_FILE=COPYRIGHT ./copyright.sh

# Run go fmt against code
.PHONY: fmt
fmt:
	go fmt ./...

# Run go vet against code
.PHONY: vet
vet:
	go vet ./...

# Generate code
.PHONY: generate
generate: controller-gen
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

# go-get-tool will 'go install' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))

define go-get-tool
@[ -f $(1) ] || { \
set -e ;\
TMP_DIR=$$(mktemp -d) ;\
cd $$TMP_DIR ;\
go mod init tmp ;\
echo "Installing $(2)" ;\
GOBIN=$(PROJECT_DIR)/bin go install $(2) ;\
rm -rf $$TMP_DIR ;\
}
endef

# find or download controller-gen
# download controller-gen if necessary
CONTROLLER_GEN = $(shell pwd)/bin/controller-gen
.PHONY: controller-gen
controller-gen: ## Download controller-gen locally if necessary.
	rm -f $(CONTROLLER_GEN)
	$(call go-get-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen@v0.9.2)

KUSTOMIZE = $(shell pwd)/bin/kustomize
.PHONY: kustomize
kustomize: ## Download kustomize locally if necessary.
	rm -f $(KUSTOMIZE)
	$(call go-get-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v4@v4.5.5)

# Build/Push daemon image
.PHONY: image-sriov-fec-daemon
image-sriov-fec-daemon:
	cp LICENSE TEMP_LICENSE_COPY
	$(CONTAINER_TOOL) build . -f Dockerfile.daemon -t $(SRIOV_FEC_DAEMON_IMAGE) --build-arg=VERSION=$(IMG_VERSION)
	$(CONTAINER_TOOL) tag $(SRIOV_FEC_DAEMON_IMAGE) ghcr.io/smart-edge-open/sriov-fec-daemon:$(VERSION)
	
.PHONY: push-sriov-fec-daemon
podman-push-sriov-fec-daemon:
	podman push $(SRIOV_FEC_DAEMON_IMAGE) --tls-verify=$(TLS_VERIFY)

.PHONY: docker-push-sriov-fec-daemon
docker-push-sriov-fec-daemon:
	docker push $(SRIOV_FEC_DAEMON_IMAGE)

# Build/Push labeler image
.PHONY: image-sriov-fec-labeler
image-sriov-fec-labeler:
	cp LICENSE TEMP_LICENSE_COPY
	$(CONTAINER_TOOL) build . -f Dockerfile.labeler -t ${SRIOV_FEC_LABELER_IMAGE} --build-arg=VERSION=$(IMG_VERSION)
	$(CONTAINER_TOOL) tag $(SRIOV_FEC_LABELER_IMAGE) ghcr.io/smart-edge-open/sriov-fec-labeler:$(VERSION)

.PHONY: push-sriov-fec-labeler
podman-push-sriov-fec-labeler:
	podman push ${SRIOV_FEC_LABELER_IMAGE} --tls-verify=$(TLS_VERIFY)

.PHONY: docker-push-sriov-fec-labeler
docker-push-sriov-fec-labeler:
	docker push ${SRIOV_FEC_LABELER_IMAGE}

# Build/Push operator image
.PHONY: image-sriov-fec-operator
image-sriov-fec-operator:
	cp LICENSE TEMP_LICENSE_COPY
	$(CONTAINER_TOOL) build . -t $(SRIOV_FEC_OPERATOR_IMAGE) --build-arg=VERSION=$(IMG_VERSION)
	$(CONTAINER_TOOL) tag $(SRIOV_FEC_OPERATOR_IMAGE) ghcr.io/smart-edge-open/sriov-fec-operator:$(VERSION)

.PHONY: podman-push-sriov-fec-operator
podman-push-sriov-fec-operator:
	podman push $(SRIOV_FEC_OPERATOR_IMAGE) --tls-verify=$(TLS_VERIFY)

.PHONY: docker-push-sriov-fec-operator
docker-push-sriov-fec-operator:
	docker push $(SRIOV_FEC_OPERATOR_IMAGE)

# Build all the images
.PHONY: image
image: image-sriov-fec-daemon image-sriov-fec-labeler image-sriov-fec-operator image-bundle

# Push all the images
.PHONY: push
push: $(CONTAINER_TOOL)-push-sriov-fec-daemon $(CONTAINER_TOOL)-push-sriov-fec-labeler $(CONTAINER_TOOL)-push-sriov-fec-operator $(CONTAINER_TOOL)-push-bundle

# Generate bundle manifests and metadata, then validate generated files.
.PHONY: bundle
bundle: check-operator-sdk-version manifests kustomize
	operator-sdk generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image sriov-fec-operator=$(SRIOV_FEC_OPERATOR_IMAGE)
	$(KUSTOMIZE) build config/manifests | envsubst | operator-sdk generate bundle -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	operator-sdk bundle validate ./bundle
	FOLDER=. COPYRIGHT_FILE=COPYRIGHT ./copyright.sh
	cat COPYRIGHT bundle.Dockerfile >bundle.tmp
	printf "\nLABEL com.redhat.openshift.versions=\"=v4.8-v4.10\"\n" >> bundle.tmp
	printf "\nCOPY TEMP_LICENSE_COPY /licenses/LICENSE\n" >> bundle.tmp
	mv bundle.tmp bundle.Dockerfile

# Build/Push the bundle image.
.PHONY: image-bundle
image-bundle: bundle
	cp LICENSE TEMP_LICENSE_COPY
	$(CONTAINER_TOOL) build -f bundle.Dockerfile -t $(BUNDLE_IMG) .
	$(CONTAINER_TOOL) tag $(BUNDLE_IMG) ghcr.io/smart-edge-open/sriov-fec-bundle:$(VERSION)

.PHONY: podman-push-bundle
podman-push-bundle:
	podman push $(BUNDLE_IMG) --tls-verify=$(TLS_VERIFY)
	
# push images into github container registry in smart-edge-open
.PHONY: push-sriov-fec-daemon-ghcr
push-sriov-fec-daemon-ghcr:
	$(CONTAINER_TOOL) push ghcr.io/smart-edge-open/sriov-fec-daemon:$(VERSION)  

.PHONY: push-sriov-fec-operator-ghcr
push-sriov-fec-operator-ghcr:
	$(CONTAINER_TOOL) push ghcr.io/smart-edge-open/sriov-fec-operator:$(VERSION)

.PHONY: push-sriov-fec-bundle-ghcr
push-sriov-fec-bundle-ghcr:
	$(CONTAINER_TOOL) push ghcr.io/smart-edge-open/sriov-fec-bundle:$(VERSION)

.PHONY: push-sriov-fec-labeler-ghcr
push-sriov-fec-labeler-ghcr:
	$(CONTAINER_TOOL) push ghcr.io/smart-edge-open/sriov-fec-labeler:$(VERSION)

.PHONY: push-all-ghcr
push-all-ghcr: push-sriov-fec-daemon-ghcr push-sriov-fec-operator-ghcr push-sriov-fec-bundle-ghcr push-sriov-fec-labeler-ghcr

# pull images from github container registry
.PHONY: pull-sriov-fec-daemon-ghcr
pull-sriov-fec-daemon-ghcr:
	docker pull ghcr.io/smart-edge-open/sriov-fec-daemon:$(VERSION)  

.PHONY: pull-sriov-fec-operator-ghcr
pull-sriov-fec-operator-ghcr:
	docker pull ghcr.io/smart-edge-open/sriov-fec-operator:$(VERSION)

.PHONY: pull-bundle-ghcr	
pull-bundle-ghcr:
	docker pull ghcr.io/smart-edge-open/sriov-fec-bundle:$(VERSION)

.PHONY: pull-labeler-ghcr
pull-labeler-ghcr:
	docker pull ghcr.io/smart-edge-open/sriov-fec-labeler:$(VERSION)

.PHONY: pull-all-ghcr     
pull-all-ghcr: pull-sriov-fec-daemon-ghcr pull-sriov-fec-operator-ghcr pull-bundle-ghcr pull-labeler-ghcr

.PHONY: scan-sriov-fec-daemon-image
scan-sriov-fec-daemon-image:
	snyk container test ghcr.io/smart-edge-open/sriov-fec-daemon:$(VERSION) || true
	snyk container monitor --exclude-base-image-vulns ghcr.io/smart-edge-open/sriov-fec-daemon:$(VERSION)

.PHONY: scan-sriov-fec-operator-image
scan-sriov-fec-operator-image:i
	snyk container test ghcr.io/smart-edge-open/sriov-fec-operator:$(VERSION) || true
	snyk container monitor --exclude-base-image-vulns ghcr.io/smart-edge-open/sriov-fec-operator:$(VERSION)

.PHONY: scan-sriov-fec-bundle-image
scan-sriov-fec-bundle-image:
	snyk container test ghcr.io/smart-edge-open/sriov-fec-bundle:$(VERSION) || true
	snyk container monitor --exclude-base-image-vulns ghcr.io/smart-edge-open/sriov-fec-bundle:$(VERSION)

.PHONY: scan-sriov-fec-labeler-image
scan-sriov-fec-labeler-image:
	snyk container test ghcr.io/smart-edge-open/sriov-fec-labeler:$(VERSION) || true
	snyk container monitor --exclude-base-image-vulns ghcr.io/smart-edge-open/sriov-fec-labeler:$(VERSION)

.PHONY: scan_all
scan_all: scan-sriov-fec-daemon-image scan-sriov-fec-operator-image scan-sriov-fec-bundle-image scan-sriov-fec-labeler-image

.PHONY: docker-push-bundle
docker-push-bundle:
	docker push $(BUNDLE_IMG)
.PHONY: build
build: image push

.PHONY: build_all
build_all: build
	$(MAKE) VERSION=$(VERSION) IMAGE_REGISTRY=$(IMAGE_REGISTRY) TLS_VERIFY=$(TLS_VERIFY) build_index

.PHONY: build_index
build_index:
	opm index add --bundles $(BUNDLE_IMG) --tag localhost/sriov-fec-index:$(VERSION) $(if ifeq $(TLS_VERIFY) false, --skip-tls) -c $(CONTAINER_TOOL) --mode=semver
	$(MAKE) VERSION=$(VERSION) IMAGE_REGISTRY=$(IMAGE_REGISTRY) TLS_VERIFY=$(TLS_VERIFY) $(CONTAINER_TOOL)_push_index	

.PHONY: podman_push_index
podman_push_index:
	podman push localhost/sriov-fec-index:$(VERSION) $(IMAGE_REGISTRY)sriov-fec-index:$(VERSION) --tls-verify=$(TLS_VERIFY)

.PHONY: docker_push_index
docker_push_index:
	docker tag localhost/sriov-fec-index:$(VERSION) $(IMAGE_REGISTRY)sriov-fec-index:$(VERSION)
	docker push $(IMAGE_REGISTRY)sriov-fec-index:$(VERSION)

.PHONY: install_operator_sdk
install_operator_sdk:
	curl -LO https://github.com/operator-framework/operator-sdk/releases/download/$(REQUIRED_OPERATOR_SDK_VERSION)/operator-sdk_linux_amd64
	chmod +x operator-sdk_linux_amd64 && sudo mv operator-sdk_linux_amd64 /usr/bin/operator-sdk

OPERATOR_SDK_INSTALLED := $(shell command -v operator-sdk version 2> /dev/null)
.PHONY: check-operator-sdk-version
check-operator-sdk-version:
ifndef OPERATOR_SDK_INSTALLED
	$(info operator-sdk is not installed - downloading it)
	$(MAKE) REQUIRED_OPERATOR_SDK_VERSION=$(REQUIRED_OPERATOR_SDK_VERSION) install_operator_sdk
else
ifneq ($(shell operator-sdk version | awk -F',' '{print $$1}' | awk -F'[""]' '{print $$2}'), $(REQUIRED_OPERATOR_SDK_VERSION))
	$(info updating operator-sdk to $(REQUIRED_OPERATOR_SDK_VERSION))
	$(MAKE) REQUIRED_OPERATOR_SDK_VERSION=$(REQUIRED_OPERATOR_SDK_VERSION) install_operator_sdk
endif
endif
