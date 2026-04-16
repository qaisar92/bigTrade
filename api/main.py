from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.db.session import init_db
from app.logger import get_logger
from app.routers.ingest import router as ingest_router

logger = get_logger()


@asynccontextmanager
async def lifespan(app: FastAPI):
    try:
        init_db()
        logger.info("Database schema initialized successfully")
    except Exception as exc:
        logger.warning("Database initialization failed (may not be available yet): %s", exc)
    yield


app = FastAPI(title="Trading Ingest API", lifespan=lifespan)
app.include_router(ingest_router)


@app.get("/")
def health() -> dict[str, str]:
    return {"message": "API is running"}