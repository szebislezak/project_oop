//+------------------------------------------------------------------+
//| XAU "Bari mode" Signal + Auto EA (M5 entry, M15 bias)            |
//| - TREND algo: BOS + zone from last opposite candle (LIMIT ladder)|
//| - RANGE algo: M15 range-edge + reversal trigger (MARKET entry)   |
//| - Bari-like: Zone 2-4$, SL buffer 7$, TP step 5$                 |
//| - TP1 always; TP2/TP3 conditional; then HOLD (no TP4)            |
//| - Anti-spam + Quiet hours (no signals 21:30-06:00)               |
//| - "No slip" for LIMIT: don't alert if price too far from zone    |
//+------------------------------------------------------------------+
#property strict
#property description "Bari-like XAU | TREND=BOS+LIMIT ladder | RANGE=edge+reversal+MARKET | Anti-spam | Quiet hours | Telegram"

#include <Trade/Trade.mqh>
CTrade trade;

//======================== INPUTS ========================
input string InpSymbol               = "XAUUSD.s";
input int    InpMagic                = 260913;

// Signal vs Trade
input bool   EnableAutoTrade         = false;   // TRUE in tester/live if you want auto trading
input double RiskPercentPerTrade     = 0.25;

// Filters
input bool   UseSpreadFilter         = false;
input int    MaxSpreadPoints         = 120;

// Quiet hours (server time)
input bool   UseQuietHours           = true;
input int    QuietStartHour          = 21;
input int    QuietStartMin           = 30;
input int    QuietEndHour            = 6;
input int    QuietEndMin             = 0;

// pacing / anti-spam
input int    MinMinutesBetweenSetups = 2;       // basic pacing
input int    AntiSpamMinutes         = 45;      // block same-ish setup repeat
input double AntiSpamZoneTolDollars  = 1.0;     // zone similarity tolerance (in $)

// "No slip": if current price too far from LIMIT zone, don't signal
input bool   UseNoSlipFilter         = true;
input double MaxDistanceFromZoneDollars = 6.0;  // if price is farther than this from zone -> skip LIMIT signal

// Daily cap
input int    MaxSetupsPerDay         = 50;
input bool   AllowReEntry            = true;

//======================== BACKTEST MODE ========================
input bool   BacktestTP1Only         = true;     // tester validation: TP=TP1 only

//======================== TIMEFRAMES ========================
input ENUM_TIMEFRAMES EntryTF        = PERIOD_M5;
input ENUM_TIMEFRAMES BiasTF         = PERIOD_M15;

//======================== TREND (BOS) DETECTION ========================
input int    StructureLookback       = 10;
input double BOS_Confirm_ATR         = 0.03;
input bool   UseCandleQuality        = true;
input double MinBody_ATR             = 0.05;
input double MinRange_ATR            = 0.20;
input int    FindLastOppCandleBars   = 8;

//======================== RANGE DETECTION (REAL RANGE ALGO) ========================
// Range is defined on M15 over last N candles.
// Trigger: price touches range edge (within tol) + M5 reversal candle (engulf/pin-ish).
input int    RangeLookbackBars_M15   = 30;     // 20..50 is typical
input double RangeEdgeTol_ATR15      = 0.20;   // edge proximity tolerance = ATR15 * this
input double RangeReversalBody_ATR5  = 0.06;   // reversal candle min body (ATR5 fraction)
input bool   RequireCloseBackInside  = true;   // after touching edge, M5 close back inside range
input bool   UseRangeOnlyIfADXLow    = true;   // range algo only when ADX < threshold

//======================== BIAS (M15 EMA200) ========================
input bool   UseTrendBias            = true;
input int    BiasEMAPeriod           = 200;
input double BiasMinDist_ATR15       = 0.40;
input bool   AllowCounterTrendBOS    = true;
input double CounterTrendMinMomentum = 1.8;

//======================== REGIME DETECTION ========================
// ADX low => RANGE algo (MARKET). ADX high => TREND algo (LIMIT ladder).
input bool   UseRegimeDetection      = true;
input int    ADXPeriod               = 14;
input double ADXTrendThreshold       = 22.0;    // >= trend, < range

//======================== BARI TP/SL MODEL ========================
input double ZoneMinDollars          = 2.0;
input double ZoneMaxDollars          = 4.0;
input double Bari_TPStep_Dollars     = 5.0;
input double Bari_SLBuffer_Dollars   = 7.0;

// Conditional TP enabling (momentum)
input double TP2_MinMomentum         = 0.9;
input double TP3_MinMomentum         = 1.7;

//======================== ORDERING ========================
input int    PendingExpiryMinutes    = 180;
input int    StopLevelBufferPts      = 10;

//======================== COOLDOWN ========================
input int    LossStreakToCooldown    = 2;
input int    CooldownMinutes         = 45;

//======================== TELEGRAM ========================
input bool   UseTelegram             = false;
input string TgBotToken              = "";
input string TgChatId                = "";
input int    DetailsDelaySeconds     = 45; // random 5..N sec

//======================== DEBUG ========================
input bool   PrintDebug              = true;
input bool   PrintRejectStats         = true;

//======================== GLOBALS ========================
datetime g_cooldownUntil     = 0;
int      g_lossStreak        = 0;
datetime g_lastBarTime       = 0;
datetime g_nextSetupAllowed  = 0;

