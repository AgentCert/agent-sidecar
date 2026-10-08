# Base images: upstream names by default (plain `docker build` works anywhere).
# scripts/build-and-push.sh, setup.sh and prepare-images.sh pass the copy from
# IMAGE_REGISTRY / the frozen agentcert/ Docker Hub copies (scripts/lib/registry.sh).
ARG PYTHON_IMAGE=python:3.12-slim
FROM ${PYTHON_IMAGE}

# Create non-root user
RUN groupadd -g 1000 sidecar && useradd -u 1000 -g sidecar -m sidecar

WORKDIR /app
COPY proxy.py .
RUN chown sidecar:sidecar /app/proxy.py

USER sidecar
EXPOSE 4001

ENTRYPOINT ["python", "proxy.py"]
