//+------------------------------------------------------------------+
//| SetupProbe.mq5                                                   |
//| Research script, not an EA: it never trades.                     |
//|                                                                  |
//| Scans M1 history for three fast-scalp setups and replays the     |
//| real ticks after each one to measure what a <= 10 minute trade   |
//| would have made, after the spread and commission.                |
//|                                                                  |
//| Setups                                                           |
//|  A_squeeze : tight N-bar range, then an expansion candle closes  |
//|              outside it (trade the break)                        |
//|  B_open    : first M1 close outside the opening range of a       |
//|              session (trade the break)                           |
//|  C_sweep   : candle wicks through the N-bar high/low and closes  |
//|              back inside (fade it)                               |
//|  control   : long and short every N bars, no signal. A setup has |
//|              an edge only if it beats this.                      |
//|                                                                  |
//| Entry = first tick after the signal candle closes + latency, at  |
//| the ask for longs and the bid for shorts. Exits are on the       |
//| opposite side, so every result already pays the spread.          |
//|                                                                  |
//| Output                                                           |
//|  Experts tab : per setup, results at fixed hold times and the    |
//|                best exit settings in sample, shown with their    |
//|                out-of-sample result.                             |
//|  MQL5/Files/SetupProbe_<symbol>.csv : one row per event, with    |
//|                every exit setting. Slice it with                 |
//|                mt5/analyze_probe.py.                             |
//+------------------------------------------------------------------+
#property copyright "goldscalp"
#property version   "1.00"
#property script_show_inputs

#define MAXC 16 // max exit combinations
#define NH   4  // hold-time horizons
#define NSET 4  // setups incl. control

input group "Period"
input datetime InpFrom         = D'2026.07.24 00:00'; // From (server time = UTC on Exness)
input datetime InpTo           = D'2026.10.27 00:00'; // To
input double   InpOosFrac      = 0.333;  // Last fraction of the period kept out of sample

input group "Execution and costs"
input int      InpLatencyMs    = 250;    // Delay from candle close to entry, ms
input int      InpMaxHoldMin   = 10;     // Time stop, minutes
input double   InpLots         = 0.01;   // Lots used for the $ figures
input double   InpCommission   = 0.0;    // Commission per 1 lot, ROUND TRIP, account currency (Zero/Raw)

input group "Indicators (M1)"
input int      InpAtrFast      = 14;     // ATR period used for stops
input int      InpAtrSlow      = 60;     // ATR period used to define compression
input int      InpTrendEma     = 200;    // EMA period for the trend-alignment tag (200 M1 = ~EMA40 on M5)

input group "A: compression breakout"
input bool     InpUseA         = true;   // Use setup A
input int      InpSqzBars      = 10;     // Range = high/low of the last N closed candles
input double   InpSqzMaxAtr    = 2.0;    // Range must be <= this x slow ATR
input double   InpExpBarAtr    = 1.2;    // Breakout candle range >= this x slow ATR

input group "B: session-open breakout"
input bool     InpUseB         = true;   // Use setup B
input string   InpSessions     = "00:00,07:00,13:30"; // Session opens, server time (HH:MM, comma separated)
input int      InpOrbMin       = 5;      // Opening range, minutes
input int      InpOrbWindowMin = 60;     // Break must come within N minutes after the range

input group "C: sweep and reclaim"
input bool     InpUseC         = true;   // Use setup C
input int      InpSweepBars    = 30;     // Level = high/low of the last N closed candles
input double   InpSweepMinAtr  = 0.2;    // Wick must pierce the level by >= this x fast ATR

input group "Control and spacing"
input int      InpControlEvery = 15;     // Control: long + short every N candles (0 = off)
input int      InpCooldownBars = 5;      // Min candles between two events of the same setup

input group "Exit grid"
input string   InpSlAtrList    = "0.5,1.0,1.5"; // Stop distances, x fast ATR
input string   InpTpRList      = "1,1.5,2,3";   // Targets, x stop (R)
input double   InpSlMinCosts   = 2.0;    // Stop is at least this many round-trip costs (spread + commission)

