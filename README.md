<div align="center">

# agent-sidecar

**A zero-dependency HTTP proxy that transparently injects experiment & agent identity
into LLM API calls.**

Deployed as a sidecar container next to an AgentCert agent. Agents speak unmodified
OpenAI-compatible JSON to `localhost:4001`; the sidecar adds Langfuse-canonical metadata
(`trace_id`, `trace_name`, `session_id`, `generation_name`, plus agent identity) and
forwards the request to the upstream LiteLLM proxy. **The agent code stays oblivious.**

![Python](https://img.shields.io/badge/Python-3.12-3776AB?style=flat-square&logo=python)
![No-Deps](https://img.shields.io/badge/Dependencies-stdlib%20only-success?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-lightgrey?style=flat-square)

</div>

---

## Why a sidecar?

The AgentCert platform needs every LLM request from an agent to carry the
`experiment_id`, `experiment_run_id`, `agent_id`, `workflow_name` and a
deterministic `trace_id` so that:

- Langfuse can group spans into per-experiment traces.
- The certifier can correlate trace data back to the originating chaos experiment.
- Agents themselves remain **portable** — no AgentCert-specific code, no SDK to
  maintain across language stacks, no rebuilds when metadata fields change.

The sidecar solves this at the network boundary. Agents make standard OpenAI requests to
a localhost port; the sidecar rewrites them in flight.

```
┌──────────────┐  POST :4001         ┌──────────────────┐  POST upstream
│   AI Agent   │ ───── /chat/        │  agent-sidecar   │ ─── /chat/ ──────▶ LiteLLM
│  (any lang)  │       completions   │   (proxy.py)     │     completions    :4000
└──────┬───────┘                     └───────┬──────────┘
       │ standard openai client              │ injects metadata into the JSON body
       │ — knows nothing about               │ (openai-metadata mode)
       │ AgentCert                           │ or as X-Experiment-* headers
       │                                     │ (http-header mode)
       ▼                                     ▼
                                ┌────────────────────────┐
                                │ ConfigMap (auto-read)  │
                                │ /etc/agent/metadata/   │
                                │   NOTIFY_ID            │
                                │   WORKFLOW_NAME        │
                                │   WORKFLOW_UID         │
                                │   AGENT_NAME           │
                                │   AGENT_ROLE           │
                                │   AGENT_ID             │
                                │   AGENT_VERSION        │
                                └────────────────────────┘
```

---

## What the proxy actually does

All of the logic lives in [`proxy.py`](proxy.py) — a single file, ~340 lines, **Python
stdlib only** (`http.server`, `urllib.request`, `json`, `threading`, `os`).

| Function | What it does |
|---|---|
| `main()` | Boots `HTTPServer` on `0.0.0.0:${SIDECAR_PORT}` |
| `ProxyHandler.do_POST/GET/PUT/DELETE/OPTIONS` | Mirrors every method/header/body to `UPSTREAM_URL` |
| `_load_context()` | Reads the 7 metadata keys from the ConfigMap mount (or env vars) on every request; merges with the previous request's cache when the `notify_id` matches (guards against transient mount reads) |
| `_inject_metadata()` | Parses JSON body, merges context into the top-level `metadata` dict, sets `trace_id` (from `notify_id`), `trace_name` (from `workflow_name`), `session_id`, `user_id`, plus agent identity fields; rewrites the request body |
| `_detect_generation_name()` | Regex over message content classifies each call as `"tool-selection"` or `"llm-analysis"` for cleaner Langfuse spans |
| `_remember_trace_id()` | Caches the last `trace_id` so log lines emit a clear *"trace switched"* event when experiments change |
| `_build_context_headers()` | Alternate injection path — emits `X-Experiment-<Key>` HTTP headers instead of touching the body |

ConfigMap key ↔ Langfuse field mapping:

| ConfigMap key | Langfuse field | Notes |
|---|---|---|
| `NOTIFY_ID` | `trace_id` | Highest priority — comes from ChaosCenter's `experiment_run_id` |
| `WORKFLOW_NAME` | `trace_name` | Argo workflow display name |
| `WORKFLOW_UID` | `session_id` | Per-workflow grouping |
| `AGENT_ID` | `user_id` + body `metadata.agent_id` | Registry UUID |
| `AGENT_NAME` | body `metadata.agent_name` | Human-readable name |
| `AGENT_ROLE` | body `metadata.agent_role` | e.g. `flash-agent` / `k8s-agent` |
| `AGENT_VERSION` | body `metadata.agent_version` | Chart/image version |

---

## Configuration

| Variable | Default | Description |
|---|---|---|
| `SIDECAR_PORT` | `4001` | Port the proxy listens on |
| `UPSTREAM_URL` | `http://localhost:4000` | LiteLLM (or other OpenAI-compatible) URL |
| `INJECTION_MODE` | `openai-metadata` | `openai-metadata` (JSON body), `http-header`, or `none` |
| `CONFIG_MOUNT` | `/etc/agent/metadata` | ConfigMap volume path (each file is one key) |

ConfigMap reads happen on every request — refreshes hot, no restart needed. Kubernetes'
~60 s ConfigMap propagation delay applies.

---

## Build

The image is published as `agentcert/agent-sidecar:latest` from the project's
[`Dockerfile`](Dockerfile) — `python:3.12-slim`, non-root `sidecar:1000`, single
`proxy.py`, port `4001`.

```bash
make build                      # → agentcert/agent-sidecar:latest
make build-no-cache             # full rebuild
make push                       # to registry
make build-push                 # build + push
make tag NEW_TAG=v1.0.0
make kind-load                  # docker save → kind load
make clean                      # remove local image
make run                        # docker run -p 4001:4001 -e UPSTREAM_URL=... :latest
```

CI flow ([`build-agent-sidecar.sh`](build-agent-sidecar.sh)) reads `../.env`, builds a
`ci-YYYYMMDDHHMMSS` tag plus `latest` + `dev`, falls back to the legacy builder if
BuildKit fails, loads the result into Minikube, prunes stale tags from the cluster's
containerd, and writes `AGENT_SIDECAR_IMAGE=agentcert/agent-sidecar:latest` back into
`.env`.

---

## Local development

```bash
# Run against an external LiteLLM
docker run --rm -p 4001:4001 \
  -e UPSTREAM_URL=http://host.docker.internal:4000 \
  -e INJECTION_MODE=openai-metadata \
  agentcert/agent-sidecar:latest

# Smoke test (assumes LiteLLM up on :4000 with model gpt-4o)
curl -s -X POST http://localhost:4001/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
        "model": "gpt-4o",
        "messages": [{"role":"user","content":"hello"}]
      }' | jq .
```

Inject mock context:

```bash
docker run --rm -p 4001:4001 \
  -e UPSTREAM_URL=http://host.docker.internal:4000 \
  -e CONFIG_MOUNT=/tmp/ctx \
  -v $(pwd)/example-ctx:/tmp/ctx:ro \
  agentcert/agent-sidecar:latest
```

Where `example-ctx/` is a directory of single-line files named `NOTIFY_ID`,
`WORKFLOW_NAME`, … (one key per file — mirrors how a Kubernetes ConfigMap volume
mounts).

---

## Kubernetes integration

The sidecar is auto-injected by [`agent-charts/charts/flash-agent`](../agent-charts/charts/flash-agent)
when `sidecar.enabled=true` in the chart's values. The chart wires the ConfigMap mount,
sets `SIDECAR_PORT`, and points `UPSTREAM_URL` at
`http://litellm-proxy.litellm.svc.cluster.local:4000`.

```yaml
# values.yaml fragment
sidecar:
  enabled: true
  port:     4001
  upstreamUrl: http://litellm-proxy.litellm.svc.cluster.local:4000
  injectionMode: openai-metadata
  image:
    repository: agentcert/agent-sidecar
    tag: latest
    pullPolicy: Always
```

To make the agent traffic flow through the sidecar without code changes, either:

- Set the agent's `OPENAI_BASE_URL` (or equivalent) to `http://localhost:4001/v1`.
- Or apply a service-mesh / iptables rewrite redirecting `:4000` egress to `:4001` on
  the same pod (advanced).

---

## Security considerations

The sidecar is documented under
[`AgentCert/docs/Flash-agent-data-leakage-analysis.md`](../AgentCert/docs/Flash-agent-data-leakage-analysis.md)
as the source of risk **RC-4**: it stamps experiment identity onto every outgoing LLM
call, which lets a Langfuse-aware agent in theory correlate itself to the experiment
context. The documented mitigation is server-side blind-observer integrity checks rather
than disabling the sidecar — the metadata is the whole point.

---

## Relationship with the rest of the stack

| Component | Relationship |
|---|---|
| [`agent-charts`](../agent-charts) | Helm-injects this container alongside the agent pod and wires the ConfigMap |
| [`AgentCert`](../AgentCert) | Writes the ConfigMap content (`NOTIFY_ID`, `WORKFLOW_*`, `AGENT_*`) when a scenario starts |
| [`agentcert-stack`](../agentcert-stack) | Provides the LiteLLM proxy this sidecar forwards to |
| [`certifier`](../certifier) | Consumes the resulting Langfuse traces — the injected `trace_id` is the join key |

---

## License

MIT — see [LICENSE](LICENSE).
