FROM python:3.12-slim

# Create non-root user
RUN groupadd -g 1000 sidecar && useradd -u 1000 -g sidecar -m sidecar

WORKDIR /app
COPY proxy.py .

USER sidecar
EXPOSE 4001

ENTRYPOINT ["python", "proxy.py"]
