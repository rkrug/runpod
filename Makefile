# Build/push targets for every image under docker/, plus `make test`.
# REGISTRY has no default on purpose — set it explicitly so a fork never
# accidentally builds/pushes into someone else's namespace. The `test*`
# targets don't need a registry at all, so they're exempted below.
#
# Usage:
#   REGISTRY=ghcr.io/<you> make docker-tei
#   REGISTRY=ghcr.io/<you> make docker-bertopic
#   REGISTRY=ghcr.io/<you> make docker-nli
#   REGISTRY=ghcr.io/<you> make docker-all
#   make test

# Goals actually requested, or the default (first) target if none were —
# mirrors what `make` would run so the REGISTRY check below applies to a
# bare `make` too, without misfiring on `make test`.
_GOALS := $(if $(MAKECMDGOALS),$(MAKECMDGOALS),docker-tei-build)
ifneq ($(filter-out test test-skip-docker test-skip-build,$(_GOALS)),)
ifndef REGISTRY
$(error REGISTRY must be set, e.g. `REGISTRY=ghcr.io/<you> make docker-all`)
endif
endif

VERSION  ?= v0.1.0
TEI_TAG  ?= 89-1.5
PLATFORM ?= linux/amd64
IMAGE_SOURCE_URL ?= https://github.com/rkrug/runpod
# Empty = use the Dockerfile default (deberta-v3-large-zeroshot-v2.0).
# Override to bake a different model, e.g.:
#   make docker-nli NLI_MODEL=MoritzLaurer/deberta-v3-base-zeroshot-v2.0
NLI_MODEL ?=

.PHONY: docker-tei-build docker-tei-push docker-tei \
        docker-bertopic-build docker-bertopic-push docker-bertopic \
        docker-nli-build docker-nli-push docker-nli \
        docker-all \
        test test-skip-docker test-skip-build

docker-tei-build: ## Build TEI images (proximity + adhoc_query adapters)
	docker buildx build --platform $(PLATFORM) \
	    -t $(REGISTRY)/tei-specter2:proximity-$(VERSION) --build-arg ADAPTER=proximity --build-arg TEI_TAG=$(TEI_TAG) \
	    --build-arg IMAGE_SOURCE_URL=$(IMAGE_SOURCE_URL) \
	    -f docker/tei-runpod/Dockerfile .
	docker buildx build --platform $(PLATFORM) \
	    -t $(REGISTRY)/tei-specter2:adhoc_query-$(VERSION) --build-arg ADAPTER=adhoc_query --build-arg TEI_TAG=$(TEI_TAG) \
	    --build-arg IMAGE_SOURCE_URL=$(IMAGE_SOURCE_URL) \
	    -f docker/tei-runpod/Dockerfile .

docker-tei-push: ## Push TEI images to the registry
	docker push $(REGISTRY)/tei-specter2:proximity-$(VERSION)
	docker push $(REGISTRY)/tei-specter2:adhoc_query-$(VERSION)

docker-tei: docker-tei-build docker-tei-push

docker-bertopic-build: ## Build the BERTopic RunPod image
	docker buildx build --platform $(PLATFORM) -t $(REGISTRY)/bertopic-runpod:$(VERSION) \
	    --build-arg IMAGE_SOURCE_URL=$(IMAGE_SOURCE_URL) \
	    -f docker/bertopic-runpod/Dockerfile .

docker-bertopic-push: ## Push the BERTopic RunPod image to the registry
	docker push $(REGISTRY)/bertopic-runpod:$(VERSION)

docker-bertopic: docker-bertopic-build docker-bertopic-push

docker-nli-build: ## Build the NLI RunPod image (NLI_MODEL=... to override the baked model)
	docker buildx build --platform $(PLATFORM) \
	    $(if $(NLI_MODEL),--build-arg NLI_MODEL=$(NLI_MODEL),) \
	    -t $(REGISTRY)/nli-runpod:$(VERSION) \
	    --build-arg IMAGE_SOURCE_URL=$(IMAGE_SOURCE_URL) \
	    -f docker/nli-runpod/Dockerfile .

docker-nli-push: ## Push the NLI RunPod image to the registry
	docker push $(REGISTRY)/nli-runpod:$(VERSION)

docker-nli: docker-nli-build docker-nli-push

docker-all: docker-tei docker-bertopic docker-nli

test: ## Run the full local verification suite (shellcheck + builds + smoke tests, no RunPod/GPU needed)
	test/smoke-test.sh

test-skip-docker: ## Run shellcheck + pod-lifecycle dry-run validation only (no docker needed)
	test/smoke-test.sh --skip-docker

test-skip-build: ## Re-run smoke tests against already-built runpod-smoketest/* images
	test/smoke-test.sh --skip-build
