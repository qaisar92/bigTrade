from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.logger import get_logger
from app.schemas import BatchIngestRequest, EventPayload
from app.services.ingest import IngestService

router = APIRouter()
_logger = get_logger()


def _raise_http_error(exc: Exception, context: str) -> None:
    """Map known exception types to appropriate HTTP status codes."""
    _logger.error("%s error=%s", context, exc, exc_info=True)
    if isinstance(exc, IntegrityError):
        raise HTTPException(status_code=409, detail=f"Conflict: {exc}")
    if isinstance(exc, ValueError):
        raise HTTPException(status_code=400, detail=f"Validation error: {exc}")
    raise HTTPException(status_code=500, detail=f"Internal server error: {context}")


@router.post("/ingest")
def ingest(
    data: EventPayload,
    db: Session = Depends(get_db),
) -> dict[str, object]:
    """Ingest a single event (feature or label) and persist to the database."""
    try:
        service = IngestService(db, _logger)
        result = service.dispatch_event(data)
        db.commit()
        service._log_result(data, result)
        return service.build_event_response(data, result)
    except Exception as exc:
        db.rollback()
        _raise_http_error(exc, f"ingest event_id={data.event_id}")


@router.post("/ingest/batch")
def ingest_batch(
    data: BatchIngestRequest,
    db: Session = Depends(get_db),
) -> dict[str, object]:
    """Ingest a batch of events and persist to the database."""
    try:
        service = IngestService(db, _logger)
        response = service.process_batch(data)
        db.commit()
        return response
    except Exception as exc:
        db.rollback()
        _raise_http_error(exc, "ingest batch")
