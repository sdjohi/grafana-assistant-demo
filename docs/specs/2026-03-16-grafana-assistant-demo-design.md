# Grafana Assistant Demo — Design Spec

## Overview

A demo application showcasing Grafana Assistant's ability to investigate observability issues and submit code fixes as pull requests. The demo consists of three FastAPI microservices instrumented with OpenTelemetry and Pyroscope (`pyroscope-io` SDK via `grafana/pyroscope-rs`). Failure modes are controlled by feature flags (Flagd). When an issue is detected, a human asks the Grafana Assistant to investigate. The Assistant queries traces, profiles, logs, and metrics, identifies the root cause, and opens a PR on GitHub with a fix.

## Architecture

### Service Topology

Linear chain of three FastAPI (Python) services:

```
API Gateway (8000) → Order Service (8001) → Inventory Service (8002)
```

- **API Gateway** — public entry point. Exposes `POST /orders` and `GET /orders/{id}`. Forwards requests to Order Service.
- **Order Service** — business logic. Processes orders and calls Inventory Service to check/reserve stock. Hosts Scenario 1 (slow code) and Scenario 3 (memory leak) failure modes.
- **Inventory Service** — data layer. Manages stock levels with an in-memory or SQLite store. Hosts Scenario 2 (bad config) failure mode.

### Infrastructure (Docker Compose)

| Container | Port | Purpose |
|---|---|---|
| `api-gateway` | 8000 | FastAPI service, public entry point |
| `order-service` | 8001 | FastAPI service, business logic |
| `inventory-service` | 8002 | FastAPI service, data layer |
| `flagd` | 8013 (gRPC) | Feature flag server |
| `otel-collector` | 4317 (OTLP gRPC) | Receives OTLP, ships to Grafana Cloud |
| `load-generator` | — | Constant traffic against API Gateway |

Services define health check endpoints (`GET /health`) and use `depends_on` with `condition: service_healthy` to ensure correct startup order: Flagd + OTel Collector start first, then Inventory Service, then Order Service, then API Gateway, then load generator.

### Grafana Cloud

All telemetry backends and UI hosted in Grafana Cloud:

- **Tempo** — distributed traces
- **Mimir** — metrics (via Prometheus remote write)
- **Loki** — logs
- **Pyroscope** — continuous profiles (received from `pyroscope-io` SDK in each service)
- **Grafana Assistant** — AI investigation and remediation

### MCP Server

GitHub's hosted MCP server at `https://api.githubcopilot.com/mcp/` with PAT authentication. No self-hosted MCP infrastructure needed. Verify whether a GitHub Copilot subscription is required or if a standard PAT with `repo` scope suffices.

### Source Code Repository

Monorepo on GitHub.

## Configuration & Secrets

All external endpoints and credentials are provided via environment variables, defined in a `.env` file (gitignored) with an `.env.example` template committed to the repo.

| Variable | Purpose |
|---|---|
| `GRAFANA_CLOUD_TEMPO_ENDPOINT` | Tempo OTLP endpoint URL |
| `GRAFANA_CLOUD_MIMIR_ENDPOINT` | Mimir remote write endpoint URL |
| `GRAFANA_CLOUD_LOKI_ENDPOINT` | Loki OTLP endpoint URL |
| `GRAFANA_CLOUD_PYROSCOPE_ENDPOINT` | Pyroscope endpoint URL |
| `GRAFANA_CLOUD_USER` | Grafana Cloud instance user ID |
| `GRAFANA_CLOUD_API_KEY` | Grafana Cloud API key |
| `GITHUB_PAT` | GitHub PAT for MCP server (repo scope) |

The `.env` file is mounted into the OTel Collector container. Application services need the OTel Collector address (`otel-collector:4317`) for traces/metrics/logs, and the Pyroscope endpoint + credentials for profiling.

## Feature Flags (Flagd)

Flagd runs as a container, serving flag evaluations over gRPC (port 8013). Services use the OpenFeature Python SDK with the Flagd provider. Flags are defined in `flagd/flags.json` and Flagd watches the file for changes — no restart needed.

| Flag Key | Default | When Enabled | Affected Service |
|---|---|---|---|
| `slow-order-processing` | `false` | Order Service uses a CPU-burning O(n²) computation instead of the efficient code path | Order Service |
| `bad-inventory-config` | `false` | Inventory Service loads a malformed database URL, causing connection errors (500s) | Inventory Service |
| `memory-leak` | `false` | Order Service appends to a module-level list on every request, never clearing it | Order Service |

