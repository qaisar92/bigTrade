BEGIN;

-- Enumerations for strongly typed categorical market features.
CREATE TYPE trend_direction AS ENUM ('UP', 'DOWN', 'SIDEWAYS');
CREATE TYPE trading_session AS ENUM ('ASIA', 'LONDON', 'NEW_YORK', 'OVERLAP');

-- Dimension table for tradable instruments.
CREATE TABLE symbols (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    symbol VARCHAR(32) NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_symbols_symbol UNIQUE (symbol),
    CONSTRAINT chk_symbols_symbol_not_blank CHECK (btrim(symbol) <> '')
);

COMMENT ON TABLE symbols IS 'Reference data for tradable instruments such as forex pairs or CFDs.';
COMMENT ON COLUMN symbols.symbol IS 'Unique broker-independent symbol code, for example EURUSD.';

-- Dimension table for candle aggregation intervals.
CREATE TABLE timeframes (
    id SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(8) NOT NULL,
    minutes INTEGER NOT NULL,
    CONSTRAINT uq_timeframes_name UNIQUE (name),
    CONSTRAINT uq_timeframes_minutes UNIQUE (minutes),
    CONSTRAINT chk_timeframes_name_not_blank CHECK (btrim(name) <> ''),
    CONSTRAINT chk_timeframes_minutes_positive CHECK (minutes > 0)
);

COMMENT ON TABLE timeframes IS 'Reference data for supported candle aggregation windows.';
COMMENT ON COLUMN timeframes.name IS 'Canonical timeframe name such as M1, M5, M15, H1, H4, or D1.';

-- Central fact table for time-series price bars.
CREATE TABLE candles (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    symbol_id BIGINT NOT NULL,
    timeframe_id SMALLINT NOT NULL,
    timestamp_utc TIMESTAMPTZ NOT NULL,
    open NUMERIC(20,10) NOT NULL,
    high NUMERIC(20,10) NOT NULL,
    low NUMERIC(20,10) NOT NULL,
    close NUMERIC(20,10) NOT NULL,
    volume NUMERIC(20,4) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_candles_symbol FOREIGN KEY (symbol_id) REFERENCES symbols (id) ON DELETE RESTRICT,
    CONSTRAINT fk_candles_timeframe FOREIGN KEY (timeframe_id) REFERENCES timeframes (id) ON DELETE RESTRICT,
    CONSTRAINT uq_candles_symbol_timeframe_ts UNIQUE (symbol_id, timeframe_id, timestamp_utc),
    CONSTRAINT chk_candles_open_positive CHECK (open > 0),
    CONSTRAINT chk_candles_high_positive CHECK (high > 0),
    CONSTRAINT chk_candles_low_positive CHECK (low > 0),
    CONSTRAINT chk_candles_close_positive CHECK (close > 0),
    CONSTRAINT chk_candles_volume_non_negative CHECK (volume >= 0),
    CONSTRAINT chk_candles_ohlc_bounds CHECK (
        high >= GREATEST(open, close)
        AND low <= LEAST(open, close)
        AND high >= low
    )
);

COMMENT ON TABLE candles IS 'Canonical OHLCV fact table keyed by symbol, timeframe, and UTC candle timestamp.';
COMMENT ON COLUMN candles.timestamp_utc IS 'UTC-aligned candle open time stored as timestamptz.';
COMMENT ON COLUMN candles.ingested_at IS 'UTC timestamp when the Expert Advisor ingested or transmitted the record.';

-- Derived technical indicators versioned per candle.
CREATE TABLE indicators (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candle_id BIGINT NOT NULL,
    rsi NUMERIC(10,6),
    macd NUMERIC(20,10),
    macd_signal NUMERIC(20,10),
    ema_20 NUMERIC(20,10),
    ema_50 NUMERIC(20,10),
    ema_200 NUMERIC(20,10),
    atr NUMERIC(20,10),
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_indicators_candle FOREIGN KEY (candle_id) REFERENCES candles (id) ON DELETE CASCADE,
    CONSTRAINT uq_indicators_candle_version UNIQUE (candle_id, version),
    CONSTRAINT chk_indicators_version_positive CHECK (version > 0),
    CONSTRAINT chk_indicators_rsi_range CHECK (rsi IS NULL OR (rsi >= 0 AND rsi <= 100)),
    CONSTRAINT chk_indicators_atr_non_negative CHECK (atr IS NULL OR atr >= 0)
);

COMMENT ON TABLE indicators IS 'Versioned technical indicator feature set derived from a single candle.';

-- Market structure annotations at candle granularity.
CREATE TABLE market_structure (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candle_id BIGINT NOT NULL,
    trend trend_direction NOT NULL,
    bos BOOLEAN NOT NULL DEFAULT FALSE,
    liquidity_sweep BOOLEAN NOT NULL DEFAULT FALSE,
    structure_strength NUMERIC(10,6),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_market_structure_candle FOREIGN KEY (candle_id) REFERENCES candles (id) ON DELETE CASCADE,
    CONSTRAINT uq_market_structure_candle UNIQUE (candle_id),
    CONSTRAINT chk_market_structure_strength_non_negative CHECK (
        structure_strength IS NULL OR structure_strength >= 0
    )
);