// delayed details scheduling
string   g_pendingDetailsMsg = "";
bool     g_hasPendingDetails = false;
datetime g_detailsSendAt     = 0;

// seen deals
ulong g_seenDeals[];

// position direction map
struct PosDir { ulong posId; bool isBuy; };
PosDir g_posDirs[];

// indicator handles
int hATR_M5  = INVALID_HANDLE;
int hATR_M15 = INVALID_HANDLE;
int hEMA_M15 = INVALID_HANDLE;
int hADX_M15 = INVALID_HANDLE;

// reject counters
int r_noBar=0, r_atr=0, r_struct=0, r_quality=0, r_noBOS=0, r_bias=0, r_far=0, r_range=0, r_stop=0, r_orders=0, r_spam=0, r_quiet=0;

// anti-spam memory
datetime g_lastSignalTime = 0;
bool     g_lastSignalBuy  = true;
double   g_lastZLow = 0, g_lastZHigh = 0;

//======================== UTIL ===========================
void Dbg(const string s){ if(PrintDebug) Print(s); }

double ClampD(double v,double lo,double hi){ if(v<lo) return lo; if(v>hi) return hi; return v; }

double SymPoint(){ return SymbolInfoDouble(InpSymbol,SYMBOL_POINT); }

double NormalizePrice(double p)
{
   int digits=(int)SymbolInfoInteger(InpSymbol,SYMBOL_DIGITS);
   return NormalizeDouble(p,digits);
}

bool InCooldown(){ return TimeCurrent() < g_cooldownUntil; }
bool InSetupPacing(){ return TimeCurrent() < g_nextSetupAllowed; }

bool SpreadOk()
{
   if(!UseSpreadFilter) return true;
   long spr=(long)SymbolInfoInteger(InpSymbol,SYMBOL_SPREAD);
   if(spr<=0) return true;
   return spr<=MaxSpreadPoints;
}

bool NewBar(ENUM_TIMEFRAMES tf, datetime &lastTime)
{
   datetime t[2];
   if(CopyTime(InpSymbol, tf, 0, 2, t) < 2) return false;
   if(t[0]!=lastTime){ lastTime=t[0]; return true; }
   return false;
}

bool UlongArrayContains(ulong &arr[], ulong v)
{
   int n=ArraySize(arr);
   for(int i=0;i<n;i++) if(arr[i]==v) return true;
   return false;
}
void UlongArrayAddUnique(ulong &arr[], ulong v)
{
   if(UlongArrayContains(arr,v)) return;
   int n=ArraySize(arr);
   ArrayResize(arr,n+1);
   arr[n]=v;
}

int FindPosDir(ulong posId)
{
   for(int i=0;i<ArraySize(g_posDirs);i++)
      if(g_posDirs[i].posId==posId) return i;
   return -1;
}
void SetPosDir(ulong posId, bool isBuy)
{
   int idx=FindPosDir(posId);
   if(idx>=0){ g_posDirs[idx].isBuy=isBuy; return; }
   int n=ArraySize(g_posDirs);
   ArrayResize(g_posDirs,n+1);
   g_posDirs[n].posId=posId;
   g_posDirs[n].isBuy=isBuy;
}
bool GetPosDir(ulong posId, bool &isBuy)
{
   int idx=FindPosDir(posId);
   if(idx<0) return false;
   isBuy=g_posDirs[idx].isBuy;
   return true;
}

bool HasOurOpenPosition()
{
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong pt=PositionGetTicket(i);
      if(pt==0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if((string)PositionGetString(POSITION_SYMBOL)!=InpSymbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      return true;
   }
   return false;
}

int SetupsTodayCount()
{
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   MqlDateTime ds=t; ds.hour=0; ds.min=0; ds.sec=0;
   datetime dayStart=StructToTime(ds);

   HistorySelect(dayStart, TimeCurrent());
   int deals=HistoryDealsTotal();
   int cnt=0;

   for(int i=deals-1;i>=0;--i)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0) continue;
      if((string)HistoryDealGetString(d,DEAL_SYMBOL)!=InpSymbol) continue;
      if((long)HistoryDealGetInteger(d,DEAL_MAGIC)!=InpMagic) continue;
      if((long)HistoryDealGetInteger(d,DEAL_ENTRY)==DEAL_ENTRY_IN) cnt++;
   }
   return cnt;
}

//======================== QUIET HOURS =========================
bool IsQuietNow()
{
   if(!UseQuietHours) return false;

   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   int nowMin = t.hour*60 + t.min;
   int sMin   = QuietStartHour*60 + QuietStartMin;
   int eMin   = QuietEndHour*60   + QuietEndMin;

   if(sMin<eMin) return (nowMin>=sMin && nowMin<eMin);
   return (nowMin>=sMin || nowMin<eMin);
}

//======================== TELEGRAM =========================
string UrlEncode(const string s)
{
   uchar bytes[];
   StringToCharArray(s, bytes, 0, WHOLE_ARRAY, CP_UTF8);
   string out="";
   int n=ArraySize(bytes);
   for(int i=0;i<n;i++)
   {
      uchar b=bytes[i];
      if((b>='a' && b<='z')||(b>='A' && b<='Z')||(b>='0' && b<='9')||b=='-'||b=='_'||b=='.'||b=='~')
         out += CharToString(b);
      else if(b==' ') out += "%20";
      else if(b=='\n' || b=='\r') out += "%0A";
      else out += StringFormat("%%%02X",(int)b);
   }
   return out;
}