struct Ev
  {
   long              msc;        // decision time + latency, ms
   int               setup;
   int               dir;        // +1 long, -1 short
   double            atr;        // fast ATR at the signal candle
   double            atrSlow;
   double            f1;         // setup feature 1 (see header of the CSV)
   double            f2;         // setup feature 2
   int               aligned;    // 1 = trade is on the side of the trend EMA
   int               ok;         // 1 = simulated on ticks
   long              entryMsc;
   double            entry;
   double            spread;     // at entry
   double            mfe[NH];    // best move in the trade's favour, net of spread
   double            mae[NH];    // worst move
   double            pnlH[NH];   // exit at the horizon
   double            sl[MAXC];
   double            net[MAXC];  // price units, after spread
   double            gross[MAXC];// price units, mid to mid (before spread)
   int               res[MAXC];  // 1 target, -1 stop, 0 time stop
  };

string g_names[NSET] = {"A_squeeze", "B_open", "C_sweep", "control"};
int    g_hor[NH]     = {1, 3, 5, 10};
Ev     g_ev[];
int    g_n = 0;
double g_slA[], g_tpR[];
int    g_nC = 0;
double g_cpx = 0.0; // commission per round trip, in price units

//+------------------------------------------------------------------+
int ParseList(const string s, double &out[])
  {
   string parts[];
   int n = StringSplit(s, ',', parts);
   ArrayResize(out, 0);
   for(int i = 0; i < n; i++)
     {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      if(parts[i] == "")
         continue;
      int k = ArraySize(out);
      ArrayResize(out, k + 1);
      out[k] = StringToDouble(parts[i]);
     }
   return ArraySize(out);
  }

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
void AddEv(long msc, int setup, int dir, double atr, double atrSlow,
           double f1, double f2, int aligned)
  {
   ArrayResize(g_ev, g_n + 1, 8192);
   ZeroMemory(g_ev[g_n]);
   g_ev[g_n].msc     = msc;
   g_ev[g_n].setup   = setup;
   g_ev[g_n].dir     = dir;
   g_ev[g_n].atr     = atr;
   g_ev[g_n].atrSlow = atrSlow;
   g_ev[g_n].f1      = f1;
   g_ev[g_n].f2      = f2;
   g_ev[g_n].aligned = aligned;
   g_n++;
  }

