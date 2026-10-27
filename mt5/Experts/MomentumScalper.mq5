//+------------------------------------------------------------------+
//| MomentumScalper.mq5  v2.1                                        |
//| High-frequency momentum + price-action + VWAP + SMC scalper      |
//| for MT5 (built around Exness BTCUSDm). Decides on every tick,    |
//| holds seconds to a few minutes, one position at a time.          |
//|                                                                  |
//| An entry needs ONE trigger and a confluence SCORE >= InpMinScore.|
//|                                                                  |
//| Triggers                                                         |
//|  burst : price moves N spreads in a few seconds, flow one-sided  |
//|  bos   : price breaks the last unbroken M1 swing (BOS / CHoCH)   |
//|  sweep : price wicks through a swing (liquidity grab) and        |
//|          reclaims it with flow                                   |
//|  fvg   : price taps an unfilled fair value gap and bounces       |
//|                                                                  |
//| Score (0-100)                                                    |
//|  M1 EMA trend 15 | M5 EMA trend 10 | VWAP side 15 |              |
//|  last structure break 10 | discount/premium 5 | flow 0-20 |      |
//|  tick speed 0-10 | side of POC 5 | room to next volume level 10  |
//|                                                                  |
//| Hard gates: spread/ATR, volatility spike, daily loss, trade caps,|
//| cooldown, losing-streak pause. No martingale, no grid.           |
//| Closed trades: MQL5/Files/MomentumScalper_<symbol>.csv           |
//+------------------------------------------------------------------+
#property copyright "goldscalp"
#property version   "2.10"
#property description "HF momentum + price action + VWAP + SMC scalper (trigger + confluence score)"

#include <Trade/Trade.mqh>

//--- general
input group "General"
input long   InpMagic             = 260426; // Magic number
input int    InpDeviationPts      = 300;    // Max slippage, points (BTCUSDm: 100 pts = $1)
input bool   InpVerbose           = true;   // Print every entry and exit
input bool   InpLogTrades         = true;   // Write closed trades to CSV

//--- risk
input group "Risk"
input double InpRiskPercent       = 0.0;    // Risk per trade, % of equity (0 = fixed lots)
input double InpFixedLots         = 0.01;   // Fixed lots when risk % is 0
input double InpMaxLots           = 1.0;    // Hard cap on lots
input double InpMaxDailyLossPct   = 5.0;    // Stop for the day after this equity drawdown %
input int    InpMaxTradesPerDay   = 200;    // Max entries per server day
input int    InpMaxTradesPerHour  = 25;     // Max entries per rolling hour
input int    InpCooldownSec       = 10;     // Wait after any exit, seconds
input int    InpMaxConsecLosses   = 5;      // Pause after this many losses in a row
input int    InpLossPauseMin      = 15;     // Pause length, minutes

//--- hard gates
input group "Hard gates"
input int    InpMaxSpreadPts      = 0;      // Max spread, points (0 = off)
input double InpMinAtrToSpread    = 3.5;    // M1 ATR must be >= this x spread
input double InpMaxAtrSpikeX      = 3.5;    // Skip when M1 ATR(14) > this x ATR(100)
input double InpMinTickRate       = 0.1;    // Skip when the feed is slower than this, ticks/s

//--- triggers
input group "Triggers"
input bool   InpUseBurst          = true;   // Momentum burst
input bool   InpUseBos            = true;   // Break of structure / CHoCH
input bool   InpUseSweep          = true;   // Liquidity sweep and reclaim
input bool   InpUseFvg            = true;   // Fair value gap tap and bounce
input int    InpBurstSec          = 8;      // Burst look-back, seconds (also the flow window)
input double InpBurstMinSpreads   = 1.8;    // Burst: move >= this many spreads in the look-back
input double InpBurstMaxAtr       = 1.2;    // Burst: ...but <= this x ATR (overextended)
input double InpBurstMinSpeedX    = 1.2;    // Burst: tick speed >= this x 10-min average
input double InpTrigMinFlow       = 0.25;   // Every trigger: flow must agree by at least this
input double InpMaxChaseAtr       = 0.5;    // Skip if price is this many ATR past the trigger level

//--- structure
input group "Structure (smart money concepts)"
input int    InpStructBars        = 120;    // M1 candles scanned for swings, BOS/CHoCH and FVGs
input int    InpPivotK            = 2;      // Swing = high/low with K lower/higher candles each side
input int    InpRangeBars         = 60;     // Dealing range for premium/discount, M1 candles
input double InpFvgMinAtr         = 0.2;    // Min FVG size, x ATR
input int    InpFvgLookback       = 20;     // FVGs younger than this many candles

//--- confluence
input group "Confluence score"
input int    InpMinScore          = 65;     // Min score (0-100) to enter
input int    InpEmaFast           = 9;      // M1 fast EMA
input int    InpEmaSlow           = 21;     // M1 slow EMA
input ENUM_TIMEFRAMES InpHtfTF    = PERIOD_M5; // Higher timeframe
input int    InpHtfEma            = 50;     // HTF EMA period (0 = off)
input int    InpProfileBars       = 240;    // M1 candles for the rolling VWAP and volume profile
input double InpHvnPct            = 0.60;   // HVN = local profile peak >= this x POC volume
input double InpRoomR             = 1.0;    // Room points need this many R to the next volume level

//--- exits
input group "Exits"
input double InpSlAtr             = 1.0;    // Initial stop, x ATR
input double InpSlMinSpreads      = 3.0;    // Stop at least this many spreads
input bool   InpStructSl          = true;   // Sweep/FVG: stop beyond the wick or gap if wider
input double InpSlMaxAtr          = 2.0;    // Never wider than this x ATR
input double InpTpR               = 1.0;    // Take profit in R (0 = none, trail only)
input double InpBreakEvenR        = 0.5;    // Move stop to entry at +R (0 = off)
input double InpTrailStartR       = 0.8;    // Start trailing at +R (0 = off)
input double InpTrailAtr          = 0.6;    // Trail distance, x ATR
input int    InpMaxHoldSec        = 300;    // Time stop, seconds (0 = off)
input bool   InpFlowExit          = false;  // Exit when flow turns hard against the trade (cut 74% of trades in v2 tests)
input double InpExitFlow          = 0.55;   // ...imbalance against
input int    InpFlowExitMinSec    = 10;     // ...only after holding this long
input double InpFlowExitMaxR      = 0.3;    // ...and only while profit is below this R

