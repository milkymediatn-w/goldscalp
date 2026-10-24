//+------------------------------------------------------------------+
//| MomentumScalper.mq5                                              |
//| High-frequency trend + momentum scalper for MT5 (built around    |
//| Exness BTCUSDm). Decides on every tick, holds seconds to a few   |
//| minutes.                                                         |
//|                                                                  |
//| Trend     : M1 EMA fast/slow, optional HTF EMA, rolling VWAP     |
//| Setups    : burst    - price jumps N spreads in a few seconds    |
//|                        with one-sided flow and fast ticks        |
//|             pullback - in trend, price dips 0.3-1.2 ATR, then    |
//|                        breaks the last closed M1 candle again    |
//| Profile   : rolling tick-volume profile (POC, value area, HVNs): |
//|             trade on the right side of POC, and only with room   |
//|             to the next high-volume level                        |
//| Exits     : stop, optional TP in R, break-even, ATR trail,       |
//|             time stop in seconds, flow-fade exit                 |
//| Safety    : cooldown, trades/hour and /day caps, daily loss      |
//|             limit, losing-streak pause, spread and spike filters |
//|                                                                  |
//| No martingale, no grid, no averaging down: one position at a     |
//| time, sized from a fixed lot or a fixed % risk.                  |
//| Closed trades go to MQL5/Files/MomentumScalper_<symbol>.csv.     |
//+------------------------------------------------------------------+
#property copyright "goldscalp"
#property version   "1.00"
#property description "HF trend + momentum scalper (burst, pullback, volume profile, VWAP)"

#include <Trade/Trade.mqh>

//--- general
input group "General"
input long   InpMagic             = 260425; // Magic number
input int    InpDeviationPts      = 300;    // Max slippage, points (BTCUSDm: 100 pts = $1)
input bool   InpVerbose           = true;   // Print every entry and exit
input bool   InpLogTrades         = true;   // Write closed trades to CSV

//--- risk
input group "Risk"
input double InpRiskPercent       = 0.0;    // Risk per trade, % of equity (0 = fixed lots)
input double InpFixedLots         = 0.01;   // Fixed lots when risk % is 0
input double InpMaxLots           = 1.0;    // Hard cap on lots
input double InpMaxDailyLossPct   = 3.0;    // Stop for the day after this equity drawdown %
input int    InpMaxTradesPerDay   = 150;    // Max entries per server day
input int    InpMaxTradesPerHour  = 20;     // Max entries per rolling hour
input int    InpCooldownSec       = 15;     // Wait after any exit, seconds
input int    InpMaxConsecLosses   = 5;      // Pause after this many losses in a row
input int    InpLossPauseMin      = 20;     // Pause length, minutes

//--- costs and regime
input group "Costs and regime"
input int    InpMaxSpreadPts      = 0;      // Max spread, points (0 = off)
input double InpMinAtrToSpread    = 2.5;    // M1 ATR must be >= this x spread
input double InpMaxAtrSpikeX      = 3.0;    // Skip when M1 ATR(14) > this x ATR(100)
input double InpMinTickRate       = 0.2;    // Skip when the feed is slower than this, ticks/s

//--- trend
input group "Trend"
input bool   InpRequireTrend      = true;   // Only trade in the trend direction
input int    InpEmaFast           = 9;      // M1 fast EMA
input int    InpEmaSlow           = 21;     // M1 slow EMA
input ENUM_TIMEFRAMES InpHtfTF    = PERIOD_M5; // Higher-timeframe filter
input int    InpHtfEma            = 50;     // HTF EMA period (0 = off)
input bool   InpUseVwap           = true;   // Longs above VWAP, shorts below

//--- burst
input group "Setup: momentum burst"
input bool   InpUseBurst          = true;   // Enable
input int    InpBurstSec          = 10;     // Look-back, seconds
input double InpBurstMinSpreads   = 1.5;    // Price must move >= this many spreads in the look-back
input double InpBurstMaxAtr       = 1.0;    // ...but not more than this x ATR (overextended)
input double InpBurstMinFlow      = 0.40;   // Min flow imbalance in the look-back, 0..1
input double InpBurstMinSpeedX    = 1.5;    // Tick speed >= this x 10-min average

//--- pullback
input group "Setup: pullback continuation"
input bool   InpUsePullback       = true;   // Enable
input int    InpPbLookback        = 8;      // M1 candles to find the swing
input double InpPbMinAtr          = 0.3;    // Pullback depth >= this x ATR
input double InpPbMaxAtr          = 1.2;    // Pullback depth <= this x ATR
input double InpPbMinFlow         = 0.20;   // Flow must agree by at least this
input double InpMaxChaseAtr       = 0.4;    // Skip if price ran this many ATR past the trigger

