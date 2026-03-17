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
