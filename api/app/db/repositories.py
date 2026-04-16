from datetime import datetime, timezone

from sqlalchemy.orm import Session

from app.db.models import Candle, Indicators, Label, MarketContext, MarketStructure, Symbol, Timeframe
from app.models import FeatureEvent, LabelEvent

_UTC = timezone.utc
_TF_MINUTES: dict[str, int] = {"M1": 1, "M5": 5, "M15": 15, "H1": 60}


class EventRepository:
    """Orchestrates all database writes for feature and label events."""

    def __init__(self, db: Session) -> None:
        self.db = db

    # ------------------------------------------------------------------
    # Dimension helpers
    # ------------------------------------------------------------------

    def _get_or_create_symbol(self, symbol: str) -> Symbol:
        row = self.db.query(Symbol).filter_by(symbol=symbol).first()
        if row:
            return row
        row = Symbol(symbol=symbol, created_at=datetime.now(_UTC))
        self.db.add(row)
        self.db.flush()
        return row

    def _get_or_create_timeframe(self, tf_name: str) -> Timeframe:
        row = self.db.query(Timeframe).filter_by(name=tf_name).first()
        if row:
            return row
        row = Timeframe(name=tf_name, minutes=_TF_MINUTES.get(tf_name, 0))
        self.db.add(row)
        self.db.flush()
        return row

    # ------------------------------------------------------------------
    # Event ingestion
    # ------------------------------------------------------------------

    def ingest_feature_event(self, event: FeatureEvent) -> int:
        """Persist a feature event; return candle_id."""
        symbol = self._get_or_create_symbol(event.symbol)
        timeframe = self._get_or_create_timeframe(event.timeframe)
        ts = datetime.fromisoformat(event.timestamp_utc.replace("Z", "+00:00"))
        now = datetime.now(_UTC)

        candle = Candle(
            symbol_id=symbol.id,
            timeframe_id=timeframe.id,
            timestamp_utc=ts,
            open=event.candle.open,
            high=event.candle.high,
            low=event.candle.low,
            close=event.candle.close,
            volume=event.candle.volume,
            created_at=now,
            ingested_at=now,
        )
        self.db.add(candle)
        self.db.flush()

        self.db.add(Indicators(
            candle_id=candle.id,
            rsi=event.indicators.rsi,
            macd=event.indicators.macd,
            macd_signal=event.indicators.macd_signal,
            ema_20=event.indicators.ema20,
            ema_50=event.indicators.ema50,
            ema_200=event.indicators.ema200,
            atr=event.indicators.atr,
            version=1,
            created_at=now,
        ))

        self.db.add(MarketStructure(
            candle_id=candle.id,
            trend=event.structure.trend,
            bos=bool(event.structure.bos),
            liquidity_sweep=bool(event.structure.liquidity_sweep),
            structure_strength=event.structure.structure_strength,
            created_at=now,
        ))

        self.db.add(MarketContext(
            candle_id=candle.id,
            session=event.context.session,
            spread=event.context.spread,
            bid_price=event.context.bid,
            ask_price=event.context.ask,
            volatility_atr=event.context.volatility,
            created_at=now,
        ))

        self.db.flush()
        return candle.id

    def ingest_label_event(self, event: LabelEvent) -> int | None:
        """Persist a label event; return label_id, or None if the target candle isn't ingested yet.

        None is expected when a label arrives before its feature event (EA timing gap).
        """
        ts = datetime.fromisoformat(event.timestamp_utc.replace("Z", "+00:00"))

        candle = (
            self.db.query(Candle)
            .join(Symbol, Symbol.id == Candle.symbol_id)
            .join(Timeframe, Timeframe.id == Candle.timeframe_id)
            .filter(
                Symbol.symbol == event.symbol,
                Timeframe.name == event.timeframe,
                Candle.timestamp_utc == ts,
            )
            .first()
        )
        if candle is None:
            return None

        label = Label(
            candle_id=candle.id,
            label=event.label.label,
            future_return_percent=event.label.future_return_percent,
            hold_period_candles=event.label.hold_period_candles,
            created_at=datetime.now(_UTC),
        )
        self.db.add(label)
        self.db.flush()
        return label.id
