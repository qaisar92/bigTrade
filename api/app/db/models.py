from datetime import datetime

from sqlalchemy import (
    Boolean,
    DateTime,
    Enum,
    ForeignKey,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    """SQLAlchemy declarative base."""

    pass


class Symbol(Base):
    __tablename__ = "symbols"

    id: Mapped[int] = mapped_column(primary_key=True)
    symbol: Mapped[str] = mapped_column(String(32), unique=True, nullable=False)
    description: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)

    candles: Mapped[list["Candle"]] = relationship(back_populates="symbol")
    multi_timeframe_bias: Mapped[list["MultiTimeframeBias"]] = relationship(
        back_populates="symbol"
    )


class Timeframe(Base):
    __tablename__ = "timeframes"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(8), unique=True, nullable=False)
    minutes: Mapped[int] = mapped_column(unique=True, nullable=False)

    candles: Mapped[list["Candle"]] = relationship(back_populates="timeframe")


class Candle(Base):
    __tablename__ = "candles"
    __table_args__ = (
        UniqueConstraint("symbol_id", "timeframe_id", "timestamp_utc"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    symbol_id: Mapped[int] = mapped_column(ForeignKey("symbols.id"), nullable=False)
    timeframe_id: Mapped[int] = mapped_column(
        ForeignKey("timeframes.id"), nullable=False
    )
    timestamp_utc: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    open: Mapped[float] = mapped_column(Numeric(20, 10), nullable=False)
    high: Mapped[float] = mapped_column(Numeric(20, 10), nullable=False)
    low: Mapped[float] = mapped_column(Numeric(20, 10), nullable=False)
    close: Mapped[float] = mapped_column(Numeric(20, 10), nullable=False)
    volume: Mapped[float] = mapped_column(Numeric(20, 4), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    ingested_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )

    symbol: Mapped[Symbol] = relationship(back_populates="candles")
    timeframe: Mapped[Timeframe] = relationship(back_populates="candles")
    indicators: Mapped["Indicators"] = relationship(
        uselist=False, back_populates="candle", cascade="all, delete-orphan"
    )
    market_structure: Mapped["MarketStructure"] = relationship(
        uselist=False, back_populates="candle", cascade="all, delete-orphan"
    )
    market_context: Mapped["MarketContext"] = relationship(
        uselist=False, back_populates="candle", cascade="all, delete-orphan"
    )
    labels: Mapped["Label"] = relationship(
        uselist=False, back_populates="candle", cascade="all, delete-orphan"
    )
    data_quality_checks: Mapped[list["DataQualityCheck"]] = relationship(
        back_populates="candle", cascade="all, delete-orphan"
    )


class Indicators(Base):
    __tablename__ = "indicators"

    id: Mapped[int] = mapped_column(primary_key=True)
    candle_id: Mapped[int] = mapped_column(ForeignKey("candles.id"), nullable=False)
    rsi: Mapped[float | None] = mapped_column(Numeric(10, 6))
    macd: Mapped[float | None] = mapped_column(Numeric(20, 10))
    macd_signal: Mapped[float | None] = mapped_column(Numeric(20, 10))
    ema_20: Mapped[float | None] = mapped_column(Numeric(20, 10))
    ema_50: Mapped[float | None] = mapped_column(Numeric(20, 10))
    ema_200: Mapped[float | None] = mapped_column(Numeric(20, 10))
    atr: Mapped[float | None] = mapped_column(Numeric(20, 10))
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )

    candle: Mapped[Candle] = relationship(back_populates="indicators")


class MarketStructure(Base):
    __tablename__ = "market_structure"

    id: Mapped[int] = mapped_column(primary_key=True)
    candle_id: Mapped[int] = mapped_column(
        ForeignKey("candles.id"), nullable=False, unique=True
    )
    trend: Mapped[str] = mapped_column(
        Enum("UP", "DOWN", "SIDEWAYS", name="trend_direction"), nullable=False
    )
    bos: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    liquidity_sweep: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False
    )
    structure_strength: Mapped[float | None] = mapped_column(Numeric(10, 6))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )

    candle: Mapped[Candle] = relationship(back_populates="market_structure")


class MarketContext(Base):
    __tablename__ = "market_context"

    id: Mapped[int] = mapped_column(primary_key=True)
    candle_id: Mapped[int] = mapped_column(
        ForeignKey("candles.id"), nullable=False, unique=True
    )
    session: Mapped[str] = mapped_column(
        Enum("ASIA", "LONDON", "NEW_YORK", "OVERLAP", name="trading_session"),
        nullable=False,
    )
    volatility_atr: Mapped[float | None] = mapped_column(Numeric(20, 10))
    spread: Mapped[float | None] = mapped_column(Numeric(20, 10))
    bid_price: Mapped[float | None] = mapped_column(Numeric(20, 10))
    ask_price: Mapped[float | None] = mapped_column(Numeric(20, 10))
    slippage_estimate: Mapped[float | None] = mapped_column(Numeric(20, 10))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )

    candle: Mapped[Candle] = relationship(back_populates="market_context")


class Label(Base):
    __tablename__ = "labels"

    id: Mapped[int] = mapped_column(primary_key=True)
    candle_id: Mapped[int] = mapped_column(
        ForeignKey("candles.id"), nullable=False, unique=True
    )
    label: Mapped[int] = mapped_column(Integer, nullable=False)
    future_return_percent: Mapped[float | None] = mapped_column(Numeric(12, 6))
    hold_period_candles: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )

    candle: Mapped[Candle] = relationship(back_populates="labels")


class MultiTimeframeBias(Base):
    __tablename__ = "multi_timeframe_bias"
    __table_args__ = (UniqueConstraint("symbol_id", "timestamp_utc"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    symbol_id: Mapped[int] = mapped_column(ForeignKey("symbols.id"), nullable=False)
    timestamp_utc: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    h1_bias: Mapped[str] = mapped_column(
        Enum("UP", "DOWN", "SIDEWAYS", name="trend_direction"), nullable=False
    )
    m5_bias: Mapped[str] = mapped_column(
        Enum("UP", "DOWN", "SIDEWAYS", name="trend_direction"), nullable=False
    )
    m1_bias: Mapped[str] = mapped_column(
        Enum("UP", "DOWN", "SIDEWAYS", name="trend_direction"), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )

    symbol: Mapped[Symbol] = relationship(back_populates="multi_timeframe_bias")


class DataQualityCheck(Base):
    __tablename__ = "data_quality_checks"

    id: Mapped[int] = mapped_column(primary_key=True)
    candle_id: Mapped[int] = mapped_column(ForeignKey("candles.id"), nullable=False)
    is_valid: Mapped[bool] = mapped_column(Boolean, nullable=False)
    issue_log: Mapped[str | None] = mapped_column(Text)
    checked_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )

    candle: Mapped[Candle] = relationship(back_populates="data_quality_checks")
