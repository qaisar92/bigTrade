from datetime import datetime, timezone
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

_UTC = timezone.utc


class _StrictModel(BaseModel):
    """Base model that rejects unknown fields across all event types."""

    model_config = ConfigDict(extra="forbid")


# ---------------------------------------------------------------------------
# Candle sub-schemas
# ---------------------------------------------------------------------------


class CandleSchema(_StrictModel):
    open: float = Field(gt=0)
    high: float = Field(gt=0)
    low: float = Field(gt=0)
    close: float = Field(gt=0)
    volume: float = Field(ge=0)


class IndicatorsSchema(_StrictModel):
    rsi: float = Field(ge=0, le=100)
    macd: float
    macd_signal: float
    ema20: float
    ema50: float
    ema200: float
    atr: float = Field(ge=0)


class StructureSchema(_StrictModel):
    trend: Literal["UP", "DOWN", "SIDEWAYS"]
    bos: int = Field(ge=0, le=1)
    liquidity_sweep: int = Field(ge=0, le=1)
    structure_strength: float = Field(ge=0, le=5)


class ContextSchema(_StrictModel):
    session: Literal["ASIA", "LONDON", "NEW_YORK", "OVERLAP"]
    spread: float = Field(ge=0)
    slippage_estimate: float = Field(ge=0)
    bid: float = Field(gt=0)
    ask: float = Field(gt=0)
    volatility: float = Field(ge=0)


class LabelDataSchema(_StrictModel):
    label: int = Field(ge=0, le=2)
    future_return_percent: float
    hold_period_candles: int = Field(ge=1, le=5)


# ---------------------------------------------------------------------------
# Event schemas
# ---------------------------------------------------------------------------


class _EventBase(_StrictModel):
    """Shared header fields present on every event."""

    schema_version: str
    feature_version: str
    label_version: str
    dataset_split: Literal["train", "test", "live"]
    event_id: str
    symbol: str = Field(min_length=1, max_length=32)
    timeframe: Literal["M1", "M5", "M15", "H1"]
    timestamp_utc: datetime

    @field_validator("timestamp_utc")
    @classmethod
    def _normalize_timestamp_utc(cls, value: datetime) -> datetime:
        if value.tzinfo is None:
            raise ValueError("timestamp_utc must include timezone information")
        return value.astimezone(_UTC)


class FeatureEvent(_EventBase):
    event_type: Literal["feature"]
    candle: CandleSchema
    indicators: IndicatorsSchema
    structure: StructureSchema
    context: ContextSchema


class LabelEvent(_EventBase):
    event_type: Literal["label"]
    label: LabelDataSchema
    computed_at_utc: datetime

    @field_validator("computed_at_utc")
    @classmethod
    def _normalize_computed_at_utc(cls, value: datetime) -> datetime:
        if value.tzinfo is None:
            raise ValueError("computed_at_utc must include timezone information")
        return value.astimezone(_UTC)


# Discriminated union used as the single-event request body type.
EventPayload = Annotated[
    FeatureEvent | LabelEvent,
    Field(discriminator="event_type"),
]


class BatchIngestRequest(_StrictModel):
    event_type: Literal["batch"] = "batch"
    schema_version: str
    dataset_split: Literal["train", "test", "live"]
    items: list[EventPayload] = Field(min_length=1)
