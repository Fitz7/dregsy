#
# Copyright 2020 Alexander Vollschwitz
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
#
REGISTRY = gcr.io/faceit-general

.DEFAULT_GOAL := help
SHELL = /bin/bash

REPO = dregsy-fork
DREGSY_VERSION = $$(git describe --always --tag --dirty)
SKOPEO_VERSION = v1.11.2 # https://github.com/containers/skopeo/releases

ROOT = $(shell pwd)
BUILD_OUTPUT =_build
BINARIES = $(BUILD_OUTPUT)/bin
ISOLATED_PKG = $(BUILD_OUTPUT)/pkg
ISOLATED_CACHE = $(BUILD_OUTPUT)/cache

GO_IMAGE = docker.io/golang:1.20.2
# use digests of plain golang:{x:y:z} image
GO_IMAGE_DIGEST_amd64 = 2101aa981e68ab1e06e3d4ac35ae75ed122f0380e5331e3ae4ba7e811bf9d256 # linux/amd64
GO_IMAGE_DIGEST_arm64 = 2b66aad188b275018254d2877159381a05013fc8c5f695e9595a56fcfc83d995 # linux/arm64/v8
GO_IMAGE_DIGEST_arm = 1cac9131c1684a9c407b618da17948780bfd061a91377f20df21b92066d6f9a1   # linux/arm/v7
GO_IMAGE_DIGEST_386 = 5c3c6546290acfd0c5de02eae32fac9711d2831c3ad6f74fefa872981bf9cff7   # linux/386

GOOS = $(shell uname -s | tr A-Z a-z)
GOARCH = $(shell ./hack/devenvutil get_architecture)

## makerc
# You need to set the following parameters in configuration file ${DIM}.makerc${NRM}, with every line
# containing a parameter in the form ${ITL}key = value${NRM}:
#
#	${ITL}DREGSY_TEST_DOCKERHOST${NRM}		how the ${ITL}Docker${NRM} daemon is set up for testing, i.e. how
#					it can be reached from within the test container, which
#					uses host networking; defaults to ${DIM}tcp://127.0.0.1:2375${NRM}
#
#	${ITL}DREGSY_TEST_ECR_REGISTRY${NRM}	the ECR instance to use
#	${ITL}DREGSY_TEST_ECR_REPO${NRM} 		the repo to use within the ECR instance;
#					defaults to ${DIM}dregsy/test${NRM}
#
#	${ITL}DREGSY_TEST_ECR_PUB_REGISTRY${NRM}	the public ECR instance to use
#	${ITL}DREGSY_TEST_ECR_PUB_REPO${NRM} 	the repo to use within the public ECR instance
#
#	${ITL}AWS_ACCESS_KEY_ID${NRM}		credentials for AWS account in which ECR instance for
#	${ITL}AWS_SECRET_ACCESS_KEY${NRM}		testing is located; the user associated with these
#					credentials needs to have sufficient IAM permissions for
#					creating an ECR instance, pulling & pushing from/to it,
#					and deleting it
#
#	If any of the above settings without a default is missing, ECR tests are skipped!
#
#	${ITL}DREGSY_TEST_GCR_HOST${NRM}		the GCR host to use; defaults to ${DIM}eu.gcr.io${NRM}
#	${ITL}DREGSY_TEST_GCR_PROJECT${NRM} 	the GCP project ID to use with GCR tests
#	${ITL}DREGSY_TEST_GCR_IMAGE${NRM} 		the image to use; defaults to ${DIM}dregsy/test${NRM}
#
#	${ITL}DREGSY_TEST_GAR_HOST${NRM}		the GAR host to use; defaults to ${DIM}europe-west3-docker.pkg.dev${NRM}
#	${ITL}DREGSY_TEST_GAR_PROJECT${NRM} 	the GCP project ID to use with GAR tests
#	${ITL}DREGSY_TEST_GAR_IMAGE${NRM} 		the image to use; defaults to ${DIM}dregsy/test${NRM}
#
#	${ITL}GCP_CREDENTIALS${NRM}			full path to credentials file for GCP service account
#					with which to test GCR/GAR
#
#	If any of the above settings without a default is missing, GCR and/or GAR tests are skipped!
#
-include .makerc

