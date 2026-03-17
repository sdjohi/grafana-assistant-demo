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