void SendTelegram(const string msg)
{
   if(!UseTelegram) return;
   if(TgBotToken=="" || TgChatId==""){ Print("TG: missing token/chatId"); return; }

   string url  = "https://api.telegram.org/bot"+TgBotToken+"/sendMessage";
   string data = "chat_id="+UrlEncode(TgChatId)+"&text="+UrlEncode(msg);

   uchar post[];
   StringToCharArray(data, post, 0, WHOLE_ARRAY, CP_UTF8);

   uchar result[];
   string headers="Content-Type: application/x-www-form-urlencoded\r\n";
   string result_headers="";

   ResetLastError();
   int res=WebRequest("POST",url,headers,8000,post,result,result_headers);
   int err=GetLastError();
   if(res==-1) PrintFormat("TG send failed err=%d",err);
}

//======================== INDICATORS (HANDLE CACHED) =========================
bool Copy1(int handle, int buffer, int shift, double &out)
{
   if(handle==INVALID_HANDLE) return false;
   if(BarsCalculated(handle) < 20) return false;
   double b[]; ArraySetAsSeries(b,true);
   if(CopyBuffer(handle, buffer, shift, 1, b) < 1) return false;
   out=b[0];
   return true;
}
double ATR_M5(int shift=1){ double v=0.0; if(!Copy1(hATR_M5,0,shift,v)) return 0.0; return v; }
double ATR_M15(int shift=1){ double v=0.0; if(!Copy1(hATR_M15,0,shift,v)) return 0.0; return v; }
double EMA_M15(int shift=1){ double v=0.0; if(!Copy1(hEMA_M15,0,shift,v)) return 0.0; return v; }
double ADX_M15(int shift=1){ double v=0.0; if(!Copy1(hADX_M15,0,shift,v)) return 0.0; return v; }

//======================== BARS =========================
bool GetBarOHLC(ENUM_TIMEFRAMES tf,int shift,double &o,double &h,double &l,double &c)
{
   double O[],H[],L[],C[];
   ArraySetAsSeries(O,true); ArraySetAsSeries(H,true); ArraySetAsSeries(L,true); ArraySetAsSeries(C,true);
   if(CopyOpen (InpSymbol,tf,shift,1,O)<1) return false;
   if(CopyHigh (InpSymbol,tf,shift,1,H)<1) return false;
   if(CopyLow  (InpSymbol,tf,shift,1,L)<1) return false;
   if(CopyClose(InpSymbol,tf,shift,1,C)<1) return false;
   o=O[0]; h=H[0]; l=L[0]; c=C[0];
   return true;
}

double HighestHigh(ENUM_TIMEFRAMES tf,int startShift,int count)
{
   double arr[]; ArrayResize(arr,count); ArraySetAsSeries(arr,true);
   if(CopyHigh(InpSymbol,tf,startShift,count,arr)<count) return 0.0;
   double m=arr[0];
   for(int i=1;i<count;i++) if(arr[i]>m) m=arr[i];
   return m;
}
double LowestLow(ENUM_TIMEFRAMES tf,int startShift,int count)
{
   double arr[]; ArrayResize(arr,count); ArraySetAsSeries(arr,true);
   if(CopyLow(InpSymbol,tf,startShift,count,arr)<count) return 0.0;
   double m=arr[0];
   for(int i=1;i<count;i++) if(arr[i]<m) m=arr[i];
   return m;
}

//======================== BIAS =========================
int TrendBias()
{
   if(!UseTrendBias) return 0;

   double ema = EMA_M15(1);
   if(ema<=0.0) return 0;

   double c[]; ArraySetAsSeries(c,true);
   if(CopyClose(InpSymbol, PERIOD_M15, 1, 1, c) < 1) return 0;

   double atr15 = ATR_M15(1);
   if(atr15<=0.0) return 0;

   if(MathAbs(c[0]-ema) < atr15*BiasMinDist_ATR15) return 0;
   if(c[0]>ema) return +1;
   if(c[0]<ema) return -1;
   return 0;
}

//======================== REGIME =========================
enum Regime { REGIME_TREND=0, REGIME_RANGE=1 };

Regime GetRegime()
{
   if(!UseRegimeDetection) return REGIME_TREND;

   double adx = ADX_M15(1);
   if(adx<=0.0) return REGIME_TREND; // fail-safe
   if(adx >= ADXTrendThreshold) return REGIME_TREND;
   return REGIME_RANGE;
}

//======================== MOMENTUM =========================
double MomentumScore(double o,double h,double l,double c,double atr,bool isBuy,double bosLevel)
{
   if(atr<=0.0) return 0.0;

   double body=MathAbs(c-o);
   double range=(h-l);
   double br = (range>0.0)?(body/range):0.0;

   double beyond = isBuy ? (c-bosLevel) : (bosLevel-c);
   double beyondA = beyond/atr;

   double score=0.0;
   if(br>=0.55) score+=1.0;
   else if(br>=0.40) score+=0.6;
   else score+=0.2;

   if(beyondA>=0.20) score+=1.0;
   else if(beyondA>=0.08) score+=0.6;
   else score+=0.2;

   if(score<0.0) score=0.0;
   return score; // ~0..2
}

