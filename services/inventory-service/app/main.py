import os
from contextlib import asynccontextmanager

from fastapi import FastAPI
from openfeature import api
from openfeature.contrib.provider.flagd import FlagdProvider
from openfeature.contrib.provider.flagd.config import ResolverType

from app.routes import router


@asynccontextmanager
async def lifespan(app: FastAPI):
    flagd_host = os.environ.get("FLAGD_HOST", "localhost")
    flagd_port = int(os.environ.get("FLAGD_PORT", "8013"))
    api.set_provider(FlagdProvider(host=flagd_host, port=flagd_port, resolver_type=ResolverType.IN_PROCESS))
    yield


app = FastAPI(title="Inventory Service", lifespan=lifespan)
app.include_router(router)