//--- session
input group "Session (server time, Exness = UTC)"
input int    InpSessionStartHour  = 0;      // Start hour
input int    InpSessionEndHour    = 24;     // End hour (exclusive)
input bool   InpTradeWeekends     = true;   // Trade Saturday and Sunday

//--- optimisation
input group "Optimisation"
input int    InpOptMinTrades      = 200;    // Custom optimizer score needs at least this many trades

//--- tick ring: one bucket per second
#define RING 900
long   g_secStamp[RING];
int    g_buy[RING];
int    g_sell[RING];
int    g_cnt[RING];
double g_secMid[RING];
long   g_lastMsc     = 0;
int    g_sameMscSeen = 0;
double g_lastMid     = 0.0;
bool   g_hasAggFlags = false;

//--- indicators
int g_atr = INVALID_HANDLE, g_atrSlow = INVALID_HANDLE;
int g_emaF = INVALID_HANDLE, g_emaS = INVALID_HANDLE, g_htf = INVALID_HANDLE;

//--- per-candle context (rebuilt on each new M1 candle)
datetime g_ctxBar = 0;
double   g_poc = 0.0, g_vah = 0.0, g_val = 0.0, g_vwap = 0.0;
double   g_hvn[];
double   g_swH = 0.0, g_swL = 0.0;           // last unbroken swing high / low
int      g_structDir = 0;                    // +1 last break was bullish, -1 bearish
bool     g_choch = false;                    // last break flipped the previous direction
double   g_eq = 0.0;                         // equilibrium of the dealing range
double   g_bullTop = 0.0, g_bullBot = 0.0;   // newest unfilled bullish FVG
double   g_bearTop = 0.0, g_bearBot = 0.0;   // newest unfilled bearish FVG

//--- state
CTrade   trade;
datetime g_day = 0;
double   g_dayStartEquity = 0.0;
bool     g_haltDay = false;
int      g_tradesToday = 0;
datetime g_entryTimes[64];
int      g_entryIdx = 0;
datetime g_lastExit = 0;
int      g_consecLosses = 0;
datetime g_pauseUntil = 0;
datetime g_lastCloseTry = 0;
string   g_closeWhy = "";
string   g_status = "";
string   g_lastCand = "";
datetime g_trigUsed[4];
datetime g_flatSince = 0;

//--- open trade context
ulong    g_posTicket = 0;
string   g_setup = "";
double   g_entry = 0.0, g_riskDist = 0.0, g_slInitial = 0.0, g_spreadEntry = 0.0, g_atrEntry = 0.0;
double   g_flowEntry = 0.0, g_speedEntry = 0.0, g_mfe = 0.0, g_mae = 0.0;
double   g_inCommission = 0.0, g_lots = 0.0;
int      g_scoreEntry = 0;
datetime g_openTime = 0;

//--- diagnostics
#define SKIP_HALTED   0
#define SKIP_PAUSED   1
#define SKIP_CAPS     2
#define SKIP_ALGO     3
#define SKIP_SESSION  4
#define SKIP_SPREAD   5
#define SKIP_ATR      6
#define SKIP_SPIKE    7
#define SKIP_FEED     8
#define SKIP_NOTRIG   9
#define SKIP_SCORE    10
#define SKIP_FAILED   11
#define SKIP_COUNT    12
string   g_skipName[SKIP_COUNT] = {"daily loss limit", "losing-streak pause", "hour/day trade cap",
                                   "algo trading disabled", "outside session", "spread above max",
                                   "ATR < min x spread", "volatility spike", "slow feed",
                                   "no trigger", "score below minimum", "order rejected"};
int      g_skipMin[SKIP_COUNT];
datetime g_skipLast[SKIP_COUNT];
int      g_minutesSeen = 0;
datetime g_lastSeenMin = 0;
double   g_ratioSum = 0.0;
int      g_ratioN = 0;
datetime g_ratioMin = 0;
#define TRIG_COUNT 4
string   g_trigName[TRIG_COUNT] = {"burst", "bos", "sweep", "fvg"};
int      g_trigN[TRIG_COUNT], g_trigW[TRIG_COUNT];
double   g_trigR[TRIG_COUNT];

