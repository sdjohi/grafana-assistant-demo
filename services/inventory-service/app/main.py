from fastapi import FastAPI
from app.routes import router

app = FastAPI(title="Inventory Service")
app.include_router(router)