## Observability Instrumentation

### OpenTelemetry (per service)

- `opentelemetry-instrument` auto-instrumentation for FastAPI (traces + metrics)
- Manual span creation for key business logic functions (so slow/leaking functions are clearly named in traces)
- OTel SDK exports to the OTel Collector via OTLP gRPC (`otel-collector:4317`)
- Python `logging` with OTel log bridge for structured JSON logs with trace/span ID correlation
- OTel runtime metrics enabled (exposes `process_resident_memory_bytes` and other process metrics)

### Continuous Profiling (Pyroscope SDK)

Each service integrates `pyroscope-io` (from `grafana/pyroscope-rs`) for continuous CPU and memory profiling:

```python
import pyroscope

pyroscope.configure(
    application_name="order-service",
    server_address="<GRAFANA_CLOUD_PYROSCOPE_ENDPOINT>",
    basic_auth_username="<GRAFANA_CLOUD_USER>",
    basic_auth_password="<GRAFANA_CLOUD_API_KEY>",
    oncpu=True,
    enable_logging=True,
    tags={"service": "order-service"}
)
```

- CPU profiling (`oncpu=True`) captures hot functions for Scenario 1
- `pyroscope.tag_wrapper()` used around key code paths for clear labeling in profiles:
  ```python
  with pyroscope.tag_wrapper({"function": "process_order_slow"}):
      process_order_slow(order)
  ```
- Profiles sent directly to Grafana Cloud Pyroscope (not through OTel Collector)

### OTel Collector

Uses the **contrib** distribution (`otel/opentelemetry-collector-contrib`) for Loki exporter support.

- Receives: OTLP gRPC (traces, metrics, logs) from all services on port 4317
- Exports traces → Grafana Cloud Tempo (OTLP/HTTP)
- Exports metrics → Grafana Cloud Mimir (Prometheus remote write)
- Exports logs → Grafana Cloud Loki (Loki exporter)

## Grafana Cloud Configuration

### Dashboards

- **Service Overview** — request rate, error rate, latency p50/p95/p99 per service
- **SLO Dashboard** — latency SLO burn rate visualization

### SLOs

- Latency SLO on API Gateway: 99% of requests < 500ms over a 30-day window
- Error rate SLO: 99.5% success rate

### Alerts

- SLO burn rate alert (fast burn): fires when error budget burns at 14x allowed rate over 1 hour
- Error rate alert on Inventory Service: fires when 5xx rate exceeds 5%

### Setup

Dashboards, SLOs, and alerts configured manually in the Grafana Cloud UI.

## Grafana Assistant Skill — "Investigate and Fix"

The skill instructs the Assistant to follow this workflow:

1. **Investigate** — query Tempo for slow/error traces, query Pyroscope for hot functions, query Loki for error logs, query Mimir for metric anomalies (e.g., `http_server_duration_seconds_bucket`, `process_resident_memory_bytes`)
2. **Identify root cause** — correlate findings across signals
3. **Locate the code** — use GitHub MCP `get_file_contents` to browse the repo and find the offending code
4. **Generate a fix** — determine the minimal code change needed
5. **Open a PR** — `create_branch` → `push_files` with the fix → `create_pull_request`

### MCP servers the Assistant needs

- GitHub hosted MCP (`https://api.githubcopilot.com/mcp/`) — repo browsing, branch creation, file push, PR creation
- Grafana built-in data source capabilities — Tempo, Loki, Mimir, Pyroscope queries

## Failure Scenarios (Detail)

### Design Principle

Both the good and bad code paths exist in the codebase. The feature flag selects which one runs. The Assistant's "fix" is always a code change that removes the bad path or switches to the good one. This keeps PR diffs small and readable, and makes the pattern consistent across all scenarios.

### Scenario 1 — Slow Order Processing (SLO Burn)

- **Trigger:** Set `slow-order-processing` flag to `true`
- **Effect:** Order Service switches from efficient `process_order()` to `process_order_slow()` containing a CPU-burning O(n²) nested loop (actual computation, not `time.sleep()` — so CPU profiling captures it)
- **What the Assistant sees:**
  - Tempo: Order Service spans taking 2-3 seconds
  - Pyroscope: `process_order_slow()` dominating CPU time in the Order Service profile
  - Mimir: `http_server_duration_seconds_bucket` showing latency spike
  - SLO burn rate alert fires
- **The fix:** One-line change in the route handler to call `process_order()` instead of `process_order_slow()`

### Scenario 2 — Bad Inventory Config

