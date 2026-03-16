# Grafana Assistant Demo Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a three-service FastAPI demo instrumented with OpenTelemetry and Pyroscope, with Flagd-controlled failure modes, for showcasing Grafana Assistant's investigate-and-fix workflow.

**Architecture:** Three FastAPI services in a linear chain (API Gateway → Order Service → Inventory Service), orchestrated via Docker Compose. Feature flags (Flagd) toggle failure modes. OTel Collector ships traces/metrics/logs to Grafana Cloud. Pyroscope SDK sends profiles directly to Grafana Cloud.

**Tech Stack:** Python 3.12, FastAPI, httpx, OpenTelemetry (auto-instrumentation + OTLP), pyroscope-io, OpenFeature + Flagd, Docker Compose, otel-collector-contrib

**Spec:** `docs/specs/2026-03-16-grafana-assistant-demo-design.md`

---

## Chunk 1: Project Scaffolding & Base Services

### Task 1: Project Scaffolding

**Files:**
- Create: `.gitignore`
- Create: `.env.example`

- [ ] **Step 1: Create `.gitignore`**

```
__pycache__/
*.pyc
.env
.venv/
*.egg-info/
dist/
build/
```

- [ ] **Step 2: Create `.env.example`**

```bash
# Grafana Cloud
GRAFANA_CLOUD_TEMPO_ENDPOINT=https://tempo-us-central1.grafana.net:443
GRAFANA_CLOUD_MIMIR_ENDPOINT=https://mimir-us-central1.grafana.net/api/v1/push
GRAFANA_CLOUD_LOKI_ENDPOINT=https://logs-us-central1.grafana.net
GRAFANA_CLOUD_PYROSCOPE_ENDPOINT=https://profiles-prod-us-central1.grafana.net
GRAFANA_CLOUD_USER=123456
GRAFANA_CLOUD_API_KEY=glc_xxx

# Base64-encoded auth for OTel Collector: echo -n "<user>:<api_key>" | base64
GRAFANA_CLOUD_AUTH=MTIzNDU2OmdsY194eHg=

# GitHub (for Grafana Assistant MCP — used in Grafana Cloud UI, not by containers)
GITHUB_PAT=ghp_xxx
```

- [ ] **Step 3: Commit**

```bash
git init
git add .gitignore .env.example
git commit -m "chore: project scaffolding"
```

---

### Task 2: Inventory Service (Base)

Build the downstream service first so we can test the chain incrementally.

**Files:**
- Create: `services/inventory-service/app/__init__.py`
- Create: `services/inventory-service/app/main.py`
- Create: `services/inventory-service/app/routes.py`
- Create: `services/inventory-service/app/config.py`
- Create: `services/inventory-service/requirements.txt`
- Create: `services/inventory-service/Dockerfile`

- [ ] **Step 1: Create `services/inventory-service/app/__init__.py`**

Empty file.

- [ ] **Step 2: Create `services/inventory-service/requirements.txt`**

```
fastapi==0.115.13
uvicorn==0.34.0
httpx==0.28.1
```

- [ ] **Step 3: Create `services/inventory-service/app/config.py`**

This will later hold both good and bad config values. For now, just the good path.

```python
VALID_DATABASE_URL = "sqlite:///./inventory.db"

def get_database_url() -> str:
    return VALID_DATABASE_URL
```

- [ ] **Step 4: Create `services/inventory-service/app/routes.py`**

```python
import logging
from fastapi import APIRouter

logger = logging.getLogger(__name__)

router = APIRouter()

# In-memory inventory store
_inventory: dict[str, int] = {
    "WIDGET-001": 100,
    "WIDGET-002": 50,
    "GADGET-001": 200,
    "GADGET-002": 75,
}


@router.get("/health")
async def health():
    return {"status": "healthy"}


@router.get("/inventory/{item_id}")
async def get_inventory(item_id: str):
    logger.info("Checking inventory for item %s", item_id)
    quantity = _inventory.get(item_id, 0)
    return {"item_id": item_id, "quantity": quantity}


@router.post("/inventory/{item_id}/reserve")
async def reserve_inventory(item_id: str, quantity: int = 1):
    logger.info("Reserving %d of item %s", quantity, item_id)
    current = _inventory.get(item_id, 0)
    if current < quantity:
        logger.warning("Insufficient stock for %s: have %d, need %d", item_id, current, quantity)
        return {"success": False, "message": "Insufficient stock", "available": current}
    _inventory[item_id] = current - quantity
    return {"success": True, "reserved": quantity, "remaining": _inventory[item_id]}
```

- [ ] **Step 5: Create `services/inventory-service/app/main.py`**

```python
from fastapi import FastAPI
from app.routes import router

app = FastAPI(title="Inventory Service")
app.include_router(router)
```

- [ ] **Step 6: Create `services/inventory-service/Dockerfile`**

```dockerfile
FROM python:3.12

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ app/

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8002"]
```

- [ ] **Step 7: Verify locally**

```bash
cd services/inventory-service
pip install -r requirements.txt
uvicorn app.main:app --port 8002 &
curl http://localhost:8002/health
curl http://localhost:8002/inventory/WIDGET-001
# Expected: {"item_id":"WIDGET-001","quantity":100}
kill %1
```

- [ ] **Step 8: Commit**

```bash
git add services/inventory-service/
git commit -m "feat: add inventory service base"
```

---

### Task 3: Order Service (Base)

**Files:**
- Create: `services/order-service/app/__init__.py`
- Create: `services/order-service/app/main.py`
- Create: `services/order-service/app/routes.py`
- Create: `services/order-service/app/processing.py`
- Create: `services/order-service/requirements.txt`
- Create: `services/order-service/Dockerfile`

