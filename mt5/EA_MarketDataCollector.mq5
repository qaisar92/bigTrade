#property strict
#property version   "1.00"
#property description "Deterministic MT5 market data collector for REST ingestion (no trading, no DB)."

input string InpSymbol                 = "";
input string InpApiUrl                 = "http://127.0.0.1:8000/ingest";
input int    InpRequestTimeoutMs       = 1500;
input int    InpMaxRetries             = 3;
input int    InpRetryDelayMs           = 200;
input int    InpSwingLookbackBars      = 5;
input int    InpSweepThresholdPoints   = 5;
input bool   InpEnableLabelCollector   = true;
input int    InpLabelHoldPeriodCandles = 3;   // Allowed range: 1..5
input double InpNoTradeThresholdPct    = 0.02;
input int    InpMaxSpreadPoints        = 200;
input double InpMaxVolume              = 1000000000.0;
input bool   InpEnableBatching         = false;
input int    InpBatchSize              = 5;
input string InpFeatureVersion         = "v1.0";
input string InpLabelVersion           = "v1.0";
input string InpSchemaVersion          = "schema_v1";
input string InpDatasetSplit           = "live"; // train | test | live
input string InpBatchApiUrl            = "http://127.0.0.1:8000/ingest/batch";

#define TF_COUNT 4
#define SENT_CACHE_LIMIT 100000

const ENUM_TIMEFRAMES ALLOWED_TFS[TF_COUNT] = { PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_H1 };
const string ALLOWED_TF_NAMES[TF_COUNT]     = { "M1", "M5", "M15", "H1" };

struct TFContext
{
   ENUM_TIMEFRAMES tf;
   string          tf_name;
   datetime        last_processed_bar_utc;
   int             h_rsi;
   int             h_macd;
   int             h_ema20;
   int             h_ema50;
   int             h_ema200;
   int             h_atr;
};

struct PendingItem
{
   string event_id;
   string payload;
   int    attempts;
};

TFContext   g_tf_contexts[TF_COUNT];
PendingItem g_queue[];
string      g_sent_event_ids[];
string      g_symbol = "";
bool        g_ready  = false;

string QUEUE_FILE = "EA_MarketDataCollector_queue.tsv";
string SENT_FILE  = "EA_MarketDataCollector_sent.tsv";
string DLQ_FILE   = "EA_MarketDataCollector_deadletter.tsv";

enum SendResult
{
   SEND_OK = 0,
   SEND_DUPLICATE = 1,
   SEND_RETRYABLE_FAIL = 2,
   SEND_NON_RETRYABLE_FAIL = 3
};

// ---------- Utility ----------
string JsonEscape(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\r", "");
   StringReplace(s, "\n", " ");
   return s;
}

string TimeframeToName(const ENUM_TIMEFRAMES tf)
{
   for(int i = 0; i < TF_COUNT; i++)
   {
      if(ALLOWED_TFS[i] == tf)
         return ALLOWED_TF_NAMES[i];
   }
   return "";
}

bool IsAllowedTimeframe(const ENUM_TIMEFRAMES tf)
{
   return TimeframeToName(tf) != "";
}

datetime BrokerToUtc(const datetime broker_time)
{
   // MT5 bars are broker-time based. Convert using current server-GMT offset.
   int offset_seconds = (int)(TimeTradeServer() - TimeGMT());
   return broker_time - offset_seconds;
}

string ToIsoUtc(const datetime t)
{
   string d = TimeToString(t, TIME_DATE);
   string h = TimeToString(t, TIME_SECONDS);
   StringReplace(d, ".", "-");
   return d + "T" + h + "Z";
}

string HashEventId(const string source_text)
{
   uchar bytes[];
   int len = StringToCharArray(source_text, bytes, 0, WHOLE_ARRAY, CP_UTF8);
   if(len <= 0)
      return "0000000000000000";

   ulong hash = 1469598103934665603;
   ulong prime = 1099511628211;

   // Ignore trailing null terminator from StringToCharArray.
   for(int i = 0; i < len - 1; i++)
   {
      hash ^= (ulong)bytes[i];
      hash *= prime;
   }

   return StringFormat("%016I64X", hash);
}

bool IsFiniteNumber(const double v)
{
   return (MathIsValidNumber(v) && v != DBL_MAX && v != -DBL_MAX);
}

bool IsValidDatasetSplit(const string split)
{
   return (split == "train" || split == "test" || split == "live");
}

string BuildWebRequestErrorHint(const int err_code)
{
   if(err_code == 4014)
   {
      return " WebRequest blocked (err=4014). In MT5: Tools -> Options -> Expert Advisors -> check 'Allow WebRequest for listed URL' and add both URLs: " +
             InpApiUrl + " and " + InpBatchApiUrl +
             ". If MT5 still cannot reach localhost, also try 127.0.0.1 in EA inputs. WebRequest is not available in Strategy Tester.";
   }
   return "";
}