//======================== SIGNAL =========================
struct Signal
{
   bool   ok;
   bool   isBuy;
   bool   isMarket;      // true => MARKET NOW entry (range algo)
   Regime regime;        // RANGE/TREND label
   double entryNow;      // for market signals (0 if limit)
   double zLow;
   double zHigh;
   double sl;
   double tp1;
   double tp2; // 0 => HOLD
   double tp3; // 0 => HOLD
   double mom;
};

string SignalText(const Signal &s)
{
   string side = s.isBuy ? "BUY" : "SELL";
   string icon = s.isBuy ? "🟢" : "🔴";
   string reg  = (s.regime==REGIME_RANGE ? "RANGE" : "TREND");
   string how  = (s.isMarket ? "NOW" : "LIMIT");

   double a=s.zLow,b=s.zHigh;
   if(a>b){ double t=a; a=b; b=t; }

   string header = "XAUUSD ("+reg+")\n\n"+icon+" "+side+" ("+how+")";

   // market: show entry price too
   if(s.isMarket && s.entryNow>0.0)
      header += " @"+DoubleToString(s.entryNow,2);

   string txt = header + " " + DoubleToString(a,0) + " - " + DoubleToString(b,0) +
                "\n\nSL " + DoubleToString(s.sl,0) +
                "\n\nTP1 " + DoubleToString(s.tp1,0);

   if(s.tp2>0.0) txt += "\nTP2 "+DoubleToString(s.tp2,0);
   else          txt += "\nTP2 HOLD.";

   if(s.tp3>0.0) txt += "\nTP3 "+DoubleToString(s.tp3,0);
   else          txt += "\nTP3 HOLD.";

   return txt;
}

//======================== ANTI-SPAM =========================
bool IsSpamDuplicate(const Signal &s)
{
   if(g_lastSignalTime==0) return false;

   if((TimeCurrent() - g_lastSignalTime) < AntiSpamMinutes*60)
   {
      if(s.isBuy == g_lastSignalBuy)
      {
         double dz1 = MathAbs(s.zLow  - g_lastZLow);
         double dz2 = MathAbs(s.zHigh - g_lastZHigh);
         if(dz1<=AntiSpamZoneTolDollars && dz2<=AntiSpamZoneTolDollars)
            return true;
      }
   }
   return false;
}

//======================== TREND: zone from last opposite candle =========================
bool FindOppCandleZone(bool isBuy, int maxBars, double &zLow, double &zHigh)
{
   for(int sh=2; sh<=maxBars+1; sh++)
   {
      double o,h,l,c;
      if(!GetBarOHLC(EntryTF, sh, o,h,l,c)) return false;

      bool bearish = (c<o);
      bool bullish = (c>o);

      if(isBuy && bearish)
      {
         zLow  = l;
         zHigh = MathMax(o,c);
         return true;
      }
      if(!isBuy && bullish)
      {
         zLow  = MathMin(o,c);
         zHigh = h;
         return true;
      }
   }
   return false;
}

bool IsTooFarFromZone_Limit(bool isBuy, double zLow, double zHigh)
{
   if(!UseNoSlipFilter) return false;

   double bid=0, ask=0;
   if(!SymbolInfoDouble(InpSymbol,SYMBOL_BID,bid)) return false;
   if(!SymbolInfoDouble(InpSymbol,SYMBOL_ASK,ask)) return false;

   double px = isBuy ? bid : ask;

   double dist=0.0;
   if(px<zLow) dist = zLow-px;
   else if(px>zHigh) dist = px-zHigh;

   return (dist > MaxDistanceFromZoneDollars);
}