//--- volume profile
input group "Volume profile (tick volume)"
input bool   InpUseProfile        = true;   // Enable profile filters
input int    InpProfileBars       = 240;    // M1 candles in the profile (240 = 4 hours)
input int    InpProfileBinPts     = 0;      // Bin size, points (0 = auto: ATR / 4)
input double InpHvnPct            = 0.60;   // HVN = local peak >= this x POC volume
input bool   InpProfileBias       = true;   // Longs only above POC, shorts only below
input double InpMinRoomR          = 1.0;    // Need this many R of room to the next POC/VA edge/HVN

//--- exits
input group "Exits"
input double InpSlAtr             = 0.8;    // Initial stop, x M1 ATR
input double InpSlMinSpreads      = 2.5;    // Stop at least this many spreads
input double InpTpR               = 1.5;    // Take profit in R (0 = none, trail only)
input double InpBreakEvenR        = 0.6;    // Move stop to entry at +R (0 = off)
input double InpTrailStartR       = 1.0;    // Start trailing at +R (0 = off)
input double InpTrailAtr          = 0.6;    // Trail distance, x ATR
input int    InpMaxHoldSec        = 180;    // Time stop, seconds (0 = off)
input bool   InpFlowExit          = true;   // Exit when flow turns hard against the trade
input double InpExitFlow          = 0.50;   // ...imbalance against, over the burst look-back
input int    InpFlowExitMinSec    = 10;     // ...only after holding this long
input double InpFlowExitMaxR      = 0.5;    // ...and only while profit is below this R

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

//--- volume profile and VWAP
double   g_poc = 0.0, g_vah = 0.0, g_val = 0.0, g_vwap = 0.0;
double   g_hvn[];
datetime g_profileBar = 0;

//--- state
CTrade   trade;
datetime g_day = 0;
double   g_dayStartEquity = 0.0;
bool     g_haltDay = false;
int      g_tradesToday = 0;
datetime g_entryTimes[64];
int      g_entryIdx = 0;
datetime g_lastExit = 0;
datetime g_pbBar = 0;
int      g_consecLosses = 0;
datetime g_pauseUntil = 0;
datetime g_lastCloseTry = 0;
string   g_closeWhy = "";
string   g_status = "";

//--- open trade context
ulong    g_posTicket = 0;
string   g_setup = "";
int      g_dir = 0;
double   g_entry = 0.0, g_riskDist = 0.0, g_slInitial = 0.0, g_spreadEntry = 0.0, g_atrEntry = 0.0;
double   g_flowEntry = 0.0, g_speedEntry = 0.0, g_roomEntry = 0.0, g_mfe = 0.0, g_mae = 0.0;
double   g_inCommission = 0.0, g_lots = 0.0;
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
#define SKIP_NOTREND  9
#define SKIP_NOSETUP  10
#define SKIP_PROFILE  11
#define SKIP_ROOM     12
#define SKIP_FAILED   13
#define SKIP_COUNT    14
string   g_skipName[SKIP_COUNT] = {"daily loss limit", "losing-streak pause", "hour/day trade cap",
                                   "algo trading disabled", "outside session", "spread above max",
                                   "ATR < min x spread", "volatility spike", "slow feed", "no trend",
                                   "no setup", "wrong side of POC", "no room to next level",
                                   "order rejected"};
int      g_skipMin[SKIP_COUNT];
datetime g_skipLast[SKIP_COUNT];
int      g_minutesSeen = 0;
datetime g_lastSeenMin = 0;
double   g_ratioSum = 0.0;
int      g_ratioN = 0;
datetime g_ratioMin = 0;
string   g_setupName[2] = {"burst", "pullback"};
int      g_setupN[2], g_setupW[2];
double   g_setupR[2];

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
   ArrayInitialize(g_setupN, 0);
   ArrayInitialize(g_setupW, 0);
   ArrayInitialize(g_setupR, 0.0);

   if(InpBurstSec < 2 || InpBurstSec > 120)
     { Print("InpBurstSec must be within 2..120"); return INIT_PARAMETERS_INCORRECT; }
   if(InpEmaFast >= InpEmaSlow || InpPbLookback < 3 || InpProfileBars < 30)
     { Print("Check EMA periods, InpPbLookback (>= 3) and InpProfileBars (>= 30)"); return INIT_PARAMETERS_INCORRECT; }

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
   PrintFormat("MomentumScalper on %s | burst %ds/%.1f spreads | pullback %.1f-%.1f ATR | stop %.2fxATR "
               "(min %.1f spreads) | TP %.1fR | time stop %ds | %s",
               _Symbol, InpBurstSec, InpBurstMinSpreads, InpPbMinAtr, InpPbMaxAtr, InpSlAtr,
               InpSlMinSpreads, InpTpR, InpMaxHoldSec,
               InpRiskPercent > 0 ? StringFormat("risk %.2f%%", InpRiskPercent)
                                  : StringFormat("fixed %.2f lots", InpFixedLots));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
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