//+------------------------------------------------------------------+
int OnInit()
  {
   ArrayInitialize(g_secStamp, -1);
   ArrayInitialize(g_buy, 0);
   ArrayInitialize(g_sell, 0);
   ArrayInitialize(g_cnt, 0);
   ArrayInitialize(g_secMid, 0.0);
   ArrayInitialize(g_entryTimes, 0);
   ArrayInitialize(g_skipMin, 0);
   ArrayInitialize(g_skipLast, 0);
   ArrayInitialize(g_trigN, 0);
   ArrayInitialize(g_trigW, 0);
   ArrayInitialize(g_trigR, 0.0);
   ArrayInitialize(g_trigUsed, 0);

   if(InpBurstSec < 2 || InpBurstSec > 120)
     { Print("InpBurstSec must be within 2..120"); return INIT_PARAMETERS_INCORRECT; }
   if(InpEmaFast >= InpEmaSlow || InpPivotK < 1 || InpStructBars < 30 || InpProfileBars < 30)
     { Print("Check EMA periods, InpPivotK (>= 1), InpStructBars and InpProfileBars (>= 30)"); return INIT_PARAMETERS_INCORRECT; }

   g_atr     = iATR(_Symbol, PERIOD_M1, 14);
   g_atrSlow = iATR(_Symbol, PERIOD_M1, 100);
   g_emaF    = iMA(_Symbol, PERIOD_M1, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_emaS    = iMA(_Symbol, PERIOD_M1, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   if(InpHtfEma > 0)
      g_htf = iMA(_Symbol, InpHtfTF, InpHtfEma, 0, MODE_EMA, PRICE_CLOSE);
   if(g_atr == INVALID_HANDLE || g_atrSlow == INVALID_HANDLE || g_emaF == INVALID_HANDLE ||
      g_emaS == INVALID_HANDLE || (InpHtfEma > 0 && g_htf == INVALID_HANDLE))
     { Print("Cannot create indicators"); return INIT_FAILED; }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPts);
   trade.SetTypeFillingBySymbol(_Symbol);

   PullTicks();
   RecoverPosition();
   EventSetTimer(1);
   PrintFormat("MomentumScalper v2.1 on %s | min score %d | stop %.1fxATR (min %.1f spreads, max %.1fxATR) | "
               "TP %.1fR | BE %.1fR | trail from %.1fR | time stop %ds | %s",
               _Symbol, InpMinScore, InpSlAtr, InpSlMinSpreads, InpSlMaxAtr, InpTpR, InpBreakEvenR,
               InpTrailStartR, InpMaxHoldSec,
               InpRiskPercent > 0 ? StringFormat("risk %.2f%%", InpRiskPercent)
                                  : StringFormat("fixed %.2f lots", InpFixedLots));
   return INIT_SUCCEEDED;
  }

void ReleaseHandle(int handle)
  {
   if(handle != INVALID_HANDLE)
      IndicatorRelease(handle);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   PrintReport();
   ReleaseHandle(g_atr);
   ReleaseHandle(g_atrSlow);
   ReleaseHandle(g_emaF);
   ReleaseHandle(g_emaS);
   ReleaseHandle(g_htf);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   PullTicks();
   DayCheck();
   RefreshContext();
   ManagePosition();
   TryEntry();
  }

void OnTimer()
  {
   // Time stops must fire even when no tick arrives.
   DayCheck();
   ManagePosition();
   if(!MQLInfoInteger(MQL_TESTER))
      ShowPanel();
  }

//+------------------------------------------------------------------+
//| Ticks: flow per second (aggressor flags or tick rule) + mid      |
//+------------------------------------------------------------------+
void AddTick(const MqlTick &t)
  {
   long sec = t.time_msc / 1000;
   int  i   = (int)(sec % RING);
   if(g_secStamp[i] != sec)
     {
      g_secStamp[i] = sec;
      g_buy[i] = 0;
      g_sell[i] = 0;
      g_cnt[i] = 0;
      g_secMid[i] = 0.0;
     }
   double mid = (t.bid > 0.0 && t.ask > 0.0) ? (t.bid + t.ask) * 0.5 : 0.0;
   if(mid > 0.0)
      g_secMid[i] = mid;

   int  sign   = 0;
   bool isBuy  = (t.flags & TICK_FLAG_BUY)  != 0;
   bool isSell = (t.flags & TICK_FLAG_SELL) != 0;
   if(isBuy != isSell)
     {
      sign = isBuy ? 1 : -1;
      g_hasAggFlags = true;
     }
   else
     {
      if(g_hasAggFlags || mid <= 0.0)
         return;
      if(g_lastMid > 0.0)
         sign = mid > g_lastMid ? 1 : (mid < g_lastMid ? -1 : 0);
      g_lastMid = mid;
      if(sign == 0)
         return;
     }
   g_cnt[i]++;
   if(sign > 0)
      g_buy[i]++;
   else
      g_sell[i]++;
  }

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
         g_lastMsc = m;
         g_sameMscSeen = 1;
         same = 1;
        }
      if(n < 20000)
         return;
      from = (ulong)g_lastMsc;
     }
  }

// Flow imbalance and tick rate over the last windowSec, plus the 10-minute base rate.
void Flow(int windowSec, double &imb, double &rate, double &baseRate)
  {
   long now = g_lastMsc / 1000;
   int b = 0, s = 0, c = 0, cb = 0;
   for(int k = 0; k < windowSec; k++)
     {
      long sec = now - k;
      int  i   = (int)(sec % RING);
      if(g_secStamp[i] == sec)
        { b += g_buy[i]; s += g_sell[i]; c += g_cnt[i]; }
     }
   const int base = 600;
   for(int k = windowSec; k < windowSec + base; k++)
     {
      long sec = now - k;
      int  i   = (int)(sec % RING);
      if(g_secStamp[i] == sec)
         cb += g_cnt[i];
     }
   imb      = (b + s) > 0 ? (double)(b - s) / (b + s) : 0.0;
   rate     = (double)c / windowSec;
   baseRate = (double)cb / base;
  }

// Mid price about secAgo seconds ago (nearest second with a quote, up to 5 s older).
double MidSecondsAgo(int secAgo)
  {
   long now = g_lastMsc / 1000;
   for(int k = secAgo; k < secAgo + 5; k++)
     {
      long sec = now - k;
      int  i   = (int)(sec % RING);
      if(g_secStamp[i] == sec && g_secMid[i] > 0.0)
         return g_secMid[i];
     }
   return 0.0;
  }

//+------------------------------------------------------------------+
//| Per-candle context: VWAP, volume profile, structure, FVGs        |
//+------------------------------------------------------------------+
void RefreshContext()
  {
   datetime bar = iTime(_Symbol, PERIOD_M1, 0);
   if(bar == 0 || bar == g_ctxBar)
      return;
   double atr = Atr();
   if(atr <= 0.0)
      return;
   g_ctxBar = bar;
   BuildProfile(atr);
   BuildStructure(atr);
  }

double TickVol(const MqlRates &r)
  {
   return r.tick_volume > 0 ? (double)r.tick_volume : 1.0;
  }

