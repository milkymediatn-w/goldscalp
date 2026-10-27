//+------------------------------------------------------------------+
//| FastScalper.mq5  v1                                              |
//| M1 scalper for CFD quote feeds (built for Exness BTCUSD).        |
//| Every trade is out within InpMaxHoldMin minutes (default 10).    |
//|                                                                  |
//| Setups, checked when an M1 candle closes (same rules and math as |
//| Scripts/SetupProbe.mq5, so probe results carry over):            |
//|  A_squeeze : tight N-bar range, then an expansion candle closes  |
//|              outside it -> trade the break                       |
//|  B_open    : first close outside a session's opening range       |
//|              -> trade the break                                  |
//|  C_sweep   : wick through the N-bar high/low, close back inside  |
//|              -> fade it                                          |
//|                                                                  |
//| Exits: ATR stop and R target on the server, optional break-even  |
//| and trail, and a hard time stop.                                 |
//|                                                                  |
//| Risk: one position, daily loss limit, losing-streak pause, max   |
//| trades per day, fixed lots or fixed % risk. Nothing grows after  |
//| a loss.                                                          |
//|                                                                  |
//| Every closed trade goes to MQL5/Files/FastScalper_<symbol>.csv   |
//| (analyse with analyze_trades.py); a skip-reason report is        |
//| printed when the EA stops.                                       |
//+------------------------------------------------------------------+
#property copyright "goldscalp"
#property version   "1.00"
#property description "M1 scalper: squeeze breakout, session-open breakout, sweep fade; out within 10 minutes"

#include <Trade/Trade.mqh>

//--- setups
input group "Setups (M1)"
input bool   InpUseA            = true;   // A: compression breakout
input int    InpSqzBars         = 10;     // A: range = high/low of the last N closed candles
input double InpSqzMaxAtr       = 2.0;    // A: range must be <= this x slow ATR
input double InpExpBarAtr       = 1.2;    // A: breakout candle range >= this x slow ATR
input bool   InpUseB            = true;   // B: session-open breakout
input string InpSessions        = "00:00,07:00,13:30"; // B: session opens, server time (HH:MM, comma separated)
input int    InpOrbMin          = 5;      // B: opening range, minutes
input int    InpOrbWindowMin    = 60;     // B: break must come within N minutes after the range
input bool   InpUseC            = true;   // C: sweep and reclaim (fade)
input int    InpSweepBars       = 30;     // C: level = high/low of the last N closed candles
input double InpSweepMinAtr     = 0.2;    // C: wick must pierce the level by >= this x fast ATR
input int    InpCooldownBars    = 5;      // A/C: min candles between two signals of the same setup
input int    InpAtrFast         = 14;     // Fast ATR period (stops)
input int    InpAtrSlow         = 60;     // Slow ATR period (compression)
input int    InpTrendEma        = 200;    // Trend EMA period on M1
input bool   InpWithTrendOnly   = false;  // Take only trades on the side of the trend EMA

//--- exits
input group "Exits"
input double InpSlAtr           = 1.0;    // Stop, x fast ATR
input double InpTpR             = 1.5;    // Target, x stop (R). 0 = no target
input double InpSlMinCosts      = 2.0;    // Stop is at least this many round-trip costs
input int    InpMaxHoldMin      = 10;     // Time stop, minutes
input double InpBreakEvenR      = 0.0;    // Move stop to entry + costs at +R (0 = off)
input double InpTrailStartR     = 0.0;    // Start trailing at +R (0 = off)
input double InpTrailAtr        = 0.5;    // Trail distance, x fast ATR

//--- costs and filters
input group "Cost and time filters"
input double InpCommission      = 0.0;    // Commission per 1 lot, round trip, account currency (Zero/Raw)
input double InpMinAtrToCost    = 3.0;    // Fast ATR must be >= this x round-trip cost (0 = off)
input int    InpMaxSpreadPts    = 0;      // Max spread, points (0 = off)
input string InpHours           = "";     // Entry hours, server time, e.g. "7-10,13-16" (empty = all)
input int    InpMaxEntryDelaySec = 20;    // Skip if the first tick after the candle close is later than this