//======================== TREND SIGNAL (BOS) =========================
bool DetectSignalTrend(Signal &s)
{
   // BOS on EntryTF (M5)
   double o,h,l,c;
   if(!GetBarOHLC(EntryTF, 1, o,h,l,c)){ r_noBar++; return false; }

   double atr = ATR_M5(1);
   if(atr<=0.0){ r_atr++; return false; }

   double structHigh = HighestHigh(EntryTF, 2, StructureLookback);
   double structLow  = LowestLow (EntryTF, 2, StructureLookback);
   if(structHigh==0.0 || structLow==0.0){ r_struct++; return false; }

   if(UseCandleQuality)
   {
      double body=MathAbs(c-o);
      double range=(h-l);
      if(body < atr*MinBody_ATR || range < atr*MinRange_ATR){ r_quality++; return false; }
   }

   bool bosBuy  = (c > structHigh + atr*BOS_Confirm_ATR);
   bool bosSell = (c < structLow  - atr*BOS_Confirm_ATR);
   if(!bosBuy && !bosSell){ r_noBOS++; return false; }

   bool isBuy = bosBuy;
   double bosLevel = isBuy ? structHigh : structLow;
   double mom = MomentumScore(o,h,l,c,atr,isBuy,bosLevel);

   // bias gating for TREND algo (but not killing everything)
   int bias = TrendBias();
   if(UseTrendBias)
   {
      if(bias==+1 && !isBuy)
      {
         if(!(AllowCounterTrendBOS && mom>=CounterTrendMinMomentum)){ r_bias++; return false; }
      }
      if(bias==-1 && isBuy)
      {
         if(!(AllowCounterTrendBOS && mom>=CounterTrendMinMomentum)){ r_bias++; return false; }
      }
   }

   // zone from last opposite candle, fallback if missing
   double zL=0,zH=0;
   if(!FindOppCandleZone(isBuy, FindLastOppCandleBars, zL, zH))
   {
      double width = ClampD(atr*0.35, ZoneMinDollars, ZoneMaxDollars);
      if(isBuy){ zH=c-atr*0.15; zL=zH-width; }
      else     { zL=c+atr*0.15; zH=zL+width; }
   }

   // normalize + clamp width to Bari
   if(zL>zH){ double t=zL; zL=zH; zH=t; }
   double w = ClampD(zH-zL, ZoneMinDollars, ZoneMaxDollars);
   if(isBuy) zL = zH - w;
   else      zH = zL + w;

   // no-slip filter only for LIMIT trend entries
   if(IsTooFarFromZone_Limit(isBuy, zL, zH)){ r_far++; return false; }

   // Bari SL/TP
   double sl  = isBuy ? (zL - Bari_SLBuffer_Dollars)
                      : (zH + Bari_SLBuffer_Dollars);

   double tp1 = isBuy ? (zH + Bari_TPStep_Dollars)
                      : (zL - Bari_TPStep_Dollars);
   double tp2 = isBuy ? (tp1 + Bari_TPStep_Dollars)
                      : (tp1 - Bari_TPStep_Dollars);
   double tp3 = isBuy ? (tp2 + Bari_TPStep_Dollars)
                      : (tp2 - Bari_TPStep_Dollars);

   double outTP2 = (mom >= TP2_MinMomentum) ? tp2 : 0.0;
   double outTP3 = (mom >= TP3_MinMomentum) ? tp3 : 0.0;
   if(outTP2<=0.0) outTP3=0.0;

   s.ok=true;
   s.regime=REGIME_TREND;
   s.isMarket=false;
   s.entryNow=0.0;
   s.isBuy=isBuy;
   s.zLow =NormalizePrice(zL);
   s.zHigh=NormalizePrice(zH);
   s.sl   =NormalizePrice(sl);
   s.tp1  =NormalizePrice(tp1);
   s.tp2  = (outTP2>0.0?NormalizePrice(outTP2):0.0);
   s.tp3  = (outTP3>0.0?NormalizePrice(outTP3):0.0);
   s.mom  = mom;

   return true;
}

//======================== RANGE SIGNAL (REAL RANGE EDGE + REVERSAL) =========================
bool GetRangeM15(double &rangeLow, double &rangeHigh)
{
   // use last N completed M15 candles (shift starts at 1)
   rangeHigh = HighestHigh(PERIOD_M15, 1, RangeLookbackBars_M15);
   rangeLow  = LowestLow (PERIOD_M15, 1, RangeLookbackBars_M15);
   return (rangeHigh>0.0 && rangeLow>0.0 && rangeHigh>rangeLow);
}

bool IsReversalBuyM5(double rangeLow, double rangeHigh, double atr5, double edgeTol)
{
   // Use last closed M5 candle (shift=1)
   double o,h,l,c;
   if(!GetBarOHLC(PERIOD_M5,1,o,h,l,c)) return false;

   double body = MathAbs(c-o);
   if(body < atr5*RangeReversalBody_ATR5) return false;

   // touched/near low edge
   bool touched = (l <= (rangeLow + edgeTol));

   if(!touched) return false;

   // bullish reversal style
   bool bullish = (c>o);

   // optional close back inside range
   if(RequireCloseBackInside)
      bullish = bullish && (c > rangeLow);

   // small pin bonus: long lower wick
   double lowerWick = MathMin(o,c) - l;
   bool pin = (lowerWick >= atr5*0.20);

   return bullish || pin;
}

bool IsReversalSellM5(double rangeLow, double rangeHigh, double atr5, double edgeTol)
{
   double o,h,l,c;
   if(!GetBarOHLC(PERIOD_M5,1,o,h,l,c)) return false;

   double body = MathAbs(c-o);
   if(body < atr5*RangeReversalBody_ATR5) return false;

   bool touched = (h >= (rangeHigh - edgeTol));
   if(!touched) return false;

   bool bearish = (c<o);

   if(RequireCloseBackInside)
      bearish = bearish && (c < rangeHigh);

   double upperWick = h - MathMax(o,c);
   bool pin = (upperWick >= atr5*0.20);

   return bearish || pin;
}