//+------------------------------------------------------------------+
int LoadTicks(MqlTick &tk[], long fromMsc, long toMsc)
  {
   for(int a = 0; a < 5 && !IsStopped(); a++)
     {
      ResetLastError();
      int n = CopyTicksRange(_Symbol, tk, COPY_TICKS_INFO, (ulong)fromMsc, (ulong)toMsc);
      if(n > 0)
         return n;
      Sleep(1000); // the terminal may still be downloading tick history
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| Replays the ticks after event k. Returns false if none found.    |
//+------------------------------------------------------------------+
bool Simulate(int k, const MqlTick &tk[], int nt)
  {
   int lo = 0, hi = nt;
   while(lo < hi)
     {
      int mid = (lo + hi) / 2;
      if(tk[mid].time_msc < g_ev[k].msc)
         lo = mid + 1;
      else
         hi = mid;
     }
   int j = lo;
   while(j < nt && (tk[j].bid <= 0.0 || tk[j].ask < tk[j].bid))
      j++;
   if(j >= nt || tk[j].time_msc > g_ev[k].msc + 60000)
      return false; // no quote within a minute: a data gap

   int    dir    = g_ev[k].dir;
   double entry  = dir > 0 ? tk[j].ask : tk[j].bid;
   double spread = tk[j].ask - tk[j].bid;
   long   t0     = tk[j].time_msc;
   long   tEnd   = t0 + (long)InpMaxHoldMin * 60000;
   g_ev[k].entryMsc = t0;
   g_ev[k].entry    = entry;
   g_ev[k].spread   = spread;

   double tp[MAXC];
   bool   live[MAXC];
   int    nOpen = g_nC;
   for(int c = 0; c < g_nC; c++)
     {
      double sl = MathMax(g_slA[c / ArraySize(g_tpR)] * g_ev[k].atr, InpSlMinCosts * (spread + g_cpx));
      g_ev[k].sl[c] = sl;
      tp[c]   = g_tpR[c % ArraySize(g_tpR)] * sl;
      live[c] = true;
     }
   for(int h = 0; h < NH; h++)
     {
      g_ev[k].mfe[h] = -DBL_MAX;
      g_ev[k].mae[h] = DBL_MAX;
     }

   double last = -spread, lastSpr = spread;
   for(int i = j; i < nt && tk[i].time_msc <= tEnd; i++)
     {
      if(tk[i].bid <= 0.0 || tk[i].ask < tk[i].bid)
         continue;
      double px  = dir > 0 ? tk[i].bid : tk[i].ask;
      double mv  = (px - entry) * dir;
      double spr = tk[i].ask - tk[i].bid;
      long   dt  = tk[i].time_msc - t0;
      for(int h = 0; h < NH; h++)
        {
         if(dt > (long)g_hor[h] * 60000)
            continue;
         g_ev[k].mfe[h]  = MathMax(g_ev[k].mfe[h], mv);
         g_ev[k].mae[h]  = MathMin(g_ev[k].mae[h], mv);
         g_ev[k].pnlH[h] = mv;
        }
      if(nOpen > 0)
         for(int c = 0; c < g_nC; c++)
           {
            if(!live[c])
               continue;
            if(mv <= -g_ev[k].sl[c])
              {
               // stop: filled at this quote, so gaps past the stop count as slippage
               g_ev[k].res[c]   = -1;
               g_ev[k].net[c]   = mv;
               g_ev[k].gross[c] = mv + (spread + spr) / 2.0;
               live[c] = false;
               nOpen--;
              }
            else
               if(mv >= tp[c])
                 {
                  // target: a limit order, filled at its price, no positive slippage
                  g_ev[k].res[c]   = 1;
                  g_ev[k].net[c]   = tp[c];
                  g_ev[k].gross[c] = tp[c] + (spread + spr) / 2.0;
                  live[c] = false;
                  nOpen--;
                 }
           }
      last    = mv;
      lastSpr = spr;
     }
   for(int c = 0; c < g_nC; c++)
      if(live[c])
        {
         g_ev[k].res[c]   = 0;
         g_ev[k].net[c]   = last;
         g_ev[k].gross[c] = last + (spread + lastSpr) / 2.0;
        }
   g_ev[k].ok = 1;
   return true;
  }

//+------------------------------------------------------------------+
string Px(double v) { return DoubleToString(v, _Digits); }

//+------------------------------------------------------------------+
void WriteCsv(long cutMsc, double usdPerPx, double commUsd)
  {
   string fname = "SetupProbe_" + _Symbol + ".csv";
   int f = FileOpen(fname, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(f == INVALID_HANDLE)
     {
      PrintFormat("Cannot write %s (error %d)", fname, GetLastError());
      return;
     }
   string hdr = "time,setup,side,sample,hour,dow,spread,atr,atr_slow,atr_cost,aligned,f1,f2,entry,lots,usd_per_px,comm_usd";
   for(int h = 0; h < NH; h++)
      hdr += StringFormat(",mfe_%d,mae_%d,pnl_%d", g_hor[h], g_hor[h], g_hor[h]);
   for(int c = 0; c < g_nC; c++)
     {
      string lbl = StringFormat("sl%s_tp%s",
                                DoubleToString(g_slA[c / ArraySize(g_tpR)], 2),
                                DoubleToString(g_tpR[c % ArraySize(g_tpR)], 2));
      hdr += ",res_" + lbl + ",sl_" + lbl + ",net_" + lbl + ",gross_" + lbl;
     }
   FileWriteString(f, hdr + "\n");

   for(int k = 0; k < g_n; k++)
     {
      if(g_ev[k].ok == 0)
         continue;
      MqlDateTime dt;
      datetime t = (datetime)(g_ev[k].entryMsc / 1000);
      TimeToStruct(t, dt);
      double spr = g_ev[k].spread;
      string s = StringFormat("%s,%s,%s,%s,%d,%d,%s,%s,%s,%.2f,%d,%.3f,%.3f,%s,%.2f,%.6f,%.4f",
                              TimeToString(t, TIME_DATE | TIME_SECONDS),
                              g_names[g_ev[k].setup],
                              g_ev[k].dir > 0 ? "long" : "short",
                              g_ev[k].entryMsc < cutMsc ? "IS" : "OOS",
                              dt.hour, dt.day_of_week,
                              Px(spr), Px(g_ev[k].atr), Px(g_ev[k].atrSlow),
                              spr + g_cpx > 0.0 ? g_ev[k].atr / (spr + g_cpx) : 0.0,
                              g_ev[k].aligned, g_ev[k].f1, g_ev[k].f2,
                              Px(g_ev[k].entry), InpLots, usdPerPx, commUsd);
      for(int h = 0; h < NH; h++)
         s += "," + Px(g_ev[k].mfe[h]) + "," + Px(g_ev[k].mae[h]) + "," + Px(g_ev[k].pnlH[h]);
      for(int c = 0; c < g_nC; c++)
         s += StringFormat(",%d,", g_ev[k].res[c]) + Px(g_ev[k].sl[c]) + ","
              + Px(g_ev[k].net[c]) + "," + Px(g_ev[k].gross[c]);
      FileWriteString(f, s + "\n");
     }
   FileClose(f);
   PrintFormat("Event log: MQL5/Files/%s (File > Open Data Folder). Analyse with: python mt5/analyze_probe.py %s",
               fname, fname);
  }

//+------------------------------------------------------------------+
void PrintSummary(long cutMsc, double usdPerPx, double commUsd)
  {
   double cpx = g_cpx;
   // control result per combo, to compare each setup against no signal
   double ctrlGross[MAXC];
   ArrayInitialize(ctrlGross, 0.0);
   int ctrlN = 0;
   for(int k = 0; k < g_n; k++)
      if(g_ev[k].ok == 1 && g_ev[k].setup == 3 && g_ev[k].entryMsc < cutMsc)
        {
         ctrlN++;
         for(int c = 0; c < g_nC; c++)
            ctrlGross[c] += g_ev[k].gross[c];
        }

   Print("----- Results per trade at ", DoubleToString(InpLots, 2), " lots, ", AccountInfoString(ACCOUNT_CURRENCY),
         ". net = after spread", commUsd > 0.0 ? " and commission" : "", ", gross = mid to mid -----");
   for(int s = 0; s < NSET; s++)
     {
      int    n[2] = {0, 0};
      double hSum[2][NH], mfe10 = 0.0, mae10 = 0.0, sprSum = 0.0;
      ArrayInitialize(hSum, 0.0);
      int    cN[2][MAXC], cW[2][MAXC];
      double cNet[2][MAXC], cGross[2][MAXC], cPos[2][MAXC], cNeg[2][MAXC];
      ArrayInitialize(cN, 0);
      ArrayInitialize(cW, 0);
      ArrayInitialize(cNet, 0.0);
      ArrayInitialize(cGross, 0.0);
      ArrayInitialize(cPos, 0.0);
      ArrayInitialize(cNeg, 0.0);

      for(int k = 0; k < g_n; k++)
        {
         if(g_ev[k].ok == 0 || g_ev[k].setup != s)
            continue;
         int p = g_ev[k].entryMsc < cutMsc ? 0 : 1;
         n[p]++;
         for(int h = 0; h < NH; h++)
            hSum[p][h] += g_ev[k].pnlH[h] - cpx;
         double cost = g_ev[k].spread + cpx;
         if(p == 0 && cost > 0.0)
           {
            mfe10  += g_ev[k].mfe[NH - 1] / cost;
            mae10  += g_ev[k].mae[NH - 1] / cost;
            sprSum += cost;
           }
         for(int c = 0; c < g_nC; c++)
           {
            double v = g_ev[k].net[c] - cpx;
            cN[p][c]++;
            cNet[p][c]   += v;
            cGross[p][c] += g_ev[k].gross[c];
            if(v > 0.0)
              {
               cW[p][c]++;
               cPos[p][c] += v;
              }
            else
               cNeg[p][c] -= v;
           }
        }
      if(n[0] + n[1] == 0)
        {
         PrintFormat("%s: no events", g_names[s]);
         continue;
        }
      double u = usdPerPx;
      PrintFormat("== %s: %d events (in sample %d, out of sample %d)%s", g_names[s], n[0] + n[1], n[0], n[1],
                  n[1] < 300 ? "  !! fewer than 300 out of sample" : "");
      if(n[0] > 0)
         PrintFormat("   In sample: avg round-trip cost %s | within 10 min the best move averages %.1f costs, the worst %.1f costs",
                     Px(sprSum / n[0]), mfe10 / n[0], mae10 / n[0]);
      for(int p = 0; p < 2; p++)
         if(n[p] > 0)
            PrintFormat("   %s time exit only, net $/trade after 1 / 3 / 5 / 10 min: %.3f / %.3f / %.3f / %.3f",
                        p == 0 ? "IS " : "OOS", hSum[p][0] / n[p] * u, hSum[p][1] / n[p] * u,
                        hSum[p][2] / n[p] * u, hSum[p][3] / n[p] * u);

      // best 3 exit settings chosen on the in-sample part only
      bool used[MAXC];
      ArrayInitialize(used, false);
      for(int r = 0; r < 3 && r < g_nC && n[0] > 0; r++)
        {
         int best = -1;
         for(int c = 0; c < g_nC; c++)
            if(!used[c] && (best < 0 || cNet[0][c] > cNet[0][best]))
               best = c;
         used[best] = true;
         string line = StringFormat("   #%d SL %.2f ATR, TP %.2fR | IS n=%d win %.0f%% net %.3f gross %.3f PF %.2f",
                                    r + 1, g_slA[best / ArraySize(g_tpR)], g_tpR[best % ArraySize(g_tpR)],
                                    cN[0][best], 100.0 * cW[0][best] / cN[0][best],
                                    cNet[0][best] / cN[0][best] * u, cGross[0][best] / cN[0][best] * u,
                                    cNeg[0][best] > 0.0 ? cPos[0][best] / cNeg[0][best] : 99.0);
         if(s != 3 && ctrlN > 0)
            line += StringFormat(" (control gross %.3f)", ctrlGross[best] / ctrlN * u);
         if(cN[1][best] > 0)
            line += StringFormat(" || OOS n=%d win %.0f%% net %.3f gross %.3f PF %.2f",
                                 cN[1][best], 100.0 * cW[1][best] / cN[1][best],
                                 cNet[1][best] / cN[1][best] * u, cGross[1][best] / cN[1][best] * u,
                                 cNeg[1][best] > 0.0 ? cPos[1][best] / cNeg[1][best] : 99.0);
         Print(line);
         if(r == 0 && s != 3)
           {
            bool pass = cNet[0][best] > 0.0 && cN[1][best] > 0 && cNet[1][best] > 0.0;
            PrintFormat("   Verdict: %s", pass
                        ? (cN[1][best] >= 300 ? "positive after costs in and out of sample. Candidate, check it with analyze_probe.py."
                           : "positive in and out of sample, but too few out-of-sample events to trust.")
                        : "not profitable after costs out of sample with its best in-sample exit.");
           }
        }
     }
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   ParseList(InpSlAtrList, g_slA);
   ParseList(InpTpRList, g_tpR);
   g_nC = ArraySize(g_slA) * ArraySize(g_tpR);
   if(g_nC == 0 || g_nC > MAXC)
     {
      PrintFormat("Exit grid has %d combinations; it must have 1..%d.", g_nC, MAXC);
      return;
     }
   if(InpTo <= InpFrom)
     {
      Print("InpTo must be after InpFrom.");
      return;
     }
   int sess[];
   ParseSessions(InpSessions, sess);
   int nSess = ArraySize(sess);

   PrintFormat("===== SetupProbe %s | %s | %s | %s to %s =====", _Symbol,
               AccountInfoString(ACCOUNT_COMPANY), AccountInfoString(ACCOUNT_SERVER),
               TimeToString(InpFrom, TIME_DATE), TimeToString(InpTo, TIME_DATE));

   //--- M1 candles, with warm-up for the indicators
   int warmBars = InpTrendEma * 3 + InpAtrSlow * 3 + MathMax(InpSqzBars, InpSweepBars) + 10;
   datetime from = InpFrom - warmBars * 60;
   MqlRates r[];
   int nb = -1;
   for(int a = 0; a < 10 && nb <= 0 && !IsStopped(); a++)
     {
      nb = CopyRates(_Symbol, PERIOD_M1, from, InpTo, r);
      if(nb <= 0)
         Sleep(1000);
     }
   if(nb < 1000)
     {
      PrintFormat("Only %d M1 candles loaded. Set Tools > Options > Charts > Max bars in chart to Unlimited, scroll the M1 chart back to %s and run again.",
                  nb, TimeToString(InpFrom, TIME_DATE));
      return;
     }
   PrintFormat("M1 candles: %d (%s to %s)", nb, TimeToString(r[0].time), TimeToString(r[nb - 1].time));

   double atrF[], atrS[], ema[];
   WilderAtr(r, nb, InpAtrFast, atrF);
   WilderAtr(r, nb, InpAtrSlow, atrS);
   Ema(r, nb, InpTrendEma, ema);

   //--- find the events. Candle i is closed when candle i+1 exists.
   int lastBar[NSET];
   ArrayInitialize(lastBar, -1000000);
   datetime trigDay[];
   ArrayResize(trigDay, MathMax(nSess, 1));
   ArrayInitialize(trigDay, 0);
   int need = MathMax(MathMax(InpSqzBars, InpSweepBars), MathMax(InpAtrFast, InpAtrSlow)) + 1;

   for(int i = need; i < nb - 1 && !IsStopped(); i++)
     {
      if(r[i].time < InpFrom)
         continue;
      long   msc   = ((long)r[i].time + 60) * 1000 + InpLatencyMs;
      double c     = r[i].close;
      double rng   = r[i].high - r[i].low;
      double aS    = atrS[i - 1];
      double aF    = atrF[i];
      int    trend = c > ema[i] ? 1 : (c < ema[i] ? -1 : 0);
      if(aS <= 0.0 || aF <= 0.0)
         continue;

      //--- A: compression, then an expansion candle closes outside the range
      if(InpUseA && i - lastBar[0] >= InpCooldownBars)
        {
         double hi = r[i - 1].high, lo = r[i - 1].low;
         for(int j = i - InpSqzBars; j < i - 1; j++)
           {
            hi = MathMax(hi, r[j].high);
            lo = MathMin(lo, r[j].low);
           }
         if(hi - lo <= InpSqzMaxAtr * aS && rng >= InpExpBarAtr * aS)
           {
            int dir = c > hi ? 1 : (c < lo ? -1 : 0);
            if(dir != 0)
              {
               AddEv(msc, 0, dir, aF, aS, (hi - lo) / aS, rng / aS, dir == trend ? 1 : 0);
               lastBar[0] = i;
              }
           }
        }

      //--- B: first close outside a session's opening range
      if(InpUseB)
        {
         long     tod      = (long)r[i].time % 86400;
         datetime dayStart = (datetime)((long)r[i].time - tod);
         for(int s = 0; s < nSess; s++)
           {
            long orEnd = sess[s] + (long)InpOrbMin * 60;
            if(tod < orEnd || tod >= orEnd + (long)InpOrbWindowMin * 60 || trigDay[s] == dayStart)
               continue;
            datetime orFrom = (datetime)((long)dayStart + sess[s]);
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
               trigDay[s] = dayStart; // opening range incomplete: skip this session today
               continue;
              }
            int dir = c > hi ? 1 : (c < lo ? -1 : 0);
            if(dir != 0)
              {
               AddEv(msc, 1, dir, aF, aS, (hi - lo) / aS, (double)(tod - orEnd) / 60.0, dir == trend ? 1 : 0);
               trigDay[s] = dayStart;
              }
           }
        }

      //--- C: wick through the N-bar high/low, close back inside: fade
      if(InpUseC && i - lastBar[2] >= InpCooldownBars)
        {
         double hi = r[i - 1].high, lo = r[i - 1].low;
         for(int j = i - InpSweepBars; j < i - 1; j++)
           {
            hi = MathMax(hi, r[j].high);
            lo = MathMin(lo, r[j].low);
           }
         bool up = r[i].high >= hi + InpSweepMinAtr * aF && c < hi;
         bool dn = r[i].low <= lo - InpSweepMinAtr * aF && c > lo;
         if(up != dn) // both = an outside candle, skip it
           {
            int dir = up ? -1 : 1;
            double pierce = up ? r[i].high - hi : lo - r[i].low;
            double back   = up ? hi - c : c - lo;
            AddEv(msc, 2, dir, aF, aS, pierce / aF, back / aF, dir == trend ? 1 : 0);
            lastBar[2] = i;
           }
        }

      //--- control: no signal, both sides
      if(InpControlEvery > 0 && i % InpControlEvery == 0)
        {
         AddEv(msc, 3, 1, aF, aS, 0.0, 0.0, trend == 1 ? 1 : 0);
         AddEv(msc, 3, -1, aF, aS, 0.0, 0.0, trend == -1 ? 1 : 0);
        }
     }
   int cntSetup[NSET];
   ArrayInitialize(cntSetup, 0);
   for(int k = 0; k < g_n; k++)
      cntSetup[g_ev[k].setup]++;
   PrintFormat("Events found: A %d | B %d | C %d | control %d", cntSetup[0], cntSetup[1], cntSetup[2], cntSetup[3]);
   if(g_n == 0)
      return;

   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_cpx = (tv > 0.0 && ts > 0.0) ? InpCommission * ts / tv : 0.0;

   //--- replay ticks, one day at a time
   const long dayMs = 86400000;
   int k0 = 0, days = 0, noTicks = 0, gaps = 0;
   MqlTick tk[];
   while(k0 < g_n && !IsStopped())
     {
      long day0 = (g_ev[k0].msc / dayMs) * dayMs;
      int  k1   = k0;
      while(k1 < g_n && g_ev[k1].msc < day0 + dayMs)
         k1++;
      int nt = LoadTicks(tk, day0, day0 + dayMs + ((long)InpMaxHoldMin + 2) * 60000);
      if(nt == 0)
         noTicks++;
      else
         for(int k = k0; k < k1; k++)
            if(!Simulate(k, tk, nt))
               gaps++;
      days++;
      Comment(StringFormat("SetupProbe: day %d, %s, %d ticks", days,
                           TimeToString((datetime)(day0 / 1000), TIME_DATE), nt));
      k0 = k1;
     }
   Comment("");
   if(IsStopped())
      return;
   PrintFormat("Tick replay: %d days, %d days without tick history, %d events skipped for a data gap",
               days, noTicks, gaps);

   //--- money
   double usdPerPx = ts > 0.0 ? tv / ts * InpLots : 0.0;
   double commUsd  = InpCommission * InpLots;
   long   cutMsc   = ((long)InpFrom + (long)((1.0 - InpOosFrac) * (double)((long)InpTo - (long)InpFrom))) * 1000;
   PrintFormat("1.0 price move = %.4f %s at %.2f lots | commission %.4f per trade | out of sample from %s",
               usdPerPx, AccountInfoString(ACCOUNT_CURRENCY), InpLots, commUsd,
               TimeToString((datetime)(cutMsc / 1000), TIME_DATE | TIME_MINUTES));

   PrintSummary(cutMsc, usdPerPx, commUsd);
   WriteCsv(cutMsc, usdPerPx, commUsd);
  }
//+------------------------------------------------------------------+
