import logging
import os
from contextlib import asynccontextmanager

import pyroscope
from fastapi import FastAPI
from openfeature import api
from openfeature.contrib.provider.flagd import FlagdProvider
from openfeature.contrib.provider.flagd.config import ResolverType
from opentelemetry import trace
from pyroscope.otel import PyroscopeSpanProcessor

from app.routes import router

logging.basicConfig(level=logging.INFO)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Feature flags
    flagd_host = os.environ.get("FLAGD_HOST", "localhost")
    flagd_port = int(os.environ.get("FLAGD_PORT", "8013"))
    api.set_provider(FlagdProvider(host=flagd_host, port=flagd_port, resolver_type=ResolverType.IN_PROCESS))

    # Link Pyroscope profiles to OTel trace spans
    provider = trace.get_tracer_provider()
    provider.add_span_processor(PyroscopeSpanProcessor())

    # Pyroscope
    pyroscope.configure(
        application_name="order-service",
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
        tags={"service": "order-service"},
    )
    yield


app = FastAPI(title="Order Service", lifespan=lifespan)
app.include_router(router)