void BuildProfile(double atr)
  {
   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M1, 1, InpProfileBars, r);
   if(n < 30)
      return;
   double lo = DBL_MAX, hi = -DBL_MAX, pv = 0.0, vs = 0.0;
   for(int k = 0; k < n; k++)
     {
      lo = MathMin(lo, r[k].low);
      hi = MathMax(hi, r[k].high);
      pv += (r[k].high + r[k].low + r[k].close) / 3.0 * TickVol(r[k]);
      vs += TickVol(r[k]);
     }
   g_vwap = vs > 0.0 ? pv / vs : 0.0;

   double bin = MathMax(atr / 4.0, 10 * _Point);
   if(hi <= lo)
      return;
   int nb = (int)MathCeil((hi - lo) / bin) + 1;
   if(nb > 2000)
     {
      bin = (hi - lo) / 1999.0;
      nb  = 2000;
     }
   if(nb < 5)
      return;
   double raw[], vol[];
   ArrayResize(raw, nb);
   ArrayResize(vol, nb);
   ArrayInitialize(raw, 0.0);
   for(int k = 0; k < n; k++)
     {
      int a = (int)((r[k].low - lo) / bin);
      int b = (int)((r[k].high - lo) / bin);
      a = MathMax(0, MathMin(nb - 1, a));
      b = MathMax(a, MathMin(nb - 1, b));
      double v = TickVol(r[k]) / (b - a + 1);
      for(int j = a; j <= b; j++)
         raw[j] += v;
     }
   for(int j = 0; j < nb; j++)
      vol[j] = (raw[MathMax(0, j - 1)] + raw[j] + raw[MathMin(nb - 1, j + 1)]) / 3.0;

   int poc = ArrayMaximum(vol);
   double total = 0.0;
   for(int j = 0; j < nb; j++)
      total += vol[j];
   double area = vol[poc];
   int loI = poc, hiI = poc;
   while(area < 0.7 * total && (loI > 0 || hiI < nb - 1))
     {
      double down = loI > 0 ? vol[loI - 1] : -1.0;
      double up   = hiI < nb - 1 ? vol[hiI + 1] : -1.0;
      if(up >= down)
        { hiI++; area += up; }
      else
        { loI--; area += down; }
     }
   g_poc = lo + (poc + 0.5) * bin;
   g_val = lo + loI * bin;
   g_vah = lo + (hiI + 1) * bin;

   ArrayResize(g_hvn, 0);
   for(int j = 1; j < nb - 1; j++)
      if(j != poc && vol[j] >= InpHvnPct * vol[poc] && vol[j] >= vol[j - 1] && vol[j] > vol[j + 1])
        {
         int m = ArraySize(g_hvn);
         ArrayResize(g_hvn, m + 1);
         g_hvn[m] = lo + (j + 0.5) * bin;
        }
  }

bool IsPivotHigh(const MqlRates &r[], int j, int k)
  {
   for(int m = 1; m <= k; m++)
      if(r[j].high <= r[j - m].high || r[j].high < r[j + m].high)
         return false;
   return true;
  }

bool IsPivotLow(const MqlRates &r[], int j, int k)
  {
   for(int m = 1; m <= k; m++)
      if(r[j].low >= r[j - m].low || r[j].low > r[j + m].low)
         return false;
   return true;
  }

// Walks the closed candles oldest to newest: confirms swings K candles after they form,
// records a bullish (bearish) break when a candle CLOSES beyond the active swing high (low),
// and keeps the swings that are still unbroken plus the newest unfilled FVG on each side.
void BuildStructure(double atr)
  {
   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M1, 1, InpStructBars, r);   // oldest first
   int k = InpPivotK;
   if(n < 2 * k + 3)
      return;
   double actH = 0.0, actL = 0.0;
   int    dir = 0;
   bool   choch = false;
   for(int i = 0; i < n; i++)
     {
      int j = i - k;
      if(j >= k)
        {
         if(IsPivotHigh(r, j, k))
            actH = r[j].high;
         if(IsPivotLow(r, j, k))
            actL = r[j].low;
        }
      if(actH > 0.0 && r[i].close > actH)
        { choch = dir < 0; dir = 1; actH = 0.0; }
      if(actL > 0.0 && r[i].close < actL)
        { choch = dir > 0; dir = -1; actL = 0.0; }
     }
   g_swH = actH;
   g_swL = actL;
   g_structDir = dir;
   g_choch = choch;

   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = MathMax(0, n - InpRangeBars); i < n; i++)
     {
      hi = MathMax(hi, r[i].high);
      lo = MathMin(lo, r[i].low);
     }
   g_eq = (hi + lo) * 0.5;

   g_bullTop = g_bullBot = g_bearTop = g_bearBot = 0.0;
   for(int i = n - 1; i >= MathMax(2, n - InpFvgLookback); i--)
     {
      if(g_bullTop == 0.0 && r[i].low > r[i - 2].high && r[i].low - r[i - 2].high >= InpFvgMinAtr * atr)
        {
         bool filled = false;
         for(int m = i + 1; m < n && !filled; m++)
            filled = r[m].low <= r[i - 2].high;
         if(!filled)
           { g_bullTop = r[i].low; g_bullBot = r[i - 2].high; }
        }
      if(g_bearTop == 0.0 && r[i].high < r[i - 2].low && r[i - 2].low - r[i].high >= InpFvgMinAtr * atr)
        {
         bool filled = false;
         for(int m = i + 1; m < n && !filled; m++)
            filled = r[m].high >= r[i - 2].low;
         if(!filled)
           { g_bearTop = r[i - 2].low; g_bearBot = r[i].high; }
        }
     }
  }

