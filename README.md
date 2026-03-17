# Grafana Assistant Demo

Demo application for showcasing Grafana Assistant's ability to investigate
observability issues and open pull requests with fixes.

## Architecture

Three FastAPI microservices in a linear chain:

```
API Gateway (:8000) → Order Service (:8001) → Inventory Service (:8002)
```

Instrumented with OpenTelemetry (traces, metrics, logs) and Pyroscope (CPU profiling).
Feature flags via Flagd control failure modes.

## Quick Start

1. Copy `.env.example` to `.env` and fill in your Grafana Cloud credentials
2. Run: `docker compose up --build -d`
3. Verify: `curl http://localhost:8000/health`
4. Watch traffic: `docker compose logs -f load-generator`

## Failure Scenarios

Toggle by editing `flagd/flags.json` and changing `defaultVariant` to `"on"`:

| Flag | Effect |
|------|--------|
| `slow-order-processing` | Order Service uses CPU-burning O(n²) code path |
| `bad-inventory-config` | Inventory Service loads broken database config |
| `memory-leak` | Order Service leaks memory on every request |

## Reset

```bash
./scripts/reset-demo.sh
```

## Grafana Assistant

Configure the Assistant with:
- GitHub MCP server (`https://api.githubcopilot.com/mcp/`) for code browsing and PR creation
- Access to Tempo, Mimir, Loki, and Pyroscope data sources

Then ask: "Investigate why the latency SLO is burning fast" or similar.