void WriteDeadLetter(const string event_id, const string reason, const string payload)
{
   int f = FileOpen(DLQ_FILE, FILE_COMMON | FILE_CSV | FILE_READ | FILE_WRITE, '\t');
   if(f == INVALID_HANDLE)
   {
      Print("Dead-letter write failed. event_id=", event_id, " err=", GetLastError());
      return;
   }

   FileSeek(f, 0, SEEK_END);
   FileWrite(f, event_id, (string)TimeGMT(), reason, payload);
   FileClose(f);
}

// ---------- Dedup tracking ----------
bool IsSentEvent(const string event_id)
{
   int n = ArraySize(g_sent_event_ids);
   for(int i = 0; i < n; i++)
   {
      if(g_sent_event_ids[i] == event_id)
         return true;
   }
   return false;
}

void AddSentEvent(const string event_id)
{
   if(IsSentEvent(event_id))
      return;

   int n = ArraySize(g_sent_event_ids);
   ArrayResize(g_sent_event_ids, n + 1);
   g_sent_event_ids[n] = event_id;

   int f = FileOpen(SENT_FILE, FILE_COMMON | FILE_CSV | FILE_READ | FILE_WRITE, '\t');
   if(f != INVALID_HANDLE)
   {
      FileSeek(f, 0, SEEK_END);
      FileWrite(f, event_id, (string)TimeGMT());
      FileClose(f);
   }

   if(ArraySize(g_sent_event_ids) > SENT_CACHE_LIMIT)
   {
      int drop = ArraySize(g_sent_event_ids) - SENT_CACHE_LIMIT;
      for(int i = 0; i < SENT_CACHE_LIMIT; i++)
         g_sent_event_ids[i] = g_sent_event_ids[i + drop];
      ArrayResize(g_sent_event_ids, SENT_CACHE_LIMIT);
   }
}

void LoadSentEvents()
{
   int f = FileOpen(SENT_FILE, FILE_COMMON | FILE_CSV | FILE_READ, '\t');
   if(f == INVALID_HANDLE)
      return;

   while(!FileIsEnding(f))
   {
      string event_id = FileReadString(f);
      string ts = FileReadString(f);
      if(event_id == "")
         continue;

      int n = ArraySize(g_sent_event_ids);
      ArrayResize(g_sent_event_ids, n + 1);
      g_sent_event_ids[n] = event_id;
   }
   FileClose(f);
}

// ---------- Queue persistence ----------
bool IsQueued(const string event_id)
{
   int n = ArraySize(g_queue);
   for(int i = 0; i < n; i++)
   {
      if(g_queue[i].event_id == event_id)
         return true;
   }
   return false;
}

void PersistQueueToFile()
{
   int f = FileOpen(QUEUE_FILE, FILE_COMMON | FILE_CSV | FILE_WRITE, '\t');
   if(f == INVALID_HANDLE)
   {
      Print("Queue persist failed. LastError=", GetLastError());
      return;
   }

   int n = ArraySize(g_queue);
   for(int i = 0; i < n; i++)
      FileWrite(f, g_queue[i].event_id, g_queue[i].attempts, g_queue[i].payload);

   FileClose(f);
}

void LoadQueueFromFile()
{
   int f = FileOpen(QUEUE_FILE, FILE_COMMON | FILE_CSV | FILE_READ, '\t');
   if(f == INVALID_HANDLE)
      return;

   while(!FileIsEnding(f))
   {
      string event_id = FileReadString(f);
      int attempts = (int)FileReadNumber(f);
      string payload = FileReadString(f);

      if(event_id == "" || payload == "")
         continue;
      if(IsSentEvent(event_id) || IsQueued(event_id))
         continue;

      int n = ArraySize(g_queue);
      ArrayResize(g_queue, n + 1);
      g_queue[n].event_id = event_id;
      g_queue[n].payload = payload;
      g_queue[n].attempts = attempts;
   }
   FileClose(f);
}

void EnqueuePayload(const string event_id, const string payload)
{
   if(event_id == "" || payload == "")
      return;
   if(IsSentEvent(event_id) || IsQueued(event_id))
      return;

   int n = ArraySize(g_queue);
   ArrayResize(g_queue, n + 1);
   g_queue[n].event_id = event_id;
   g_queue[n].payload = payload;
   g_queue[n].attempts = 0;

   PersistQueueToFile();
   Print("Queued payload for retry. event_id=", event_id, " queue_size=", ArraySize(g_queue));
}

void RemoveQueueItem(const int idx)
{
   int n = ArraySize(g_queue);
   if(idx < 0 || idx >= n)
      return;

   for(int i = idx; i < n - 1; i++)
      g_queue[i] = g_queue[i + 1];

   ArrayResize(g_queue, n - 1);
   PersistQueueToFile();
}

