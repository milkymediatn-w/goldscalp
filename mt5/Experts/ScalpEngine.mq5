//+------------------------------------------------------------------+
//| ScalpEngine.mq5                                                  |
//| 1-minute order-flow scalper: trade the candle, tight stop,       |
//| break-even + ATR trailing stop, no take-profit.                  |
//|                                                                  |
//| Signals come from tick flow (aggressor flags when the broker     |
//| sends them, otherwise the tick rule on bid/ask), tick speed,     |
//| N-bar range breaks / sweeps, an optional M5 trend filter and     |
//| an optional depth-of-market imbalance (only used when the        |
//| broker actually publishes a book).                               |
//|                                                                  |
//| Every closed trade is written to MQL5/Files/ScalpEngine_*.csv    |
//| for analysis with mt5/analyze_trades.py.                         |
//+------------------------------------------------------------------+
#property copyright "goldscalp"
#property version   "1.00"
#property description "1m order-flow scalper (trade the candle, trailing stop, no TP)"

#include <Trade/Trade.mqh>

enum ENUM_SIGNAL_MODE
  {
   MODE_BREAKOUT   = 0,   // Breakout with flow
   MODE_SWEEP_FADE = 1,   // Sweep and reclaim (fade)
   MODE_BOTH       = 2    // Both
  };

//--- risk
input group "Risk"
input double InpRiskPercent       = 0.25;   // Risk per trade, % of equity (0 = fixed lots)
input double InpFixedLots         = 0.01;   // Fixed lots when risk % is 0
input double InpMaxLots           = 1.0;    // Hard cap on lots
input bool   InpAllowMinLot       = true;   // Use min lot if it risks <= 1.5x target
input double InpMaxDailyLossPct   = 2.0;    // Stop for the day after this equity drawdown %
input int    InpMaxTradesPerDay   = 60;     // Max entries per server day
input int    InpMaxConsecLosses   = 4;      // Pause after this many losses in a row
input int    InpLossPauseMin      = 30;     // Pause length, minutes
input long   InpMagic             = 260424; // Magic number
input int    InpDeviationPts      = 50;     // Max slippage, points

//--- cost filters
input group "Cost filters"
input int    InpMaxSpreadPts      = 0;      // Max spread, points (0 = off)
input double InpMinAtrToSpread    = 4.0;    // 1m ATR must be >= this x spread

//--- signal
input group "Signal"
input ENUM_SIGNAL_MODE InpMode    = MODE_BOTH; // Setup(s) to trade
input int    InpRangeBars         = 5;      // Range = high/low of last N closed 1m bars
input int    InpEntryWindowSec    = 30;     // Enter only in the first N seconds of a bar
input int    InpFlowWindowSec     = 20;     // Tick-flow window, seconds (5..120)
input double InpMinFlowImb        = 0.25;   // Min tick-flow imbalance (0..1)
input double InpMinTickRateX      = 1.5;    // Breakout: tick speed >= this x 10-min average
input double InpMaxChaseAtr       = 0.5;    // Breakout: skip if price is this many ATR past the range
input int    InpAtrPeriod         = 14;     // ATR period (M1)
input int    InpHtfEma            = 50;     // M5 EMA trend filter period (0 = off)
input bool   InpHtfFilterFades    = false;  // Also apply the trend filter to sweep fades

//--- depth of market
input group "Depth of market"
input bool   InpUseBook           = true;   // Use DOM imbalance when the broker sends a book
input int    InpBookLevels        = 5;      // Levels per side
input double InpMinBookImb        = 0.10;   // Book must agree by at least this (0..1)

//--- exits
input group "Exits"
input double InpSlAtr             = 0.6;    // Initial stop, x ATR
input double InpSlMinSpreads      = 3.0;    // Stop at least this many spreads
input double InpBreakEvenR        = 0.5;    // Move stop to entry at +R (0 = off)
input double InpTrailStartR       = 0.8;    // Start trailing at +R (0 = off)
input double InpTrailAtr          = 0.4;    // Trail distance, x ATR
input double InpTrailStepAtr      = 0.05;   // Min stop improvement per modify, x ATR
input int    InpMaxHoldBars       = 1;      // Close after this many bars (1 = this candle)
input int    InpExitSecBeforeClose= 0;      // Close this many seconds before the bar ends

