import os
from contextlib import asynccontextmanager

import pyroscope
from fastapi import FastAPI
from openfeature import api
from openfeature.contrib.provider.flagd import FlagdProvider
from openfeature.contrib.provider.flagd.config import ResolverType

from app.routes import router


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Feature flags
    flagd_host = os.environ.get("FLAGD_HOST", "localhost")
    flagd_port = int(os.environ.get("FLAGD_PORT", "8013"))
    api.set_provider(FlagdProvider(host=flagd_host, port=flagd_port, resolver_type=ResolverType.IN_PROCESS))

    # Pyroscope
    pyroscope.configure(
        application_name="inventory-service",
        server_address=os.environ.get("PYROSCOPE_ENDPOINT", "http://localhost:4040"),
        basic_auth_username=os.environ.get("PYROSCOPE_USER", ""),
        basic_auth_password=os.environ.get("PYROSCOPE_PASSWORD", ""),
        tenant_id=os.environ.get("PYROSCOPE_TENANT_ID", ""),
        oncpu=True,
        gil_only=False,
        report_pid=True,
        report_thread_id=True,
        report_thread_name=True,
        enable_logging=True,
        tags={"service": "inventory-service"},
    )
    yield


app = FastAPI(title="Inventory Service", lifespan=lifespan)
app.include_router(router)