//--- risk
input group "Risk"
input double InpRiskPercent     = 0.0;    // Risk per trade, % of equity (0 = fixed lots)
input double InpFixedLots       = 0.01;   // Fixed lots when risk % is 0
input double InpMaxLots         = 0.10;   // Hard cap on lots
input double InpMaxDailyLossPct = 3.0;    // Stop for the day after this equity drawdown %
input int    InpMaxTradesPerDay = 20;     // Max entries per server day
input int    InpMaxConsecLosses = 4;      // Pause after this many losses in a row
input int    InpLossPauseMin    = 60;     // Pause length, minutes
input long   InpMagic           = 261027; // Magic number
input int    InpDeviationPts    = 300;    // Max slippage, points

input group "Output"
input bool   InpLogTrades       = true;   // Write the CSV trade log
input bool   InpVerbose         = true;   // Print entries and exits

//--- skip reasons, counted per signal
enum SkipReason
  {
   SK_POSITION, SK_DAYLOSS, SK_MAXTRADES, SK_STREAK, SK_HOURS, SK_TREND,
   SK_SPREAD, SK_ATRCOST, SK_LATE, SK_LOTS, SK_ORDER, SKIP_COUNT
  };
string g_skipName[SKIP_COUNT] = {"position already open", "daily loss limit", "max trades per day",
                                 "losing-streak pause", "outside entry hours", "against the trend",
                                 "spread too wide", "ATR/cost too low", "late first tick",
                                 "lot size below minimum", "order rejected"
                                };
string g_setupName[3] = {"A_squeeze", "B_open", "C_sweep"};

CTrade   trade;
int      g_skip[SKIP_COUNT];
int      g_signals[3];
int      g_entriesBy[3];
datetime g_lastSig[3];
datetime g_lastBar     = 0;
int      g_barsSeen    = 0;
int      g_sess[];
datetime g_trigDay[];
bool     g_hourOk[24];
double   g_commPx      = 0.0;  // commission per round trip, price units
double   g_valPerPx    = 0.0;  // account currency per 1.0 price move per 1 lot

//--- day and streak state
datetime g_day         = 0;
double   g_dayStartEq  = 0.0;
bool     g_dayHalted   = false;
int      g_tradesToday = 0;
int      g_consecLosses = 0;
datetime g_pauseUntil  = 0;

//--- open trade
ulong    g_posTicket   = 0;
int      g_dir         = 0;
string   g_setup       = "";
datetime g_openTime    = 0;
double   g_entry       = 0.0;
double   g_slInitial   = 0.0;
double   g_riskDist    = 0.0;
double   g_lots        = 0.0;
double   g_spreadEntry = 0.0;
double   g_atrEntry    = 0.0;
double   g_costEntry   = 0.0;
int      g_aligned     = 0;
double   g_mfe         = 0.0;
double   g_mae         = 0.0;
bool     g_trailed     = false;
double   g_inCommission = 0.0;

//--- session results
int      g_entries     = 0;
int      g_wins        = 0;
double   g_sumR        = 0.0;
double   g_sumPnl      = 0.0;
string   g_status      = "";

//+------------------------------------------------------------------+
int ParseSessions(const string s, int &out[])
  {
   string parts[];
   int n = StringSplit(s, ',', parts);
   ArrayResize(out, 0);
   for(int i = 0; i < n; i++)
     {
      string hm[];
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      if(StringSplit(parts[i], ':', hm) != 2)
         continue;
      int k = ArraySize(out);
      ArrayResize(out, k + 1);
      out[k] = (int)StringToInteger(hm[0]) * 3600 + (int)StringToInteger(hm[1]) * 60;
     }
   return ArraySize(out);
  }

//+------------------------------------------------------------------+
//| "7-10,13-16" -> allowed hours. Empty = every hour.               |
//+------------------------------------------------------------------+
void ParseHours(const string s)
  {
   string spec = s;
   StringTrimLeft(spec);
   StringTrimRight(spec);
   ArrayInitialize(g_hourOk, spec == "");
   if(spec == "")
      return;
   string parts[];
   int n = StringSplit(spec, ',', parts);
   for(int i = 0; i < n; i++)
     {
      string ab[];
      int m = StringSplit(parts[i], '-', ab);
      if(m < 1)
         continue;
      int a = (int)StringToInteger(ab[0]);
      int b = m > 1 ? (int)StringToInteger(ab[1]) : a;
      for(int h = MathMax(0, a); h <= MathMin(23, b); h++)
         g_hourOk[h] = true;
     }
  }

