/**
 * Aktualisiert die lokale, dateibasierte Accounthistory. Gew�hrung oder R�ckzug von Margin Credits werden nicht gespeichert.
 */
#include <stddefines.mqh>
int   __INIT_FLAGS__[] = {INIT_NO_BARS_REQUIRED};
int __DEINIT_FLAGS__[];
#include <core/script.mqh>
#include <stdfunctions.mqh>
#include <rsfLibs.mqh>


/**
 * Main-Funktion
 *
 * @return int - Fehlerstatus
 */
int onStart() {
   int account = GetAccountNumber();
   if (!account) {
      PlaySoundEx("Windows Notify.wav");
      MessageBox("No trade server connection.", __NAME(), MB_ICONEXCLAMATION|MB_OK);
      return(SetLastError(ERR_NO_CONNECTION));
   }


   // (1) Sortierschl�ssel aller geschlossenen Tickets auslesen und nach {CloseTime, OpenTime, Ticket} sortieren
   int orders = OrdersHistoryTotal();
   int sortKeys[][3];
   ArrayResize(sortKeys, orders);

   for (int i=0; i < orders; i++) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) {            // FALSE: w�hrend des Auslesens wurde der Anzeigezeitraum der History verk�rzt
         ArrayResize(sortKeys, i);
         orders = i;
         break;
      }
      sortKeys[i][0] = OrderCloseTime();
      sortKeys[i][1] = OrderOpenTime();
      sortKeys[i][2] = OrderTicket();
   }
   SortClosedTickets(sortKeys);


   // (2) Tickets sortiert einlesen
   int      tickets     [];
   int      types       [];
   string   symbols     [];
   double   lotSizes    [];
   datetime openTimes   [];
   datetime closeTimes  [];
   double   openPrices  [];
   double   closePrices [];
   double   stopLosses  [];
   double   takeProfits [];
   double   commissions [];
   double   swaps       [];
   double   netProfits  [];
   double   grossProfits[];
   double   balances    [];
   int      magicNumbers[];
   string   comments    [];

   for (i=0; i < orders; i++) {
      int ticket = sortKeys[i][2];
      if (!SelectTicket(ticket, "onStart(1)"))
         return(last_error);
      int type = OrderType();                                                       // gecancelte Orders und Margin Credits �berspringen
      if (type==OP_BUYLIMIT || type==OP_SELLLIMIT || type==OP_BUYSTOP || type==OP_SELLSTOP || type==OP_CREDIT)
         continue;
      ArrayPushInt   (tickets     , ticket            );
      ArrayPushInt   (types       , type              );
      ArrayPushString(symbols     , OrderSymbol()     ); if (type != OP_BALANCE) symbols[ArraySize(symbols)-1] = GetStandardSymbol(OrderSymbol());
      ArrayPushDouble(lotSizes    , ifDouble(type==OP_BALANCE, 0, OrderLots()));    // OP_BALANCE: OrderLots() enth�lt f�lschlich 0.01
      ArrayPushInt   (openTimes   , OrderOpenTime()   );
      ArrayPushInt   (closeTimes  , OrderCloseTime()  );
      ArrayPushDouble(openPrices  , OrderOpenPrice()  );
      ArrayPushDouble(closePrices , OrderClosePrice() );
      ArrayPushDouble(stopLosses  , OrderStopLoss()   );
      ArrayPushDouble(takeProfits , OrderTakeProfit() );
      ArrayPushDouble(commissions , OrderCommission() );
      ArrayPushDouble(swaps       , OrderSwap()       );
      ArrayPushDouble(netProfits  , OrderProfit()     );
      ArrayPushDouble(grossProfits, 0                 );
      ArrayPushDouble(balances    , 0                 );
      ArrayPushInt   (magicNumbers, OrderMagicNumber());
      ArrayPushString(comments    , OrderComment()    );
   }
   orders = ArraySize(tickets);


   // (3) Hedges korrigieren: relevante Daten der ersten Position zuordnen und hedgende Position korrigieren
   for (i=0; i < orders; i++) {
      if ((types[i]==OP_BUY || types[i]==OP_SELL) && EQ(lotSizes[i], 0)) {    // lotSize = 0.00: Hedge-Position
         // TODO: Pr�fen, wie sich OrderComment() bei custom comments verh�lt.

         if (!StrStartsWithI(comments[i], "close hedge by #"))
            return(catch("onStart(2)  #"+ tickets[i] +" - unknown comment for assumed hedging position: \""+ comments[i] +"\"", ERR_RUNTIME_ERROR));

         // Gegenst�ck der Order suchen
         ticket = StrToInteger(StringSubstr(comments[i], 16));
         for (int n=0; n < orders; n++) {
            if (tickets[n] == ticket)
               break;
         }
         if (n == orders) return(catch("onStart(3)  cannot find counterpart for hedging position #"+ tickets[i] +": \""+ comments[i] +"\"", ERR_RUNTIME_ERROR));
         if (i == n     ) return(catch("onStart(4)  both hedged and hedging position have the same ticket #"+ tickets[i] +": \""+ comments[i] +"\"", ERR_RUNTIME_ERROR));

         int first  = Min(i, n);
         int second = Max(i, n);

         // Orderdaten korrigieren
         lotSizes[i] = lotSizes[n];                                           // lotSizes[i] == 0 korrigieren
         if (i == first) {
            commissions[first ] = commissions[second];                        // alle Transaktionsdaten in der ersten Order speichern
            swaps      [first ] = swaps      [second];
            netProfits [first ] = netProfits [second];
            commissions[second] = 0;
            swaps      [second] = 0;
            netProfits [second] = 0;
         }
         comments[first ] = ifString(comments[n]=="partial close", "partial close", "closed") +" by hedge #"+ tickets[second];
         comments[second] = "hedge for #"+ tickets[first];
      }
   }


   // (4) letztes gespeichertes Ticket und entsprechende AccountBalance ermitteln
   string history[][AH_COLUMNS];

   int error = GetAccountHistory(account, history);
   if (IsError(error)) /*&&*/ if (error!=ERR_CANNOT_OPEN_FILE)                // ERR_CANNOT_OPEN_FILE ignorieren => History ist leer
      return(catch("onStart(5)", error));

   int    lastTicket;
   double lastBalance;
   int    histSize = ArrayRange(history, 0);

   if (histSize > 0) {
      lastTicket  = StrToInteger(history[histSize-1][I_AH_TICKET ]);
      lastBalance = StrToDouble (history[histSize-1][I_AH_BALANCE]);
      //debug("onStart()  lastTicket = "+ lastTicket +"   lastBalance = "+ NumberToStr(lastBalance, ", .2"));
   }
   if (!orders) {
      if (!EQ(lastBalance, AccountBalance())) {
         PlaySoundEx("Windows Notify.wav");
         MessageBox("Balance mismatch, more history data needed.", __NAME(), MB_ICONEXCLAMATION|MB_OK);
         return(catch("onStart(6)"));
      }
      PlaySoundEx("Windows Confirm.wav");
      MessageBox("History is up-to-date.", __NAME(), MB_ICONINFORMATION|MB_OK);
      return(catch("onStart(7)"));
   }


   // (5) Index des ersten, neu zu speichernden Tickets ermitteln
   int iFirstTicketToSave = 0;
   if (histSize > 0) {
      for (i=0; i < orders; i++) {
         if (tickets[i] == lastTicket) {
            iFirstTicketToSave = i+1;
            break;
         }
      }
   }
   if (iFirstTicketToSave == orders) {                                     // alle Tickets sind bereits in der CSV-Datei vorhanden
      if (!EQ(lastBalance, AccountBalance()))
         return(catch("onStart(8)  data error: balance mismatch between history file ("+ NumberToStr(lastBalance, ", .2") +") and account ("+ NumberToStr(AccountBalance(), ", .2") +")", ERR_RUNTIME_ERROR));
      PlaySoundEx("Windows Confirm.wav");
      MessageBox("History is up-to-date.", __NAME(), MB_ICONINFORMATION|MB_OK);
      return(catch("onStart(9)"));
   }


   // (6) GrossProfit und Balance berechnen und mit dem letzten gespeicherten Wert abgleichen
   for (i=iFirstTicketToSave; i < orders; i++) {
      grossProfits[i] = NormalizeDouble(netProfits[i] + commissions[i] + swaps[i], 2);
      if (types[i] == OP_CREDIT)
         grossProfits[i] = 0;                                              // Credit-Betr�ge ignorieren (falls sie hier �berhaupt auftauchen)
      balances[i]     = NormalizeDouble(lastBalance + grossProfits[i], 2);
      lastBalance     = balances[i];
   }
   if (!EQ(lastBalance, AccountBalance())) {
      if (__LOG()) log("onStart(11)  balance mismatch: calculated = "+ NumberToStr(lastBalance, ", .2") +"   current = "+ NumberToStr(AccountBalance(), ", .2"));
      PlaySoundEx("Windows Notify.wav");
      MessageBox("Balance mismatch, more history data needed.", __NAME(), MB_ICONEXCLAMATION|MB_OK);
      return(catch("onStart(12)"));
   }


   // (7) CSV-Datei erzeugen
   string filename = ShortAccountCompany() +"/"+ account +"_account_history.csv";

   if (ArrayRange(history, 0) == 0) {
      // (7.1) Datei erzeugen (und ggf. auf L�nge 0 zur�cksetzen)
      int hFile = FileOpen(filename, FILE_CSV|FILE_WRITE, '\t');
      if (hFile < 0)
         return(catch("onStart(13)->FileOpen()"));

      // Header schreiben
      string header = "# Account history for "+ ifString(IsDemoFix(), "demo", "real")  +" account #"+ account +" (name: "+ AccountName() +") at "+ AccountCompany() +" (server: "+ GetServerName() +")\n"
                    + "#";
      if (FileWrite(hFile, header) < 0) {
         catch("onStart(14)->FileWrite()");
         FileClose(hFile);
         return(last_error);
      }
      if (FileWrite(hFile, "Ticket","OpenTime","OpenTimestamp","Description","Type","Size","Symbol","OpenPrice","StopLoss","TakeProfit","CloseTime","CloseTimestamp","ClosePrice","MagicNumber","Commission","Swap","NetProfit","GrossProfit","Balance","Comment") < 0) {
         catch("onStart(15)->FileWrite()");
         FileClose(hFile);
         return(last_error);
      }
   }

   else {
      // (7.2) CSV-Datei enth�lt bereits Daten, �ffnen und FilePointer ans Ende setzen
      hFile = FileOpen(filename, FILE_CSV|FILE_READ|FILE_WRITE, '\t');
      if (hFile < 0)
         return(catch("onStart(16)->FileOpen()"));
      if (!FileSeek(hFile, 0, SEEK_END)) {
         catch("onStart(17)->FileSeek()");
         FileClose(hFile);
         return(last_error);
      }
   }


   // (8) Orderdaten schreiben
   for (i=iFirstTicketToSave; i < orders; i++) {
      if (!tickets[i])                                               // verworfene Hedge-Orders �berspringen
         continue;

      string strType        = OperationTypeDescription(types[i]);
      string strSize        = ifString(EQ(lotSizes[i], 0), "", NumberToStr(lotSizes[i], ".+"));

      string strOpenTime    = TimeToStr(openTimes [i], TIME_FULL);
      string strCloseTime   = TimeToStr(closeTimes[i], TIME_FULL);

      string strOpenPrice   = ifString(EQ(openPrices [i], 0), "", NumberToStr(openPrices [i], ".2+"));
      string strClosePrice  = ifString(EQ(closePrices[i], 0), "", NumberToStr(closePrices[i], ".2+"));
      string strStopLoss    = ifString(EQ(stopLosses [i], 0), "", NumberToStr(stopLosses [i], ".2+"));
      string strTakeProfit  = ifString(EQ(takeProfits[i], 0), "", NumberToStr(takeProfits[i], ".2+"));

      string strCommission  = DoubleToStr(commissions [i], 2);
      string strSwap        = DoubleToStr(swaps       [i], 2);
      string strNetProfit   = DoubleToStr(netProfits  [i], 2);
      string strGrossProfit = DoubleToStr(grossProfits[i], 2);
      string strBalance     = DoubleToStr(balances    [i], 2);

      string strMagicNumber = ifString(!magicNumbers[i], "", magicNumbers[i]);

      if (FileWrite(hFile, tickets[i], strOpenTime, openTimes[i], strType, types[i], strSize, symbols[i], strOpenPrice, strStopLoss, strTakeProfit, strCloseTime, closeTimes[i], strClosePrice, strMagicNumber, strCommission, strSwap, strNetProfit, strGrossProfit, strBalance, comments[i]) < 0) {
         catch("onStart(18)->FileWrite()");
         FileClose(hFile);
         return(last_error);
      }
   }
   FileClose(hFile);

   PlaySoundEx("Windows Confirm.wav");
   MessageBox("History successfully updated.", __NAME(), MB_ICONINFORMATION|MB_OK);
   return(last_error);
}
