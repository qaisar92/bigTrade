from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Literal

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db.models import Candle, Indicators, Label, MarketContext, MarketStructure, Symbol, Timeframe
from app.models import FeatureEvent, LabelEvent

_UTC = timezone.utc
_TF_MINUTES: dict[str, int] = {"M1": 1, "M5": 5, "M15": 15, "H1": 60}


@dataclass(frozen=True)
class IngestResult:
    resource: Literal["feature", "label"]
    action: Literal["created", "updated", "skipped"]
    record_id: int | None
    reason: str | None = None


class EventRepository:
    """Orchestrates all database writes for feature and label events."""

    def __init__(self, db: Session) -> None:
        self.db = db
        self._symbol_cache: dict[str, Symbol] = {}
        self._timeframe_cache: dict[str, Timeframe] = {}

    def _now(self) -> datetime:
        return datetime.now(_UTC)

    # ------------------------------------------------------------------
    # Dimension helpers
    # ------------------------------------------------------------------

    def _get_or_create_symbol(self, symbol: str) -> Symbol:
        cached = self._symbol_cache.get(symbol)
        if cached is not None:
            return cached

        row = self.db.execute(select(Symbol).where(Symbol.symbol == symbol)).scalar_one_or_none()
        if row:
            self._symbol_cache[symbol] = row
            return row

        row = Symbol(symbol=symbol, created_at=self._now())
        self.db.add(row)
        self.db.flush()
        self._symbol_cache[symbol] = row
        return row

    def _get_or_create_timeframe(self, tf_name: str) -> Timeframe:
        cached = self._timeframe_cache.get(tf_name)
        if cached is not None:
            return cached

        row = self.db.execute(select(Timeframe).where(Timeframe.name == tf_name)).scalar_one_or_none()
        if row:
            self._timeframe_cache[tf_name] = row
            return row

        row = Timeframe(name=tf_name, minutes=_TF_MINUTES.get(tf_name, 0))
        self.db.add(row)
        self.db.flush()
        self._timeframe_cache[tf_name] = row
        return row

    def _find_candle_by_ids(self, symbol_id: int, timeframe_id: int, timestamp_utc: datetime) -> Candle | None:
        stmt = select(Candle).where(
            Candle.symbol_id == symbol_id,
            Candle.timeframe_id == timeframe_id,
            Candle.timestamp_utc == timestamp_utc,
        )
        return self.db.execute(stmt).scalar_one_or_none()

    def _find_candle(self, symbol: str, timeframe: str, timestamp_utc: datetime) -> Candle | None:
        stmt = (
            select(Candle)
            .join(Symbol, Symbol.id == Candle.symbol_id)
            .join(Timeframe, Timeframe.id == Candle.timeframe_id)
            .where(
                Symbol.symbol == symbol,
                Timeframe.name == timeframe,
                Candle.timestamp_utc == timestamp_utc,
            )
        )
        return self.db.execute(stmt).scalar_one_or_none()

    def _upsert_candle(
        self,
        event: FeatureEvent,
        symbol: Symbol,
        timeframe: Timeframe,
        now: datetime,
    ) -> tuple[Candle, Literal["created", "updated"]]:
        candle = self._find_candle_by_ids(symbol.id, timeframe.id, event.timestamp_utc)
        action: Literal["created", "updated"] = "updated"

        if candle is None:
            action = "created"
            candle = Candle(
                symbol_id=symbol.id,
                timeframe_id=timeframe.id,
                timestamp_utc=event.timestamp_utc,
                created_at=now,
                ingested_at=now,
                open=event.candle.open,
                high=event.candle.high,
                low=event.candle.low,
                close=event.candle.close,
                volume=event.candle.volume,
            )
            self.db.add(candle)
            self.db.flush()
            return candle, action

        candle.open = event.candle.open
        candle.high = event.candle.high
        candle.low = event.candle.low
        candle.close = event.candle.close
        candle.volume = event.candle.volume
        candle.ingested_at = now
        self.db.flush()
        return candle, action

    def _upsert_indicators(self, candle_id: int, event: FeatureEvent, now: datetime) -> None:
        indicators = self.db.execute(
            select(Indicators).where(Indicators.candle_id == candle_id)
        ).scalar_one_or_none()
        if indicators is None:
            indicators = Indicators(candle_id=candle_id, version=1, created_at=now)
            self.db.add(indicators)

        indicators.rsi = event.indicators.rsi
        indicators.macd = event.indicators.macd
        indicators.macd_signal = event.indicators.macd_signal
        indicators.ema_20 = event.indicators.ema20
        indicators.ema_50 = event.indicators.ema50
        indicators.ema_200 = event.indicators.ema200
        indicators.atr = event.indicators.atr

    def _upsert_market_structure(self, candle_id: int, event: FeatureEvent, now: datetime) -> None:
        structure = self.db.execute(
            select(MarketStructure).where(MarketStructure.candle_id == candle_id)
        ).scalar_one_or_none()
        if structure is None:
            structure = MarketStructure(candle_id=candle_id, created_at=now)
            self.db.add(structure)

        structure.trend = event.structure.trend
        structure.bos = bool(event.structure.bos)
        structure.liquidity_sweep = bool(event.structure.liquidity_sweep)
        structure.structure_strength = event.structure.structure_strength

    def _upsert_market_context(self, candle_id: int, event: FeatureEvent, now: datetime) -> None:
        context = self.db.execute(
            select(MarketContext).where(MarketContext.candle_id == candle_id)
        ).scalar_one_or_none()
        if context is None:
            context = MarketContext(candle_id=candle_id, created_at=now)
            self.db.add(context)

        context.session = event.context.session
        context.spread = event.context.spread
        context.slippage_estimate = event.context.slippage_estimate
        context.bid_price = event.context.bid
        context.ask_price = event.context.ask
        context.volatility_atr = event.context.volatility

    def _upsert_label(self, candle_id: int, event: LabelEvent, now: datetime) -> tuple[Label, Literal["created", "updated"]]:
        label = self.db.execute(select(Label).where(Label.candle_id == candle_id)).scalar_one_or_none()
        action: Literal["created", "updated"] = "updated"

        if label is None:
            action = "created"
            label = Label(candle_id=candle_id, created_at=now)
            self.db.add(label)

        label.label = event.label.label
        label.future_return_percent = event.label.future_return_percent
        label.hold_period_candles = event.label.hold_period_candles
        self.db.flush()
        return label, action

    # ------------------------------------------------------------------
    # Event ingestion
    # ------------------------------------------------------------------

    def ingest_feature_event(self, event: FeatureEvent) -> IngestResult:
        """Persist a feature event idempotently; return the persistence outcome."""
        symbol = self._get_or_create_symbol(event.symbol)
        timeframe = self._get_or_create_timeframe(event.timeframe)
        now = self._now()

        candle, action = self._upsert_candle(event, symbol, timeframe, now)
        self._upsert_indicators(candle.id, event, now)
        self._upsert_market_structure(candle.id, event, now)
        self._upsert_market_context(candle.id, event, now)
        self.db.flush()
        return IngestResult(resource="feature", action=action, record_id=candle.id)

    def ingest_label_event(self, event: LabelEvent) -> IngestResult:
        """Persist a label event idempotently; skip cleanly if its candle is not available yet."""
        candle = self._find_candle(event.symbol, event.timeframe, event.timestamp_utc)
        if candle is None:
            return IngestResult(
                resource="label",
                action="skipped",
                record_id=None,
                reason="candle_not_found",
            )

        label, action = self._upsert_label(candle.id, event, self._now())
        return IngestResult(resource="label", action=action, record_id=label.id)