bool DetectSignalRange(Signal &s)
{
   // only if ADX low (optional)
   if(UseRangeOnlyIfADXLow)
   {
      double adx = ADX_M15(1);
      if(adx<=0.0) return false;
      if(adx >= ADXTrendThreshold) return false; // not range now
   }

   double rangeLow=0, rangeHigh=0;
   if(!GetRangeM15(rangeLow, rangeHigh)){ r_range++; return false; }

   double atr15 = ATR_M15(1);
   double atr5  = ATR_M5(1);
   if(atr15<=0.0 || atr5<=0.0){ r_atr++; return false; }

   double edgeTol = atr15 * RangeEdgeTol_ATR15;

   // check reversal triggers on M5 at edges
   bool buyTrig  = IsReversalBuyM5(rangeLow, rangeHigh, atr5, edgeTol);
   bool sellTrig = IsReversalSellM5(rangeLow, rangeHigh, atr5, edgeTol);
   if(!buyTrig && !sellTrig){ r_range++; return false; }

   bool isBuy = buyTrig;
   // market entry price now
   double bid=0, ask=0;
   if(!SymbolInfoDouble(InpSymbol,SYMBOL_BID,bid)) return false;
   if(!SymbolInfoDouble(InpSymbol,SYMBOL_ASK,ask)) return false;
   double entryNow = isBuy ? ask : bid;

   // zone (for message clarity): tight 2-4$ band at touched edge
   double w = ClampD(atr15*0.35, ZoneMinDollars, ZoneMaxDollars);
   double zL=0, zH=0;
   if(isBuy)
   {
      zL = rangeLow;
      zH = rangeLow + w;
   }
   else
   {
      zH = rangeHigh;
      zL = rangeHigh - w;
   }

   // SL: beyond the touched edge (Bari buffer)
   double sl = isBuy ? (zL - Bari_SLBuffer_Dollars)
                     : (zH + Bari_SLBuffer_Dollars);

   // momentum for TP2/TP3 enabling (use how far last M5 close moved from edge)
   // simple stable approximation:
   double o1,h1,l1,c1;
   if(!GetBarOHLC(PERIOD_M5,1,o1,h1,l1,c1)) return false;
   double bosLevel = isBuy ? zL : zH;
   double mom = MomentumScore(o1,h1,l1,c1,atr5,isBuy,bosLevel); // reusing same scoring

   // TP ladder from ENTRY NOW (market) so it makes sense in range
   double tp1 = isBuy ? (entryNow + Bari_TPStep_Dollars)
                      : (entryNow - Bari_TPStep_Dollars);
   double tp2 = isBuy ? (tp1 + Bari_TPStep_Dollars)
                      : (tp1 - Bari_TPStep_Dollars);
   double tp3 = isBuy ? (tp2 + Bari_TPStep_Dollars)
                      : (tp2 - Bari_TPStep_Dollars);

   double outTP2 = (mom >= TP2_MinMomentum) ? tp2 : 0.0;
   double outTP3 = (mom >= TP3_MinMomentum) ? tp3 : 0.0;
   if(outTP2<=0.0) outTP3=0.0;

   s.ok=true;
   s.regime=REGIME_RANGE;
   s.isMarket=true;
   s.entryNow=NormalizePrice(entryNow);
   s.isBuy=isBuy;
   s.zLow =NormalizePrice(zL);
   s.zHigh=NormalizePrice(zH);
   s.sl   =NormalizePrice(sl);
   s.tp1  =NormalizePrice(tp1);
   s.tp2  = (outTP2>0.0?NormalizePrice(outTP2):0.0);
   s.tp3  = (outTP3>0.0?NormalizePrice(outTP3):0.0);
   s.mom  = mom;

   return true;
}

//======================== LOT =========================
double RoundLot(double lot)
{
   double step  = SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_STEP);
   double minLot= SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MIN);
   double maxLot= SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MAX);
   if(step<=0.0) step=0.01;
   lot = MathFloor(lot/step)*step;
   if(lot<minLot) lot=minLot;
   if(lot>maxLot) lot=maxLot;
   return lot;
}

double CalcLotForRisk(double riskPercent, double entryPrice, double slPrice)
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (riskPercent / 100.0);

   double tickValue = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_SIZE);

   double slDist    = MathAbs(entryPrice - slPrice);
   double riskPerLot= (slDist / tickSize) * tickValue;

   if(riskPerLot <= 0.0 || riskMoney <= 0.0) return 0.0;

   double lot = riskMoney / riskPerLot;
   return RoundLot(lot);
}