void ReleaseHandle(int handle)
  {
   if(handle != INVALID_HANDLE)
      IndicatorRelease(handle);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   PullTicks();
   DayCheck();
   RefreshProfile();
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
//| Volume profile + rolling VWAP from M1 tick volume                |
//+------------------------------------------------------------------+
void RefreshProfile()
  {
   datetime bar = iTime(_Symbol, PERIOD_M1, 0);
   if(bar == 0 || bar == g_profileBar)
      return;
   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M1, 1, InpProfileBars, r);
   if(n < 30)
      return;
   g_profileBar = bar;

   double lo = DBL_MAX, hi = -DBL_MAX, pv = 0.0, vs = 0.0;
   for(int k = 0; k < n; k++)
     {
      lo = MathMin(lo, r[k].low);
      hi = MathMax(hi, r[k].high);
      double v = (r[k].tick_volume > 0 ? (double)r[k].tick_volume : 1.0);
      pv += (r[k].high + r[k].low + r[k].close) / 3.0 * v;
      vs += v;
     }
   g_vwap = vs > 0.0 ? pv / vs : 0.0;

   double atr = Atr();
   double bin = InpProfileBinPts > 0 ? InpProfileBinPts * _Point : MathMax(atr / 4.0, 10 * _Point);
   if(bin <= 0.0 || hi <= lo)
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
      double v = (r[k].tick_volume > 0 ? (double)r[k].tick_volume : 1.0) / (b - a + 1);
      for(int j = a; j <= b; j++)
         raw[j] += v;
     }
   // 3-bin smoothing so single-bin noise does not count as a node.
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

// Distance from price to the nearest profile level in the trade direction.
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

// +1 up, -1 down, 0 = the filters disagree.
int TrendDir(double price)
  {
   double f = BufferValue(g_emaF, 1), s = BufferValue(g_emaS, 1);
   if(f <= 0.0 || s <= 0.0 || f == s)
      return 0;
   int dir = f > s ? 1 : -1;
   if(g_htf != INVALID_HANDLE)
     {
      double e = BufferValue(g_htf, 1), c = iClose(_Symbol, InpHtfTF, 1);
      if(e <= 0.0 || c <= 0.0 || (c > e ? 1 : -1) != dir)
         return 0;
     }
   if(InpUseVwap && g_vwap > 0.0 && (price > g_vwap ? 1 : -1) != dir)
      return 0;
   return dir;
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
   double perLot = riskDist / ts * tv;
   return NormLots(AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0 / perLot);
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
   g_dir       = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1;
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
   int n = g_setupN[0] + g_setupN[1];
   int w = g_setupW[0] + g_setupW[1];
   PrintFormat("=== MomentumScalper report: %d minutes scanned flat, %d trades, %d wins, %+.2f R ===",
               g_minutesSeen, n, w, g_setupR[0] + g_setupR[1]);
   for(int s = 0; s < 2; s++)
      if(g_setupN[s] > 0)
         PrintFormat("  %-8s %4d trades | win %.0f%% | %+.2f R | avg %+.3f R",
                     g_setupName[s], g_setupN[s], 100.0 * g_setupW[s] / g_setupN[s],
                     g_setupR[s], g_setupR[s] / g_setupN[s]);
   if(g_ratioN > 0)
      PrintFormat("Average M1 ATR / spread: %.2f (filter needs >= %.1f)", g_ratioSum / g_ratioN, InpMinAtrToSpread);
   for(int r = 0; r < SKIP_COUNT; r++)
      if(g_skipMin[r] > 0)
         PrintFormat("  blocked by %-24s in %6d minutes (%.1f%%)", g_skipName[r], g_skipMin[r],
                     g_minutesSeen > 0 ? 100.0 * g_skipMin[r] / g_minutesSeen : 0.0);
  }

