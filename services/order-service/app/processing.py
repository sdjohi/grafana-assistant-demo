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