//--- sessions (server time; Exness server time is UTC)
input group "Session"
input int    InpSessionStartHour  = 0;      // Start hour (server time)
input int    InpSessionEndHour    = 24;     // End hour (server time, exclusive)
input bool   InpLogTrades         = true;   // Write closed trades to CSV

//--- tick-flow ring buffer: one bucket per second
#define RING 900
long   g_secStamp[RING];
int    g_buy[RING];
int    g_sell[RING];
int    g_cnt[RING];
long   g_lastMsc     = 0;
int    g_sameMscSeen = 0;
double g_lastMid     = 0.0;
bool   g_hasAggFlags = false;

//--- book
bool     g_bookSubscribed = false;
double   g_bookImb        = 0.0;
int      g_bookLevels     = 0;
datetime g_bookTime       = 0;

//--- indicators
int g_atrHandle = INVALID_HANDLE;
int g_emaHandle = INVALID_HANDLE;

//--- state
CTrade   trade;
datetime g_lastEntryBar   = 0;
datetime g_day            = 0;
double   g_dayStartEquity = 0.0;
bool     g_haltDay        = false;
int      g_tradesToday    = 0;
int      g_consecLosses   = 0;
datetime g_pauseUntil     = 0;
string   g_status         = "";

//--- diagnostics: why bars were skipped (each reason counted once per bar)
#define SKIP_HALTED   0
#define SKIP_PAUSED   1
#define SKIP_MAXDAY   2
#define SKIP_ALGO     3
#define SKIP_SESSION  4
#define SKIP_SPREAD   5
#define SKIP_ATR      6
#define SKIP_NOSIGNAL 7
#define SKIP_MINLOT   8
#define SKIP_FAILED   9
#define SKIP_NODATA   10
#define SKIP_COUNT    11
string   g_skipName[SKIP_COUNT] = {"daily loss limit", "losing-streak pause", "max trades per day",
                                   "algo trading disabled", "outside session", "spread above max",
                                   "ATR < min x spread", "no setup", "min lot risks too much",
                                   "order rejected", "no ATR/bar data"};
int      g_skipBars[SKIP_COUNT];
datetime g_skipLastBar[SKIP_COUNT];
int      g_barsSeen      = 0;
datetime g_lastSeenBar   = 0;
double   g_ratioSum      = 0.0;
int      g_ratioN        = 0;
datetime g_lastRatioBar   = 0;
int      g_entries       = 0;
bool     g_minLotWarned  = false;

//--- context of the open trade (for logging and R maths)
ulong    g_posTicket   = 0;
string   g_setup       = "";
double   g_entry       = 0.0;
double   g_riskDist    = 0.0;
double   g_slInitial   = 0.0;
double   g_spreadEntry = 0.0;
double   g_atrEntry    = 0.0;
double   g_flowEntry   = 0.0;
double   g_rateEntry   = 0.0;
double   g_bookEntry   = 0.0;
int      g_bookLvEntry = 0;
double   g_mfe         = 0.0;
double   g_mae         = 0.0;
double   g_inCommission= 0.0;
datetime g_openTime    = 0;
double   g_lots        = 0.0;

//+------------------------------------------------------------------+
int OnInit()
  {
   ArrayInitialize(g_secStamp, -1);
   ArrayInitialize(g_buy, 0);
   ArrayInitialize(g_sell, 0);
   ArrayInitialize(g_cnt, 0);
   ArrayInitialize(g_skipBars, 0);
   ArrayInitialize(g_skipLastBar, 0);

   if(InpFlowWindowSec < 5 || InpFlowWindowSec > 120)
     { Print("InpFlowWindowSec must be within 5..120"); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxHoldBars < 1)
     { Print("InpMaxHoldBars must be >= 1"); return INIT_PARAMETERS_INCORRECT; }

   g_atrHandle = iATR(_Symbol, PERIOD_M1, InpAtrPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     { Print("Cannot create ATR"); return INIT_FAILED; }
   if(InpHtfEma > 0)
     {
      g_emaHandle = iMA(_Symbol, PERIOD_M5, InpHtfEma, 0, MODE_EMA, PRICE_CLOSE);
      if(g_emaHandle == INVALID_HANDLE)
        { Print("Cannot create M5 EMA"); return INIT_FAILED; }
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPts);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpUseBook && !MQLInfoInteger(MQL_TESTER))
     {
      g_bookSubscribed = MarketBookAdd(_Symbol);
      if(!g_bookSubscribed)
         Print("No depth of market for ", _Symbol, ": running on tick flow only");
     }

   PullTicks();
   RecoverPosition();
   EventSetTimer(1);
   PrintFormat("ScalpEngine on %s | risk %.2f%% | stop %.2fxATR | trail %.2fxATR from %.1fR | hold %d bar(s)",
               _Symbol, InpRiskPercent, InpSlAtr, InpTrailAtr, InpTrailStartR, InpMaxHoldBars);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   PrintSkipReport();
   if(g_bookSubscribed)
      MarketBookRelease(_Symbol);
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   if(g_emaHandle != INVALID_HANDLE)
      IndicatorRelease(g_emaHandle);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   PullTicks();
   DayCheck();
   ManagePosition();
   TryEntry();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   // Exits must fire at the bar boundary even if no tick arrives.
   DayCheck();
   ManagePosition();
   if(!MQLInfoInteger(MQL_TESTER))
      ShowPanel();
  }