## env
# You can set the following environment variables when calling make:
#
#	${ITL}VERBOSE=y${NRM}	get detailed output
#
#	${ITL}ISOLATED=y${NRM}	when using this with a build or test target, the build/test will be isolated
#			in the sense that local caches such as ${DIM}\${GOPATH}/pkg${NRM} and ${DIM}~/.cache${NRM} will
#			not be mounted into the container. Instead, according folders underneath
#			the configured build folder are used. These folders are removed when
#			running ${DIM}make clean${NRM}. That way you can force a clean build/test, where all
#			dependencies are retrieved & built inside the container.
#
#	${ITL}TEST_ALPINE=n${NRM}	when using this with the test target, tests will not be performed
#	${ITL}TEST_UBUNTU=n${NRM}	for the respective image (${ITL}Alpine${NRM} or ${ITL}Ubuntu${NRM} based)
#
#	${ITL}TEST_OPTS="..."${NRM} any options you would like to pass to the test run, e.g. to select a
#			particular test, ${DIM}TEST_OPTS="-run TestE2ESkopeo"${NRM}
#

VERBOSE ?=
ifeq ($(VERBOSE),y)
    $(warning ***** starting Makefile for goal(s) "$(MAKECMDGOALS)")
    $(warning ***** $(shell date))
    MAKEFLAGS += --trace
    TEST_OPTS += -v
else
    MAKEFLAGS += -s
endif

ifeq ($(MAKECMDGOALS),release)
	ISOLATED = y
endif

ISOLATED ?=
ifeq ($(ISOLATED),y)
    CACHE_VOLS = -v $(ROOT)/$(ISOLATED_PKG):/go/pkg -v $(ROOT)/$(ISOLATED_CACHE):/.cache
else
    CACHE_VOLS = -v $(GOPATH)/pkg:/go/pkg -v $(HOME)/.cache:/.cache
endif

ifeq ($(GCP_CREDENTIALS),)
	GCP_CREDS =
else
	GCP_CREDS = -v $(GCP_CREDENTIALS):/var/run/secrets/gcp-creds.json -e GOOGLE_APPLICATION_CREDENTIALS=/var/run/secrets/gcp-creds.json
endif

TEST_ALPINE ?= y
TEST_UBUNTU ?= y

TEST_CLEANUP = "127.0.0.1:5000/*/*/*/*" "*/*/*/busybox*" \
		"*/cloudrun/container/hello" "registry.hub.docker.com/library/busybox" \
		"*/jenkins/jnlp-slave" "*/*/*/hello"

export

#
#

.PHONY: help
help:
#	show this help
#
	$(call utils, synopsis) | more


.PHONY: release
release: clean rmi dregsy imgdregsy imgtests tests registrydown
#	clean, do an isolated build, create container images, and test
#


.PHONY: publish
publish:
#	tag & push all container images belonging to a complete release
#
	docker tag $(REGISTRY)/$(REPO):latest-alpine $(REGISTRY)/$(REPO):$(DREGSY_VERSION)
	docker tag $(REGISTRY)/$(REPO):latest-alpine $(REGISTRY)/$(REPO):$(DREGSY_VERSION)-alpine
	docker tag $(REGISTRY)/$(REPO):latest-ubuntu $(REGISTRY)/$(REPO):$(DREGSY_VERSION)-ubuntu

	docker push $(REGISTRY)/$(REPO):latest
	docker push $(REGISTRY)/$(REPO):latest-alpine
	docker push $(REGISTRY)/$(REPO):$(DREGSY_VERSION)
	docker push $(REGISTRY)/$(REPO):$(DREGSY_VERSION)-alpine
	docker push $(REGISTRY)/$(REPO):latest-ubuntu
	docker push $(REGISTRY)/$(REPO):$(DREGSY_VERSION)-ubuntu


.PHONY: dregsy
dregsy: prep
#	build the ${ITL}dregsy${NRM} binary
#
	echo "os: $(GOOS), arch: $(GOARCH)"
	docker run --rm --user $(shell id -u):$(shell id -g) \
		-v $(shell pwd)/$(BINARIES):/go/bin $(CACHE_VOLS) \
		-v $(shell pwd):/go/src/$(REPO) -w /go/src/$(REPO) \
		-e CGO_ENABLED=0 -e GOOS=$(GOOS) -e GOARCH=$(GOARCH) \
		$(GO_IMAGE)@sha256:$(GO_IMAGE_DIGEST_$(GOARCH)) bash -c \
			"go mod tidy && go build -v -tags netgo -installsuffix netgo \
			-ldflags \"-w -X main.DregsyVersion=$(DREGSY_VERSION)\" \
			-o $(BINARIES)/dregsy ./cmd/dregsy/"