- [ ] **Step 1: Create `services/order-service/app/__init__.py`**

Empty file.

- [ ] **Step 2: Create `services/order-service/requirements.txt`**

```
fastapi==0.115.13
uvicorn==0.34.0
httpx==0.28.1
```

- [ ] **Step 3: Create `services/order-service/app/processing.py`**

Contains both good and bad code paths. The bad path will be activated by feature flags in Chunk 2.

```python
import logging

logger = logging.getLogger(__name__)


def process_order(order: dict) -> dict:
    """Efficient order processing — the good path."""
    total = sum(item["price"] * item["quantity"] for item in order["items"])
    return {
        "order_id": order["order_id"],
        "total": round(total, 2),
        "status": "processed",
    }


def process_order_slow(order: dict) -> dict:
    """Intentionally slow O(n^2) order processing — the bad path.

    Burns CPU with unnecessary nested computation so Pyroscope captures it.
    """
    logger.warning("Using slow order processing path")
    total = 0.0
    items = order["items"]
    # O(n^2) unnecessary recomputation
    for i, item in enumerate(items):
        subtotal = 0.0
        for j in range(len(items)):
            if j <= i:
                subtotal += items[j]["price"] * items[j]["quantity"]
        # Burn more CPU with pointless work
        _waste = sum(k * k for k in range(5_000_000))
        total = subtotal
    return {
        "order_id": order["order_id"],
        "total": round(total, 2),
        "status": "processed",
    }


# Module-level list for memory leak scenario
_leaked_data: list = []


def leak_memory(order: dict) -> None:
    """Appends order data to a module-level list that is never cleared."""
    logger.warning("Leaking memory: _leaked_data size = %d", len(_leaked_data))
    _leaked_data.append({
        "order": order,
        "padding": "x" * 10000,  # Make the leak grow faster
    })
```

- [ ] **Step 4: Create `services/order-service/app/routes.py`**

```python
import logging
import uuid
import os

import httpx
from fastapi import APIRouter, HTTPException

from app.processing import process_order

logger = logging.getLogger(__name__)

router = APIRouter()

INVENTORY_SERVICE_URL = os.environ.get("INVENTORY_SERVICE_URL", "http://localhost:8002")

# In-memory order store
_orders: dict[str, dict] = {}


@router.get("/health")
async def health():
    return {"status": "healthy"}


@router.post("/orders")
async def create_order(items: list[dict]):
    order_id = str(uuid.uuid4())
    order = {"order_id": order_id, "items": items}

    logger.info("Creating order %s with %d items", order_id, len(items))

    # Check inventory for each item
    async with httpx.AsyncClient() as client:
        for item in items:
            resp = await client.post(
                f"{INVENTORY_SERVICE_URL}/inventory/{item['item_id']}/reserve",
                params={"quantity": item.get("quantity", 1)},
            )
            if resp.status_code != 200:
                raise HTTPException(status_code=502, detail="Inventory service error")
            result = resp.json()
            if not result["success"]:
                raise HTTPException(status_code=409, detail=f"Insufficient stock for {item['item_id']}")

    # Process the order
    processed = process_order(order)
    _orders[order_id] = processed
    logger.info("Order %s processed successfully", order_id)
    return processed


@router.get("/orders/{order_id}")
async def get_order(order_id: str):
    if order_id not in _orders:
        raise HTTPException(status_code=404, detail="Order not found")
    return _orders[order_id]
```

- [ ] **Step 5: Create `services/order-service/app/main.py`**

```python
from fastapi import FastAPI
from app.routes import router

app = FastAPI(title="Order Service")
app.include_router(router)
```

- [ ] **Step 6: Create `services/order-service/Dockerfile`**

```dockerfile
FROM python:3.12

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ app/

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8001"]
```

- [ ] **Step 7: Commit**

```bash
git add services/order-service/
git commit -m "feat: add order service base"
```

---

### Task 4: API Gateway (Base)

**Files:**
- Create: `services/api-gateway/app/__init__.py`
- Create: `services/api-gateway/app/main.py`
- Create: `services/api-gateway/app/routes.py`
- Create: `services/api-gateway/requirements.txt`
- Create: `services/api-gateway/Dockerfile`

- [ ] **Step 1: Create `services/api-gateway/app/__init__.py`**

Empty file.

- [ ] **Step 2: Create `services/api-gateway/requirements.txt`**

```
fastapi==0.115.13
uvicorn==0.34.0
httpx==0.28.1
```

- [ ] **Step 3: Create `services/api-gateway/app/routes.py`**

```python
import logging
import os

import httpx
from fastapi import APIRouter, HTTPException

logger = logging.getLogger(__name__)

router = APIRouter()

ORDER_SERVICE_URL = os.environ.get("ORDER_SERVICE_URL", "http://localhost:8001")


@router.get("/health")
async def health():
    return {"status": "healthy"}


@router.post("/orders")
async def create_order(items: list[dict]):
    logger.info("Gateway: forwarding order with %d items", len(items))
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{ORDER_SERVICE_URL}/orders",
            json=items,
            timeout=30.0,
        )
    if resp.status_code != 200:
        raise HTTPException(status_code=resp.status_code, detail=resp.json().get("detail", "Order service error"))
    return resp.json()


@router.get("/orders/{order_id}")
async def get_order(order_id: str):
    logger.info("Gateway: fetching order %s", order_id)
    async with httpx.AsyncClient() as client:
        resp = await client.get(f"{ORDER_SERVICE_URL}/orders/{order_id}", timeout=10.0)
    if resp.status_code != 200:
        raise HTTPException(status_code=resp.status_code, detail=resp.json().get("detail", "Order service error"))
    return resp.json()
```