- **Trigger:** Set `bad-inventory-config` flag to `true`
- **Effect:** Inventory Service's `config.py` has both a valid and invalid database URL. The flag causes the service to load the invalid one, resulting in connection errors on every request.
- **What the Assistant sees:**
  - Tempo: Inventory Service spans failing with 500s
  - Loki: Repeated connection error logs with the malformed URL
  - Mimir: Error rate spike on `http_server_request_count` with status 5xx
  - Error rate alert fires
- **The fix:** Change `config.py` to always use the valid database URL (remove the flag-conditional branch)

### Scenario 3 — Memory Leak

- **Trigger:** Set `memory-leak` flag to `true`
- **Effect:** Order Service appends data to a module-level list on every request, never clearing it. Memory grows over time.
- **What the Assistant sees:**
  - Mimir: `process_resident_memory_bytes` for Order Service growing steadily
  - Pyroscope: Memory allocation profiles showing `leak_memory()` via `pyroscope-io` memory profiling
  - Loki: Potential OOM warnings or GC pressure logs
- **The fix:** Remove the append to the global list (scope data to the request lifecycle)

## Load Generator

A Python script (`load-generator/generate.py`) using `httpx` to send constant traffic:

- `POST /orders` with randomized order payloads — primary traffic path
- `GET /orders/{id}` for read traffic — secondary path
- Rate: ~5 requests/second (configurable via environment variable)
- **Not** instrumented with OTel (to avoid polluting traces with synthetic traffic)
- Runs as a Docker container with its own `Dockerfile` and `requirements.txt`

## Demo Flow

### Setup (before demo)

1. Clone the repo, copy `.env.example` to `.env`, fill in Grafana Cloud credentials and GitHub PAT
2. `docker-compose up` — starts all services, Flagd, OTel Collector, load generator
3. Verify baseline traffic in Grafana Cloud: dashboards show healthy metrics, SLOs green

### During Demo (example: Scenario 1)

1. **Flip the flag** — edit `flagd/flags.json`, set `slow-order-processing` to `true`
2. **Wait 2-5 minutes** — latency SLO burn rate climbs, alert fires
3. **Ask the Assistant** — "Investigate why the latency SLO for api-gateway is burning fast"
4. **Assistant investigates** — queries Tempo (slow spans in Order Service), Pyroscope (`process_order_slow()` is hot), Loki (slow query warnings)
5. **Assistant identifies root cause** — explains the inefficient function and that an efficient version exists
6. **Assistant opens a PR** — creates branch, pushes the one-line fix, opens PR on GitHub
7. **Human reviews and merges** — diff is small and obvious
8. **(Optional)** Flip the flag back off to show immediate recovery

### Reset Between Demos

To restore the repo to its original state between demo runs or scenarios:

- Revert the merged PR (GitHub's "Revert" button creates a revert PR)
- Or: maintain a `demo-base` branch and force-reset `main` to it before each run
- Or: use a script (`scripts/reset-demo.sh`) that restores the original files via `git checkout`

## Key Dependencies (per service)

```
# FastAPI services
fastapi
uvicorn
httpx                                    # Inter-service HTTP calls

# OpenTelemetry
opentelemetry-api
opentelemetry-sdk
opentelemetry-instrumentation-fastapi
opentelemetry-exporter-otlp
opentelemetry-instrumentation-logging

# Feature flags
openfeature-sdk
openfeature-provider-flagd

# Profiling
pyroscope-io
```

```
# Load generator
httpx
```

## Project Structure

```
grafana-ai-demo/
├── services/
│   ├── api-gateway/
│   │   ├── app/
│   │   │   ├── main.py
│   │   │   └── routes.py
│   │   ├── Dockerfile
│   │   └── requirements.txt
│   ├── order-service/
│   │   ├── app/
│   │   │   ├── main.py
│   │   │   ├── routes.py
│   │   │   └── processing.py       # Good + bad code paths
│   │   ├── Dockerfile
│   │   └── requirements.txt
│   └── inventory-service/
│       ├── app/
│       │   ├── main.py
│       │   ├── routes.py
│       │   └── config.py            # Good + bad config values
│       ├── Dockerfile
│       └── requirements.txt
├── flagd/
│   └── flags.json
├── otel-collector/
│   └── config.yaml
├── load-generator/
│   ├── generate.py
│   ├── Dockerfile
│   └── requirements.txt
├── scripts/
│   └── reset-demo.sh
├── docker-compose.yml
├── .env.example
├── .gitignore
└── docs/
    └── specs/
```