//======================== PENDING MGMT =========================
void CancelAllOurPendings()
{
   for(int i=OrdersTotal()-1;i>=0;--i)
   {
      ulong ot=OrderGetTicket(i);
      if(ot==0) continue;
      if(!OrderSelect(ot)) continue;
      if((string)OrderGetString(ORDER_SYMBOL)!=InpSymbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;

      long type=(long)OrderGetInteger(ORDER_TYPE);
      if(type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_SELL_LIMIT ||
         type==ORDER_TYPE_BUY_STOP  || type==ORDER_TYPE_SELL_STOP  ||
         type==ORDER_TYPE_BUY_STOP_LIMIT || type==ORDER_TYPE_SELL_STOP_LIMIT)
      {
         trade.OrderDelete(ot);
      }
   }
}

bool PlaceTrendLimitLadder(const Signal &s)
{
   int    stopLevel=(int)SymbolInfoInteger(InpSymbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist=(stopLevel+StopLevelBufferPts)*SymPoint();

   double zL=s.zLow, zH=s.zHigh;
   if(zL>zH){ double t=zL; zL=zH; zH=t; }

   double p1=NormalizePrice(zH);
   double p2=NormalizePrice((zH+zL)/2.0);
   double p3=NormalizePrice(zL);

   if(s.isBuy)
   {
      if((p1-s.sl)<minStopDist || (p2-s.sl)<minStopDist || (p3-s.sl)<minStopDist){ r_stop++; return false; }
   }
   else
   {
      if((s.sl-p1)<minStopDist || (s.sl-p2)<minStopDist || (s.sl-p3)<minStopDist){ r_stop++; return false; }
   }

   double entryRef=(zH+zL)/2.0;
   double lot=CalcLotForRisk(RiskPercentPerTrade, entryRef, s.sl);
   if(lot<=0.0){ r_orders++; return false; }

   datetime exp=TimeCurrent() + (datetime)(PendingExpiryMinutes*60);

   double tpForOrders=0.0;
   if(BacktestTP1Only) tpForOrders=s.tp1;
   else
   {
      if(s.tp3>0.0) tpForOrders=s.tp3;
      else if(s.tp2>0.0) tpForOrders=s.tp2;
      else tpForOrders=0.0;
   }

   bool ok=true;
   if(s.isBuy)
   {
      ok &= trade.BuyLimit(lot, p1, InpSymbol, s.sl, tpForOrders, ORDER_TIME_SPECIFIED, exp, "BARI_TOP");
      ok &= trade.BuyLimit(lot, p2, InpSymbol, s.sl, tpForOrders, ORDER_TIME_SPECIFIED, exp, "BARI_MID");
      ok &= trade.BuyLimit(lot, p3, InpSymbol, s.sl, tpForOrders, ORDER_TIME_SPECIFIED, exp, "BARI_LOW");
   }
   else
   {
      ok &= trade.SellLimit(lot, p1, InpSymbol, s.sl, tpForOrders, ORDER_TIME_SPECIFIED, exp, "BARI_TOP");
      ok &= trade.SellLimit(lot, p2, InpSymbol, s.sl, tpForOrders, ORDER_TIME_SPECIFIED, exp, "BARI_MID");
      ok &= trade.SellLimit(lot, p3, InpSymbol, s.sl, tpForOrders, ORDER_TIME_SPECIFIED, exp, "BARI_LOW");
   }

   if(!ok){ r_orders++; return false; }
   return true;
}

bool PlaceRangeMarket(const Signal &s)
{
   double bid=0, ask=0;
   if(!SymbolInfoDouble(InpSymbol,SYMBOL_BID,bid)) return false;
   if(!SymbolInfoDouble(InpSymbol,SYMBOL_ASK,ask)) return false;

   double entry = s.isBuy ? ask : bid;
   double lot=CalcLotForRisk(RiskPercentPerTrade, entry, s.sl);
   if(lot<=0.0){ r_orders++; return false; }

   double tp=0.0;
   if(BacktestTP1Only) tp=s.tp1;
   else
   {
      if(s.tp3>0.0) tp=s.tp3;
      else if(s.tp2>0.0) tp=s.tp2;
      else tp=0.0;
   }

   bool ok=false;
   if(s.isBuy) ok = trade.Buy(lot, InpSymbol, entry, s.sl, tp, "BARI_RANGE_MKT");
   else        ok = trade.Sell(lot, InpSymbol, entry, s.sl, tp, "BARI_RANGE_MKT");

   if(!ok){ r_orders++; return false; }
   return true;
}

//======================== TRADE EVENTS =========================
string DealReasonToText(long reason)
{
   if(reason==DEAL_REASON_SL) return "SL hit";
   if(reason==DEAL_REASON_TP) return "TP hit";
   if(reason==DEAL_REASON_SO) return "StopOut";
   return "Close";
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong deal=trans.deal;
   if(deal==0) return;

   if(UlongArrayContains(g_seenDeals, deal)) return;
   UlongArrayAddUnique(g_seenDeals, deal);

   HistorySelect(TimeCurrent()-86400*30, TimeCurrent());

   if((string)HistoryDealGetString(deal,DEAL_SYMBOL)!=InpSymbol) return;
   if((long)HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic) return;

   long entryType=(long)HistoryDealGetInteger(deal,DEAL_ENTRY);
   long dealType =(long)HistoryDealGetInteger(deal,DEAL_TYPE);
   long reason   =(long)HistoryDealGetInteger(deal,DEAL_REASON);

   double price  = HistoryDealGetDouble(deal,DEAL_PRICE);
   double volume = HistoryDealGetDouble(deal,DEAL_VOLUME);
   double profit = HistoryDealGetDouble(deal,DEAL_PROFIT);

   if(entryType==DEAL_ENTRY_IN)
   {
      ulong posId=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
      bool isBuyPos=(dealType==DEAL_TYPE_BUY);
      SetPosDir(posId,isBuyPos);

      // if we placed a ladder: cancel remaining pendings on first fill
      CancelAllOurPendings();

      SendTelegram("🟩 BELÉPÉS (filled)\n"+string(isBuyPos?"BUY":"SELL")+
                   "\nÁr: "+DoubleToString(price,2)+
                   "\nLot: "+DoubleToString(volume,2));
      return;
   }

   if(entryType==DEAL_ENTRY_OUT)
   {
      string rs=DealReasonToText(reason);

      if(profit < -0.0000001)
      {
         g_lossStreak++;
         if(g_lossStreak >= LossStreakToCooldown)
            g_cooldownUntil = TimeCurrent() + CooldownMinutes*60;

         SendTelegram("🟥 ZÁRÁS: "+rs+"\nProfit: "+DoubleToString(profit,2));
      }
      else
      {
         g_lossStreak=0;
         SendTelegram("🟦 ZÁRÁS: "+rs+"\nProfit: "+DoubleToString(profit,2));
      }
   }
}

//======================== TIMER =========================
void OnTimer()
{
   if(!UseTelegram) return;

   if(g_hasPendingDetails && g_pendingDetailsMsg!="" && TimeCurrent()>=g_detailsSendAt)
   {
      SendTelegram(g_pendingDetailsMsg);
      g_hasPendingDetails=false;
      g_pendingDetailsMsg="";
   }
}

//======================== INIT/DEINIT =========================
int OnInit()
{
   if(!SymbolSelect(InpSymbol,true))
   {
      Print("INIT FAILED: SymbolSelect failed on ",InpSymbol);
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);

   hATR_M5  = iATR(InpSymbol, EntryTF, 14);
   hATR_M15 = iATR(InpSymbol, BiasTF, 14);
   hEMA_M15 = iMA (InpSymbol, BiasTF, BiasEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hADX_M15 = iADX(InpSymbol, BiasTF, ADXPeriod);

   if(hATR_M5==INVALID_HANDLE || hATR_M15==INVALID_HANDLE || hEMA_M15==INVALID_HANDLE || hADX_M15==INVALID_HANDLE)
   {
      Print("INIT FAILED: indicator handles invalid. err=",GetLastError());
      return INIT_FAILED;
   }

   MathSrand((uint)TimeLocal());
   EventSetTimer(5);

   Print("✅ Bari mode EA ONLINE: ",InpSymbol);
   SendTelegram("✅ Bari mode EA ONLINE: "+InpSymbol);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();

   if(hATR_M5!=INVALID_HANDLE)  IndicatorRelease(hATR_M5);
   if(hATR_M15!=INVALID_HANDLE) IndicatorRelease(hATR_M15);
   if(hEMA_M15!=INVALID_HANDLE) IndicatorRelease(hEMA_M15);
   if(hADX_M15!=INVALID_HANDLE) IndicatorRelease(hADX_M15);
}

//======================== MAIN =========================
void OnTick()
{
   if(IsQuietNow()){ r_quiet++; return; }
   if(!SpreadOk()) return;
   if(InCooldown()) return;
   if(InSetupPacing()) return;

   // evaluate only on new M5 bar (signal generation)
   if(!NewBar(EntryTF, g_lastBarTime)) return;

   if(!AllowReEntry && (HasOurOpenPosition() || OrdersTotal()>0)) return;
   if(SetupsTodayCount() >= MaxSetupsPerDay) return;

   Regime regime = GetRegime();

   Signal s; s.ok=false;

   // REAL: in range regime use range algo, otherwise use trend algo.
   if(regime==REGIME_RANGE)
   {
      if(!DetectSignalRange(s))
      {
         if(PrintRejectStats)
         {
            static int k1=0; k1++;
            if(k1%25==0)
            {
               PrintFormat("REJECTS: quiet=%d noBar=%d atr=%d struct=%d quality=%d noBOS=%d bias=%d far=%d rangeFail=%d stop=%d orders=%d spam=%d",
                           r_quiet,r_noBar,r_atr,r_struct,r_quality,r_noBOS,r_bias,r_far,r_range,r_stop,r_orders,r_spam);
            }
         }
         return;
      }
   }
   else
   {
      if(!DetectSignalTrend(s))
      {
         if(PrintRejectStats)
         {
            static int k2=0; k2++;
            if(k2%25==0)
            {
               PrintFormat("REJECTS: quiet=%d noBar=%d atr=%d struct=%d quality=%d noBOS=%d bias=%d far=%d rangeFail=%d stop=%d orders=%d spam=%d",
                           r_quiet,r_noBar,r_atr,r_struct,r_quality,r_noBOS,r_bias,r_far,r_range,r_stop,r_orders,r_spam);
            }
         }
         return;
      }
   }

   // anti-spam duplicate block
   if(IsSpamDuplicate(s)){ r_spam++; return; }

   // pacing
   g_nextSetupAllowed = TimeCurrent() + (datetime)(MinMinutesBetweenSetups*60);

   // remember last signal
   g_lastSignalTime = TimeCurrent();
   g_lastSignalBuy  = s.isBuy;
   g_lastZLow       = s.zLow;
   g_lastZHigh      = s.zHigh;

   // Telegram: instant side msg
   string regTxt = (s.regime==REGIME_RANGE ? "RANGE" : "TREND");
   string howTxt = (s.isMarket ? "NOW" : "LIMIT");
   SendTelegram("📌 ÚJ SETUP (bari)\n" + string(s.isBuy ? "BUY" : "SELL") + " ("+regTxt+"/"+howTxt+")");

   // details after random delay
   int maxD = (DetailsDelaySeconds<5 ? 5 : DetailsDelaySeconds);
   int delay = 5 + (int)MathRand() % (maxD - 4);
   g_detailsSendAt = TimeCurrent() + delay;
   g_pendingDetailsMsg = "📌 ÚJ SETUP – részletek\n" + SignalText(s);
   g_hasPendingDetails = true;

   if(!EnableAutoTrade) return;

   // execute depending on signal type
   bool ok=false;
   if(s.isMarket)
      ok = PlaceRangeMarket(s);
   else
      ok = PlaceTrendLimitLadder(s);

   if(!ok)
      Print("Order placement failed. err=",GetLastError());
}
//+------------------------------------------------------------------+
