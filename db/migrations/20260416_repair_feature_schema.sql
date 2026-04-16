BEGIN;

ALTER TABLE market_structure
    ADD COLUMN IF NOT EXISTS structure_strength NUMERIC(10,6);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_market_structure_strength_non_negative'
    ) THEN
        ALTER TABLE market_structure
            ADD CONSTRAINT chk_market_structure_strength_non_negative
            CHECK (structure_strength IS NULL OR structure_strength >= 0);
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM indicators
        GROUP BY candle_id, version
        HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'Cannot add uq_indicators_candle_version: duplicate (candle_id, version) rows exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'uq_indicators_candle_version'
    ) THEN
        ALTER TABLE indicators
            ADD CONSTRAINT uq_indicators_candle_version UNIQUE (candle_id, version);
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'uq_market_structure_candle'
    ) THEN
        ALTER TABLE market_structure
            ADD CONSTRAINT uq_market_structure_candle UNIQUE (candle_id);
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'uq_market_context_candle'
    ) THEN
        ALTER TABLE market_context
            ADD CONSTRAINT uq_market_context_candle UNIQUE (candle_id);
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'uq_labels_candle'
    ) THEN
        ALTER TABLE labels
            ADD CONSTRAINT uq_labels_candle UNIQUE (candle_id);
    END IF;
END $$;

COMMIT;