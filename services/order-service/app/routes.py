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

# Shared HTTP client — created once at module load to avoid per-request
# SSL context initialisation overhead (create_ssl_context / create_default_context).
# Previously a new AsyncClient was instantiated inside create_order on every request,
# which consumed ~34.8% of total CPU (Pyroscope, 2026-03-17).
_http_client = httpx.AsyncClient(
    limits=httpx.Limits(max_connections=100, max_keepalive_connections=20),
    timeout=10.0,
)


@router.get("/health")
async def health():
    return {"status": "healthy"}


@router.post("/orders")
async def create_order(items: list[dict]):
    order_id = str(uuid.uuid4())
    order = {"order_id": order_id, "items": items}

    logger.info("Creating order %s with %d items", order_id, len(items))

    # Check inventory for each item using the shared client
    for item in items:
        resp = await _http_client.post(
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
