from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.db.repositories import EventRepository
from app.db.session import get_db
from app.logger import get_logger
from app.models import BatchIngestRequest, EventPayload

router = APIRouter()
_logger = get_logger()


@router.post("/ingest")
def ingest(
    data: EventPayload,
    db: Session = Depends(get_db),
) -> dict[str, object]:
    """Ingest a single event (feature or label) and persist to database."""
    try:
        repo = EventRepository(db)

        if data.event_type == "feature":
            candle_id = repo.ingest_feature_event(data)
            _logger.info(
                "ingest feature event_id=%s symbol=%s timeframe=%s candle_id=%d",
                data.event_id, data.symbol, data.timeframe, candle_id,
            )
        else:  # label
            label_id = repo.ingest_label_event(data)
            if label_id is None:
                _logger.debug(
                    "ingest label skipped (candle not yet persisted) event_id=%s symbol=%s timeframe=%s ts=%s",
                    data.event_id, data.symbol, data.timeframe, data.timestamp_utc,
                )
                return {"status": "skipped", "reason": "candle_not_found", "event_id": data.event_id}
            _logger.info(
                "ingest label event_id=%s symbol=%s timeframe=%s label_id=%d",
                data.event_id, data.symbol, data.timeframe, label_id,
            )

        db.commit()
        return {"status": "ok", "received": True, "event_id": data.event_id}

    except Exception as exc:
        db.rollback()
        _logger.error("ingest failed event_id=%s error=%s", data.event_id, exc, exc_info=True)
        raise HTTPException(status_code=400, detail=f"Failed to ingest event: {exc}")


@router.post("/ingest/batch")
def ingest_batch(
    data: BatchIngestRequest,
    db: Session = Depends(get_db),
) -> dict[str, object]:
    """Ingest a batch of events and persist to database."""
    try:
        repo = EventRepository(db)
        count = 0

        for index, item in enumerate(data.items):
            try:
                if item.event_type == "feature":
                    candle_id = repo.ingest_feature_event(item)
                    _logger.info("ingest batch item=%d feature candle_id=%d", index, candle_id)
                else:  # label
                    label_id = repo.ingest_label_event(item)
                    if label_id is None:
                        _logger.debug(
                            "ingest batch item=%d label skipped (candle not found) event_id=%s",
                            index, item.event_id,
                        )
                        continue
                    _logger.info("ingest batch item=%d label label_id=%d", index, label_id)
                count += 1
            except Exception as item_exc:
                _logger.warning(
                    "ingest batch item=%d failed event_id=%s error=%s",
                    index, item.event_id, item_exc,
                )

        db.commit()
        _logger.info("ingest batch committed count=%d/%d", count, len(data.items))
        return {"status": "ok", "received": True, "count": count, "total": len(data.items)}

    except Exception as exc:
        db.rollback()
        _logger.error("ingest batch failed error=%s", exc, exc_info=True)
        raise HTTPException(status_code=400, detail=f"Batch ingestion failed: {exc}")