// ---------- API ----------
bool ResponseLooksOk(string body, const string event_id)
{
   StringReplace(body, " ", "");
   StringReplace(body, "\n", "");
   StringReplace(body, "\r", "");

   // "skipped" (e.g. label with no matching candle yet) is a deliberate terminal
   // response — treat it the same as "ok" so we don't retry or dead-letter it.
   bool status_ok      = (StringFind(body, "\"status\":\"ok\"")      >= 0);
   bool status_skipped = (StringFind(body, "\"status\":\"skipped\"") >= 0);

   if(status_skipped)
      return true;

   if(!status_ok)
      return false;

   bool received_true = (StringFind(body, "\"received\":true") >= 0);
   if(!received_true)
      return false;

   // If event_id appears in body, it must match.
   int pos = StringFind(body, "\"event_id\":\"");
   if(pos >= 0)
   {
      int start = pos + StringLen("\"event_id\":\"");
      int end = StringFind(body, "\"", start);
      if(end > start)
      {
         string returned = StringSubstr(body, start, end - start);
         if(returned != event_id)
            return false;
      }
   }

   return true;
}

SendResult SendPayloadWithRetry(const string event_id, const string payload)
{
   char data[];
   char result[];
   string response_headers;
   string headers = "Content-Type: application/json\r\n";

   StringToCharArray(payload, data, 0, StringLen(payload), CP_UTF8);

   for(int attempt = 1; attempt <= InpMaxRetries; attempt++)
   {
      ResetLastError();
      int code = WebRequest("POST", InpApiUrl, headers, InpRequestTimeoutMs, data, result, response_headers);

      if(code == -1)
      {
         int err = GetLastError();
         Print("WebRequest transport error. event_id=", event_id,
               " attempt=", attempt,
            " err=", err,
            BuildWebRequestErrorHint(err));
      }
      else
      {
         string body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);

         if(code == 409)
         {
            Print("Duplicate accepted (idempotent). event_id=", event_id, " http=409");
            return SEND_DUPLICATE;
         }

         if(code >= 200 && code < 300 && ResponseLooksOk(body, event_id))
         {
            Print("Ingest success. event_id=", event_id, " http=", code);
            return SEND_OK;
         }

          if(code == 400)
          {
            Print("Bad data (non-retryable). event_id=", event_id, " http=400 body=", body);
            return SEND_NON_RETRYABLE_FAIL;
          }

          if(code >= 500)
          {
            Print("Server error (retryable). event_id=", event_id,
                  " attempt=", attempt,
                  " http=", code,
                  " body=", body);
          }
          else if(code >= 400)
          {
            Print("Client error (non-retryable). event_id=", event_id,
                  " http=", code,
                  " body=", body);
            return SEND_NON_RETRYABLE_FAIL;
          }
          else
          {
            Print("Unexpected HTTP status. event_id=", event_id,
                  " attempt=", attempt,
                  " http=", code,
                  " body=", body);
          }
      }

      if(attempt < InpMaxRetries)
         Sleep(InpRetryDelayMs);
   }

   return SEND_RETRYABLE_FAIL;
}

string BuildBatchPayload(const int start_index, const int item_count)
{
   string json = "{";
   json += "\"event_type\":\"batch\",";
   json += "\"schema_version\":\"" + JsonEscape(InpSchemaVersion) + "\",";
   json += "\"dataset_split\":\"" + JsonEscape(InpDatasetSplit) + "\",";
   json += "\"items\":[";

   for(int i = 0; i < item_count; i++)
   {
      int idx = start_index + i;
      if(i > 0)
         json += ",";
      json += g_queue[idx].payload;
   }

   json += "]}";
   return json;
}

SendResult SendBatchWithRetry(const string batch_payload)
{
   char data[];
   char result[];
   string response_headers;
   string headers = "Content-Type: application/json\r\n";

   StringToCharArray(batch_payload, data, 0, StringLen(batch_payload), CP_UTF8);

   for(int attempt = 1; attempt <= InpMaxRetries; attempt++)
   {
      ResetLastError();
      int code = WebRequest("POST", InpBatchApiUrl, headers, InpRequestTimeoutMs, data, result, response_headers);

      if(code == -1)
      {
         int err = GetLastError();
         Print("Batch WebRequest transport error. attempt=", attempt,
               " err=", err,
               BuildWebRequestErrorHint(err));
      }
      else
      {
         string body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);

         if(code == 409)
            return SEND_DUPLICATE;
         if(code >= 200 && code < 300)
            return SEND_OK;
         if(code == 400)
            return SEND_NON_RETRYABLE_FAIL;
         if(code >= 400 && code < 500)
            return SEND_NON_RETRYABLE_FAIL;

         Print("Batch send retryable failure. attempt=", attempt, " http=", code, " body=", body);
      }

      if(attempt < InpMaxRetries)
         Sleep(InpRetryDelayMs);
   }

   return SEND_RETRYABLE_FAIL;
}