//+------------------------------------------------------------------+
//| Tick flow                                                        |
//+------------------------------------------------------------------+
void AddTick(const MqlTick &t)
  {
   int sign = 0;
   bool isBuy  = (t.flags & TICK_FLAG_BUY)  != 0;
   bool isSell = (t.flags & TICK_FLAG_SELL) != 0;
   if(isBuy != isSell)
     {
      // Exchange instruments mark the aggressor side.
      sign = isBuy ? 1 : -1;
      g_hasAggFlags = true;
     }
   else
     {
      // Exchange feeds: quote-only ticks carry no trade, skip them.
      if(g_hasAggFlags)
         return;
      // CFD feeds only send quotes: classify by the direction the mid moved.
      if(t.bid <= 0.0 || t.ask <= 0.0)
         return;
      double mid = (t.bid + t.ask) * 0.5;
      if(g_lastMid > 0.0)
        {
         if(mid > g_lastMid)
            sign = 1;
         else
            if(mid < g_lastMid)
               sign = -1;
        }
      g_lastMid = mid;
      if(sign == 0)
         return;
     }

   long sec = t.time_msc / 1000;
   int  i   = (int)(sec % RING);
   if(g_secStamp[i] != sec)
     {
      g_secStamp[i] = sec;
      g_buy[i]  = 0;
      g_sell[i] = 0;
      g_cnt[i]  = 0;
     }
   g_cnt[i]++;
   if(sign > 0)
      g_buy[i]++;
   else
      g_sell[i]++;
  }

//+------------------------------------------------------------------+
//| Pull every tick since the last one processed (OnTick can skip    |
//| ticks when the terminal is busy, CopyTicks cannot).              |
//+------------------------------------------------------------------+
void PullTicks()
  {
   ulong from = (g_lastMsc > 0) ? (ulong)g_lastMsc : (ulong)(TimeCurrent() - RING) * 1000;
   for(int round = 0; round < 20; round++)
     {
      MqlTick ticks[];
      int n = CopyTicks(_Symbol, ticks, COPY_TICKS_ALL, from, 20000);
      if(n <= 0)
         return;
      int same = 0;
      for(int k = 0; k < n; k++)
        {
         long m = ticks[k].time_msc;
         if(m < g_lastMsc)
            continue;
         if(m == g_lastMsc)
           {
            same++;
            if(same <= g_sameMscSeen)
               continue;
            AddTick(ticks[k]);
            g_sameMscSeen++;
            continue;
           }
         AddTick(ticks[k]);
         g_lastMsc     = m;
         g_sameMscSeen = 1;
         same          = 1;
        }
      if(n < 20000)
         return;
      from = (ulong)g_lastMsc;
     }
  }

//+------------------------------------------------------------------+
void FlowStats(double &imb, double &rate, double &baseRate)
  {
   long now = g_lastMsc / 1000;
   int b = 0, s = 0, c = 0, cb = 0;
   for(int k = 0; k < InpFlowWindowSec; k++)
     {
      long sec = now - k;
      int  i   = (int)(sec % RING);
      if(g_secStamp[i] == sec)
        { b += g_buy[i]; s += g_sell[i]; c += g_cnt[i]; }
     }
   const int base = 600;
   for(int k = InpFlowWindowSec; k < InpFlowWindowSec + base; k++)
     {
      long sec = now - k;
      int  i   = (int)(sec % RING);
      if(g_secStamp[i] == sec)
         cb += g_cnt[i];
     }
   imb      = (b + s) > 0 ? (double)(b - s) / (b + s) : 0.0;
   rate     = (double)c / InpFlowWindowSec;
   baseRate = (double)cb / base;
  }