//+------------------------------------------------------------------+
void WilderAtr(const MqlRates &r[], int n, int p, double &out[])
  {
   ArrayResize(out, n);
   double sum = 0.0;
   for(int i = 0; i < n; i++)
     {
      double tr = (i == 0) ? r[i].high - r[i].low
                  : MathMax(r[i].high, r[i - 1].close) - MathMin(r[i].low, r[i - 1].close);
      if(i < p)
        {
         sum += tr;
         out[i] = sum / (i + 1);
        }
      else
         out[i] = (out[i - 1] * (p - 1) + tr) / p;
     }
  }

//+------------------------------------------------------------------+
void Ema(const MqlRates &r[], int n, int p, double &out[])
  {
   ArrayResize(out, n);
   double a = 2.0 / (p + 1.0);
   for(int i = 0; i < n; i++)
      out[i] = (i == 0) ? r[i].close : out[i - 1] + a * (r[i].close - out[i - 1]);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpSlAtr <= 0.0 || InpMaxHoldMin <= 0 || InpFixedLots <= 0.0)
     {
      Print("InpSlAtr, InpMaxHoldMin and InpFixedLots must be above 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   ParseSessions(InpSessions, g_sess);
   ArrayResize(g_trigDay, MathMax(ArraySize(g_sess), 1));
   ArrayInitialize(g_trigDay, 0);
   ParseHours(InpHours);
   ArrayInitialize(g_skip, 0);
   ArrayInitialize(g_signals, 0);
   ArrayInitialize(g_entriesBy, 0);
   ArrayInitialize(g_lastSig, 0);

   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_valPerPx = ts > 0.0 ? tv / ts : 0.0;
   g_commPx   = g_valPerPx > 0.0 ? InpCommission / g_valPerPx : 0.0;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPts);
   trade.SetTypeFillingBySymbol(_Symbol);

   // pick up a position left open by a restart
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      g_posTicket = t;
      g_dir       = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1;
      g_openTime  = (datetime)PositionGetInteger(POSITION_TIME);
      g_entry     = PositionGetDouble(POSITION_PRICE_OPEN);
      g_slInitial = PositionGetDouble(POSITION_SL);
      g_riskDist  = g_slInitial > 0.0 ? MathAbs(g_entry - g_slInitial) : 0.0;
      g_lots      = PositionGetDouble(POSITION_VOLUME);
      g_setup     = "restored";
      PrintFormat("Resumed managing position %I64u", t);
      break;
     }

   PrintFormat("FastScalper v1 %s | 1.0 move = %.4f %s per lot | commission %.2f per lot = %s in price | hold <= %d min",
               _Symbol, g_valPerPx, AccountInfoString(ACCOUNT_CURRENCY), InpCommission,
               DoubleToString(g_commPx, _Digits), InpMaxHoldMin);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   PrintFormat("===== FastScalper report %s: %d candles, %d entries, %d wins, %+.2fR, %+.2f %s =====",
               _Symbol, g_barsSeen, g_entries, g_wins, g_sumR, g_sumPnl, AccountInfoString(ACCOUNT_CURRENCY));
   for(int s = 0; s < 3; s++)
      PrintFormat("  %-10s signals %6d | entries %6d", g_setupName[s], g_signals[s], g_entriesBy[s]);
   int total = g_signals[0] + g_signals[1] + g_signals[2];
   for(int r = 0; r < SKIP_COUNT; r++)
      if(g_skip[r] > 0)
         PrintFormat("  skipped: %-24s %6d signals (%.1f%%)", g_skipName[r], g_skip[r],
                     total > 0 ? 100.0 * g_skip[r] / total : 0.0);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   NewDayCheck();
   ManagePosition();

   datetime bar = iTime(_Symbol, PERIOD_M1, 0);
   if(bar != 0 && bar != g_lastBar)
     {
      bool first = g_lastBar == 0;
      g_lastBar = bar;
      if(!first) // the first bar seen may be mid-candle after a restart
        {
         g_barsSeen++;
         OnNewBar(bar);
        }
     }
   ShowPanel();
  }

//+------------------------------------------------------------------+
void NewDayCheck()
  {
   datetime now = TimeCurrent();
   datetime day = (datetime)((long)now - (long)now % 86400);
   if(day != g_day)
     {
      g_day         = day;
      g_dayStartEq  = AccountInfoDouble(ACCOUNT_EQUITY);
      g_dayHalted   = false;
      g_tradesToday = 0;
     }
   if(!g_dayHalted && InpMaxDailyLossPct > 0.0 && g_dayStartEq > 0.0)
     {
      double dd = 100.0 * (g_dayStartEq - AccountInfoDouble(ACCOUNT_EQUITY)) / g_dayStartEq;
      if(dd >= InpMaxDailyLossPct)
        {
         g_dayHalted = true;
         PrintFormat("Daily loss limit: equity down %.2f%% today. No new trades until tomorrow.", dd);
        }
     }
  }

