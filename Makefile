# Makefile for agent-sidecar Docker image
# Transparent proxy for LLM metadata injection

# Configuration
IMAGE_REGISTRY ?= agentcert
IMAGE_NAME ?= agent-sidecar
IMAGE_TAG ?= latest

# Full image reference
IMAGE = $(IMAGE_REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

# Build context - current directory
BUILD_CONTEXT = .

.PHONY: help
help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@awk 'BEGIN {FS = ":.*##"; } /^[a-zA-Z_-]+:.*?##/ { printf "  %-15s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: build
build: ## Build the Docker image
	@echo "Building Docker image: $(IMAGE)"
	docker build -t $(IMAGE) -f Dockerfile $(BUILD_CONTEXT)

.PHONY: build-no-cache
build-no-cache: ## Build the Docker image without cache
	@echo "Building Docker image (no cache): $(IMAGE)"
	docker build --no-cache -t $(IMAGE) -f Dockerfile $(BUILD_CONTEXT)

.PHONY: push
push: ## Push the Docker image to registry
	@echo "Pushing Docker image: $(IMAGE)"
	docker push $(IMAGE)

.PHONY: build-push
build-push: build push ## Build and push the Docker image

.PHONY: run
run: ## Run the sidecar proxy locally
	docker run --rm -p 4001:4001 \
		-e LITELLM_PROXY_URL=$(LITELLM_PROXY_URL) \
		-e EXPERIMENT_ID=$(EXPERIMENT_ID) \
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
	docker tag $(IMAGE) $(IMAGE_REGISTRY)/$(IMAGE_NAME):$(NEW_TAG)

.PHONY: clean
clean: ## Remove local Docker image
	docker rmi $(IMAGE) 2>/dev/null || true

.PHONY: kind-load
kind-load: build ## Load image into kind cluster
	@echo "Loading image into kind cluster..."
	kind load docker-image $(IMAGE) --name agentcert