void ProcessQueue()
{
   if(InpEnableBatching)
   {
      while(ArraySize(g_queue) > 0)
      {
         int batch_size = MathMax(1, MathMin(InpBatchSize, ArraySize(g_queue)));
         string batch_payload = BuildBatchPayload(0, batch_size);
         SendResult r = SendBatchWithRetry(batch_payload);

         if(r == SEND_OK || r == SEND_DUPLICATE)
         {
            for(int i = 0; i < batch_size; i++)
               AddSentEvent(g_queue[i].event_id);
            for(int j = 0; j < batch_size; j++)
               RemoveQueueItem(0);
            continue;
         }

         for(int k = 0; k < batch_size; k++)
            g_queue[k].attempts++;

         if(r == SEND_NON_RETRYABLE_FAIL)
         {
            for(int m = 0; m < batch_size; m++)
            {
               WriteDeadLetter(g_queue[m].event_id, "batch_non_retryable", g_queue[m].payload);
               AddSentEvent(g_queue[m].event_id);
            }
            for(int n = 0; n < batch_size; n++)
               RemoveQueueItem(0);
            continue;
         }

         // Retryable failure: keep queue for next candle.
         break;
      }
      return;
   }

   int i = 0;
   while(i < ArraySize(g_queue))
   {
      if(IsSentEvent(g_queue[i].event_id))
      {
         RemoveQueueItem(i);
         continue;
      }

      SendResult r = SendPayloadWithRetry(g_queue[i].event_id, g_queue[i].payload);
      g_queue[i].attempts++;

      if(r == SEND_OK || r == SEND_DUPLICATE)
      {
         AddSentEvent(g_queue[i].event_id);
         RemoveQueueItem(i);
      }
      else if(r == SEND_NON_RETRYABLE_FAIL)
      {
         WriteDeadLetter(g_queue[i].event_id, "single_non_retryable", g_queue[i].payload);
         AddSentEvent(g_queue[i].event_id);
         RemoveQueueItem(i);
      }
      else
      {
         // Keep in queue for next candle; move forward.
         i++;
      }
   }
}

// ---------- Feature computation ----------
bool GetIndicatorValue(const int handle, const int buffer_index, const int shift, double &out_val)
{
   if(handle == INVALID_HANDLE)
      return false;

   double tmp[];
   if(CopyBuffer(handle, buffer_index, shift, 1, tmp) != 1)
      return false;

   out_val = tmp[0];
   return IsFiniteNumber(out_val);
}

string DetectSessionUtc(const datetime utc_ts)
{
   MqlDateTime dt;
   TimeToStruct(utc_ts, dt);
   int h = dt.hour;

   if(h >= 13 && h < 16)
      return "OVERLAP";
   if(h >= 7 && h < 13)
      return "LONDON";
   if(h >= 16 && h < 21)
      return "NEW_YORK";
   return "ASIA";
}

string DetectTrend(const double ema50, const double ema200)
{
   if(ema50 > ema200)
      return "UP";
   if(ema50 < ema200)
      return "DOWN";
   return "SIDEWAYS";
}

bool ComputeStructure(const string symbol,
                      const ENUM_TIMEFRAMES tf,
                      const double point,
                      int &bos,
                      int &liq_sweep,
                      double &structure_strength,
                      const double atr,
                      double &prev_swing_high,
                      double &prev_swing_low)
{
   bos = 0;
   liq_sweep = 0;
   structure_strength = 0.0;
   prev_swing_high = 0.0;
   prev_swing_low = 0.0;

   int lookback = MathMax(3, InpSwingLookbackBars);
   int need = lookback + 2; // current closed + previous lookback window

   MqlRates rates[];
   int copied = CopyRates(symbol, tf, 1, need, rates);
   if(copied < need)
      return false;

   prev_swing_high = rates[1].high;
   prev_swing_low = rates[1].low;

   for(int i = 2; i < need; i++)
   {
      if(rates[i].high > prev_swing_high)
         prev_swing_high = rates[i].high;
      if(rates[i].low < prev_swing_low)
         prev_swing_low = rates[i].low;
   }

   double c = rates[0].close;
   double h = rates[0].high;
   double l = rates[0].low;

   if(c > prev_swing_high || c < prev_swing_low)
      bos = 1;

   double threshold = (double)MathMax(1, InpSweepThresholdPoints) * point;
   if((h - prev_swing_high) >= threshold || (prev_swing_low - l) >= threshold)
      liq_sweep = 1;

   // Strength combines close-based break distance and wick-based sweep distance,
   // normalized by ATR so scores are comparable across volatility regimes.
   double breakout_dist = 0.0;
   if(c > prev_swing_high)
      breakout_dist = c - prev_swing_high;
   else if(c < prev_swing_low)
      breakout_dist = prev_swing_low - c;

   double sweep_dist = 0.0;
   if(h > prev_swing_high)
      sweep_dist = h - prev_swing_high;
   if(l < prev_swing_low)
   {
      double down_sweep = prev_swing_low - l;
      if(down_sweep > sweep_dist)
         sweep_dist = down_sweep;
   }

   double base = breakout_dist;
   if(sweep_dist > base)
      base = sweep_dist;

   double norm = MathMax(atr, point);
   structure_strength = base / norm;

   if(!IsFiniteNumber(structure_strength) || structure_strength < 0.0)
      structure_strength = 0.0;

   return true;
}