//+------------------------------------------------------------------+
//| Signal on the candle that just closed. Returns setup or -1.      |
//+------------------------------------------------------------------+
int FindSignal(datetime barNow, int &dir, double &atrF, int &trend)
  {
   int need = InpTrendEma * 3 + InpAtrSlow * 3 + MathMax(MathMax(InpSqzBars, InpSweepBars), InpOrbMin + InpOrbWindowMin) + 10;
   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M1, 1, need, r); // oldest first, r[n-1] = the closed candle
   if(n < MathMax(MathMax(InpSqzBars, InpSweepBars), MathMax(InpAtrFast, InpAtrSlow)) + 2)
      return -1;
   double aFa[], aSa[], ema[];
   WilderAtr(r, n, InpAtrFast, aFa);
   WilderAtr(r, n, InpAtrSlow, aSa);
   Ema(r, n, InpTrendEma, ema);
   int    i   = n - 1;
   double c   = r[i].close;
   double rng = r[i].high - r[i].low;
   double aS  = aSa[i - 1];
   atrF  = aFa[i];
   trend = c > ema[i] ? 1 : (c < ema[i] ? -1 : 0);
   if(aS <= 0.0 || atrF <= 0.0)
      return -1;
   int found = -1;

   //--- A
   if(InpUseA && (barNow - g_lastSig[0]) / 60 >= InpCooldownBars)
     {
      double hi = r[i - 1].high, lo = r[i - 1].low;
      for(int j = i - InpSqzBars; j < i - 1; j++)
        {
         hi = MathMax(hi, r[j].high);
         lo = MathMin(lo, r[j].low);
        }
      if(hi - lo <= InpSqzMaxAtr * aS && rng >= InpExpBarAtr * aS)
        {
         int d = c > hi ? 1 : (c < lo ? -1 : 0);
         if(d != 0)
           {
            g_lastSig[0] = barNow;
            g_signals[0]++;
            dir   = d;
            found = 0;
           }
        }
     }

   //--- B (state per session is updated even when A already fired)
   if(InpUseB)
     {
      long     tod      = (long)r[i].time % 86400;
      datetime dayStart = (datetime)((long)r[i].time - tod);
      for(int s = 0; s < ArraySize(g_sess); s++)
        {
         long orEnd = g_sess[s] + (long)InpOrbMin * 60;
         if(tod < orEnd || tod >= orEnd + (long)InpOrbWindowMin * 60 || g_trigDay[s] == dayStart)
            continue;
         datetime orFrom = (datetime)((long)dayStart + g_sess[s]);
         datetime orTo   = (datetime)((long)dayStart + orEnd);
         double hi = -DBL_MAX, lo = DBL_MAX;
         int cnt = 0;
         for(int j = i - 1; j >= 0 && r[j].time >= orFrom; j--)
            if(r[j].time < orTo)
              {
               hi = MathMax(hi, r[j].high);
               lo = MathMin(lo, r[j].low);
               cnt++;
              }
         if(cnt < MathMax(1, InpOrbMin - 1))
           {
            g_trigDay[s] = dayStart;
            continue;
           }
         int d = c > hi ? 1 : (c < lo ? -1 : 0);
         if(d != 0)
           {
            g_trigDay[s] = dayStart;
            g_signals[1]++;
            if(found < 0)
              {
               dir   = d;
               found = 1;
              }
           }
        }
     }

   //--- C
   if(InpUseC && (barNow - g_lastSig[2]) / 60 >= InpCooldownBars)
     {
      double hi = r[i - 1].high, lo = r[i - 1].low;
      for(int j = i - InpSweepBars; j < i - 1; j++)
        {
         hi = MathMax(hi, r[j].high);
         lo = MathMin(lo, r[j].low);
        }
      bool up = r[i].high >= hi + InpSweepMinAtr * atrF && c < hi;
      bool dn = r[i].low <= lo - InpSweepMinAtr * atrF && c > lo;
      if(up != dn)
        {
         g_lastSig[2] = barNow;
         g_signals[2]++;
         if(found < 0)
           {
            dir   = up ? -1 : 1;
            found = 2;
           }
        }
     }
   return found;
  }

