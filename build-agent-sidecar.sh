#!/bin/bash
set -e

ENV_FILE="/mnt/d/Studies/AgentCert/local-custom/config/.env"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--env-file)
			ENV_FILE="${2:-}"
			shift 2
			;;
		*)
			shift
			;;
	esac
done

if [[ ! -f "${ENV_FILE}" ]]; then
	echo "[ERROR] Env file not found: ${ENV_FILE}" >&2
	exit 1
fi

# Prune old agentcert/agent-sidecar images before building new one
echo "[INFO] Pruning old agent-sidecar images..."
docker images | grep "agentcert/agent-sidecar" | grep -v "latest\|dev" | awk '{print $3}' | xargs -r docker rmi -f 2>/dev/null || true
docker image prune -f 2>/dev/null || true
echo "[OK] Old images pruned"

IMAGE_TAG="ci-$(date +%Y%m%d%H%M%S)"
IMAGE="agentcert/agent-sidecar:${IMAGE_TAG}"

echo "[INFO] Building ${IMAGE}"
cd /mnt/d/Studies/AgentCert/agent-sidecar

run_docker_build() {
	docker build -t "${IMAGE}" -f Dockerfile .
}

# If BuildKit/buildx is unavailable, retry automatically with legacy builder.
if ! run_docker_build; then
	echo "[WARN] Docker build failed. Retrying with DOCKER_BUILDKIT=0..."
	DOCKER_BUILDKIT=0 run_docker_build
fi

docker tag "${IMAGE}" agentcert/agent-sidecar:latest
docker tag "${IMAGE}" agentcert/agent-sidecar:dev
echo "[OK] Docker build completed"

echo "[INFO] Cleaning up old images from minikube..."
# Remove old ci-* tags from minikube (keep only latest, dev, and the new one will be loaded next)
minikube image ls | grep "agent-sidecar:ci-" | grep -v "${IMAGE_TAG}" | awk '{print $1}' | xargs -r minikube image rm 2>/dev/null || true
# Also remove the existing :latest and :dev so the freshly built image is unambiguously loaded
# (avoids any chance of a cached layer / stale digest sticking around in containerd).
minikube image rm agentcert/agent-sidecar:latest 2>/dev/null || true
minikube image rm agentcert/agent-sidecar:dev    2>/dev/null || true
echo "[OK] Old minikube images cleaned"

echo "[INFO] Loading into minikube..."
minikube image load "${IMAGE}"
minikube image load agentcert/agent-sidecar:latest
minikube image load agentcert/agent-sidecar:dev
echo "[OK] Images loaded into minikube"

# Update .env with :latest tag
# Chart values reference this image; keeping .env in sync allows build-and-deploy.sh to patch it if needed
LATEST_IMAGE="agentcert/agent-sidecar:latest"
if grep -q "^AGENT_SIDECAR_IMAGE=" "${ENV_FILE}" 2>/dev/null; then
	sed -i "s|^AGENT_SIDECAR_IMAGE=.*|AGENT_SIDECAR_IMAGE=${LATEST_IMAGE}|" "${ENV_FILE}"
else
	# Add after FLASH_AGENT_IMAGE or INSTALL_AGENT_IMAGE line
	if grep -q "^FLASH_AGENT_IMAGE=" "${ENV_FILE}"; then
		sed -i "/^FLASH_AGENT_IMAGE=/a AGENT_SIDECAR_IMAGE=${LATEST_IMAGE}" "${ENV_FILE}"
	elif grep -q "^INSTALL_AGENT_IMAGE=" "${ENV_FILE}"; then
		sed -i "/^INSTALL_AGENT_IMAGE=/a AGENT_SIDECAR_IMAGE=${LATEST_IMAGE}" "${ENV_FILE}"
	else
		printf '\nAGENT_SIDECAR_IMAGE=%s\n' "${LATEST_IMAGE}" >> "${ENV_FILE}"
	fi
fi
echo "[OK] .env updated: AGENT_SIDECAR_IMAGE=${LATEST_IMAGE}"