// Distance from price to the nearest volume level (POC, VA edges, HVNs) in the trade direction.
double RoomTo(int dir, double price, double atr)
  {
   double best = DBL_MAX, gap = 0.1 * atr;
   double lv[3];
   lv[0] = g_poc;
   lv[1] = g_vah;
   lv[2] = g_val;
   for(int k = 0; k < 3; k++)
     {
      double d = dir > 0 ? lv[k] - price : price - lv[k];
      if(lv[k] > 0.0 && d > gap && d < best)
         best = d;
     }
   for(int k = 0; k < ArraySize(g_hvn); k++)
     {
      double d = dir > 0 ? g_hvn[k] - price : price - g_hvn[k];
      if(d > gap && d < best)
         best = d;
     }
   return best;
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double BufferValue(int handle, int shift)
  {
   double v[];
   if(handle == INVALID_HANDLE || CopyBuffer(handle, 0, shift, 1, v) != 1)
      return 0.0;
   return v[0];
  }

double Atr()     { return BufferValue(g_atr, 1); }
double AtrSlow() { return BufferValue(g_atrSlow, 1); }

double Clamp01(double x) { return MathMax(0.0, MathMin(1.0, x)); }

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

double Lots(double riskDist)
  {
   if(InpRiskPercent <= 0.0)
      return NormLots(InpFixedLots);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0.0)
      tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0.0 || ts <= 0.0)
      return 0.0;
   return NormLots(AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0 / (riskDist / ts * tv));
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
   if(TimeCurrent() == g_lastCloseTry)
      return;
   g_lastCloseTry = TimeCurrent();
   if(!SelectOurPosition())
      return;
   g_closeWhy = why;
   if(!trade.PositionClose((ulong)PositionGetInteger(POSITION_TICKET), InpDeviationPts))
      PrintFormat("Close (%s) failed: %d %s", why, trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

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

int EntriesLastHour()
  {
   int n = 0;
   for(int k = 0; k < 64; k++)
      if(g_entryTimes[k] > 0 && TimeCurrent() - g_entryTimes[k] < 3600)
         n++;
   return n;
  }

void DayCheck()
  {
   datetime now = TimeCurrent();
   datetime day = (datetime)((long)now - (long)now % 86400);
   if(day != g_day)
     {
      g_day = day;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_haltDay = false;
      g_tradesToday = 0;
     }
   if(!g_haltDay && InpMaxDailyLossPct > 0.0 &&
      AccountInfoDouble(ACCOUNT_EQUITY) <= g_dayStartEquity * (1.0 - InpMaxDailyLossPct / 100.0))
     {
      g_haltDay = true;
      CloseOurPosition("daily_limit");
      PrintFormat("Daily loss limit hit (%.2f%%): no new trades until the next server day", InpMaxDailyLossPct);
     }
  }

//+------------------------------------------------------------------+
//| Diagnostics                                                      |
//+------------------------------------------------------------------+
void Skip(int reason, const string status)
  {
   g_status = status;
   datetime m = iTime(_Symbol, PERIOD_M1, 0);
   if(g_skipLast[reason] != m)
     {
      g_skipLast[reason] = m;
      g_skipMin[reason]++;
     }
  }

void PrintReport()
  {
   int n = 0, w = 0;
   double R = 0.0;
   for(int t = 0; t < TRIG_COUNT; t++)
     {
      n += g_trigN[t];
      w += g_trigW[t];
      R += g_trigR[t];
     }
   PrintFormat("=== MomentumScalper v2.1 report: %d minutes scanned flat, %d trades, %d wins, %+.2f R ===",
               g_minutesSeen, n, w, R);
   for(int t = 0; t < TRIG_COUNT; t++)
      if(g_trigN[t] > 0)
         PrintFormat("  %-6s %4d trades | win %.0f%% | %+.2f R | avg %+.3f R",
                     g_trigName[t], g_trigN[t], 100.0 * g_trigW[t] / g_trigN[t],
                     g_trigR[t], g_trigR[t] / g_trigN[t]);
   if(g_ratioN > 0)
      PrintFormat("Average M1 ATR / spread: %.2f (gate needs >= %.1f)", g_ratioSum / g_ratioN, InpMinAtrToSpread);
   for(int r = 0; r < SKIP_COUNT; r++)
      if(g_skipMin[r] > 0)
         PrintFormat("  blocked by %-22s in %6d minutes (%.1f%%)", g_skipName[r], g_skipMin[r],
                     g_minutesSeen > 0 ? 100.0 * g_skipMin[r] / g_minutesSeen : 0.0);
  }

//+------------------------------------------------------------------+
//| Triggers: returns the direction, sets the trigger index and a    |
//| structural stop level (0 = none)                                 |
//+------------------------------------------------------------------+
int FindTrigger(const MqlTick &tk, double mid, double imb, double speedX, double atr, double spread,
                int &trig, double &structStop)
  {
   datetime bar   = iTime(_Symbol, PERIOD_M1, 0);
   double   chase = InpMaxChaseAtr * atr;
   double   barLo = iLow(_Symbol, PERIOD_M1, 0);
   double   barHi = iHigh(_Symbol, PERIOD_M1, 0);
   structStop = 0.0;

   // Liquidity sweep: wick through the unbroken swing, back inside, flow reclaiming.
   if(InpUseSweep && g_trigUsed[2] != bar)
     {
      if(g_swL > 0.0 && barLo < g_swL && tk.bid > g_swL && tk.bid - g_swL <= chase && imb >= InpTrigMinFlow)
        { trig = 2; structStop = barLo - 0.1 * atr; return 1; }
      if(g_swH > 0.0 && barHi > g_swH && tk.bid < g_swH && g_swH - tk.bid <= chase && imb <= -InpTrigMinFlow)
        { trig = 2; structStop = barHi + 0.1 * atr; return -1; }
     }

   // FVG: this candle tapped the gap and price is turning away from it.
   if(InpUseFvg && g_trigUsed[3] != bar)
     {
      double then = MidSecondsAgo(3);
      if(g_bullTop > 0.0 && barLo <= g_bullTop && tk.bid > g_bullBot && tk.bid - g_bullTop <= chase &&
         then > 0.0 && mid > then && imb >= InpTrigMinFlow)
        { trig = 3; structStop = MathMin(barLo, g_bullBot) - 0.1 * atr; return 1; }
      if(g_bearBot > 0.0 && barHi >= g_bearBot && tk.ask < g_bearTop && g_bearBot - tk.ask <= chase &&
         then > 0.0 && mid < then && imb <= -InpTrigMinFlow)
        { trig = 3; structStop = MathMax(barHi, g_bearTop) + 0.1 * atr; return -1; }
     }

   // BOS / CHoCH: price trades through the last unbroken swing with flow.
   if(InpUseBos && g_trigUsed[1] != bar)
     {
      if(g_swH > 0.0 && tk.bid > g_swH && tk.bid - g_swH <= chase && imb >= InpTrigMinFlow)
        { trig = 1; return 1; }
      if(g_swL > 0.0 && tk.bid < g_swL && g_swL - tk.bid <= chase && imb <= -InpTrigMinFlow)
        { trig = 1; return -1; }
     }

   // Momentum burst: several spreads in a few seconds, one-sided and fast.
   if(InpUseBurst && g_trigUsed[0] != bar)
     {
      double then = MidSecondsAgo(InpBurstSec);
      double move = then > 0.0 ? mid - then : 0.0;
      if(MathAbs(move) >= InpBurstMinSpreads * spread && MathAbs(move) <= InpBurstMaxAtr * atr &&
         speedX >= InpBurstMinSpeedX)
        {
         int d = move > 0.0 ? 1 : -1;
         if(d * imb >= InpTrigMinFlow)
           { trig = 0; return d; }
        }
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| Confluence score, 0-100                                          |
//+------------------------------------------------------------------+
int Score(int dir, double mid, double price, double imb, double speedX, double risk, double atr, string &detail)
  {
   int ema = 0, htf = 0, vwap = 0, bos = 0, pd = 0, poc = 0, room = 0;
   double f = BufferValue(g_emaF, 1), s = BufferValue(g_emaS, 1);
   if(f > 0.0 && s > 0.0 && (dir > 0 ? f > s : f < s))
      ema = 15;
   if(g_htf != INVALID_HANDLE)
     {
      double e = BufferValue(g_htf, 1), c = iClose(_Symbol, InpHtfTF, 1);
      if(e > 0.0 && c > 0.0 && (dir > 0 ? c > e : c < e))
         htf = 10;
     }
   if(g_vwap > 0.0 && (dir > 0 ? mid > g_vwap : mid < g_vwap))
      vwap = 15;
   if(g_structDir == dir)
      bos = 10;
   if(g_eq > 0.0 && (dir > 0 ? mid < g_eq : mid > g_eq))
      pd = 5;
   int flow  = (int)MathRound(20.0 * Clamp01(dir * imb / 0.6));
   int speed = (int)MathRound(10.0 * Clamp01(speedX - 1.0));
   if(g_poc > 0.0 && (dir > 0 ? mid > g_poc : mid < g_poc))
      poc = 5;
   if(RoomTo(dir, price, atr) >= InpRoomR * risk)
      room = 10;
   detail = StringFormat("ema %d htf %d vwap %d bos %d pd %d flow %d speed %d poc %d room %d",
                         ema, htf, vwap, bos, pd, flow, speed, poc, room);
   return ema + htf + vwap + bos + pd + flow + speed + poc + room;
  }

//+------------------------------------------------------------------+
//| Entries: evaluated on every tick while flat                      |
//+------------------------------------------------------------------+
void TryEntry()
  {
   datetime now = TimeCurrent();
   if(SelectOurPosition())
     { g_status = "in position"; g_flatSince = 0; return; }
   // A position just closed but its exit transaction (which records the result and starts
   // the cooldown) has not been processed yet: entering now would mislabel that exit.
   if(g_setup != "")
     {
      if(g_flatSince == 0)
         g_flatSince = now;
      if(now - g_flatSince < 5)
        { g_status = "settling the last exit"; return; }
      g_setup = "";
      g_riskDist = 0.0;
      g_atrEntry = 0.0;
     }
   g_flatSince = 0;
   datetime m   = iTime(_Symbol, PERIOD_M1, 0);
   if(m != g_lastSeenMin)
     {
      g_lastSeenMin = m;
      g_minutesSeen++;
     }
   if(now - g_lastExit < InpCooldownSec)
     { g_status = "cooldown"; return; }
   if(g_haltDay)
     { Skip(SKIP_HALTED, "halted: daily loss limit"); return; }
   if(now < g_pauseUntil)
     { Skip(SKIP_PAUSED, "paused after losing streak"); return; }
   if(g_tradesToday >= InpMaxTradesPerDay || EntriesLastHour() >= InpMaxTradesPerHour)
     { Skip(SKIP_CAPS, "trade cap reached"); return; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     { Skip(SKIP_ALGO, "algo trading disabled"); return; }

   MqlDateTime dt;
   TimeToStruct(now, dt);
   bool weekend = dt.day_of_week == 0 || dt.day_of_week == 6;
   if(dt.hour < InpSessionStartHour || dt.hour >= InpSessionEndHour || (weekend && !InpTradeWeekends))
     { Skip(SKIP_SESSION, "outside session"); return; }

   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk) || tk.bid <= 0.0 || tk.ask <= 0.0)
      return;
   double spread = tk.ask - tk.bid;
   double atr = Atr(), atrSlow = AtrSlow();
   if(atr <= 0.0)
      return;
   if(spread > 0.0 && m != g_ratioMin)
     {
      g_ratioMin = m;
      g_ratioSum += atr / spread;
      g_ratioN++;
     }
   if(InpMaxSpreadPts > 0 && spread > InpMaxSpreadPts * _Point)
     { Skip(SKIP_SPREAD, "spread too wide"); return; }
   if(atr < InpMinAtrToSpread * spread)
     { Skip(SKIP_ATR, StringFormat("M1 ATR only %.1fx the spread (gate %.1f)", spread > 0.0 ? atr / spread : 0.0,
                                   InpMinAtrToSpread)); return; }
   if(InpMaxAtrSpikeX > 0.0 && atrSlow > 0.0 && atr > InpMaxAtrSpikeX * atrSlow)
     { Skip(SKIP_SPIKE, "volatility spike"); return; }

   double imb, rate, baseRate;
   Flow(InpBurstSec, imb, rate, baseRate);
   if(baseRate < InpMinTickRate)
     { Skip(SKIP_FEED, "feed too slow"); return; }
   double speedX = baseRate > 0.0 ? rate / baseRate : 0.0;
   double mid    = (tk.bid + tk.ask) * 0.5;

   int    trig = -1;
   double structStop = 0.0;
   int    dir = FindTrigger(tk, mid, imb, speedX, atr, spread, trig, structStop);
   if(dir == 0)
     {
      Skip(SKIP_NOTRIG, StringFormat("waiting for a trigger | flow %+.2f | speed %.1fx", imb, speedX));
      return;
     }

   // Stop: ATR based, at least N spreads, pushed beyond the sweep wick / FVG if wider, capped.
   double price  = dir > 0 ? tk.ask : tk.bid;
   double ref    = dir > 0 ? tk.bid : tk.ask;
   double slDist = MathMax(InpSlAtr * atr, InpSlMinSpreads * spread);
   if(InpStructSl && structStop > 0.0)
      slDist = MathMax(slDist, MathAbs(ref - structStop));
   slDist = MathMin(slDist, MathMax(InpSlMaxAtr * atr, InpSlMinSpreads * spread));
   slDist = MathMax(slDist, (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point + spread);
   double sl   = NormPrice(dir > 0 ? ref - slDist : ref + slDist);
   double risk = MathAbs(price - sl);

   string detail;
   int score = Score(dir, mid, price, imb, speedX, risk, atr, detail);
   g_lastCand = StringFormat("%s %s score %d/%d: %s", g_trigName[trig], dir > 0 ? "long" : "short",
                             score, InpMinScore, detail);
   if(score < InpMinScore)
     {
      Skip(SKIP_SCORE, g_lastCand);
      return;
     }

   double lots = Lots(risk);
   if(lots <= 0.0)
     { Skip(SKIP_FAILED, "lot size below minimum"); return; }
   double tp = InpTpR > 0.0 ? NormPrice(dir > 0 ? price + InpTpR * risk : price - InpTpR * risk) : 0.0;
   string setup = g_trigName[trig];

   bool ok = dir > 0 ? trade.Buy(lots, _Symbol, tk.ask, sl, tp, "MS " + setup)
                     : trade.Sell(lots, _Symbol, tk.bid, sl, tp, "MS " + setup);
   g_trigUsed[trig] = m;
   if(!ok || (trade.ResultRetcode() != TRADE_RETCODE_DONE && trade.ResultRetcode() != TRADE_RETCODE_PLACED))
     {
      Skip(SKIP_FAILED, "order rejected");
      PrintFormat("%s %s failed: %d %s", setup, dir > 0 ? "BUY" : "SELL",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
      g_lastExit = now;
      return;
     }

   g_tradesToday++;
   g_entryTimes[g_entryIdx] = now;
   g_entryIdx = (g_entryIdx + 1) % 64;
   g_setup = setup;
   g_slInitial = sl;
   g_spreadEntry = spread;
   g_atrEntry = atr;
   g_flowEntry = imb;
   g_speedEntry = speedX;
   g_scoreEntry = score;
   g_mfe = 0.0;
   g_mae = 0.0;
   g_lots = lots;
   g_closeWhy = "";
   g_posTicket = 0;
   g_entry = price;
   g_openTime = now;
   if(SelectOurPosition())
     {
      g_posTicket = (ulong)PositionGetInteger(POSITION_TICKET);
      g_entry     = PositionGetDouble(POSITION_PRICE_OPEN);
      g_openTime  = (datetime)PositionGetInteger(POSITION_TIME);
     }
   g_riskDist = MathAbs(g_entry - sl);
   if(InpVerbose)
      PrintFormat("ENTRY %s %s %.2f @ %s | SL %s TP %s | risk %.2f (%.1f spreads) | score %d (%s)",
                  setup, dir > 0 ? "BUY" : "SELL", lots, DoubleToString(g_entry, _Digits),
                  DoubleToString(sl, _Digits), tp > 0.0 ? DoubleToString(tp, _Digits) : "-",
                  g_riskDist, spread > 0.0 ? g_riskDist / spread : 0.0, score, detail);
  }

//+------------------------------------------------------------------+
//| Exits: time stop, flow fade, break-even, ATR trail               |
//+------------------------------------------------------------------+
void ManagePosition()
  {
   if(!SelectOurPosition())
      return;
   ulong    ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   bool     isBuy  = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
   double   open   = PositionGetDouble(POSITION_PRICE_OPEN);
   double   sl     = PositionGetDouble(POSITION_SL);
   double   tp     = PositionGetDouble(POSITION_TP);
   datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
   if(ticket != g_posTicket)
     {
      if(g_posTicket == 0 && g_setup != "")
        {
         g_posTicket = ticket;
         g_entry = open;
         g_openTime = opened;
         if(sl > 0.0)
            g_riskDist = MathAbs(open - sl);
        }
      else
         RecoverPosition();
     }

   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;
   double move = isBuy ? tk.bid - open : open - tk.ask;
   g_mfe = MathMax(g_mfe, move);
   g_mae = MathMin(g_mae, move);
   double R   = g_riskDist > 0.0 ? g_riskDist : (sl > 0.0 ? MathAbs(open - sl) : 0.0);
   double atr = g_atrEntry > 0.0 ? g_atrEntry : Atr();
   long   held = (long)(TimeCurrent() - opened);

   if(InpMaxHoldSec > 0 && held >= InpMaxHoldSec)
     { CloseOurPosition("time"); return; }

   if(InpFlowExit && held >= InpFlowExitMinSec && R > 0.0 && move < InpFlowExitMaxR * R)
     {
      double imb, rate, baseRate;
      Flow(InpBurstSec, imb, rate, baseRate);
      if((isBuy ? -imb : imb) >= InpExitFlow)
        { CloseOurPosition("flow_fade"); return; }
     }

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
   double step = MathMax(0.05 * atr, SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE));
   bool better = isBuy ? newSl >= sl + step : (sl == 0.0 || newSl <= sl - step);
   if(!better || newSl == sl)
      return;
   double minDist = MathMax((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                            (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * _Point;
   if(isBuy ? tk.bid - newSl <= minDist : newSl - tk.ask <= minDist)
      return;
   if(!trade.PositionModify(ticket, newSl, tp))
      PrintFormat("Stop modify failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Optimizer score ("Custom max"): net profit over max equity       |
//| drawdown, scaled by sample size; 0 below InpOptMinTrades.        |
//+------------------------------------------------------------------+
double OnTester()
  {
   double trades = TesterStatistics(STAT_TRADES);
   double net    = TesterStatistics(STAT_PROFIT);
   double dd     = TesterStatistics(STAT_EQUITY_DD);
   if(trades < InpOptMinTrades)
      return 0.0;
   if(net <= 0.0)
      return net;
   return net / MathMax(dd, 1.0) * MathSqrt(trades / InpOptMinTrades);
  }

//+------------------------------------------------------------------+
//| Results, streaks and the CSV log                                 |
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

   double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                HistoryDealGetDouble(trans.deal, DEAL_COMMISSION) + g_inCommission;
   g_inCommission = 0.0;
   bool   wasLong = HistoryDealGetInteger(trans.deal, DEAL_TYPE) == DEAL_TYPE_SELL;
   double exitPx  = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double r = g_riskDist > 0.0 ? (wasLong ? exitPx - g_entry : g_entry - exitPx) / g_riskDist : 0.0;

   long reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
   string why = reason == DEAL_REASON_SL ? (r > -0.05 ? "trail_or_be" : "stop") :
                reason == DEAL_REASON_TP ? "tp" :
                reason == DEAL_REASON_SO ? "stop_out" :
                reason == DEAL_REASON_EXPERT ? (g_closeWhy != "" ? g_closeWhy : "ea") : "manual";

   for(int t = 0; t < TRIG_COUNT; t++)
      if(g_setup == g_trigName[t])
        {
         g_trigN[t]++;
         g_trigR[t] += r;
         if(pnl > 0.0)
            g_trigW[t]++;
        }
   if(pnl < 0.0)
     {
      g_consecLosses++;
      if(InpMaxConsecLosses > 0 && g_consecLosses >= InpMaxConsecLosses)
        {
         g_pauseUntil = TimeCurrent() + InpLossPauseMin * 60;
         g_consecLosses = 0;
         PrintFormat("%d losses in a row: pausing %d minutes", InpMaxConsecLosses, InpLossPauseMin);
        }
     }
   else
      g_consecLosses = 0;

   if(InpVerbose)
      PrintFormat("EXIT  %s %s @ %s (%s) after %ds | %+.2fR | %+.2f %s | best %+.2fR worst %+.2fR",
                  g_setup, wasLong ? "long" : "short", DoubleToString(exitPx, _Digits), why,
                  (int)((datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME) - g_openTime), r, pnl,
                  AccountInfoString(ACCOUNT_CURRENCY),
                  g_riskDist > 0.0 ? g_mfe / g_riskDist : 0.0, g_riskDist > 0.0 ? g_mae / g_riskDist : 0.0);
   if(InpLogTrades)
      LogTrade(trans.deal, pnl, wasLong, why);

   g_lastExit = TimeCurrent();
   g_posTicket = 0;
   g_setup = "";
   g_riskDist = 0.0;
   g_atrEntry = 0.0;
   g_closeWhy = "";
  }

void LogTrade(ulong deal, double pnl, bool wasLong, const string why)
  {
   string name = "MomentumScalper_" + _Symbol + ".csv";
   int h = FileOpen(name, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
     {
      Print("Cannot open ", name, ": ", GetLastError());
      return;
     }
   if(FileSize(h) == 0)
      FileWrite(h, "open_time", "close_time", "symbol", "side", "setup", "lots", "entry", "exit",
                "sl_initial", "risk", "spread", "atr", "flow_imb", "speed_x", "score",
                "mfe", "mae", "exit_reason", "pnl");
   FileSeek(h, 0, SEEK_END);
   FileWrite(h,
             TimeToString(g_openTime, TIME_DATE | TIME_SECONDS),
             TimeToString((datetime)HistoryDealGetInteger(deal, DEAL_TIME), TIME_DATE | TIME_SECONDS),
             _Symbol, wasLong ? "long" : "short", g_setup,
             DoubleToString(g_lots, 2),
             DoubleToString(g_entry, _Digits),
             DoubleToString(HistoryDealGetDouble(deal, DEAL_PRICE), _Digits),
             DoubleToString(g_slInitial, _Digits),
             DoubleToString(g_riskDist, _Digits),
             DoubleToString(g_spreadEntry, _Digits),
             DoubleToString(g_atrEntry, _Digits),
             DoubleToString(g_flowEntry, 3),
             DoubleToString(g_speedEntry, 2),
             IntegerToString(g_scoreEntry),
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
   Flow(InpBurstSec, imb, rate, baseRate);
   double atr = Atr(), spread = tk.ask - tk.bid;
   int n = 0, w = 0;
   double R = 0.0;
   for(int t = 0; t < TRIG_COUNT; t++)
     {
      n += g_trigN[t];
      w += g_trigW[t];
      R += g_trigR[t];
     }
   Comment(StringFormat(
              "MomentumScalper v2.1  %s\n"
              "Spread %s | M1 ATR %s | ATR/spread %.1f (gate %.1f) | flow %+.2f (%s) | speed %.1fx\n"
              "VWAP %s | POC %s | VA %s - %s\n"
              "Structure: last break %s%s | swing H %s | swing L %s | EQ %s\n"
              "FVG bull %s - %s | FVG bear %s - %s\n"
              "Last candidate: %s\n"
              "Today %d trades, last hour %d/%d | session %d trades, %d wins, %+.2fR | streak %d\n"
              "Status: %s",
              _Symbol,
              DoubleToString(spread, _Digits), DoubleToString(atr, _Digits),
              spread > 0.0 ? atr / spread : 0.0, InpMinAtrToSpread, imb,
              g_hasAggFlags ? "aggressor" : "tick rule", baseRate > 0.0 ? rate / baseRate : 0.0,
              DoubleToString(g_vwap, _Digits), DoubleToString(g_poc, _Digits),
              DoubleToString(g_val, _Digits), DoubleToString(g_vah, _Digits),
              g_structDir > 0 ? "BULLISH" : (g_structDir < 0 ? "BEARISH" : "none"), g_choch ? " (CHoCH)" : "",
              g_swH > 0.0 ? DoubleToString(g_swH, _Digits) : "-", g_swL > 0.0 ? DoubleToString(g_swL, _Digits) : "-",
              DoubleToString(g_eq, _Digits),
              g_bullTop > 0.0 ? DoubleToString(g_bullBot, _Digits) : "-",
              g_bullTop > 0.0 ? DoubleToString(g_bullTop, _Digits) : "-",
              g_bearTop > 0.0 ? DoubleToString(g_bearBot, _Digits) : "-",
              g_bearTop > 0.0 ? DoubleToString(g_bearTop, _Digits) : "-",
              g_lastCand == "" ? "none yet" : g_lastCand,
              g_tradesToday, EntriesLastHour(), InpMaxTradesPerHour, n, w, R, g_consecLosses,
              g_status));
  }
//+------------------------------------------------------------------+
