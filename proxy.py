"""
agent-sidecar - Transparent metadata-injection HTTP proxy.
==========================================================

Sits between any LLM agent and LiteLLM to enrich requests with
agent identity. The agent has ZERO awareness of experiment IDs.
Context is loaded dynamically on every request from the ConfigMap
volume mount so long-running pods use fresh experiment IDs.

Env vars (startup config):
    SIDECAR_PORT   - listen port (default 4001)
    UPSTREAM_URL   - real LiteLLM base URL (e.g. http://litellm:4000)
    INJECTION_MODE - openai-metadata | http-header | none
    CONFIG_MOUNT   - ConfigMap mount path (default /etc/agent/metadata)
"""

import json
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Lock
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

SIDECAR_PORT = int(os.environ.get("SIDECAR_PORT", "4001"))
UPSTREAM_URL = (os.environ.get("UPSTREAM_URL") or "http://localhost:4000").rstrip("/")
INJECTION_MODE = (os.environ.get("INJECTION_MODE") or "openai-metadata").strip().lower()

# Directory where the agent-metadata ConfigMap is mounted.
# The same ConfigMap is mounted by the agent container; sidecar gets its own
# volumeMount pointing here so it sees live updates within ~60 s.
CONFIG_MOUNT = os.environ.get("CONFIG_MOUNT", "/etc/agent/metadata")

_CONTEXT_KEYS = (
    # NOTIFY_ID is the only experiment identifier the sidecar needs — it
    # becomes trace_id so all LLM calls for this run land in one Langfuse
    # trace. EXPERIMENT_ID, EXPERIMENT_RUN_ID, WORKFLOW_NAME are deliberately
    # excluded: injecting them into LLM metadata would correlate the observer
    # to the experiment in the observability store, breaking blind-observer
    # integrity. Experiment-correlation is handled server-side (GraphQL layer).
    "NOTIFY_ID",
    "AGENT_NAME",
    "AGENT_ROLE",
    "AGENT_ID",
    "AGENT_VERSION",
)

# Headers to strip (hop-by-hop)
_HOP_HEADERS = frozenset(("host", "transfer-encoding"))

# Thread-safe state shared across requests
_CONTEXT_LOCK = Lock()
_LAST_CONTEXT: dict = {}
_LAST_TRACE_ID: str = ""


def _load_context() -> dict:
    """Read experiment context from ConfigMap mount with env-var fallback.

    Reading from files on each request means the sidecar always uses the
    current experiment's IDs even for long-running Deployment pods where
    env vars were frozen at pod-startup time.
    """
    ctx = {}
    for key in _CONTEXT_KEYS:
        val = ""
        file_path = os.path.join(CONFIG_MOUNT, key)
        try:
            with open(file_path) as fh:
                val = fh.read().strip()
        except (FileNotFoundError, IOError):
            val = ""
        if not val:
            # Fall back to env var when the file is missing OR empty.
            # AGENT_ID in particular starts empty in the ConfigMap and is
            # only populated after helmUpgradeWithAgentID runs, so the env
            # var (set from .Values.agentId) may carry the value first.
            val = os.environ.get(key, "")
        if val:
            ctx[key.lower()] = val

    with _CONTEXT_LOCK:
        cached = dict(_LAST_CONTEXT)
        merged = dict(ctx)

        # Merge cached context from the previous request if notify_id matches
        # (guards against transient ConfigMap read races on long-running pods).
        same_experiment = (
            bool(ctx.get("notify_id"))
            and ctx.get("notify_id") == cached.get("notify_id")
        )

        if cached and same_experiment:
            for key, value in cached.items():
                merged.setdefault(key, value)

        if merged.get("notify_id"):
            _LAST_CONTEXT.clear()
            _LAST_CONTEXT.update(merged)

        return merged


def _remember_trace_id(trace_id: str, context: dict) -> None:
    global _LAST_TRACE_ID

    if not trace_id:
        return

    with _CONTEXT_LOCK:
        if _LAST_TRACE_ID and _LAST_TRACE_ID != trace_id:
            print(
                "[agent-sidecar] trace_id switched "
                f"from={_LAST_TRACE_ID} to={trace_id} "
                f"notify_id={context.get('notify_id', '')}"
            )
        _LAST_TRACE_ID = trace_id


def _detect_generation_name(messages: list) -> str | None:
    """Return a meaningful generation label based on the prompt content.

    Langfuse uses generation_name to label individual spans within a trace,
    so the kubernetes routing call and the analysis call show up as distinct
    named observations rather than both appearing as 'litellm-acompletion'.
    """
    for msg in messages:
        content = msg.get("content", "")
        if not isinstance(content, str):
            continue
        lower = content.lower()
        if "routing agent" in lower or "choose the best data source" in lower:
            return "tool-selection"
        if "expert system-analysis" in lower or "fault-injection" in lower:
            return "llm-analysis"
    return None


