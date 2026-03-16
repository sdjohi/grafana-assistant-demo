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
