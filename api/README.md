# Trading Ingest API

FastAPI server that ingests market data payloads from an MT5 Expert Advisor, validates them strictly with Pydantic, and logs everything to file + console.

## Architecture

```
api/
├── app/
│   ├── models.py          # Pydantic event models (feature/label/batch)
│   ├── logger.py          # Logging factory with file + stream handlers
│   └── routers/
│       └── ingest.py      # POST /ingest and POST /ingest/batch endpoints
└── main.py                # Thin entry point; wires routes and app
```

**Key design:**
- `_StrictModel` base class enforces `extra="forbid"` across all event types
- `_EventBase` extracts shared header fields to eliminate duplication
- Logger factory ensures safe hot-reload behavior (handler dedup)
- Routers own their dependencies; main.py only wires

## Quick Start

### 1. Start PostgreSQL + pgAdmin (Docker)

From project root:
```bash
cd /c/Users/qaisa/Documents/bigTrade
docker compose up -d
```

- PostgreSQL: `localhost:5432`
- pgAdmin: `http://localhost:5050`

### 2. Start the API server

From `api/` directory:
```bash
cd /c/Users/qaisa/Documents/bigTrade/api
uv run uvicorn main:app --reload
```

- API: `http://127.0.0.1:8000`
- Swagger docs: `http://127.0.0.1:8000/docs`
- Logs: `api/logs/ea_ingest.log`

### 3. Setup MT5 permissions (one-time)

In MetaTrader 5:

**Tools → Options → Expert Advisors → ✓ "Allow WebRequest for listed URL"**

Add both URLs:
- `http://127.0.0.1:8000`
- `http://localhost:8000`

Restart MT5 after saving.

### 4. Compile & attach the EA

1. Open MetaEditor → compile `mt5/EA_MarketDataCollector.mq5`
2. Open a **EURUSD chart** (not Strategy Tester)
3. Drag EA onto the chart → **Allow DLL imports** + **AutoTrading**
4. Verify EA parameters:
   - `InpApiUrl`: `http://127.0.0.1:8000/ingest`
   - `InpDatasetSplit`: `live` (or `train`/`test`)
   - `InpEnableBatching`: `false` (single-event mode)

## Verification

After the first closed candle, check logs:
```bash
cat api/logs/ea_ingest.log | tail -20
```

You should see JSON payloads with `event_type: feature` and `event_type: label`.

**If still seeing `err=4014` in MT5 Experts log:** URL whitelist wasn't saved → restart MT5.

## Endpoints

### POST `/ingest`

Send a single feature or label event:

```json
{
  "event_type": "feature",
  "schema_version": "schema_v1",
  "feature_version": "v1.0",
  "label_version": "v1.0",
  "dataset_split": "live",
  "event_id": "DCF95E87C5FADDCA",
  "symbol": "EURUSD",
  "timeframe": "M1",
  "timestamp_utc": "2026-04-16T11:40:00Z",
  "candle": {
    "open": 1.17844,
    "high": 1.17844,
    "low": 1.17835,
    "close": 1.17837,
    "volume": 116.0
  },
  "indicators": {
    "rsi": 43.48,
    "macd": -8.259e-7,
    "macd_signal": 0.0000179669,
    "ema20": 1.1784964654,
    "ema50": 1.178384182,
    "ema200": 1.1783851925,
    "atr": 0.0001114286
  },
  "structure": {
    "trend": "DOWN",
    "bos": 0,
    "liquidity_sweep": 0
  },
  "context": {
    "session": "LONDON",
    "spread": 0.00009,
    "bid": 1.17832,
    "ask": 1.17841,
    "volatility": 0.0001114286
  }
}
```

**Response (HTTP 200):**
```json
{
  "status": "ok",
  "received": true,
  "event_id": "DCF95E87C5FADDCA"
}
```

### POST `/ingest/batch`

Send multiple events at once:

```json
{
  "event_type": "batch",
  "schema_version": "schema_v1",
  "dataset_split": "live",
  "items": [
    { /* feature or label event */ },
    { /* feature or label event */ }
  ]
}
```

**Response (HTTP 200):**
```json
{
  "status": "ok",
  "received": true,
  "count": 2
}
```

## Validation

- **Unknown fields** → HTTP 422 (Pydantic `extra="forbid"`)
- **Invalid `event_type`** → HTTP 422 (discriminated union)
- **Invalid `dataset_split`** → HTTP 422 (Literal constraint)
- **Missing required fields** → HTTP 422
- **Type mismatches** → HTTP 422

## Logging

Each ingest triggers **two log lines**:

1. **Metadata line** (human-readable summary)
   ```
   2026-04-16 12:49:08 | INFO | ingest single event_type=feature event_id=DCF95E87C5FADDCA symbol=EURUSD timeframe=M1
   ```

2. **Full payload line** (JSON for downstream parsing)
   ```
   2026-04-16 12:49:08 | INFO | ingest single payload={"event_type":"feature",...}
   ```

Logs go to both `api/logs/ea_ingest.log` and stdout.

## Development

### Add a new endpoint

1. Create a new file in `app/routers/` (e.g., `labels.py`)
2. Define route handlers and import them into `main.py`
3. Register with `app.include_router(router)`

### Add a new model

1. Add to `app/models.py` inheriting from `_StrictModel`
2. Import in `app/routers/ingest.py` and use in handlers

### Modify logger behavior

Edit `app/logger.py` to change format, log level, or output destinations.

## Requirements

See `pyproject.toml`:
- `fastapi>=0.135.3`
- `pydantic>=2.13.1`
- `uvicorn>=0.44.0`

Install with:
```bash
uv sync
```