int ComputeLabelClass(const double current_close,
                      const double future_close,
                      const double threshold_pct,
                      double &future_return_pct)
{
   future_return_pct = 0.0;
   if(current_close <= 0.0)
      return 2;

   future_return_pct = ((future_close - current_close) / current_close) * 100.0;

   double abs_ret = MathAbs(future_return_pct);
   if(abs_ret < threshold_pct)
      return 2;
   if(future_close > current_close)
      return 1;
   if(future_close < current_close)
      return 0;
   return 2;
}

bool ValidateMainData(const double o,
                      const double h,
                      const double l,
                      const double c,
                      const double volume,
                      const double spread,
                      const long spread_points,
                      const double rsi,
                      const double macd,
                      const double macd_signal,
                      const double ema20,
                      const double ema50,
                      const double ema200,
                      const double atr,
                      string &reason)
{
   reason = "";

   if(!(h >= l && h >= MathMax(o, c) && l <= MathMin(o, c)))
   {
      reason = "invalid_ohlc_bounds";
      return false;
   }

   if(volume < 0.0 || volume > InpMaxVolume)
   {
      reason = "volume_out_of_range";
      return false;
   }

   if(spread < 0.0 || spread_points > InpMaxSpreadPoints)
   {
      reason = "spread_out_of_range";
      return false;
   }

   if(!IsFiniteNumber(rsi) || !IsFiniteNumber(macd) || !IsFiniteNumber(macd_signal) ||
      !IsFiniteNumber(ema20) || !IsFiniteNumber(ema50) || !IsFiniteNumber(ema200) || !IsFiniteNumber(atr))
   {
      reason = "indicator_not_finite";
      return false;
   }

   return true;
}

// ---------- JSON builders ----------
string BuildMainPayload(const string event_id,
                        const string symbol,
                        const string tf_name,
                        const datetime bar_utc,
                        const double o,
                        const double h,
                        const double l,
                        const double c,
                        const double volume,
                        const double rsi,
                        const double macd,
                        const double macd_signal,
                        const double ema20,
                        const double ema50,
                        const double ema200,
                        const double atr,
                        const string trend,
                        const int bos,
                        const int liquidity_sweep,
                        const double structure_strength,
                        const string session,
                        const double spread,
                        const double bid,
                        const double ask,
                        const double volatility)
{
   string json = "{";
   json += "\"event_type\":\"feature\",";
   json += "\"schema_version\":\"" + JsonEscape(InpSchemaVersion) + "\",";
   json += "\"feature_version\":\"" + JsonEscape(InpFeatureVersion) + "\",";
   json += "\"label_version\":\"" + JsonEscape(InpLabelVersion) + "\",";
   json += "\"dataset_split\":\"" + JsonEscape(InpDatasetSplit) + "\",";
   json += "\"event_id\":\"" + JsonEscape(event_id) + "\",";
   json += "\"symbol\":\"" + JsonEscape(symbol) + "\",";
   json += "\"timeframe\":\"" + JsonEscape(tf_name) + "\",";
   json += "\"timestamp_utc\":\"" + ToIsoUtc(bar_utc) + "\",";

   json += "\"candle\":{";
   json += "\"open\":" + DoubleToString(o, 10) + ",";
   json += "\"high\":" + DoubleToString(h, 10) + ",";
   json += "\"low\":" + DoubleToString(l, 10) + ",";
   json += "\"close\":" + DoubleToString(c, 10) + ",";
   json += "\"volume\":" + DoubleToString(volume, 2);
   json += "},";

   json += "\"indicators\":{";
   json += "\"rsi\":" + DoubleToString(rsi, 6) + ",";
   json += "\"macd\":" + DoubleToString(macd, 10) + ",";
   json += "\"macd_signal\":" + DoubleToString(macd_signal, 10) + ",";
   json += "\"ema20\":" + DoubleToString(ema20, 10) + ",";
   json += "\"ema50\":" + DoubleToString(ema50, 10) + ",";
   json += "\"ema200\":" + DoubleToString(ema200, 10) + ",";
   json += "\"atr\":" + DoubleToString(atr, 10);
   json += "},";

   json += "\"structure\":{";
   json += "\"trend\":\"" + trend + "\",";
   json += "\"bos\":" + (string)bos + ",";
   json += "\"liquidity_sweep\":" + (string)liquidity_sweep + ",";
   json += "\"structure_strength\":" + DoubleToString(structure_strength, 6);
   json += "},";

   json += "\"context\":{";
   json += "\"session\":\"" + session + "\",";
   json += "\"spread\":" + DoubleToString(spread, 10) + ",";
   json += "\"bid\":" + DoubleToString(bid, 10) + ",";
   json += "\"ask\":" + DoubleToString(ask, 10) + ",";
   json += "\"volatility\":" + DoubleToString(volatility, 10);
   json += "}";

   json += "}";
   return json;
}

