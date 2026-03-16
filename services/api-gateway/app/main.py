from fastapi import FastAPI
from app.routes import router

app = FastAPI(title="API Gateway")
app.include_router(router)
