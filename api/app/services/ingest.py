import logging

from sqlalchemy.orm import Session

from app.db.repositories import EventRepository, IngestResult
from app.logger import get_logger
from app.schemas import BatchIngestRequest, EventPayload, FeatureEvent


class IngestService:
    """Orchestrates ingestion business logic, decoupled from HTTP concerns."""

    def __init__(self, db: Session, logger: logging.Logger | None = None) -> None:
        self._db = db
        self._repo = EventRepository(db)
        self._logger = logger or get_logger()

    # ------------------------------------------------------------------
    # Dispatch
    # ------------------------------------------------------------------

    def dispatch_event(self, event: EventPayload) -> IngestResult:
        """Route a single event to the appropriate repository method."""
        if isinstance(event, FeatureEvent):
            return self._repo.ingest_feature_event(event)
        return self._repo.ingest_label_event(event)

    # ------------------------------------------------------------------
    # Batch processing
    # ------------------------------------------------------------------

    def process_batch(self, request: BatchIngestRequest) -> dict[str, object]:
        """Process each item in a batch using per-item savepoints.

        Failed items are isolated and counted; successful items are kept.
        Returns a summary dict ready for the HTTP response.
        """
        created = updated = skipped = failed = 0

        for index, item in enumerate(request.items):
            try:
                with self._db.begin_nested():
                    result = self.dispatch_event(item)

                self._log_result(item, result, batch_index=index)

                if result.action == "created":
                    created += 1
                elif result.action == "updated":
                    updated += 1
                else:
                    skipped += 1

            except Exception as exc:
                failed += 1
                self._logger.warning(
                    "ingest batch item=%d failed event_id=%s error=%s",
                    index,
                    item.event_id,
                    exc,
                )

        processed = created + updated
        self._logger.info(
            "ingest batch committed processed=%d created=%d updated=%d "
            "skipped=%d failed=%d total=%d",
            processed,
            created,
            updated,
            skipped,
            failed,
            len(request.items),
        )
        return self.build_batch_response(
            created=created,
            updated=updated,
            skipped=skipped,
            failed=failed,
            total=len(request.items),
        )

    # ------------------------------------------------------------------
    # Response builders (static — no state required)
    # ------------------------------------------------------------------

    @staticmethod
    def build_event_response(event: EventPayload, result: IngestResult) -> dict[str, object]:
        """Construct the HTTP response body for a single-event ingest."""
        if result.action == "skipped":
            return {
                "status": "skipped",
                "received": True,
                "persisted": False,
                "reason": result.reason,
                "event_id": event.event_id,
            }
        return {
            "status": "ok",
            "received": True,
            "persisted": True,
            "event_id": event.event_id,
            "action": result.action,
            "record_id": result.record_id,
        }

    @staticmethod
    def build_batch_response(
        *,
        created: int,
        updated: int,
        skipped: int,
        failed: int,
        total: int,
    ) -> dict[str, object]:
        """Construct the HTTP response body for a batch ingest."""
        return {
            "status": "ok",
            "received": True,
            "processed": created + updated,
            "created": created,
            "updated": updated,
            "skipped": skipped,
            "failed": failed,
            "total": total,
        }

    # ------------------------------------------------------------------
    # Logging helpers
    # ------------------------------------------------------------------

    def _log_result(
        self,
        event: EventPayload,
        result: IngestResult,
        batch_index: int | None = None,
    ) -> None:
        scope = "ingest" if batch_index is None else f"ingest batch item={batch_index}"

        if result.action == "skipped":
            self._logger.debug(
                "%s %s skipped event_id=%s symbol=%s timeframe=%s reason=%s",
                scope,
                result.resource,
                event.event_id,
                event.symbol,
                event.timeframe,
                result.reason,
            )
            return

        self._logger.info(
            "%s %s %s event_id=%s symbol=%s timeframe=%s record_id=%s",
            scope,
            result.resource,
            result.action,
            event.event_id,
            event.symbol,
            event.timeframe,
            result.record_id,
        )