string BuildLabelPayload(const string event_id,
                         const string symbol,
                         const string tf_name,
                         const datetime label_bar_utc,
                         const int label,
                         const double future_return_pct,
                         const int hold_period)
{
   string json = "{";
   json += "\"event_type\":\"label\",";
   json += "\"schema_version\":\"" + JsonEscape(InpSchemaVersion) + "\",";
   json += "\"feature_version\":\"" + JsonEscape(InpFeatureVersion) + "\",";
   json += "\"label_version\":\"" + JsonEscape(InpLabelVersion) + "\",";
   json += "\"dataset_split\":\"" + JsonEscape(InpDatasetSplit) + "\",";
   json += "\"event_id\":\"" + JsonEscape(event_id) + "\",";
   json += "\"symbol\":\"" + JsonEscape(symbol) + "\",";
   json += "\"timeframe\":\"" + JsonEscape(tf_name) + "\",";
   json += "\"timestamp_utc\":\"" + ToIsoUtc(label_bar_utc) + "\",";
   json += "\"label\":{";
   json += "\"label\":" + (string)label + ",";
   json += "\"future_return_percent\":" + DoubleToString(future_return_pct, 6) + ",";
   json += "\"hold_period_candles\":" + (string)hold_period;
   json += "},";
   json += "\"computed_at_utc\":\"" + ToIsoUtc(TimeGMT()) + "\"";
   json += "}";
   return json;
}

// ---------- Timeframe processing ----------
bool BuildMainEvent(TFContext &ctx, string &event_id, string &payload)
{
   MqlRates r[];
   if(CopyRates(g_symbol, ctx.tf, 1, 1, r) != 1)
      return false;

   datetime bar_utc = BrokerToUtc(r[0].time);

   double rsi, macd, macd_sig, ema20, ema50, ema200, atr;
   if(!GetIndicatorValue(ctx.h_rsi, 0, 1, rsi))
      return false;
   if(!GetIndicatorValue(ctx.h_macd, 0, 1, macd))
      return false;
   if(!GetIndicatorValue(ctx.h_macd, 1, 1, macd_sig))
      return false;
   if(!GetIndicatorValue(ctx.h_ema20, 0, 1, ema20))
      return false;
   if(!GetIndicatorValue(ctx.h_ema50, 0, 1, ema50))
      return false;
   if(!GetIndicatorValue(ctx.h_ema200, 0, 1, ema200))
      return false;
   if(!GetIndicatorValue(ctx.h_atr, 0, 1, atr))
      return false;

   int bos = 0;
   int liquidity_sweep = 0;
   double structure_strength = 0.0;
   double point = 0.0;
   if(!SymbolInfoDouble(g_symbol, SYMBOL_POINT, point) || point <= 0.0)
      return false;

   double swing_high = 0.0, swing_low = 0.0;
   if(!ComputeStructure(g_symbol, ctx.tf, point, bos, liquidity_sweep,
                        structure_strength, atr, swing_high, swing_low))
      return false;

   string trend = DetectTrend(ema50, ema200);
   string session = DetectSessionUtc(bar_utc);

   double bid = 0.0;
   double ask = 0.0;
   if(!SymbolInfoDouble(g_symbol, SYMBOL_BID, bid) || !SymbolInfoDouble(g_symbol, SYMBOL_ASK, ask))
      return false;

   long spread_points = 0;
   SymbolInfoInteger(g_symbol, SYMBOL_SPREAD, spread_points);
   double spread = (double)spread_points * point;

   double volume = (r[0].real_volume > 0 ? (double)r[0].real_volume : (double)r[0].tick_volume);

   string dq_reason = "";
   if(!ValidateMainData(r[0].open, r[0].high, r[0].low, r[0].close,
                        volume, spread, spread_points,
                        rsi, macd, macd_sig, ema20, ema50, ema200, atr,
                        dq_reason))
   {
      Print("Data quality reject. symbol=", g_symbol, " tf=", ctx.tf_name, " reason=", dq_reason);
      return false;
   }

   string tf_name = ctx.tf_name;
   string hash_input = g_symbol + "|" + tf_name + "|" + ToIsoUtc(bar_utc);
   event_id = HashEventId(hash_input);

   payload = BuildMainPayload(event_id, g_symbol, tf_name, bar_utc,
                              r[0].open, r[0].high, r[0].low, r[0].close, volume,
                              rsi, macd, macd_sig, ema20, ema50, ema200, atr,
                              trend, bos, liquidity_sweep, structure_strength,
                              session, spread, bid, ask, atr);

   return true;
}

