from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.db.repositories import EventRepository, IngestResult
from app.db.session import get_db
from app.logger import get_logger
from app.models import BatchIngestRequest, EventPayload

router = APIRouter()
_logger = get_logger()


def _ingest_event(repo: EventRepository, data: EventPayload) -> IngestResult:
    if data.event_type == "feature":
        return repo.ingest_feature_event(data)
    return repo.ingest_label_event(data)


def _response_for_event(data: EventPayload, result: IngestResult) -> dict[str, object]:
    if result.action == "skipped":
        return {
            "status": "skipped",
            "received": True,
            "persisted": False,
            "reason": result.reason,
            "event_id": data.event_id,
        }

    return {
        "status": "ok",
        "received": True,
        "persisted": True,
        "event_id": data.event_id,
        "action": result.action,
        "record_id": result.record_id,
    }


def _log_ingest_result(data: EventPayload, result: IngestResult, batch_index: int | None = None) -> None:
    scope = "ingest" if batch_index is None else f"ingest batch item={batch_index}"

    if result.action == "skipped":
        _logger.debug(
            "%s %s skipped event_id=%s symbol=%s timeframe=%s reason=%s",
            scope,
            result.resource,
            data.event_id,
            data.symbol,
            data.timeframe,
            result.reason,
        )
        return

    _logger.info(
        "%s %s %s event_id=%s symbol=%s timeframe=%s record_id=%s",
        scope,
        result.resource,
        result.action,
        data.event_id,
        data.symbol,
        data.timeframe,
        result.record_id,
    )


@router.post("/ingest")
def ingest(
    data: EventPayload,
    db: Session = Depends(get_db),
) -> dict[str, object]:
    """Ingest a single event (feature or label) and persist to database."""
    try:
        repo = EventRepository(db)
        result = _ingest_event(repo, data)
        db.commit()
        _log_ingest_result(data, result)
        return _response_for_event(data, result)

    except Exception as exc:
        db.rollback()
        _logger.error("ingest failed event_id=%s error=%s", data.event_id, exc, exc_info=True)
        if isinstance(exc, IntegrityError):
            raise HTTPException(status_code=409, detail=f"Conflict while ingesting event: {exc}")
        if isinstance(exc, ValueError):
            raise HTTPException(status_code=400, detail=f"Failed to ingest event: {exc}")
        raise HTTPException(status_code=500, detail="Internal error while ingesting event")


@router.post("/ingest/batch")
def ingest_batch(
    data: BatchIngestRequest,
    db: Session = Depends(get_db),
) -> dict[str, object]:
    """Ingest a batch of events and persist to database."""
    try:
        repo = EventRepository(db)
        created = 0
        updated = 0
        skipped = 0
        failed = 0

        for index, item in enumerate(data.items):
            try:
                with db.begin_nested():
                    result = _ingest_event(repo, item)

                _log_ingest_result(item, result, batch_index=index)

                if result.action == "created":
                    created += 1
                elif result.action == "updated":
                    updated += 1
                else:
                    skipped += 1
            except Exception as item_exc:
                failed += 1
                _logger.warning(
                    "ingest batch item=%d failed event_id=%s error=%s",
                    index, item.event_id, item_exc,
                )

        db.commit()
        processed = created + updated
        _logger.info(
            "ingest batch committed processed=%d created=%d updated=%d skipped=%d failed=%d total=%d",
            processed,
            created,
            updated,
            skipped,
            failed,
            len(data.items),
        )
        return {
            "status": "ok",
            "received": True,
            "processed": processed,
            "created": created,
            "updated": updated,
            "skipped": skipped,
            "failed": failed,
            "total": len(data.items),
        }

    except Exception as exc:
        db.rollback()
        _logger.error("ingest batch failed error=%s", exc, exc_info=True)
        if isinstance(exc, IntegrityError):
            raise HTTPException(status_code=409, detail=f"Batch conflict: {exc}")
        if isinstance(exc, ValueError):
            raise HTTPException(status_code=400, detail=f"Batch ingestion failed: {exc}")
        raise HTTPException(status_code=500, detail="Internal error while ingesting batch")