- [ ] **Step 4: Create `services/api-gateway/app/main.py`**

```python
from fastapi import FastAPI
from app.routes import router

app = FastAPI(title="API Gateway")
app.include_router(router)
```

- [ ] **Step 5: Create `services/api-gateway/Dockerfile`**

```dockerfile
FROM python:3.12

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ app/

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

- [ ] **Step 6: Commit**

```bash
git add services/api-gateway/
git commit -m "feat: add api gateway base"
```

---

### Task 5: Basic Docker Compose

**Files:**
- Create: `docker-compose.yml`

- [ ] **Step 1: Create `docker-compose.yml`** with just the three services

```yaml
services:
  inventory-service:
    build: ./services/inventory-service
    ports:
      - "8002:8002"
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8002/health')"]
      interval: 5s
      timeout: 3s
      retries: 5

  order-service:
    build: ./services/order-service
    ports:
      - "8001:8001"
    environment:
      - INVENTORY_SERVICE_URL=http://inventory-service:8002
    depends_on:
      inventory-service:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8001/health')"]
      interval: 5s
      timeout: 3s
      retries: 5

  api-gateway:
    build: ./services/api-gateway
    ports:
      - "8000:8000"
    environment:
      - ORDER_SERVICE_URL=http://order-service:8001
    depends_on:
      order-service:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]
      interval: 5s
      timeout: 3s
      retries: 5
```

- [ ] **Step 2: Build and test the chain**

```bash
docker compose up --build -d
# Wait for services to be healthy
docker compose ps
# Test the full chain
curl -X POST http://localhost:8000/orders \
  -H "Content-Type: application/json" \
  -d '[{"item_id": "WIDGET-001", "price": 9.99, "quantity": 2}]'
# Expected: {"order_id":"...","total":19.98,"status":"processed"}
docker compose down
```

- [ ] **Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add docker compose for base services"
```

---

## Chunk 2: Feature Flags with Flagd

### Task 6: Flagd Configuration

**Files:**
- Create: `flagd/flags.json`

- [ ] **Step 1: Create `flagd/flags.json`**

```json
{
  "$schema": "https://flagd.dev/schema/v0/flags.json",
  "flags": {
    "slow-order-processing": {
      "state": "ENABLED",
      "variants": {
        "on": true,
        "off": false
      },
      "defaultVariant": "off"
    },
    "bad-inventory-config": {
      "state": "ENABLED",
      "variants": {
        "on": true,
        "off": false
      },
      "defaultVariant": "off"
    },
    "memory-leak": {
      "state": "ENABLED",
      "variants": {
        "on": true,
        "off": false
      },
      "defaultVariant": "off"
    }
  }
}
```

- [ ] **Step 2: Add Flagd to `docker-compose.yml`**

Add this service before `inventory-service`:

```yaml
  flagd:
    image: ghcr.io/open-feature/flagd:v0.11.3
    ports:
      - "8013:8013"
    volumes:
      - ./flagd:/flagd
    command:
      - start
      - --uri
      - file:/flagd/flags.json
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:8016/healthz"]
      interval: 5s
      timeout: 3s
      retries: 5
```

Add `depends_on: flagd: condition: service_healthy` to `inventory-service` and `order-service`.

- [ ] **Step 3: Commit**

```bash
git add flagd/ docker-compose.yml
git commit -m "feat: add flagd feature flag configuration"
```

---

### Task 7: OpenFeature Integration in Order Service

**Files:**
- Modify: `services/order-service/requirements.txt`
- Modify: `services/order-service/app/main.py`
- Modify: `services/order-service/app/routes.py`

- [ ] **Step 1: Update `services/order-service/requirements.txt`**

Append:

```
openfeature-sdk==0.7.5
openfeature-provider-flagd==0.4.3
```

- [ ] **Step 2: Update `services/order-service/app/main.py`**

```python
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI
from openfeature import api
from openfeature.contrib.provider.flagd import FlagdProvider

from app.routes import router


@asynccontextmanager
async def lifespan(app: FastAPI):
    flagd_host = os.environ.get("FLAGD_HOST", "localhost")
    flagd_port = int(os.environ.get("FLAGD_PORT", "8013"))
    api.set_provider(FlagdProvider(host=flagd_host, port=flagd_port))
    yield


app = FastAPI(title="Order Service", lifespan=lifespan)
app.include_router(router)
```

- [ ] **Step 3: Update `services/order-service/app/routes.py`**

Replace the import and `create_order` function to use feature flags:

```python
import logging
import uuid
import os

import httpx
from fastapi import APIRouter, HTTPException
from openfeature import api

from app.processing import process_order, process_order_slow, leak_memory

logger = logging.getLogger(__name__)

router = APIRouter()

INVENTORY_SERVICE_URL = os.environ.get("INVENTORY_SERVICE_URL", "http://localhost:8002")

_orders: dict[str, dict] = {}


@router.get("/health")
async def health():
    return {"status": "healthy"}


@router.post("/orders")
async def create_order(items: list[dict]):
    order_id = str(uuid.uuid4())
    order = {"order_id": order_id, "items": items}

    logger.info("Creating order %s with %d items", order_id, len(items))

    # Check inventory for each item
    async with httpx.AsyncClient() as client:
        for item in items:
            resp = await client.post(
                f"{INVENTORY_SERVICE_URL}/inventory/{item['item_id']}/reserve",
                params={"quantity": item.get("quantity", 1)},
            )
            if resp.status_code != 200:
                raise HTTPException(status_code=502, detail="Inventory service error")
            result = resp.json()
            if not result["success"]:
                raise HTTPException(status_code=409, detail=f"Insufficient stock for {item['item_id']}")

    # Feature flag: slow processing
    ff_client = api.get_client()
    use_slow = ff_client.get_boolean_value("slow-order-processing", False)

    if use_slow:
        processed = process_order_slow(order)
    else:
        processed = process_order(order)

    # Feature flag: memory leak
    use_leak = ff_client.get_boolean_value("memory-leak", False)
    if use_leak:
        leak_memory(order)

    _orders[order_id] = processed
    logger.info("Order %s processed successfully", order_id)
    return processed


@router.get("/orders/{order_id}")
async def get_order(order_id: str):
    if order_id not in _orders:
        raise HTTPException(status_code=404, detail="Order not found")
    return _orders[order_id]
```