//+------------------------------------------------------------------+
//| Depth of market                                                  |
//+------------------------------------------------------------------+
void OnBookEvent(const string &symbol)
  {
   if(symbol != _Symbol)
      return;
   MqlBookInfo book[];
   if(!MarketBookGet(_Symbol, book))
      return;
   int sz = ArraySize(book);
   double askVol = 0.0, bidVol = 0.0;
   int asks = 0, bids = 0;
   // The book is sorted by price, highest first: asks on top, bids below.
   for(int k = sz - 1; k >= 0 && asks < InpBookLevels; k--)
      if(book[k].type == BOOK_TYPE_SELL)
        { askVol += BookVolume(book[k]); asks++; }
   for(int k = 0; k < sz && bids < InpBookLevels; k++)
      if(book[k].type == BOOK_TYPE_BUY)
        { bidVol += BookVolume(book[k]); bids++; }
   g_bookLevels = MathMin(asks, bids);
   g_bookImb    = (askVol + bidVol) > 0.0 ? (bidVol - askVol) / (bidVol + askVol) : 0.0;
   g_bookTime   = TimeCurrent();
  }

double BookVolume(const MqlBookInfo &row)
  {
   return row.volume_real > 0.0 ? row.volume_real : (double)row.volume;
  }

bool BookLive()
  {
   return InpUseBook && g_bookLevels > 0 && TimeCurrent() - g_bookTime <= 5;
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double Atr()
  {
   double v[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, v) != 1)
      return 0.0;
   return v[0];
  }

// +1 = only longs, -1 = only shorts, 0 = filter off or no data
int HtfDir()
  {
   if(g_emaHandle == INVALID_HANDLE)
      return 0;
   double ema[];
   if(CopyBuffer(g_emaHandle, 0, 1, 1, ema) != 1)
      return 0;
   double close = iClose(_Symbol, PERIOD_M5, 1);
   if(close <= 0.0)
      return 0;
   return close > ema[0] ? 1 : -1;
  }

double NormPrice(double p)
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0.0)
      ts = _Point;
   return NormalizeDouble(MathRound(p / ts) * ts, _Digits);
  }

double NormLots(double lots)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), InpMaxLots);
   if(step <= 0.0)
      step = mn;
   lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < mn)
      return 0.0;
   lots = MathMin(lots, mx);
   int d = (int)MathMax(0.0, MathCeil(-MathLog10(step) - 1e-9));
   return NormalizeDouble(lots, d);
  }

double MoneyPerLot(double dist)
  {
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0.0)
      tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0.0 || ts <= 0.0)
      return 0.0;
   return dist / ts * tv;
  }

double LotsForRisk(double riskDist)
  {
   if(InpRiskPercent <= 0.0)
      return NormLots(InpFixedLots);
   double perLot = MoneyPerLot(riskDist);
   if(perLot <= 0.0)
      return 0.0;
   double target = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
   double lots   = NormLots(target / perLot);
   if(lots == 0.0 && InpAllowMinLot)
     {
      double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(mn * perLot <= target * 1.5)
         lots = NormLots(mn);
     }
   return lots;
  }

bool SelectOurPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic && PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
     }
   return false;
  }