class ProxyHandler(BaseHTTPRequestHandler):
    """Forward requests to upstream LiteLLM, injecting metadata on POST."""

    def do_POST(self):
        body = self._read_body()
        context = _load_context()
        extra_headers = {}

        # Always attempt injection even when context is empty — the agent may
        # have already placed generation_name / step in metadata and we must
        # not drop those.  When context IS populated (ConfigMap has live
        # experiment IDs) we overwrite the canonical Langfuse fields with
        # fresh values so stale startup-time env vars in the agent don't win.
        if body:
            if INJECTION_MODE == "openai-metadata":
                body = self._inject_metadata(body, context)
            elif INJECTION_MODE == "http-header" and context:
                extra_headers = self._build_context_headers(context)

        self._proxy(body, extra_headers=extra_headers)

    def do_GET(self):
        self._proxy(None)

    def do_PUT(self):
        self._proxy(self._read_body())

    def do_DELETE(self):
        self._proxy(None)

    def do_OPTIONS(self):
        self._proxy(None)

    # ── helpers ──────────────────────────────────────────────────────

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length) if length > 0 else b""

    @staticmethod
    def _inject_metadata(body: bytes, context: dict) -> bytes:
        """Merge live experiment context into the top-level 'metadata' dict.

        The OpenAI Python SDK sends ``extra_body={"metadata": {...}}``
        which becomes a top-level ``metadata`` key in the HTTP JSON body.
        LiteLLM reads this and forwards it to Langfuse.

        Key Langfuse fields set here:
          trace_id        – groups ALL LLM calls for this experiment run into
                            ONE Langfuse trace (reads live from ConfigMap mount
                            so it is always the current experiment's value)
          trace_name      – human-readable trace / experiment name
          generation_name – distinguishes "tool-selection" vs "llm-analysis"
                            so both appear as named spans inside the trace
          session_id      – experiment definition id
          user_id         – experiment run id
                    agent_name      – agent identity, dynamically injected from context
                    agent_role      – optional agent role from context
        """
        try:
            data = json.loads(body)
            if not isinstance(data, dict):
                return body

            metadata = data.get("metadata")
            if not isinstance(metadata, dict):
                metadata = {}
                data["metadata"] = metadata

            # Spread raw context fields (notify_id, experiment_id, etc.)
            metadata.update(context)

            # Canonical Langfuse trace id – all LLM calls for this experiment
            # run share the same id so they nest as observations in one trace.
            #
            # Priority: ConfigMap-fresh values ALWAYS beat whatever the agent
            # sent in metadata.trace_id.  The agent's value may be frozen from
            # pod-startup env vars and refer to an older experiment run.
            canonical_trace_id = (
                context.get("notify_id")          # ConfigMap-fresh, highest priority
                or metadata.get("trace_id")        # agent-provided fallback (may be stale)
            )
            if canonical_trace_id:
                metadata["trace_id"] = canonical_trace_id
                _remember_trace_id(canonical_trace_id, context)
            else:
                print(
                    "[agent-sidecar] missing trace_id for LLM request "
                    f"notify_id={context.get('notify_id', '')}"
                )

            # Named generation label – distinguishes routing and analysis calls.
            if "generation_name" not in metadata:
                gen_name = _detect_generation_name(data.get("messages", []))
                if gen_name:
                    metadata["generation_name"] = gen_name

            # notify_id is emitted as a top-level key so it is directly visible
            # on the Langfuse observation (not buried under requester_metadata).
            # Experiment-correlation identifiers (experiment_id, experiment_run_id,
            # workflow_name) are NOT injected here — they are linked server-side.
            if context.get("notify_id"):
                metadata["notify_id"] = context["notify_id"]

            # Agent identity for filtering/comparison across different agents.
            # Use explicit keys (not just context spread) so naming is always
            # consistent: agent_id, agent_name, agent_role (snake_case).
            if "agent_id" in context:
                metadata["agent_id"] = context["agent_id"]
            if "agent_name" in context:
                metadata["agent_name"] = context["agent_name"]
            if "agent_version" in context:
                metadata["agent_version"] = context["agent_version"]
            if "agent_role" in context:
                metadata.setdefault("agent_role", context["agent_role"])
            # agent_platform comes from the agent body (not sidecar context),
            # preserve it if already set by the agent.
            if context.get("agent_platform"):
                metadata.setdefault("agent_platform", context["agent_platform"])

            return json.dumps(data).encode("utf-8")
        except (json.JSONDecodeError, ValueError):
            pass  # non-JSON body – forward as-is
        return body

    @staticmethod
    def _build_context_headers(context: dict) -> dict:
        """Return experiment context as X-Experiment-* HTTP headers."""
        return {
            f"X-Experiment-{k.replace('_', '-').title()}": v
            for k, v in context.items()
        }

    def _proxy(self, body, *, extra_headers=None):
        upstream = f"{UPSTREAM_URL}{self.path}"

        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in _HOP_HEADERS
        }
        if extra_headers:
            headers.update(extra_headers)
        if body is not None:
            headers["Content-Length"] = str(len(body))

        try:
            req = Request(upstream, data=body, headers=headers, method=self.command)
            with urlopen(req, timeout=300) as resp:
                resp_body = resp.read()
                self.send_response(resp.status)
                for key, val in resp.getheaders():
                    if key.lower() not in ("transfer-encoding",):
                        self.send_header(key, val)
                self.end_headers()
                self.wfile.write(resp_body)
        except HTTPError as e:
            resp_body = e.read()
            self.send_response(e.code)
            for key, val in e.headers.items():
                if key.lower() not in ("transfer-encoding",):
                    self.send_header(key, val)
            self.end_headers()
            self.wfile.write(resp_body)
        except URLError as e:
            self.send_error(502, f"Upstream unreachable: {e.reason}")

    def log_message(self, fmt, *args):
        print(f"[agent-sidecar] {self.client_address[0]} {args[0]}", flush=True)


def main():
    print(f"[agent-sidecar] Starting on :{SIDECAR_PORT} -> {UPSTREAM_URL} mode={INJECTION_MODE}", flush=True)
    print(f"[agent-sidecar] Config mount: {CONFIG_MOUNT} (dynamic per-request reads)", flush=True)
    server = HTTPServer(("0.0.0.0", SIDECAR_PORT), ProxyHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
