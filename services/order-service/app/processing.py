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
