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