//+------------------------------------------------------------------+
void Skip(SkipReason why, int setup)
  {
   g_skip[why]++;
   g_status = StringFormat("%s %s skipped: %s", TimeToString(TimeCurrent(), TIME_MINUTES),
                           g_setupName[setup], g_skipName[why]);
  }

//+------------------------------------------------------------------+
void OnNewBar(datetime bar)
  {
   int    dir = 0, trend = 0;
   double atrF = 0.0;
   int setup = FindSignal(bar, dir, atrF, trend);
   if(setup < 0)
      return;

   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;
   double spread = tk.ask - tk.bid;
   double cost   = spread + g_commPx;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(g_posTicket != 0)                                { Skip(SK_POSITION, setup); return; }
   if(g_dayHalted)                                     { Skip(SK_DAYLOSS, setup); return; }
   if(InpMaxTradesPerDay > 0 && g_tradesToday >= InpMaxTradesPerDay) { Skip(SK_MAXTRADES, setup); return; }
   if(TimeCurrent() < g_pauseUntil)                    { Skip(SK_STREAK, setup); return; }
   if(!g_hourOk[dt.hour])                              { Skip(SK_HOURS, setup); return; }
   if(InpWithTrendOnly && dir != trend)                { Skip(SK_TREND, setup); return; }
   if(InpMaxSpreadPts > 0 && spread > InpMaxSpreadPts * _Point) { Skip(SK_SPREAD, setup); return; }
   if(InpMinAtrToCost > 0.0 && cost > 0.0 && atrF < InpMinAtrToCost * cost) { Skip(SK_ATRCOST, setup); return; }
   if(TimeCurrent() - bar > InpMaxEntryDelaySec)       { Skip(SK_LATE, setup); return; }

   double slDist = MathMax(InpSlAtr * atrF, InpSlMinCosts * cost);
   double minDist = MathMax((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                            (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * _Point;
   slDist = MathMax(slDist, minDist + spread);
   double tpDist = InpTpR * slDist;
   if(InpTpR > 0.0)
      tpDist = MathMax(tpDist, minDist + spread);

   double lots = Lots(slDist);
   if(lots <= 0.0)                                     { Skip(SK_LOTS, setup); return; }

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double px = dir > 0 ? tk.ask : tk.bid;
   double sl = NormalizeDouble(MathRound((px - dir * slDist) / tickSize) * tickSize, _Digits);
   double tp = InpTpR > 0.0 ? NormalizeDouble(MathRound((px + dir * tpDist) / tickSize) * tickSize, _Digits) : 0.0;
   string cmt = "FS " + g_setupName[setup];
   bool ok = dir > 0 ? trade.Buy(lots, _Symbol, 0.0, sl, tp, cmt)
                     : trade.Sell(lots, _Symbol, 0.0, sl, tp, cmt);
   if(!ok || (trade.ResultRetcode() != TRADE_RETCODE_DONE && trade.ResultRetcode() != TRADE_RETCODE_PLACED))
     {
      PrintFormat("Order failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      Skip(SK_ORDER, setup);
      return;
     }

   // find the new position
   g_posTicket = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t != 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic && PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
         g_posTicket = t;
         break;
        }
     }
   g_dir         = dir;
   g_setup       = g_setupName[setup];
   g_openTime    = TimeCurrent();
   g_entry       = trade.ResultPrice() > 0.0 ? trade.ResultPrice() : px;
   g_slInitial   = sl;
   g_riskDist    = MathAbs(g_entry - sl);
   g_lots        = lots;
   g_spreadEntry = spread;
   g_atrEntry    = atrF;
   g_costEntry   = cost;
   g_aligned     = dir == trend ? 1 : 0;
   g_mfe         = 0.0;
   g_mae         = 0.0;
   g_trailed     = false;
   g_tradesToday++;
   g_entries++;
   g_entriesBy[setup]++;
   g_status = StringFormat("%s %s %s @ %s", TimeToString(TimeCurrent(), TIME_MINUTES), g_setup,
                           dir > 0 ? "long" : "short", DoubleToString(g_entry, _Digits));
   if(InpVerbose)
      PrintFormat("ENTRY %s %s %.2f @ %s | SL %s TP %s | ATR %s cost %s (x%.1f) | %s trend",
                  g_setup, dir > 0 ? "long" : "short", lots, DoubleToString(g_entry, _Digits),
                  DoubleToString(sl, _Digits), DoubleToString(tp, _Digits),
                  DoubleToString(atrF, _Digits), DoubleToString(cost, _Digits),
                  cost > 0.0 ? atrF / cost : 0.0, g_aligned ? "with" : "against");
  }

//+------------------------------------------------------------------+
//| Fixed lots, or the lots that lose InpRiskPercent at the stop      |
//| (commission included). 0 = cannot size within the limits.        |
//+------------------------------------------------------------------+
double Lots(double slDist)
  {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double maxLot = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), InpMaxLots);
   double lots   = InpFixedLots;
   if(InpRiskPercent > 0.0)
     {
      double lossPerLot = slDist * g_valPerPx + InpCommission;
      if(lossPerLot <= 0.0)
         return 0.0;
      lots = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0 / lossPerLot;
     }
   if(step > 0.0)
      lots = MathFloor(lots / step + 1e-9) * step;
   lots = MathMin(lots, maxLot);
   if(lots < minLot)
      return 0.0;
   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
//| Time stop, excursions, optional break-even and trail.            |
//+------------------------------------------------------------------+
void ManagePosition()
  {
   if(g_posTicket == 0)
      return;
   if(!PositionSelectByTicket(g_posTicket))
      return; // closed; OnTradeTransaction does the bookkeeping
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;
   double exitPx = g_dir > 0 ? tk.bid : tk.ask;
   double move   = (exitPx - g_entry) * g_dir;
   g_mfe = MathMax(g_mfe, move);
   g_mae = MathMin(g_mae, move);

   if(TimeCurrent() - g_openTime >= InpMaxHoldMin * 60)
     {
      if(!trade.PositionClose(g_posTicket, InpDeviationPts))
         PrintFormat("Time-stop close failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
     }
   if(g_riskDist <= 0.0)
      return;

   double sl    = PositionGetDouble(POSITION_SL);
   double tp    = PositionGetDouble(POSITION_TP);
   double newSl = sl;
   double rNow  = move / g_riskDist;
   if(InpBreakEvenR > 0.0 && rNow >= InpBreakEvenR)
     {
      double be = g_entry + g_dir * g_commPx; // cover the commission too
      if(g_dir > 0 ? be > newSl : (newSl == 0.0 || be < newSl))
         newSl = be;
     }
   if(InpTrailStartR > 0.0 && g_atrEntry > 0.0 && rNow >= InpTrailStartR)
     {
      double tr = exitPx - g_dir * InpTrailAtr * g_atrEntry;
      if(g_dir > 0 ? tr > newSl : (newSl == 0.0 || tr < newSl))
        {
         newSl = tr;
         g_trailed = true;
        }
     }
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   newSl = NormalizeDouble(MathRound(newSl / tickSize) * tickSize, _Digits);
   if(newSl == sl)
      return;
   double minDist = MathMax((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                            (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * _Point;
   if(g_dir > 0 && tk.bid - newSl <= minDist)
      return;
   if(g_dir < 0 && newSl - tk.ask <= minDist)
      return;
   if(!trade.PositionModify(g_posTicket, newSl, tp))
      PrintFormat("Stop modify failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Bookkeeping: losing streaks, results and the CSV trade log       |
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

   // The closing deal is opposite to the position: a SELL deal closes a long.
   bool   wasLong = HistoryDealGetInteger(trans.deal, DEAL_TYPE) == DEAL_TYPE_SELL;
   double exitPx  = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double r       = g_riskDist > 0.0 ? (wasLong ? exitPx - g_entry : g_entry - exitPx) / g_riskDist : 0.0;
   g_sumR   += r;
   g_sumPnl += pnl;
   if(pnl > 0.0)
      g_wins++;

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

   string why = ExitReason(trans.deal);
   if(InpVerbose)
      PrintFormat("EXIT  %s %s @ %s (%s) | %+.2fR | %+.2f %s | held %ds | best %+.2fR worst %+.2fR",
                  g_setup, wasLong ? "long" : "short", DoubleToString(exitPx, _Digits), why, r,
                  pnl, AccountInfoString(ACCOUNT_CURRENCY), (int)(TimeCurrent() - g_openTime),
                  g_riskDist > 0.0 ? g_mfe / g_riskDist : 0.0, g_riskDist > 0.0 ? g_mae / g_riskDist : 0.0);
   if(InpLogTrades)
      LogTrade(trans.deal, pnl, wasLong, why);

   g_posTicket = 0;
   g_setup     = "";
   g_riskDist  = 0.0;
   g_atrEntry  = 0.0;
  }

string ExitReason(ulong deal)
  {
   long reason = HistoryDealGetInteger(deal, DEAL_REASON);
   if(reason == DEAL_REASON_SL)
      return g_trailed ? "trail" : "stop";
   if(reason == DEAL_REASON_TP)
      return "tp";
   if(reason == DEAL_REASON_SO)
      return "stop_out";
   if(reason == DEAL_REASON_EXPERT)
      return "time";
   return "manual";
  }

void LogTrade(ulong deal, double pnl, bool wasLong, const string why)
  {
   string name = "FastScalper_" + _Symbol + ".csv";
   int h = FileOpen(name, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
     {
      Print("Cannot open ", name, ": ", GetLastError());
      return;
     }
   if(FileSize(h) == 0)
      FileWrite(h, "open_time", "close_time", "symbol", "side", "setup", "lots", "entry", "exit",
                "sl_initial", "risk", "spread", "cost", "atr", "atr_cost", "aligned", "hold_sec",
                "mfe", "mae", "exit_reason", "pnl");
   FileSeek(h, 0, SEEK_END);
   datetime closeTime = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
   FileWrite(h,
             TimeToString(g_openTime, TIME_DATE | TIME_SECONDS),
             TimeToString(closeTime, TIME_DATE | TIME_SECONDS),
             _Symbol, wasLong ? "long" : "short", g_setup,
             DoubleToString(g_lots, 2),
             DoubleToString(g_entry, _Digits),
             DoubleToString(HistoryDealGetDouble(deal, DEAL_PRICE), _Digits),
             DoubleToString(g_slInitial, _Digits),
             DoubleToString(g_riskDist, _Digits),
             DoubleToString(g_spreadEntry, _Digits),
             DoubleToString(g_costEntry, _Digits),
             DoubleToString(g_atrEntry, _Digits),
             DoubleToString(g_costEntry > 0.0 ? g_atrEntry / g_costEntry : 0.0, 2),
             IntegerToString(g_aligned),
             IntegerToString((int)(closeTime - g_openTime)),
             DoubleToString(g_mfe, _Digits),
             DoubleToString(g_mae, _Digits),
             why,
             DoubleToString(pnl, 2));
   FileClose(h);
  }

//+------------------------------------------------------------------+
void ShowPanel()
  {
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))
      return;
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;
   double spread = tk.ask - tk.bid;
   double cost   = spread + g_commPx;
   string pos = "flat";
   if(g_posTicket != 0)
      pos = StringFormat("%s %s %.2f @ %s | %ds of %ds | best %+.2fR worst %+.2fR",
                         g_setup, g_dir > 0 ? "long" : "short", g_lots, DoubleToString(g_entry, _Digits),
                         (int)(TimeCurrent() - g_openTime), InpMaxHoldMin * 60,
                         g_riskDist > 0.0 ? g_mfe / g_riskDist : 0.0, g_riskDist > 0.0 ? g_mae / g_riskDist : 0.0);
   string state = g_dayHalted ? "HALTED: daily loss limit"
                  : (TimeCurrent() < g_pauseUntil ? "PAUSED until " + TimeToString(g_pauseUntil, TIME_MINUTES)
                     : "active");
   Comment(StringFormat(
              "FastScalper v1  %s M1  |  %s\n"
              "Spread %s + commission %s = cost %s\n"
              "Position: %s\n"
              "Today %d/%d trades | losing streak %d | day P/L %+.2f\n"
              "Session: %d entries, %d wins, %+.2fR, %+.2f %s\n"
              "Signals A/B/C: %d / %d / %d\n"
              "%s",
              _Symbol, state,
              DoubleToString(spread, _Digits), DoubleToString(g_commPx, _Digits), DoubleToString(cost, _Digits),
              pos,
              g_tradesToday, InpMaxTradesPerDay, g_consecLosses,
              AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartEq,
              g_entries, g_wins, g_sumR, g_sumPnl, AccountInfoString(ACCOUNT_CURRENCY),
              g_signals[0], g_signals[1], g_signals[2],
              g_status));
  }
//+------------------------------------------------------------------+
