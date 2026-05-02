# Agent Sidecar

A transparent HTTP proxy that injects agent identity metadata into LLM requests. Deployed as a sidecar container alongside AI agents to enable observability without agent code changes.

## Features

- **Zero Agent Awareness**: Agents make standard OpenAI API calls; metadata injection is transparent
- **Dynamic Configuration**: Reads experiment/agent IDs from ConfigMap volume (hot-reloaded)
- **Multiple Injection Modes**: Supports OpenAI metadata field, HTTP headers, or disabled
- **Lightweight**: Python 3.12 slim container, minimal dependencies

## How It Works

```
┌─────────────┐    ┌─────────────────┐    ┌─────────────┐
│  AI Agent   │───▶│  Agent Sidecar  │───▶│   LiteLLM   │
│ (port 4001) │    │   (proxy.py)    │    │ (port 4000) │
└─────────────┘    └─────────────────┘    └─────────────┘
                          │
                   ┌──────┴──────┐
                   │  ConfigMap  │
                   │  /etc/agent │
                   │  /metadata  │
                   └─────────────┘
```

The sidecar intercepts OpenAI-compatible requests and enriches them with:
- `experiment_id` — Current chaos experiment identifier
- `agent_id` — Agent instance identifier  
- `trace_id` — Request correlation ID

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SIDECAR_PORT` | `4001` | Port the proxy listens on |
| `UPSTREAM_URL` | `http://localhost:4000` | LiteLLM proxy URL |
| `INJECTION_MODE` | `openai-metadata` | `openai-metadata`, `http-header`, or `none` |
| `CONFIG_MOUNT` | `/etc/agent/metadata` | Path to ConfigMap volume mount |

## Build

```bash
# Build Docker image
make build

# Build and load into kind cluster
make kind-load

# Build with custom tag
make build IMAGE_TAG=v1.0.0
```

## Usage

### Kubernetes Deployment

The sidecar is automatically injected when deploying agents via Helm charts with `sidecar.enabled=true`:

```yaml
# values.yaml
sidecar:
  enabled: true
  port: 4001
  image:
    repository: agentcert/agent-sidecar
    tag: latest
```

### Local Development

```bash
# Run locally (requires LiteLLM at localhost:4000)
docker run -p 4001:4001 \
  -e UPSTREAM_URL=http://host.docker.internal:4000 \
  agentcert/agent-sidecar:latest
```

## License

MIT License - see [LICENSE](LICENSE)