//+------------------------------------------------------------------+
//| Entries: evaluated on every tick while flat                      |
//+------------------------------------------------------------------+
void TryEntry()
  {
   if(SelectOurPosition())
     { g_status = "in position"; return; }
   datetime now = TimeCurrent();
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
     { Skip(SKIP_ATR, "M1 range too small for the spread"); return; }
   if(InpMaxAtrSpikeX > 0.0 && atrSlow > 0.0 && atr > InpMaxAtrSpikeX * atrSlow)
     { Skip(SKIP_SPIKE, "volatility spike"); return; }

   double imb, rate, baseRate;
   Flow(InpBurstSec, imb, rate, baseRate);
   if(baseRate < InpMinTickRate)
     { Skip(SKIP_FEED, "feed too slow"); return; }
   double speedX = baseRate > 0.0 ? rate / baseRate : 0.0;
   double mid    = (tk.bid + tk.ask) * 0.5;
   int    trend  = TrendDir(mid);
   if(InpRequireTrend && trend == 0)
     { Skip(SKIP_NOTREND, "no clear trend"); return; }

   int dir = 0, setupIdx = -1;

   // 1. Momentum burst: a fast, one-sided move of several spreads in a few seconds.
   if(InpUseBurst)
     {
      double then = MidSecondsAgo(InpBurstSec);
      double move = then > 0.0 ? mid - then : 0.0;
      if(MathAbs(move) >= InpBurstMinSpreads * spread && MathAbs(move) <= InpBurstMaxAtr * atr &&
         speedX >= InpBurstMinSpeedX)
        {
         int d = move > 0.0 ? 1 : -1;
         if(d * imb >= InpBurstMinFlow && (!InpRequireTrend || d == trend))
           { dir = d; setupIdx = 0; }
        }
     }

   // 2. Pullback continuation: swing in trend, a 0.3-1.2 ATR dip, then the last candle's
   //    extreme breaks again while price is still below (above) the swing.
   if(dir == 0 && InpUsePullback && trend != 0 && m != g_pbBar)
     {
      MqlRates r[];
      int n = CopyRates(_Symbol, PERIOD_M1, 1, InpPbLookback, r);   // oldest first, r[n-1] = last closed
      if(n == InpPbLookback)
        {
         int ext = 0;
         for(int k = 1; k < n - 1; k++)
            if(trend > 0 ? r[k].high > r[ext].high : r[k].low < r[ext].low)
               ext = k;
         double swing = trend > 0 ? r[ext].high : r[ext].low;
         double far = swing;
         for(int k = ext + 1; k < n; k++)
            far = trend > 0 ? MathMin(far, r[k].low) : MathMax(far, r[k].high);
         double depth = MathAbs(swing - far);
         double trig  = trend > 0 ? r[n - 1].high : r[n - 1].low;
         double px    = trend > 0 ? tk.bid : tk.ask;
         bool broke   = trend > 0 ? (px > trig && px < swing && px - trig <= InpMaxChaseAtr * atr)
                                  : (px < trig && px > swing && trig - px <= InpMaxChaseAtr * atr);
         if(ext < n - 1 && depth >= InpPbMinAtr * atr && depth <= InpPbMaxAtr * atr && broke &&
            trend * imb >= InpPbMinFlow)
           { dir = trend; setupIdx = 1; g_pbBar = m; }
        }
     }

   if(dir == 0)
     {
      Skip(SKIP_NOSETUP, StringFormat("scanning | trend %s | flow %+.2f | speed %.1fx",
                                      trend > 0 ? "up" : (trend < 0 ? "down" : "mixed"), imb, speedX));
      return;
     }

   // Stop on the far side of the spread: risk = stop distance + spread.
   double slDist = MathMax(InpSlAtr * atr, InpSlMinSpreads * spread);
   slDist = MathMax(slDist, (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point + spread);
   double price = dir > 0 ? tk.ask : tk.bid;
   double sl    = dir > 0 ? NormPrice(tk.bid - slDist) : NormPrice(tk.ask + slDist);
   double risk  = MathAbs(price - sl);

   // Volume profile: right side of POC and room to the next level.
   double room = DBL_MAX;
   if(InpUseProfile && g_poc > 0.0)
     {
      if(InpProfileBias && (dir > 0 ? mid < g_poc : mid > g_poc))
        { Skip(SKIP_PROFILE, "wrong side of POC"); return; }
      room = RoomTo(dir, price, atr);
      if(room < InpMinRoomR * risk)
        { Skip(SKIP_ROOM, StringFormat("only %.1fR of room to the next volume level", room / risk)); return; }
     }

   double lots = Lots(risk);
   if(lots <= 0.0)
     { Skip(SKIP_FAILED, "lot size below minimum"); return; }
   double tp = InpTpR > 0.0 ? NormPrice(dir > 0 ? price + InpTpR * risk : price - InpTpR * risk) : 0.0;
   string setup = g_setupName[setupIdx];

   bool ok = dir > 0 ? trade.Buy(lots, _Symbol, tk.ask, sl, tp, "MS " + setup)
                     : trade.Sell(lots, _Symbol, tk.bid, sl, tp, "MS " + setup);
   if(!ok || (trade.ResultRetcode() != TRADE_RETCODE_DONE && trade.ResultRetcode() != TRADE_RETCODE_PLACED))
     {
      Skip(SKIP_FAILED, "order rejected");
      PrintFormat("%s %s failed: %d %s", setup, dir > 0 ? "BUY" : "SELL",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
      g_lastExit = now;          // back off before retrying
      return;
     }

   g_tradesToday++;
   g_entryTimes[g_entryIdx] = now;
   g_entryIdx = (g_entryIdx + 1) % 64;
   g_setup = setup;
   g_dir = dir;
   g_slInitial = sl;
   g_spreadEntry = spread;
   g_atrEntry = atr;
   g_flowEntry = imb;
   g_speedEntry = speedX;
   g_roomEntry = room == DBL_MAX ? 0.0 : room / risk;
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
      PrintFormat("ENTRY %s %s %.2f @ %s | SL %s TP %s | risk %.2f (%.1f spreads) | flow %+.2f speed %.1fx | "
                  "POC %s VWAP %s room %s",
                  setup, dir > 0 ? "BUY" : "SELL", lots, DoubleToString(g_entry, _Digits),
                  DoubleToString(sl, _Digits), tp > 0.0 ? DoubleToString(tp, _Digits) : "-",
                  g_riskDist, spread > 0.0 ? g_riskDist / spread : 0.0, imb, speedX,
                  DoubleToString(g_poc, _Digits), DoubleToString(g_vwap, _Digits),
                  room == DBL_MAX ? "open" : StringFormat("%.1fR", room / risk));
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
//| Optimizer score ("Custom max" in the tester): net profit over    |
//| max equity drawdown, scaled by sample size. Runs with fewer than |
//| InpOptMinTrades trades score 0, so lucky handfuls cannot win.    |
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

   int s = g_setup == "burst" ? 0 : (g_setup == "pullback" ? 1 : -1);
   if(s >= 0)
     {
      g_setupN[s]++;
      g_setupR[s] += r;
      if(pnl > 0.0)
         g_setupW[s]++;
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
                "sl_initial", "risk", "spread", "atr", "flow_imb", "speed_x", "room_r",
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
             DoubleToString(g_roomEntry, 2),
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
   double atr = Atr(), spread = tk.ask - tk.bid, mid = (tk.bid + tk.ask) * 0.5;
   double then = MidSecondsAgo(InpBurstSec);
   int    trend = TrendDir(mid);
   int    n = g_setupN[0] + g_setupN[1];
   Comment(StringFormat(
              "MomentumScalper  %s\n"
              "Spread %s | M1 ATR %s | ATR/spread %.1f (need %.1f)\n"
              "Trend %s | VWAP %s | POC %s | VA %s - %s\n"
              "Last %ds: move %s | flow %+.2f (%s) | speed %.1fx | feed %.2f t/s\n"
              "Today %d trades, last hour %d/%d | session %d trades, %d wins, %+.2fR | streak %d\n"
              "%s",
              _Symbol,
              DoubleToString(spread, _Digits), DoubleToString(atr, _Digits),
              spread > 0.0 ? atr / spread : 0.0, InpMinAtrToSpread,
              trend > 0 ? "UP" : (trend < 0 ? "DOWN" : "mixed"),
              DoubleToString(g_vwap, _Digits), DoubleToString(g_poc, _Digits),
              DoubleToString(g_val, _Digits), DoubleToString(g_vah, _Digits),
              InpBurstSec, then > 0.0 ? DoubleToString(mid - then, _Digits) : "-",
              imb, g_hasAggFlags ? "aggressor" : "tick rule", baseRate > 0.0 ? rate / baseRate : 0.0, baseRate,
              g_tradesToday, EntriesLastHour(), InpMaxTradesPerHour,
              n, g_setupW[0] + g_setupW[1], g_setupR[0] + g_setupR[1], g_consecLosses,
              g_status));
  }
//+------------------------------------------------------------------+
