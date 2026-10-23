# Makefile for agent-sidecar Docker image
# Transparent proxy for LLM metadata injection

# Anchored to this Makefile, not to the caller's working directory, so the
# targets behave the same however make is invoked (cd, make -C or make -f).
# ACE_REPO_ROOT may be overridden from the environment or the command line.
ACE_MAKEFILE := $(abspath $(lastword $(MAKEFILE_LIST)))
ACE_COMPONENT_DIR := $(patsubst %/,%,$(dir $(ACE_MAKEFILE)))
ACE_REPO_ROOT ?= $(abspath $(ACE_COMPONENT_DIR)/..)
ACE_REGISTRY_LIB := $(ACE_REPO_ROOT)/scripts/lib/registry.sh
ACE_ENV_FILE ?= $(ACE_REPO_ROOT)/.env

# Configuration
# IMAGE is the image's PUBLIC name (e.g. agentcert/agent-sidecar:latest).
# Which registry it is built from and pushed to is resolved at run time by
# scripts/lib/registry.sh from IMAGE_REGISTRY / IMAGE_MIRROR_NAMESPACE, so a
# registry host must never be baked into this reference -- doing so drops the
# mirror namespace and publishes where no other ACE tool looks.
IMAGE_NAMESPACE ?= agentcert
IMAGE_NAME ?= agent-sidecar
IMAGE_TAG ?= latest

# Full image reference
IMAGE = $(IMAGE_NAMESPACE)/$(IMAGE_NAME):$(IMAGE_TAG)

# Build context - this component's directory
BUILD_CONTEXT = $(ACE_COMPONENT_DIR)

# Run a build command with registry.sh sourced and the env file loaded. The
# caller's IMAGE_REGISTRY is deliberately left intact: registry_load reads the
# environment first, so `IMAGE_REGISTRY= make build` forces the public path.
# With IMAGE_REGISTRY set the Dockerfile's base images resolve to that registry,
# so log in first (no-op without credentials; a failure only warns, as a prior
# `docker login` may still be valid).
ACE_WITH_REGISTRY = bash -c 'source "$$1"; registry_load "$$2" || exit; [ -z "$$IMAGE_REGISTRY" ] || registry_login >/dev/null || echo "WARN: login to $$(registry_host) failed; base-image pulls may get 401" >&2; shift 2; "$$@"' _ "$(ACE_REGISTRY_LIB)" "$(ACE_ENV_FILE)"
# Tag the public name to its resolved destination and push that. ACE_IMAGE_TAG
# is cleared so IMAGE_TAG is what gets pushed: release tags are immutable and
# belong to scripts/build-and-push.sh --push --tag, which guards them.
ACE_PUSH = bash -c 'source "$$1"; registry_load "$$2" || exit; ACE_IMAGE_TAG=; dst="$$(registry_ref "$$3")" || exit; [ "$$dst" = "$$3" ] || docker tag "$$3" "$$dst" || exit; echo "Pushing Docker image: $$dst"; docker push "$$dst"' _ "$(ACE_REGISTRY_LIB)" "$(ACE_ENV_FILE)"

.PHONY: require-ace-lib
require-ace-lib: ## Fail early (and readably) outside an ace-monorepo checkout
	@test -f "$(ACE_REGISTRY_LIB)" || { \
		echo "ERROR: $(ACE_REGISTRY_LIB) not found." >&2; \
		echo "       This target resolves images through the shared ACE registry library;" >&2; \
		echo "       run it from an ace-monorepo checkout (or set ACE_REPO_ROOT)." >&2; \
		exit 1; }

.PHONY: help
help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@awk 'BEGIN {FS = ":.*##"; } /^[a-zA-Z_-]+:.*?##/ { printf "  %-15s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: build
build: require-ace-lib ## Build the Docker image
	@echo "Building Docker image: $(IMAGE)"
	$(ACE_WITH_REGISTRY) docker_build_resolved "$(ACE_COMPONENT_DIR)/Dockerfile" -t "$(IMAGE)" "$(BUILD_CONTEXT)"

.PHONY: build-no-cache
build-no-cache: require-ace-lib ## Build the Docker image without cache
	@echo "Building Docker image (no cache): $(IMAGE)"
	$(ACE_WITH_REGISTRY) docker_build_resolved "$(ACE_COMPONENT_DIR)/Dockerfile" --no-cache -t "$(IMAGE)" "$(BUILD_CONTEXT)"

.PHONY: push
push: require-ace-lib ## Push the Docker image to the resolved registry
	$(ACE_PUSH) "$(IMAGE)"

.PHONY: build-push
build-push: build ## Build successfully before publishing, including under make -j
	$(MAKE) -f "$(ACE_MAKEFILE)" push

.PHONY: run
run: ## Run the sidecar proxy locally
	docker run --rm -p 4001:4001 \
		-e UPSTREAM_URL="$(UPSTREAM_URL)" \
		-e INJECTION_MODE="$(or $(INJECTION_MODE),openai-metadata)" \
		-e AGENT_ID=$(AGENT_ID) \
		$(IMAGE)

.PHONY: run-shell
run-shell: ## Run container with interactive shell
	docker run --rm -it --entrypoint /bin/bash $(IMAGE)

.PHONY: tag
tag: ## Tag image with additional tag (use NEW_TAG=<tag>)
ifndef NEW_TAG
	$(error NEW_TAG is required. Usage: make tag NEW_TAG=v1.0.0)
endif
	docker tag $(IMAGE) $(IMAGE_NAMESPACE)/$(IMAGE_NAME):$(NEW_TAG)

.PHONY: clean
clean: ## Remove local Docker image
	docker rmi $(IMAGE) 2>/dev/null || true

.PHONY: kind-load
kind-load: build ## Load image into kind cluster
	@echo "Loading image into kind cluster..."
	@test -n "$(KIND_CLUSTER_NAME)" || { echo "Set KIND_CLUSTER_NAME explicitly" >&2; exit 2; }
	kind load docker-image "$(IMAGE)" --name "$(KIND_CLUSTER_NAME)"