COMMENT ON TABLE market_structure IS 'Single-row structural market annotation per candle, including trend and liquidity behavior.';

-- Market context and execution environment features.
CREATE TABLE market_context (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candle_id BIGINT NOT NULL,
    session trading_session NOT NULL,
    volatility_atr NUMERIC(20,10),
    spread NUMERIC(20,10),
    bid_price NUMERIC(20,10),
    ask_price NUMERIC(20,10),
    slippage_estimate NUMERIC(20,10),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_market_context_candle FOREIGN KEY (candle_id) REFERENCES candles (id) ON DELETE CASCADE,
    CONSTRAINT uq_market_context_candle UNIQUE (candle_id),
    CONSTRAINT chk_market_context_volatility_non_negative CHECK (
        volatility_atr IS NULL OR volatility_atr >= 0
    ),
    CONSTRAINT chk_market_context_spread_non_negative CHECK (
        spread IS NULL OR spread >= 0
    ),
    CONSTRAINT chk_market_context_slippage_non_negative CHECK (
        slippage_estimate IS NULL OR slippage_estimate >= 0
    ),
    CONSTRAINT chk_market_context_bid_positive CHECK (
        bid_price IS NULL OR bid_price > 0
    ),
    CONSTRAINT chk_market_context_ask_positive CHECK (
        ask_price IS NULL OR ask_price > 0
    ),
    CONSTRAINT chk_market_context_quote_order CHECK (
        bid_price IS NULL OR ask_price IS NULL OR ask_price >= bid_price
    )
);

COMMENT ON TABLE market_context IS 'Execution context and session-level microstructure features aligned to a candle.';

-- Supervised learning target values derived from future outcomes.
CREATE TABLE labels (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candle_id BIGINT NOT NULL,
    label SMALLINT NOT NULL,
    future_return_percent NUMERIC(12,6),
    hold_period_candles INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_labels_candle FOREIGN KEY (candle_id) REFERENCES candles (id) ON DELETE CASCADE,
    CONSTRAINT uq_labels_candle UNIQUE (candle_id),
    CONSTRAINT chk_labels_class CHECK (label IN (0, 1, 2)),
    CONSTRAINT chk_labels_hold_period_positive CHECK (hold_period_candles > 0)
);

COMMENT ON TABLE labels IS 'Supervised ML target table where label values map to SELL=0, BUY=1, and NO_TRADE=2.';

-- Snapshot of directional bias across coordinated timeframes for the same symbol.
CREATE TABLE multi_timeframe_bias (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    symbol_id BIGINT NOT NULL,
    timestamp_utc TIMESTAMPTZ NOT NULL,
    h1_bias trend_direction NOT NULL,
    m5_bias trend_direction NOT NULL,
    m1_bias trend_direction NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_multi_timeframe_bias_symbol FOREIGN KEY (symbol_id) REFERENCES symbols (id) ON DELETE RESTRICT,
    CONSTRAINT uq_multi_timeframe_bias_symbol_ts UNIQUE (symbol_id, timestamp_utc)
);

COMMENT ON TABLE multi_timeframe_bias IS 'Point-in-time directional bias snapshot across higher and lower execution timeframes.';

-- Audit trail for validation and anomaly detection results.
CREATE TABLE data_quality_checks (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candle_id BIGINT NOT NULL,
    is_valid BOOLEAN NOT NULL,
    issue_log TEXT,
    checked_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_data_quality_checks_candle FOREIGN KEY (candle_id) REFERENCES candles (id) ON DELETE CASCADE,
    CONSTRAINT chk_data_quality_checks_issue_log_required CHECK (
        is_valid OR issue_log IS NOT NULL
    )
);

COMMENT ON TABLE data_quality_checks IS 'Validation log for candle-level integrity and data anomaly checks.';

-- Core time-series access patterns.
CREATE INDEX idx_candles_timestamp_utc ON candles (timestamp_utc);
CREATE INDEX idx_candles_symbol_timeframe ON candles (symbol_id, timeframe_id);

-- The following lookup patterns are covered by unique constraints, which also create indexes:
-- indicators(candle_id) via uq_indicators_candle_version
-- market_structure(candle_id) via uq_market_structure_candle
-- market_context(candle_id) via uq_market_context_candle
-- labels(candle_id) via uq_labels_candle
-- multi_timeframe_bias(symbol_id, timestamp_utc) via uq_multi_timeframe_bias_symbol_ts

-- Additional supporting index for repeated quality-audit lookups by candle.
CREATE INDEX idx_data_quality_checks_candle_id ON data_quality_checks (candle_id);

COMMIT;