- [ ] **Step 4: Add Flagd env vars to order-service in `docker-compose.yml`**

Add to the `order-service` environment:

```yaml
      - FLAGD_HOST=flagd
      - FLAGD_PORT=8013
```

- [ ] **Step 5: Commit**

```bash
git add services/order-service/ docker-compose.yml
git commit -m "feat: integrate openfeature flags in order service"
```

---

### Task 8: OpenFeature Integration in Inventory Service

**Files:**
- Modify: `services/inventory-service/requirements.txt`
- Modify: `services/inventory-service/app/main.py`
- Modify: `services/inventory-service/app/config.py`
- Modify: `services/inventory-service/app/routes.py`

- [ ] **Step 1: Update `services/inventory-service/requirements.txt`**

Append:

```
openfeature-sdk==0.7.5
openfeature-provider-flagd==0.4.3
```

- [ ] **Step 2: Update `services/inventory-service/app/config.py`**

```python
import logging
from openfeature import api

logger = logging.getLogger(__name__)

VALID_DATABASE_URL = "sqlite:///./inventory.db"
INVALID_DATABASE_URL = "postgresql://bad-host:5432/nonexistent?connect_timeout=1"


def get_database_url() -> str:
    """Return the database URL based on the feature flag."""
    ff_client = api.get_client()
    use_bad_config = ff_client.get_boolean_value("bad-inventory-config", False)

    if use_bad_config:
        logger.error("Loading INVALID database config: %s", INVALID_DATABASE_URL)
        return INVALID_DATABASE_URL

    return VALID_DATABASE_URL
```

- [ ] **Step 3: Update `services/inventory-service/app/main.py`**

```python
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI
from openfeature import api
from openfeature.contrib.provider.flagd import FlagdProvider

from app.routes import router


@asynccontextmanager
async def lifespan(app: FastAPI):
    flagd_host = os.environ.get("FLAGD_HOST", "localhost")
    flagd_port = int(os.environ.get("FLAGD_PORT", "8013"))
    api.set_provider(FlagdProvider(host=flagd_host, port=flagd_port))
    yield


app = FastAPI(title="Inventory Service", lifespan=lifespan)
app.include_router(router)
```

- [ ] **Step 4: Update `services/inventory-service/app/routes.py`**

Add the config check to the reserve endpoint so that when the bad config flag is on, the service attempts a database connection that fails:

```python
import logging
from fastapi import APIRouter, HTTPException

from app.config import get_database_url

logger = logging.getLogger(__name__)

router = APIRouter()

_inventory: dict[str, int] = {
    "WIDGET-001": 100,
    "WIDGET-002": 50,
    "GADGET-001": 200,
    "GADGET-002": 75,
}


@router.get("/health")
async def health():
    return {"status": "healthy"}


@router.get("/inventory/{item_id}")
async def get_inventory(item_id: str):
    logger.info("Checking inventory for item %s", item_id)

    # Validate config on each request (feature flag may change at runtime)
    db_url = get_database_url()
    if "bad-host" in db_url:
        logger.error("Cannot connect to database: %s", db_url)
        raise HTTPException(status_code=500, detail=f"Database connection failed: {db_url}")

    quantity = _inventory.get(item_id, 0)
    return {"item_id": item_id, "quantity": quantity}


@router.post("/inventory/{item_id}/reserve")
async def reserve_inventory(item_id: str, quantity: int = 1):
    logger.info("Reserving %d of item %s", quantity, item_id)

    db_url = get_database_url()
    if "bad-host" in db_url:
        logger.error("Cannot connect to database: %s", db_url)
        raise HTTPException(status_code=500, detail=f"Database connection failed: {db_url}")

    current = _inventory.get(item_id, 0)
    if current < quantity:
        logger.warning("Insufficient stock for %s: have %d, need %d", item_id, current, quantity)
        return {"success": False, "message": "Insufficient stock", "available": current}
    _inventory[item_id] = current - quantity
    return {"success": True, "reserved": quantity, "remaining": _inventory[item_id]}
```

- [ ] **Step 5: Add Flagd env vars to inventory-service in `docker-compose.yml`**

Add to the `inventory-service` environment:

```yaml
    environment:
      - FLAGD_HOST=flagd
      - FLAGD_PORT=8013
```

- [ ] **Step 6: Test flag toggling**

```bash
docker compose up --build -d
# Test normal path
curl -X POST http://localhost:8000/orders \
  -H "Content-Type: application/json" \
  -d '[{"item_id": "WIDGET-001", "price": 9.99, "quantity": 1}]'
# Expected: 200 OK with processed order

# Edit flagd/flags.json: change "bad-inventory-config" defaultVariant to "on"
# Wait a few seconds for Flagd to pick up the change
curl -X POST http://localhost:8000/orders \
  -H "Content-Type: application/json" \
  -d '[{"item_id": "WIDGET-001", "price": 9.99, "quantity": 1}]'
# Expected: 502 error (inventory service returns 500)

# Revert flagd/flags.json back to "off"
docker compose down
```

