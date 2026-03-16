from fastapi import FastAPI
from app.routes import router

app = FastAPI(title="Order Service")
app.include_router(router)