bool BuildLabelEvent(TFContext &ctx, string &event_id, string &payload)
{
   if(!InpEnableLabelCollector)
      return false;

   int hold = MathMax(1, MathMin(5, InpLabelHoldPeriodCandles));

   // target_shift: candle to be labeled, future_shift: candle used to derive future outcome
   int target_shift = 1 + hold;
   int future_shift = 1;

   MqlRates r[];
   if(CopyRates(g_symbol, ctx.tf, future_shift, hold + 1, r) < hold + 1)
      return false;

   // r[0] = future_shift (newest closed), r[hold] = target_shift (older candle)
   double current_close = r[hold].close;
   double future_close = r[0].close;

   double future_return_pct = 0.0;
   int label = ComputeLabelClass(current_close, future_close, InpNoTradeThresholdPct, future_return_pct);

   datetime label_bar_utc = BrokerToUtc(r[hold].time);
   string tf_name = ctx.tf_name;
   string hash_input = g_symbol + "|" + tf_name + "|" + ToIsoUtc(label_bar_utc) + "|LABEL";
   event_id = HashEventId(hash_input);

   payload = BuildLabelPayload(event_id, g_symbol, tf_name, label_bar_utc, label, future_return_pct, hold);
   return true;
}

bool IsNewClosedBarUtc(TFContext &ctx, datetime &bar_utc)
{
   datetime t[];
   if(CopyTime(g_symbol, ctx.tf, 1, 1, t) != 1)
      return false;

   bar_utc = BrokerToUtc(t[0]);
   if(bar_utc <= 0)
      return false;

   if(bar_utc == ctx.last_processed_bar_utc)
      return false;

   return true;
}

void ProcessTimeframe(TFContext &ctx)
{
   datetime closed_bar_utc = 0;
   if(!IsNewClosedBarUtc(ctx, closed_bar_utc))
      return;

   string event_id = "";
   string payload = "";
   if(BuildMainEvent(ctx, event_id, payload))
   {
      if(!IsSentEvent(event_id) && !IsQueued(event_id))
      {
         if(InpEnableBatching)
         {
            EnqueuePayload(event_id, payload);
         }
         else
         {
            SendResult r = SendPayloadWithRetry(event_id, payload);
            if(r == SEND_OK || r == SEND_DUPLICATE)
               AddSentEvent(event_id);
            else if(r == SEND_NON_RETRYABLE_FAIL)
            {
               WriteDeadLetter(event_id, "feature_non_retryable", payload);
               AddSentEvent(event_id);
            }
            else
               EnqueuePayload(event_id, payload);
         }
      }
   }
   else
   {
      Print("BuildMainEvent failed. symbol=", g_symbol, " tf=", ctx.tf_name);
   }

   if(InpEnableLabelCollector)
   {
      string label_event_id = "";
      string label_payload = "";
      if(BuildLabelEvent(ctx, label_event_id, label_payload))
      {
         if(!IsSentEvent(label_event_id) && !IsQueued(label_event_id))
         {
            if(InpEnableBatching)
            {
               EnqueuePayload(label_event_id, label_payload);
            }
            else
            {
               SendResult r = SendPayloadWithRetry(label_event_id, label_payload);
               if(r == SEND_OK || r == SEND_DUPLICATE)
                  AddSentEvent(label_event_id);
               else if(r == SEND_NON_RETRYABLE_FAIL)
               {
                  WriteDeadLetter(label_event_id, "label_non_retryable", label_payload);
                  AddSentEvent(label_event_id);
               }
               else
                  EnqueuePayload(label_event_id, label_payload);
            }
         }
      }
   }

   ctx.last_processed_bar_utc = closed_bar_utc;
}