void CloseOurPosition(const string why)
  {
   if(!SelectOurPosition())
      return;
   ulong t = (ulong)PositionGetInteger(POSITION_TICKET);
   if(!trade.PositionClose(t, InpDeviationPts))
      PrintFormat("Close (%s) failed: %d %s", why, trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

// After a restart, rebuild the R maths from the live position.
void RecoverPosition()
  {
   if(!SelectOurPosition())
      return;
   g_posTicket = (ulong)PositionGetInteger(POSITION_TICKET);
   g_entry     = PositionGetDouble(POSITION_PRICE_OPEN);
   g_slInitial = PositionGetDouble(POSITION_SL);
   g_riskDist  = g_slInitial > 0.0 ? MathAbs(g_entry - g_slInitial) : 0.0;
   g_openTime  = (datetime)PositionGetInteger(POSITION_TIME);
   g_lots      = PositionGetDouble(POSITION_VOLUME);
   g_setup     = "recovered";
   g_mfe = 0.0;
   g_mae = 0.0;
  }

//+------------------------------------------------------------------+
//| Daily guard                                                      |
//+------------------------------------------------------------------+
void DayCheck()
  {
   datetime now = TimeCurrent();
   datetime day = (datetime)((long)now - (long)now % 86400);
   if(day != g_day)
     {
      g_day            = day;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_haltDay        = false;
      g_tradesToday    = 0;
     }
   if(!g_haltDay && InpMaxDailyLossPct > 0.0 &&
      AccountInfoDouble(ACCOUNT_EQUITY) <= g_dayStartEquity * (1.0 - InpMaxDailyLossPct / 100.0))
     {
      g_haltDay = true;
      CloseOurPosition("daily loss limit");
      PrintFormat("Daily loss limit hit (%.2f%%): no new trades until the next server day", InpMaxDailyLossPct);
     }
  }

//+------------------------------------------------------------------+
//| Diagnostics                                                      |
//+------------------------------------------------------------------+
void Skip(int reason, const string status)
  {
   g_status = status;
   datetime bar = iTime(_Symbol, PERIOD_M1, 0);
   if(g_skipLastBar[reason] != bar)
     {
      g_skipLastBar[reason] = bar;
      g_skipBars[reason]++;
     }
  }

void PrintSkipReport()
  {
   PrintFormat("=== ScalpEngine report: %d bars inside the entry window, %d entries ===", g_barsSeen, g_entries);
   if(g_ratioN > 0)
      PrintFormat("Average 1m ATR / spread: %.2f (filter needs >= %.1f)", g_ratioSum / g_ratioN, InpMinAtrToSpread);
   for(int r = 0; r < SKIP_COUNT; r++)
      if(g_skipBars[r] > 0)
         PrintFormat("  skipped by %-24s on %6d bars (%.1f%%)", g_skipName[r], g_skipBars[r],
                     g_barsSeen > 0 ? 100.0 * g_skipBars[r] / g_barsSeen : 0.0);
  }

//+------------------------------------------------------------------+
//| Entries                                                          |
//+------------------------------------------------------------------+
void TryEntry()
  {
   if(SelectOurPosition())                     { g_status = "in position"; return; }

   datetime bar = iTime(_Symbol, PERIOD_M1, 0);
   if(bar == 0 || bar == g_lastEntryBar)
      return;
   datetime now = TimeCurrent();
   if(now - bar > InpEntryWindowSec)           { g_status = "waiting for next bar"; return; }
   if(bar != g_lastSeenBar)
     {
      g_lastSeenBar = bar;
      g_barsSeen++;
     }

   if(g_haltDay)                               { Skip(SKIP_HALTED, "halted: daily loss limit"); return; }
   if(TimeCurrent() < g_pauseUntil)            { Skip(SKIP_PAUSED, "paused after losing streak"); return; }
   if(g_tradesToday >= InpMaxTradesPerDay)     { Skip(SKIP_MAXDAY, "max trades for today"); return; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
                                               { Skip(SKIP_ALGO, "algo trading disabled"); return; }

   MqlDateTime dt;
   TimeToStruct(now, dt);
   if(dt.hour < InpSessionStartHour || dt.hour >= InpSessionEndHour)
                                               { Skip(SKIP_SESSION, "outside session"); return; }

   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk) || tk.bid <= 0.0 || tk.ask <= 0.0)
      return;
   double spread = tk.ask - tk.bid;
   double atr    = Atr();
   if(atr <= 0.0)                              { Skip(SKIP_NODATA, "waiting for ATR data"); return; }
   if(spread > 0.0 && bar != g_lastRatioBar)
     {
      g_lastRatioBar = bar;
      g_ratioSum += atr / spread;
      g_ratioN++;
     }
   if(InpMaxSpreadPts > 0 && spread > InpMaxSpreadPts * _Point)
                                               { Skip(SKIP_SPREAD, "spread too wide"); return; }
   if(atr < InpMinAtrToSpread * spread)        { Skip(SKIP_ATR, "range too small for the spread"); return; }

   int idxH = iHighest(_Symbol, PERIOD_M1, MODE_HIGH, InpRangeBars, 1);
   int idxL = iLowest(_Symbol, PERIOD_M1, MODE_LOW, InpRangeBars, 1);
   if(idxH < 0 || idxL < 0)                    { Skip(SKIP_NODATA, "waiting for bar data"); return; }
   double rangeHigh = iHigh(_Symbol, PERIOD_M1, idxH);
   double rangeLow  = iLow(_Symbol, PERIOD_M1, idxL);
   double barHigh   = iHigh(_Symbol, PERIOD_M1, 0);
   double barLow    = iLow(_Symbol, PERIOD_M1, 0);

   double imb, rate, baseRate;
   FlowStats(imb, rate, baseRate);
   double rateX = baseRate > 0.0 ? rate / baseRate : 0.0;
   bool   book  = BookLive();
   int    htf   = HtfDir();

   int    dir   = 0;
   string setup = "";

   if(InpMode != MODE_SWEEP_FADE)
     {
      bool fast = rateX >= InpMinTickRateX;
      if(tk.bid > rangeHigh && tk.bid - rangeHigh <= InpMaxChaseAtr * atr && imb >= InpMinFlowImb && fast &&
         (!book || g_bookImb >= InpMinBookImb) && htf >= 0)
        { dir = 1; setup = "breakout"; }
      else
         if(tk.bid < rangeLow && rangeLow - tk.bid <= InpMaxChaseAtr * atr && imb <= -InpMinFlowImb && fast &&
            (!book || g_bookImb <= -InpMinBookImb) && htf <= 0)
           { dir = -1; setup = "breakout"; }
     }
   if(dir == 0 && InpMode != MODE_BREAKOUT)
     {
      bool htfLong  = !InpHtfFilterFades || htf >= 0;
      bool htfShort = !InpHtfFilterFades || htf <= 0;
      // Price ran the stops above the range, then fell back inside with sellers in control.
      if(barHigh > rangeHigh && tk.bid < rangeHigh && imb <= -InpMinFlowImb &&
         (!book || g_bookImb <= -InpMinBookImb) && htfShort)
        { dir = -1; setup = "sweep_fade"; }
      else
         if(barLow < rangeLow && tk.bid > rangeLow && imb >= InpMinFlowImb &&
            (!book || g_bookImb >= InpMinBookImb) && htfLong)
           { dir = 1; setup = "sweep_fade"; }
     }
   if(dir == 0)
     {
      Skip(SKIP_NOSIGNAL, StringFormat("scanning | flow %+.2f | speed %.1fx", imb, rateX));
      return;
     }

   // Stop sits on the bid side for longs and the ask side for shorts, so the
   // risk we size for is stop distance + spread.
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double slDist  = MathMax(InpSlAtr * atr, InpSlMinSpreads * spread);
   slDist         = MathMax(slDist, minStop + spread);
   double sl      = dir > 0 ? NormPrice(tk.bid - slDist) : NormPrice(tk.ask + slDist);
   double risk    = dir > 0 ? tk.ask - sl : sl - tk.bid;
   double lots    = LotsForRisk(risk);
   if(lots <= 0.0)
     {
      Skip(SKIP_MINLOT, "min lot risks too much: lower the stop or raise risk %");
      if(!g_minLotWarned)
        {
         g_minLotWarned = true;
         double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         PrintFormat("Min lot %.2f would risk %.2f %s on this stop, target is %.2f (%.2f%% of equity). "
                     "Raise InpRiskPercent or use fixed lots (InpRiskPercent=0).",
                     mn, mn * MoneyPerLot(risk), AccountInfoString(ACCOUNT_CURRENCY),
                     AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0, InpRiskPercent);
        }
      g_lastEntryBar = bar;
      return;
     }

   bool ok = dir > 0 ? trade.Buy(lots, _Symbol, tk.ask, sl, 0.0, "SE " + setup)
                     : trade.Sell(lots, _Symbol, tk.bid, sl, 0.0, "SE " + setup);
   g_lastEntryBar = bar;
   if(!ok || (trade.ResultRetcode() != TRADE_RETCODE_DONE && trade.ResultRetcode() != TRADE_RETCODE_PLACED))
     {
      Skip(SKIP_FAILED, "order rejected");
      PrintFormat("%s %s failed: %d %s", setup, dir > 0 ? "BUY" : "SELL",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
     }

   g_tradesToday++;
   g_entries++;
   g_setup       = setup;
   g_slInitial   = sl;
   g_spreadEntry = spread;
   g_atrEntry    = atr;
   g_flowEntry   = imb;
   g_rateEntry   = rateX;
   g_bookEntry   = book ? g_bookImb : 0.0;
   g_bookLvEntry = book ? g_bookLevels : 0;
   g_mfe         = 0.0;
   g_mae         = 0.0;
   g_lots        = lots;
   if(SelectOurPosition())
     {
      g_posTicket = (ulong)PositionGetInteger(POSITION_TICKET);
      g_entry     = PositionGetDouble(POSITION_PRICE_OPEN);
      g_openTime  = (datetime)PositionGetInteger(POSITION_TIME);
     }
   else
     {
      g_entry    = dir > 0 ? tk.ask : tk.bid;
      g_openTime = now;
     }
   g_riskDist = MathAbs(g_entry - sl);
   PrintFormat("%s %s %.2f lots @ %s, stop %s (%.1f spreads), flow %+.2f, speed %.1fx%s",
               setup, dir > 0 ? "BUY" : "SELL", lots, DoubleToString(g_entry, _Digits),
               DoubleToString(sl, _Digits), slDist / spread, imb, rateX,
               book ? StringFormat(", book %+.2f", g_bookImb) : "");
  }

//+------------------------------------------------------------------+
//| Exits: time stop at the candle close, break-even, ATR trail      |
//+------------------------------------------------------------------+
void ManagePosition()
  {
   if(!SelectOurPosition())
      return;
   ulong  ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   long   type   = PositionGetInteger(POSITION_TYPE);
   double open   = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl     = PositionGetDouble(POSITION_SL);
   datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
   if(ticket != g_posTicket)
     {
      if(g_posTicket == 0 && g_setup != "")
        {
         // Our own fresh entry: keep the entry context, just learn the ticket.
         g_posTicket = ticket;
         g_entry     = open;
         g_openTime  = opened;
         if(sl > 0.0)
            g_riskDist = MathAbs(open - sl);
        }
      else
         RecoverPosition();
     }

   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;

   // Trade the candle: out at the close of the entry bar (or after N bars).
   datetime entryBar = (datetime)((long)opened - (long)opened % 60);
   if(TimeCurrent() >= entryBar + 60 * InpMaxHoldBars - InpExitSecBeforeClose)
     {
      CloseOurPosition("bar close");
      return;
     }

   bool   isBuy = type == POSITION_TYPE_BUY;
   double move  = isBuy ? tk.bid - open : open - tk.ask;
   g_mfe = MathMax(g_mfe, move);
   g_mae = MathMin(g_mae, move);

   double R   = g_riskDist > 0.0 ? g_riskDist : (sl > 0.0 ? MathAbs(open - sl) : 0.0);
   double atr = g_atrEntry > 0.0 ? g_atrEntry : Atr();
   if(R <= 0.0 || atr <= 0.0)
      return;

   double newSl = sl;
   if(InpBreakEvenR > 0.0 && move >= InpBreakEvenR * R)
      newSl = isBuy ? MathMax(newSl, open) : (newSl > 0.0 ? MathMin(newSl, open) : open);
   if(InpTrailStartR > 0.0 && move >= InpTrailStartR * R)
     {
      double trail = isBuy ? tk.bid - InpTrailAtr * atr : tk.ask + InpTrailAtr * atr;
      newSl = isBuy ? MathMax(newSl, trail) : (newSl > 0.0 ? MathMin(newSl, trail) : trail);
     }
   newSl = NormPrice(newSl);

   double step = MathMax(InpTrailStepAtr * atr, SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE));
   bool better = isBuy ? newSl >= sl + step : (sl == 0.0 || newSl <= sl - step);
   if(!better || newSl == sl)
      return;

   // Respect the broker's minimum stop distance and freeze level.
   double minDist = MathMax((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                            (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * _Point;
   if(isBuy && tk.bid - newSl <= minDist)
      return;
   if(!isBuy && newSl - tk.ask <= minDist)
      return;
   if(!trade.PositionModify(ticket, newSl, 0.0))
      PrintFormat("Trail modify failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Bookkeeping: losing streaks and the CSV trade log                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic ||
      HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN)
     {
      g_inCommission = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      return;
     }
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
                HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                HistoryDealGetDouble(trans.deal, DEAL_COMMISSION) + g_inCommission;
   g_inCommission = 0.0;

   if(pnl < 0.0)
     {
      g_consecLosses++;
      if(InpMaxConsecLosses > 0 && g_consecLosses >= InpMaxConsecLosses)
        {
         g_pauseUntil   = TimeCurrent() + InpLossPauseMin * 60;
         g_consecLosses = 0;
         PrintFormat("%d losses in a row: pausing %d minutes", InpMaxConsecLosses, InpLossPauseMin);
        }
     }
   else
      g_consecLosses = 0;

   if(InpLogTrades)
      LogTrade(trans.deal, pnl);
   g_posTicket = 0;
   g_setup     = "";
   g_riskDist  = 0.0;
   g_atrEntry  = 0.0;
  }

void LogTrade(ulong deal, double pnl)
  {
   string name = "ScalpEngine_" + _Symbol + ".csv";
   int h = FileOpen(name, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
     {
      Print("Cannot open ", name, ": ", GetLastError());
      return;
     }
   if(FileSize(h) == 0)
      FileWrite(h, "open_time", "close_time", "symbol", "side", "setup", "lots", "entry", "exit",
                "sl_initial", "risk", "spread", "atr", "flow_imb", "speed_x", "book_imb", "book_levels",
                "mfe", "mae", "exit_reason", "pnl");
   FileSeek(h, 0, SEEK_END);

   long reason = HistoryDealGetInteger(deal, DEAL_REASON);
   string why  = reason == DEAL_REASON_SL ? "stop" :
                 reason == DEAL_REASON_TP ? "tp" :
                 reason == DEAL_REASON_SO ? "stop_out" :
                 reason == DEAL_REASON_EXPERT ? "ea_close" : "manual";
   // The closing deal is opposite to the position: a SELL deal closes a long.
   string side = HistoryDealGetInteger(deal, DEAL_TYPE) == DEAL_TYPE_SELL ? "long" : "short";

   FileWrite(h,
             TimeToString(g_openTime, TIME_DATE | TIME_SECONDS),
             TimeToString((datetime)HistoryDealGetInteger(deal, DEAL_TIME), TIME_DATE | TIME_SECONDS),
             _Symbol, side, g_setup,
             DoubleToString(g_lots, 2),
             DoubleToString(g_entry, _Digits),
             DoubleToString(HistoryDealGetDouble(deal, DEAL_PRICE), _Digits),
             DoubleToString(g_slInitial, _Digits),
             DoubleToString(g_riskDist, _Digits),
             DoubleToString(g_spreadEntry, _Digits),
             DoubleToString(g_atrEntry, _Digits),
             DoubleToString(g_flowEntry, 3),
             DoubleToString(g_rateEntry, 2),
             DoubleToString(g_bookEntry, 3),
             IntegerToString(g_bookLvEntry),
             DoubleToString(g_mfe, _Digits),
             DoubleToString(g_mae, _Digits),
             why,
             DoubleToString(pnl, 2));
   FileClose(h);
  }

//+------------------------------------------------------------------+
void ShowPanel()
  {
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;
   double imb, rate, baseRate;
   FlowStats(imb, rate, baseRate);
   double atr    = Atr();
   double spread = tk.ask - tk.bid;
   string book   = BookLive() ? StringFormat("%+.2f (%d lv)", g_bookImb, g_bookLevels)
                              : (g_bookSubscribed ? "subscribed, empty" : "not available");
   Comment(StringFormat(
              "ScalpEngine  %s\n"
              "Spread %s | ATR(1m) %s | ATR/spread %.1f (need %.1f)\n"
              "Flow %+.2f (%s) | speed %.1fx\n"
              "Book: %s\n"
              "Trades today %d/%d | losing streak %d\n"
              "%s",
              _Symbol,
              DoubleToString(spread, _Digits), DoubleToString(atr, _Digits),
              spread > 0.0 ? atr / spread : 0.0, InpMinAtrToSpread,
              imb, g_hasAggFlags ? "aggressor flags" : "tick rule",
              baseRate > 0.0 ? rate / baseRate : 0.0,
              book,
              g_tradesToday, InpMaxTradesPerDay, g_consecLosses,
              g_status));
  }
//+------------------------------------------------------------------+