- [ ] **Step 7: Commit**

```bash
git add services/inventory-service/ docker-compose.yml
git commit -m "feat: integrate openfeature flags in inventory service"
```

---

## Chunk 3: Observability — OpenTelemetry & Pyroscope

### Task 9: OTel Collector Configuration

**Files:**
- Create: `otel-collector/config.yaml`
- Modify: `docker-compose.yml`

- [ ] **Step 1: Create `otel-collector/config.yaml`**

```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 5s
    send_batch_size: 1024
  resource:
    attributes:
      - key: deployment.environment
        value: demo
        action: upsert

exporters:
  otlphttp/tempo:
    endpoint: ${env:GRAFANA_CLOUD_TEMPO_ENDPOINT}
    headers:
      Authorization: "Basic ${env:GRAFANA_CLOUD_AUTH}"

  prometheusremotewrite:
    endpoint: ${env:GRAFANA_CLOUD_MIMIR_ENDPOINT}
    headers:
      Authorization: "Basic ${env:GRAFANA_CLOUD_AUTH}"

  otlphttp/loki:
    endpoint: ${env:GRAFANA_CLOUD_LOKI_ENDPOINT}/otlp
    headers:
      Authorization: "Basic ${env:GRAFANA_CLOUD_AUTH}"

service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch, resource]
      exporters: [otlphttp/tempo]
    metrics:
      receivers: [otlp]
      processors: [batch, resource]
      exporters: [prometheusremotewrite]
    logs:
      receivers: [otlp]
      processors: [batch, resource]
      exporters: [otlphttp/loki]
```

- [ ] **Step 2: Verify `.env.example` has the auth variable**

The `GRAFANA_CLOUD_AUTH` variable was already added in Task 1. To generate this value:

```bash
echo -n "<GRAFANA_CLOUD_USER>:<GRAFANA_CLOUD_API_KEY>" | base64
```

- [ ] **Step 3: Add OTel Collector to `docker-compose.yml`**

```yaml
  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.115.0
    ports:
      - "4317:4317"
      - "4318:4318"
    volumes:
      - ./otel-collector/config.yaml:/etc/otelcol-contrib/config.yaml
    env_file:
      - .env
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:13133/"]
      interval: 5s
      timeout: 3s
      retries: 5
```

- [ ] **Step 4: Commit**

```bash
git add otel-collector/ .env.example docker-compose.yml
git commit -m "feat: add otel collector config for grafana cloud"
```

---

### Task 10: OpenTelemetry Instrumentation in Services

**Files:**
- Modify: `services/inventory-service/requirements.txt`
- Modify: `services/inventory-service/Dockerfile`
- Modify: `services/order-service/requirements.txt`
- Modify: `services/order-service/Dockerfile`
- Modify: `services/api-gateway/requirements.txt`
- Modify: `services/api-gateway/Dockerfile`
- Modify: `docker-compose.yml`

- [ ] **Step 1: Add OTel dependencies to each service's `requirements.txt`**

Append to all three `requirements.txt` files:

```
opentelemetry-distro==0.50b0
opentelemetry-exporter-otlp==1.29.0
opentelemetry-instrumentation-fastapi==0.50b0
opentelemetry-instrumentation-httpx==0.50b0
opentelemetry-instrumentation-logging==0.50b0
opentelemetry-instrumentation-system-metrics==0.50b0
```

- [ ] **Step 2: Update all three Dockerfiles to use `opentelemetry-instrument`**

Replace the `CMD` line in each Dockerfile:

**`services/api-gateway/Dockerfile`:**
```dockerfile
FROM python:3.12

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ app/

ENV OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
CMD ["opentelemetry-instrument", "--logs_exporter", "otlp", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**`services/order-service/Dockerfile`:**
```dockerfile
FROM python:3.12

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ app/

