//+------------------------------------------------------------------+
//| FeedProbe.mq5                                                    |
//| Drop on a chart to see what your broker really sends for that    |
//| symbol: depth of market, aggressor-flagged trades, real volume,  |
//| spread distribution, tick speed and the cost of a 1m scalp.      |
//| Results go to the Experts tab (and the Journal).                 |
//+------------------------------------------------------------------+
#property copyright "goldscalp"
#property version   "1.00"
#property script_show_inputs

input int InpTicks      = 20000; // Recent ticks to analyse
input int InpBookSecs   = 20;    // Seconds to watch the depth of market
input int InpAtrPeriod  = 14;    // ATR period on M1

void OnStart()
  {
   string s = _Symbol;
   PrintFormat("===== FeedProbe %s | %s | %s =====", s,
               AccountInfoString(ACCOUNT_COMPANY), AccountInfoString(ACCOUNT_SERVER));
   PrintFormat("Digits %d | point %s | tick size %s | tick value %s %s | contract %s",
               (int)SymbolInfoInteger(s, SYMBOL_DIGITS),
               DoubleToString(SymbolInfoDouble(s, SYMBOL_POINT), 8),
               DoubleToString(SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE), 8),
               DoubleToString(SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE), 4),
               AccountInfoString(ACCOUNT_CURRENCY),
               DoubleToString(SymbolInfoDouble(s, SYMBOL_TRADE_CONTRACT_SIZE), 2));
   PrintFormat("Lots min %s step %s max %s | stops level %d pts | freeze level %d pts | exchange: %s",
               DoubleToString(SymbolInfoDouble(s, SYMBOL_VOLUME_MIN), 2),
               DoubleToString(SymbolInfoDouble(s, SYMBOL_VOLUME_STEP), 2),
               DoubleToString(SymbolInfoDouble(s, SYMBOL_VOLUME_MAX), 2),
               (int)SymbolInfoInteger(s, SYMBOL_TRADE_STOPS_LEVEL),
               (int)SymbolInfoInteger(s, SYMBOL_TRADE_FREEZE_LEVEL),
               SymbolInfoString(s, SYMBOL_EXCHANGE) == "" ? "none (OTC/CFD)" : SymbolInfoString(s, SYMBOL_EXCHANGE));

   //--- ticks
   MqlTick t[];
   int n = CopyTicks(s, t, COPY_TICKS_ALL, 0, InpTicks);
   if(n < 100)
     {
      PrintFormat("Only %d ticks available. Open a M1 chart, wait a minute and run again.", n);
      return;
     }
   int flagged = 0, withVol = 0, withLast = 0;
   double spreads[];
   ArrayResize(spreads, n);
   for(int k = 0; k < n; k++)
     {
      bool b = (t[k].flags & TICK_FLAG_BUY) != 0;
      bool sl = (t[k].flags & TICK_FLAG_SELL) != 0;
      if(b != sl)
         flagged++;
      if(t[k].volume_real > 0.0 || t[k].volume > 0)
         withVol++;
      if((t[k].flags & TICK_FLAG_LAST) != 0)
         withLast++;
      spreads[k] = t[k].ask - t[k].bid;
     }
   ArraySort(spreads);
   double med = spreads[n / 2], p90 = spreads[(int)(n * 0.9)], mx = spreads[n - 1], mn = spreads[0];
   double spanSec = (t[n - 1].time_msc - t[0].time_msc) / 1000.0;
   PrintFormat("Ticks: %d over %.0f min = %.2f ticks/s", n, spanSec / 60.0, spanSec > 0 ? n / spanSec : 0.0);
   PrintFormat("Aggressor-flagged trades: %d (%.1f%%) | ticks with volume: %d | last-price ticks: %d",
               flagged, 100.0 * flagged / n, withVol, withLast);
   PrintFormat("Spread: min %s | median %s | p90 %s | max %s",
               DoubleToString(mn, _Digits), DoubleToString(med, _Digits),
               DoubleToString(p90, _Digits), DoubleToString(mx, _Digits));

   //--- 1m range vs cost
   int h = iATR(s, PERIOD_M1, InpAtrPeriod);
   double atr[];
   bool gotAtr = false;
   for(int k = 0; k < 50 && !IsStopped(); k++)
     {
      if(CopyBuffer(h, 0, 1, 1, atr) == 1)
        { gotAtr = true; break; }
      Sleep(100);
     }
   IndicatorRelease(h);
   if(gotAtr && med > 0.0)
     {
      PrintFormat("ATR(%d) on M1: %s = %.1f x median spread. One round trip costs %.0f%% of an average 1m bar%s.",
                  InpAtrPeriod, DoubleToString(atr[0], _Digits), atr[0] / med, 100.0 * med / atr[0],
                  " (plus commission on Raw/Zero accounts)");
     }

   //--- depth of market
   if(!MarketBookAdd(s))
     {
      Print("Depth of market: NOT available for this symbol (MarketBookAdd failed).");
     }
   else
     {
      int updates = 0, maxBids = 0, maxAsks = 0, emptyPolls = 0, polls = 0;
      string lastSig = "", sample = "";
      for(int k = 0; k < InpBookSecs * 4 && !IsStopped(); k++)
        {
         Sleep(250);
         MqlBookInfo b[];
         polls++;
         if(!MarketBookGet(s, b) || ArraySize(b) == 0)
           { emptyPolls++; continue; }
         int bids = 0, asks = 0;
         string sig = "";
         for(int j = 0; j < ArraySize(b); j++)
           {
            if(b[j].type == BOOK_TYPE_BUY || b[j].type == BOOK_TYPE_BUY_MARKET)
               bids++;
            else
               asks++;
            sig += DoubleToString(b[j].price, _Digits) + ":" + DoubleToString(b[j].volume_real, 2) + " ";
           }
         maxBids = MathMax(maxBids, bids);
         maxAsks = MathMax(maxAsks, asks);
         if(sig != lastSig)
           { updates++; lastSig = sig; sample = sig; }
        }
      MarketBookRelease(s);
      PrintFormat("Depth of market: %d/%d polls empty | up to %d bid and %d ask levels | %d distinct snapshots in %ds",
                  emptyPolls, polls, maxBids, maxAsks, updates, InpBookSecs);
      if(sample != "")
         Print("Last book (price:volume, highest price first): ", sample);
     }

   //--- verdict
   Print("----- Verdict -----");
   if(flagged > n / 10)
      Print("Real trade prints with aggressor side: footprint / delta are REAL on this feed.");
   else
      Print("No aggressor-side trades: this is a quote feed (CFD). ScalpEngine falls back to the tick rule (direction of each quote change).");
   if(gotAtr && med > 0.0)
     {
      double x = atr[0] / med;
      if(x < 4.0)
         PrintFormat("ATR/spread %.1f is below 4: a 1m scalp pays too much spread here. Trade quieter hours less, busier hours more, or a cheaper account type.", x);
      else
         PrintFormat("ATR/spread %.1f: costs are workable for 1m scalping if the signal has an edge.", x);
     }
  }
//+------------------------------------------------------------------+
