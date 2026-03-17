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