.PHONY: imgdregsy
imgdregsy:
#	build the ${ITL}dregsy${NRM} container images (Alpine and Ubuntu based);
#	assumes binary was built
#
	echo -e "\nBuilding Alpine-based image...\n"
	docker build -t $(REGISTRY)/$(REPO):latest-alpine \
		--build-arg binaries=$(BINARIES) \
		--build-arg SKOPEO_VERSION=$(SKOPEO_VERSION) \
		-f ./hack/dregsy.alpine.Dockerfile .
	# for historical reasons, the `$(REGISTRY)/dregsy` image is the Alpine image
	docker tag $(REGISTRY)/$(REPO):latest-alpine $(REGISTRY)/$(REPO):latest
	echo -e "\n\nBuilding Ubuntu-based image...\n"
	docker build -t $(REGISTRY)/$(REPO):latest-ubuntu \
		--build-arg binaries=$(BINARIES) \
		--build-arg SKOPEO_VERSION=$(SKOPEO_VERSION) \
		-f ./hack/dregsy.ubuntu.Dockerfile .
	echo -e "\nDone\n"


.PHONY: imgtests
imgtests:
#	build the container images for running tests (Alpine and Ubuntu based);
#	assumes ${ITL}dregsy-...${NRM} images were built
#
	echo -e "\nBuilding Alpine-based test image...\n"
	docker build -t $(REGISTRY)/$(REPO)-tests-alpine \
		-f ./hack/tests.alpine.Dockerfile .
	echo -e "\n\nBuilding Ubuntu-based test image...\n"
	docker build -t $(REGISTRY)/$(REPO)-tests-ubuntu \
		-f ./hack/tests.ubuntu.Dockerfile .
	echo -e "\nDone\n"


.PHONY: rmi
rmi:
#	remove the ${ITL}dregsy${NRM} and testing container images
#
	docker rmi -f $(REGISTRY)/$(REPO):latest
	docker rmi -f $(REGISTRY)/$(REPO):latest-alpine
	docker rmi -f $(REGISTRY)/$(REPO):latest-ubuntu
	docker rmi -f $(REGISTRY)/$(REPO)-tests-alpine
	docker rmi -f $(REGISTRY)/$(REPO)-tests-ubuntu


.PHONY: rmitest
rmitest:
#	remove all test-related container images
#
	$(call utils, remove_test_images $(TEST_CLEANUP))


.PHONY: tests
tests: prep
#	run tests; assumes test images were built; local ${ITL}Docker${NRM} registry gets
#	(re-)started on localhost:5000
#
ifeq (,$(wildcard .makerc))
	$(warning ***** Missing .makerc! Some tests may be skipped or fail!)
endif
ifeq ($(TEST_ALPINE),y)
	$(call utils, remove_test_images $(TEST_CLEANUP)) > /dev/null
	docker image prune --force
	$(call utils, registry_restart)
	$(call utils, run_tests alpine)
endif
ifeq ($(TEST_UBUNTU),y)
	$(call utils, remove_test_images $(TEST_CLEANUP)) > /dev/null
	docker image prune --force
	$(call utils, registry_restart)
	$(call utils, run_tests ubuntu)
endif


.PHONY: registryup
registryup:
#	start local ${ITL}Docker${NRM} registry for running tests
#
	$(call utils, registry_up)


.PHONY: registrydown
registrydown:
#	stop local ${ITL}Docker${NRM} registry
#
	$(call utils, registry_down) || true


.PHONY: registryrestart
registryrestart:
#	restart local ${ITL}Docker${NRM} registry
#
	$(call utils, registry_restart)


.PHONY: clean
clean:
#	remove all build artifacts, including isolation caches
#
	[ ! -d $(BUILD_OUTPUT) ] || chmod -R u+w $(BUILD_OUTPUT)
	rm -rf $(BUILD_OUTPUT)/*


.PHONY: prep
prep:
#	prepare required directories
#
	mkdir -p $(BUILD_OUTPUT) $(BINARIES) $(ISOLATED_PKG) $(ISOLATED_CACHE)


#
# helper functions
#
utils = ./hack/devenvutil $(1)