// ---------- Lifecycle ----------
bool InitContext(TFContext &ctx, const ENUM_TIMEFRAMES tf)
{
   if(!IsAllowedTimeframe(tf))
      return false;

   ctx.tf = tf;
   ctx.tf_name = TimeframeToName(tf);
   ctx.last_processed_bar_utc = 0;

   ctx.h_rsi = iRSI(g_symbol, tf, 14, PRICE_CLOSE);
   ctx.h_macd = iMACD(g_symbol, tf, 12, 26, 9, PRICE_CLOSE);
   ctx.h_ema20 = iMA(g_symbol, tf, 20, 0, MODE_EMA, PRICE_CLOSE);
   ctx.h_ema50 = iMA(g_symbol, tf, 50, 0, MODE_EMA, PRICE_CLOSE);
   ctx.h_ema200 = iMA(g_symbol, tf, 200, 0, MODE_EMA, PRICE_CLOSE);
   ctx.h_atr = iATR(g_symbol, tf, 14);

   if(ctx.h_rsi == INVALID_HANDLE ||
      ctx.h_macd == INVALID_HANDLE ||
      ctx.h_ema20 == INVALID_HANDLE ||
      ctx.h_ema50 == INVALID_HANDLE ||
      ctx.h_ema200 == INVALID_HANDLE ||
      ctx.h_atr == INVALID_HANDLE)
   {
      Print("Indicator handle init failed for timeframe ", ctx.tf_name,
            " last_error=", GetLastError());
      return false;
   }

   return true;
}

void ReleaseContext(TFContext &ctx)
{
   if(ctx.h_rsi != INVALID_HANDLE) IndicatorRelease(ctx.h_rsi);
   if(ctx.h_macd != INVALID_HANDLE) IndicatorRelease(ctx.h_macd);
   if(ctx.h_ema20 != INVALID_HANDLE) IndicatorRelease(ctx.h_ema20);
   if(ctx.h_ema50 != INVALID_HANDLE) IndicatorRelease(ctx.h_ema50);
   if(ctx.h_ema200 != INVALID_HANDLE) IndicatorRelease(ctx.h_ema200);
   if(ctx.h_atr != INVALID_HANDLE) IndicatorRelease(ctx.h_atr);

   ctx.h_rsi = INVALID_HANDLE;
   ctx.h_macd = INVALID_HANDLE;
   ctx.h_ema20 = INVALID_HANDLE;
   ctx.h_ema50 = INVALID_HANDLE;
   ctx.h_ema200 = INVALID_HANDLE;
   ctx.h_atr = INVALID_HANDLE;
}

int OnInit()
{
   if((bool)MQLInfoInteger(MQL_TESTER))
   {
      Print("WebRequest is unavailable in Strategy Tester. Run EA on a live/demo chart terminal session.");
      return INIT_FAILED;
   }

   g_symbol = (InpSymbol == "" ? _Symbol : InpSymbol);

   if(!SymbolSelect(g_symbol, true))
   {
      Print("Invalid or unavailable symbol: ", g_symbol);
      return INIT_FAILED;
   }

   double bid = 0.0;
   if(!SymbolInfoDouble(g_symbol, SYMBOL_BID, bid))
   {
      Print("Symbol validation failed for ", g_symbol, " err=", GetLastError());
      return INIT_FAILED;
   }

   if(InpLabelHoldPeriodCandles < 1 || InpLabelHoldPeriodCandles > 5)
   {
      Print("InpLabelHoldPeriodCandles must be in [1,5]");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!IsValidDatasetSplit(InpDatasetSplit))
   {
      Print("InpDatasetSplit must be one of: train, test, live");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpBatchSize < 1)
   {
      Print("InpBatchSize must be >= 1");
      return INIT_PARAMETERS_INCORRECT;
   }

   LoadSentEvents();
   LoadQueueFromFile();

   for(int i = 0; i < TF_COUNT; i++)
   {
      if(!InitContext(g_tf_contexts[i], ALLOWED_TFS[i]))
         return INIT_FAILED;
   }

   g_ready = true;

   Print("EA_MarketDataCollector initialized. symbol=", g_symbol,
         " tf=[M1,M5,M15,H1]",
         " queue_size=", ArraySize(g_queue),
         " sent_cache=", ArraySize(g_sent_event_ids));

   Print("IMPORTANT: In MT5 allow WebRequest URL list entries: http://127.0.0.1:8000 and http://localhost:8000");
   Print("Configured single endpoint: ", InpApiUrl);
   Print("Configured batch endpoint : ", InpBatchApiUrl);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   for(int i = 0; i < TF_COUNT; i++)
      ReleaseContext(g_tf_contexts[i]);

   PersistQueueToFile();
   Print("EA_MarketDataCollector deinitialized. reason=", reason,
         " remaining_queue=", ArraySize(g_queue));
}

void OnTick()
{
   if(!g_ready)
      return;

   // Retry backlog first to minimize data loss when API recovers.
   if(ArraySize(g_queue) > 0)
      ProcessQueue();

   // Process each allowed timeframe only once per newly closed candle.
   for(int i = 0; i < TF_COUNT; i++)
      ProcessTimeframe(g_tf_contexts[i]);

   // If batching is enabled, flush newly enqueued payloads in the same tick cycle.
   if(InpEnableBatching && ArraySize(g_queue) > 0)
      ProcessQueue();
}