ENV OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
CMD ["opentelemetry-instrument", "--logs_exporter", "otlp", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8001"]
```

**`services/inventory-service/Dockerfile`:**
```dockerfile
FROM python:3.12

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ app/

ENV OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
CMD ["opentelemetry-instrument", "--logs_exporter", "otlp", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8002"]
```

- [ ] **Step 3: Add OTel environment variables to each service in `docker-compose.yml`**

Add to each of the three services' `environment` sections:

```yaml
      - OTEL_SERVICE_NAME=api-gateway          # or order-service, inventory-service
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
      - OTEL_EXPORTER_OTLP_PROTOCOL=grpc
      - OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
      - OTEL_PYTHON_DISABLED_INSTRUMENTATIONS=  # leave empty to enable all, including system-metrics
```

Add `depends_on` for `otel-collector` to all three services.

- [ ] **Step 4: Add manual spans to Order Service processing**

Modify `services/order-service/app/processing.py` — add tracing to the slow path:

```python
import logging
from opentelemetry import trace

logger = logging.getLogger(__name__)
tracer = trace.get_tracer(__name__)


def process_order(order: dict) -> dict:
    """Efficient order processing — the good path."""
    with tracer.start_as_current_span("process_order"):
        total = sum(item["price"] * item["quantity"] for item in order["items"])
        return {
            "order_id": order["order_id"],
            "total": round(total, 2),
            "status": "processed",
        }


def process_order_slow(order: dict) -> dict:
    """Intentionally slow O(n^2) order processing — the bad path."""
    with tracer.start_as_current_span("process_order_slow"):
        logger.warning("Using slow order processing path")
        total = 0.0
        items = order["items"]
        for i, item in enumerate(items):
            subtotal = 0.0
            for j in range(len(items)):
                if j <= i:
                    subtotal += items[j]["price"] * items[j]["quantity"]
            _waste = sum(k * k for k in range(5_000_000))
            total = subtotal
        return {
            "order_id": order["order_id"],
            "total": round(total, 2),
            "status": "processed",
        }


_leaked_data: list = []


def leak_memory(order: dict) -> None:
    """Appends order data to a module-level list that is never cleared."""
    with tracer.start_as_current_span("leak_memory"):
        logger.warning("Leaking memory: _leaked_data size = %d", len(_leaked_data))
        _leaked_data.append({
            "order": order,
            "padding": "x" * 10000,
        })
```

- [ ] **Step 5: Commit**

```bash
git add services/ docker-compose.yml
git commit -m "feat: add opentelemetry auto-instrumentation to all services"
```

---

### Task 11: Pyroscope Integration

**Files:**
- Modify: `services/order-service/requirements.txt`
- Modify: `services/order-service/app/main.py`
- Modify: `services/order-service/app/processing.py`
- Modify: `services/inventory-service/requirements.txt`
- Modify: `services/inventory-service/app/main.py`
- Modify: `services/api-gateway/requirements.txt`
- Modify: `services/api-gateway/app/main.py`
- Modify: `docker-compose.yml`

- [ ] **Step 1: Add `pyroscope-io` to each service's `requirements.txt`**

Append to all three:

```
pyroscope-io==0.8.7
```

- [ ] **Step 2: Update `services/order-service/app/main.py`** with Pyroscope init

```python
import os
from contextlib import asynccontextmanager

import pyroscope
from fastapi import FastAPI
from openfeature import api
from openfeature.contrib.provider.flagd import FlagdProvider

from app.routes import router


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Feature flags
    flagd_host = os.environ.get("FLAGD_HOST", "localhost")
    flagd_port = int(os.environ.get("FLAGD_PORT", "8013"))
    api.set_provider(FlagdProvider(host=flagd_host, port=flagd_port))

    # Pyroscope
    pyroscope.configure(
        application_name="order-service",
        server_address=os.environ.get("PYROSCOPE_ENDPOINT", "http://localhost:4040"),
        basic_auth_username=os.environ.get("PYROSCOPE_USER", ""),
        basic_auth_password=os.environ.get("PYROSCOPE_PASSWORD", ""),
        oncpu=True,
        enable_logging=True,
        tags={"service": "order-service"},
    )
    yield


app = FastAPI(title="Order Service", lifespan=lifespan)
app.include_router(router)
```

- [ ] **Step 3: Add Pyroscope tag wrappers to `services/order-service/app/processing.py`**

Update the slow and leak functions:

```python
import logging
import pyroscope
from opentelemetry import trace

logger = logging.getLogger(__name__)
tracer = trace.get_tracer(__name__)


def process_order(order: dict) -> dict:
    """Efficient order processing — the good path."""
    with tracer.start_as_current_span("process_order"):
        total = sum(item["price"] * item["quantity"] for item in order["items"])
        return {
            "order_id": order["order_id"],
            "total": round(total, 2),
            "status": "processed",
        }


def process_order_slow(order: dict) -> dict:
    """Intentionally slow O(n^2) order processing — the bad path."""
    with tracer.start_as_current_span("process_order_slow"):
        with pyroscope.tag_wrapper({"function": "process_order_slow"}):
            logger.warning("Using slow order processing path")
            total = 0.0
            items = order["items"]
            for i, item in enumerate(items):
                subtotal = 0.0
                for j in range(len(items)):
                    if j <= i:
                        subtotal += items[j]["price"] * items[j]["quantity"]
                _waste = sum(k * k for k in range(5_000_000))
                total = subtotal
            return {
                "order_id": order["order_id"],
                "total": round(total, 2),
                "status": "processed",
            }


_leaked_data: list = []


def leak_memory(order: dict) -> None:
    """Appends order data to a module-level list that is never cleared."""
    with tracer.start_as_current_span("leak_memory"):
        with pyroscope.tag_wrapper({"function": "leak_memory"}):
            logger.warning("Leaking memory: _leaked_data size = %d", len(_leaked_data))
            _leaked_data.append({
                "order": order,
                "padding": "x" * 10000,
            })
```

- [ ] **Step 4: Update `services/inventory-service/app/main.py`** with Pyroscope init

```python
import os
from contextlib import asynccontextmanager

import pyroscope
from fastapi import FastAPI
from openfeature import api
from openfeature.contrib.provider.flagd import FlagdProvider

from app.routes import router


@asynccontextmanager
async def lifespan(app: FastAPI):
    flagd_host = os.environ.get("FLAGD_HOST", "localhost")
    flagd_port = int(os.environ.get("FLAGD_PORT", "8013"))
    api.set_provider(FlagdProvider(host=flagd_host, port=flagd_port))

    pyroscope.configure(
        application_name="inventory-service",
        server_address=os.environ.get("PYROSCOPE_ENDPOINT", "http://localhost:4040"),
        basic_auth_username=os.environ.get("PYROSCOPE_USER", ""),
        basic_auth_password=os.environ.get("PYROSCOPE_PASSWORD", ""),
        oncpu=True,
        enable_logging=True,
        tags={"service": "inventory-service"},
    )
    yield


app = FastAPI(title="Inventory Service", lifespan=lifespan)
app.include_router(router)
```

- [ ] **Step 5: Update `services/api-gateway/app/main.py`** with Pyroscope init

```python
import os
from contextlib import asynccontextmanager

import pyroscope
from fastapi import FastAPI

from app.routes import router


@asynccontextmanager
async def lifespan(app: FastAPI):
    pyroscope.configure(
        application_name="api-gateway",
        server_address=os.environ.get("PYROSCOPE_ENDPOINT", "http://localhost:4040"),
        basic_auth_username=os.environ.get("PYROSCOPE_USER", ""),
        basic_auth_password=os.environ.get("PYROSCOPE_PASSWORD", ""),
        oncpu=True,
        enable_logging=True,
        tags={"service": "api-gateway"},
    )
    yield


app = FastAPI(title="API Gateway", lifespan=lifespan)
app.include_router(router)
```

- [ ] **Step 6: Add Pyroscope env vars to all services in `docker-compose.yml`**

Add to each service's `environment`:

```yaml
      - PYROSCOPE_ENDPOINT=${GRAFANA_CLOUD_PYROSCOPE_ENDPOINT}
      - PYROSCOPE_USER=${GRAFANA_CLOUD_USER}
      - PYROSCOPE_PASSWORD=${GRAFANA_CLOUD_API_KEY}
```

- [ ] **Step 7: Commit**

```bash
git add services/ docker-compose.yml
git commit -m "feat: add pyroscope continuous profiling to all services"
```

---

## Chunk 4: Load Generator, Reset Script & Final Docker Compose

### Task 12: Load Generator

**Files:**
- Create: `load-generator/generate.py`
- Create: `load-generator/requirements.txt`
- Create: `load-generator/Dockerfile`
- Modify: `docker-compose.yml`

- [ ] **Step 1: Create `load-generator/requirements.txt`**

```
httpx==0.28.1
```

- [ ] **Step 2: Create `load-generator/generate.py`**

```python
import asyncio
import logging
import os
import random

import httpx

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

GATEWAY_URL = os.environ.get("GATEWAY_URL", "http://localhost:8000")
REQUESTS_PER_SECOND = float(os.environ.get("REQUESTS_PER_SECOND", "5"))

ITEMS = ["WIDGET-001", "WIDGET-002", "GADGET-001", "GADGET-002"]


def random_order() -> list[dict]:
    num_items = random.randint(1, 3)
    return [
        {
            "item_id": random.choice(ITEMS),
            "price": round(random.uniform(5.0, 50.0), 2),
            "quantity": random.randint(1, 5),
        }
        for _ in range(num_items)
    ]


async def send_requests():
    delay = 1.0 / REQUESTS_PER_SECOND
    async with httpx.AsyncClient(timeout=30.0) as client:
        while True:
            try:
                if random.random() < 0.8:
                    # 80% POST /orders
                    resp = await client.post(
                        f"{GATEWAY_URL}/orders",
                        json=random_order(),
                    )
                    logger.info("POST /orders -> %d", resp.status_code)
                else:
                    # 20% GET /orders/{id} (will mostly 404, that's fine)
                    fake_id = f"order-{random.randint(1, 100)}"
                    resp = await client.get(f"{GATEWAY_URL}/orders/{fake_id}")
                    logger.info("GET /orders/%s -> %d", fake_id, resp.status_code)
            except Exception as e:
                logger.error("Request failed: %s", e)

            await asyncio.sleep(delay)


if __name__ == "__main__":
    logger.info("Starting load generator: %.1f req/s against %s", REQUESTS_PER_SECOND, GATEWAY_URL)
    asyncio.run(send_requests())
```

- [ ] **Step 3: Create `load-generator/Dockerfile`**

```dockerfile
FROM python:3.12

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY generate.py .

CMD ["python", "generate.py"]
```

- [ ] **Step 4: Add load generator to `docker-compose.yml`**

```yaml
  load-generator:
    build: ./load-generator
    environment:
      - GATEWAY_URL=http://api-gateway:8000
      - REQUESTS_PER_SECOND=5
    depends_on:
      api-gateway:
        condition: service_healthy
    restart: unless-stopped
```

- [ ] **Step 5: Commit**

```bash
git add load-generator/ docker-compose.yml
git commit -m "feat: add load generator"
```

---

### Task 13: Reset Script

**Files:**
- Create: `scripts/reset-demo.sh`

- [ ] **Step 1: Create `scripts/reset-demo.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "Resetting demo to clean state..."

# Reset feature flags to all off
cat > flagd/flags.json << 'EOF'
{
  "$schema": "https://flagd.dev/schema/v0/flags.json",
  "flags": {
    "slow-order-processing": {
      "state": "ENABLED",
      "variants": {
        "on": true,
        "off": false
      },
      "defaultVariant": "off"
    },
    "bad-inventory-config": {
      "state": "ENABLED",
      "variants": {
        "on": true,
        "off": false
      },
      "defaultVariant": "off"
    },
    "memory-leak": {
      "state": "ENABLED",
      "variants": {
        "on": true,
        "off": false
      },
      "defaultVariant": "off"
    }
  }
}
EOF

echo "Feature flags reset to default (all off)."

# Restart services to clear in-memory state (leaked data, orders)
docker compose restart order-service inventory-service api-gateway

echo "Services restarted. Demo is ready."
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/reset-demo.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/
git commit -m "feat: add demo reset script"
```

---

### Task 14: Final Docker Compose Assembly

**Files:**
- Modify: `docker-compose.yml`

- [ ] **Step 1: Write the complete `docker-compose.yml`**

This is the final assembled version with all services, correct ordering, and all environment variables:

```yaml
services:
  flagd:
    image: ghcr.io/open-feature/flagd:v0.11.3
    ports:
      - "8013:8013"
    volumes:
      - ./flagd:/flagd
    command:
      - start
      - --uri
      - file:/flagd/flags.json
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:8016/healthz"]
      interval: 5s
      timeout: 3s
      retries: 5

  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.115.0
    ports:
      - "4317:4317"
      - "4318:4318"
    volumes:
      - ./otel-collector/config.yaml:/etc/otelcol-contrib/config.yaml
    env_file:
      - .env
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:13133/"]
      interval: 5s
      timeout: 3s
      retries: 5

  inventory-service:
    build: ./services/inventory-service
    ports:
      - "8002:8002"
    environment:
      - FLAGD_HOST=flagd
      - FLAGD_PORT=8013
      - OTEL_SERVICE_NAME=inventory-service
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
      - OTEL_EXPORTER_OTLP_PROTOCOL=grpc
      - OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
      - PYROSCOPE_ENDPOINT=${GRAFANA_CLOUD_PYROSCOPE_ENDPOINT}
      - PYROSCOPE_USER=${GRAFANA_CLOUD_USER}
      - PYROSCOPE_PASSWORD=${GRAFANA_CLOUD_API_KEY}
    depends_on:
      flagd:
        condition: service_healthy
      otel-collector:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8002/health')"]
      interval: 5s
      timeout: 3s
      retries: 5

  order-service:
    build: ./services/order-service
    ports:
      - "8001:8001"
    environment:
      - INVENTORY_SERVICE_URL=http://inventory-service:8002
      - FLAGD_HOST=flagd
      - FLAGD_PORT=8013
      - OTEL_SERVICE_NAME=order-service
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
      - OTEL_EXPORTER_OTLP_PROTOCOL=grpc
      - OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
      - PYROSCOPE_ENDPOINT=${GRAFANA_CLOUD_PYROSCOPE_ENDPOINT}
      - PYROSCOPE_USER=${GRAFANA_CLOUD_USER}
      - PYROSCOPE_PASSWORD=${GRAFANA_CLOUD_API_KEY}
    depends_on:
      inventory-service:
        condition: service_healthy
      flagd:
        condition: service_healthy
      otel-collector:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8001/health')"]
      interval: 5s
      timeout: 3s
      retries: 5

  api-gateway:
    build: ./services/api-gateway
    ports:
      - "8000:8000"
    environment:
      - ORDER_SERVICE_URL=http://order-service:8001
      - OTEL_SERVICE_NAME=api-gateway
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
      - OTEL_EXPORTER_OTLP_PROTOCOL=grpc
      - OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
      - PYROSCOPE_ENDPOINT=${GRAFANA_CLOUD_PYROSCOPE_ENDPOINT}
      - PYROSCOPE_USER=${GRAFANA_CLOUD_USER}
      - PYROSCOPE_PASSWORD=${GRAFANA_CLOUD_API_KEY}
    depends_on:
      order-service:
        condition: service_healthy
      otel-collector:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]
      interval: 5s
      timeout: 3s
      retries: 5

  load-generator:
    build: ./load-generator
    environment:
      - GATEWAY_URL=http://api-gateway:8000
      - REQUESTS_PER_SECOND=5
    depends_on:
      api-gateway:
        condition: service_healthy
    restart: unless-stopped
```

- [ ] **Step 2: Full integration test**

```bash
# Copy and fill in .env
cp .env.example .env
# Edit .env with real Grafana Cloud credentials

docker compose up --build -d
docker compose ps
# All services should be healthy

# Watch load generator logs
docker compose logs -f load-generator
# Should see "POST /orders -> 200" lines

# Verify in Grafana Cloud:
# - Tempo: traces showing api-gateway -> order-service -> inventory-service
# - Mimir: metrics for all three services
# - Loki: structured logs with trace IDs
# - Pyroscope: CPU profiles for all three services

# Test Scenario 1: edit flagd/flags.json, change slow-order-processing to "on"
# Watch load-generator logs — should see slower responses
# Check Pyroscope — process_order_slow should appear

# Reset
./scripts/reset-demo.sh
docker compose down
```

- [ ] **Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: finalize docker compose with all services"
```

---

## Chunk 5: Documentation

### Task 15: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Create `README.md`**

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README"
```

---

### Task 16: Grafana Cloud Setup (Manual)

These steps are done in the Grafana Cloud UI, not in code.

- [ ] **Step 1: Verify data sources**

Confirm that Tempo, Mimir, Loki, and Pyroscope data sources are configured and receiving data from the running demo.

- [ ] **Step 2: Create Service Overview dashboard**

Create a dashboard with panels for:
- Request rate per service (from Mimir: `rate(http_server_request_duration_seconds_count[5m])`)
- Error rate per service (from Mimir: `rate(http_server_request_duration_seconds_count{http_status_code=~"5.."}[5m])`)
- Latency p50/p95/p99 per service (from Mimir: `histogram_quantile(0.99, rate(http_server_request_duration_seconds_bucket[5m]))`)
- Memory usage per service (from Mimir: `process_resident_memory_bytes`)

- [ ] **Step 3: Create SLOs**

- Latency SLO on API Gateway: 99% of requests < 500ms, 30-day window
- Error rate SLO: 99.5% success rate, 30-day window

- [ ] **Step 4: Create alerts**

- SLO burn rate alert (fast burn): fires at 14x burn rate over 1 hour
- Error rate alert on Inventory Service: fires when 5xx rate > 5%

- [ ] **Step 5: Configure Grafana Assistant**

- Add GitHub MCP server: `https://api.githubcopilot.com/mcp/` with GitHub PAT
- Create the "Investigate and Fix" skill (see spec for workflow details)
- Test: ask Assistant to investigate a known issue
