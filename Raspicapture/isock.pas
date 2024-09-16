unit isock;
{$mode ObjFPC}{$H+}

{ This unit will provide a thread that will monitor the isocket and respond when
  a message is received. The thread will create a INetServerApp, it sets up all
  the socket infrasture. When a message arrives, OnConnect is called, it reads
  the message, parses it. Then attemp to get a
  lock on the CtrlDataArray (using  LockedBySocket) if LockedByCapture permits.
  if lock is successful, will update array. If
  lock is unsuccessful, no problem, drop data on floor.
  CtrlDataArray, LockedBySocket and LockedByCapture are in pi_data_Utils.

}

interface

uses ssockets, Classes, sysutils {, BaseUnix};


const
  ThePort : integer=4100;

//type    TCaptureMesgProc = procedure(const St : string) of object;

type TCtrlData = record
    Collector : longint;
    Tank : longint;
    Pump : string;
    PumpWas : string;
    Valid : boolean;
    end;

Type             { TINetServerApp }
    TINetServerApp = Class(TObject)
    Private
        SocketCriticalSection: TRTLCriticalSection;   // we use RTL CriticalSection code

    Public
        FServer : TInetServer;
        //MessageProcedure : TCaptureMesgProc;
        Constructor Create(Port : longint);
        Destructor Destroy;override;
        Procedure OnConnect (Sender : TObject; Data : TSocketStream);
        Procedure Run;
        procedure ProcessMessage(Mesg: string);
end;


Type              { TSocketThread }
    TSocketThread = class(TThread)
        private

        protected
            procedure Execute; override;
        public
            ServerApp : TINetServerApp;
            //MessageProcedure : TCaptureMesgProc;
            Constructor Create(CreateSuspended : boolean);
            Destructor Destroy;override;
    end;

var
    CtrlDataArray : array [0..2] of TCtrlData;   // shared with raspicapture, protected by LockedByCapture, LockedBySocket
    DebugSock : boolean = false;

implementation

uses pi_data_utils;

{$define DoDebug}       // will trigger some writeln(), probably to nohup.out ?

{ ------------------- TSocketThread -------------------------------------------}



procedure TSocketThread.Execute;
begin
    ServerApp := TINetServerApp.Create(ThePORT);
    ServerApp.Run;
end;

constructor TSocketThread.Create(CreateSuspended: boolean);
begin
    inherited Create(CreateSuspended);
    if DebugSock then writelog('NOTICE : TSocketThread.Create');
    FreeOnTerminate := False;           // I seem to need this, other wise thread terminates before it should.
end;

destructor TSocketThread.Destroy;
begin
    ServerApp.Free;
    inherited Destroy;
    if DoDebug then writelog('NOTICE : TSocketThread.Destroy - Finished');
end;


// -----------------  T I NetServer App ----------------------------------------

constructor TINetServerApp.Create(Port: longint);
begin
  writelog('raspicapture Starting tcp socket on port ' + Port.ToString + ' ctrl-c or kill to quit');
  writeln('raspicapture Starting tcp socket on port ' + Port.ToString + ' ctrl-c or kill to quit');
  FServer:=TINetServer.Create(Port);
  FServer.Linger := 1;
  FServer.OnConnect:=@OnConnect;

end;

destructor TINetServerApp.Destroy;
begin
  if FServer = nil then exit;
  FServer.StopAccepting(true);                // True gives us a quick shutdown at end of app
  FServer.Free;
  FServer := Nil;
end;

procedure TINetServerApp.OnConnect(Sender: TObject; Data: TSocketStream);
Var Buf : ShortString='';
    Count : longint;
begin
  if DebugSock then writelog('NOTICE : TINetServerApp.OnConnect connecting ...');
  Repeat
    Count:=Data.Read(Buf[1], 255);
    if Count = 0 then break;
    SetLength(Buf, Count);
    // if DebugSock then writeln('TINetServerApp.OnConnect - [', Buf, ']');
    ProcessMessage(Buf);
  Until (Count=0);                     // note we only expect one short message at a time.
  Data.Free;
  // FServer.StopAccepting;             // we want it to continue listening.
end;

procedure TINetServerApp.Run;
begin
    if DebugSock then writelog('NOTICE : TINetServerApp.Run');
    try
        FServer.StartAccepting;            // This runs a loop until FServer.StopAccepting;
    except on E: ESocketError do begin
                    writeln('*** TINetServerApp.Run - Failed to bind socket to port.');
                    writeln('*** Check for another app using port : ', ThePort);
                    writeln('*** We continue but data from Controller not available');
            end;
//    except on E: Exception do writeln('Exception down in TINetServerApp.Run ', E.Message, ' ', E.ClassName);
    end;
end;

procedure TINetServerApp.ProcessMessage(Mesg : string);
var
    i : integer = 1;
//    SubSt : string = '';
//    Stage : integer = 1;
    LongArray : array [0..1] of longint;
    StArray : TStringArray;

    procedure UpdateCtrlArray(PumpSt, WasSt : string);
    begin
        EnterCriticalSection(SocketCriticalSection);
        try
//            if LockedByCapture then begin           // will, occasionally happen, its OK if occasionally
//                writeln('ERROR UpdateCtrlArray - Unable to lock CtrlDataArray, OK');
//                exit;
//            end;
            while LockedByCapture do sleep(20);
            LockedBySocket := True;
            i := 0;
            if DoDebug then writelog('NOTICE : TINetServerApp.ProcessMessage UpdateCtrlArray - looking for a slot '
                    + LongArray[0].ToString + ' ' + LongArray[1].ToString + ' ' + PumpSt);
            while i < 3 do begin
                if not CtrlDataArray[i].Valid then begin
                     CtrlDataArray[i].Pump := PumpSt;
                     CtrlDataArray[i].PumpWas := WasSt;
                     CtrlDataArray[i].Collector := LongArray[0];
                     CtrlDataArray[i].Tank := LongArray[1];
                     CtrlDataArray[i].Valid := True;
                     if DebugSock then writelog('NOTICE : TINetServerApp.ProcessMessage - found a slot');
                     break;
                end;
                inc(i);
            end;
            // if we did not find a free slot, just drop it on floor.
        finally
            LockedBySocket := False;
            LeaveCriticalSection(SocketCriticalSection);
        end;
    end;

begin
(*    if DebugSock then writelog('NOTICE : isock : processing message');
    while i < Mesg.Length do begin
        if Stage < 3 then begin                         // Stage one and two are strings that should convert to int
            if Mesg[i] in [ '0'..'9'] then
                SubSt := SubSt + Mesg[i]                // collect char, one by one.
            else if Mesg[i] = ',' then begin            // hit seperator, process !
                if not TryStrToInt(SubSt, LongArray[Stage-1]) then break;
                // writeln('TINetServerApp.ProcessMessage - Stage=', Stage, ' Long=', LongArray[Stage-1]);
                inc(Stage);
                SubSt := '';
            end else break;              // invalid data
            inc(i);
            continue;
        end else begin                   // now pointing to string at end, deal with it.
            // writeln('TINetServerApp.ProcessMessage - calling updateCtrlArray ', LongArray[0], ' ', LongArray[1]);
            UpdateCtrlArray(copy(Mesg, i, 20));  // Pump State < 20
            exit;
        end;
    end;                                 // below here because of invalid data
    writelog('ERROR : TINetServerApp.ProcessMessage - bad CtrlData string [' + Mesg + ']');         *)

    StArray := Mesg.Split(',');
    if length(StArray) > 2 then begin          // Not much of a sanity check but ...
        if TryStrToInt(StArray[0], LongArray[0])
            and TryStrToInt(StArray[1], LongArray[1]) then begin                // OK, we have the two numbers.
                if  length(StArray) > 3 then
                    UpdateCtrlArray(StArray[2], StArray[3])
                else
                    UpdateCtrlArray(StArray[2], '');
                exit;
            end;
    end;
    // Only get to here is things have gone hopelessly wrong.
    writelog('ERROR : TINetServerApp.ProcessMessage - bad CtrlData string [' + Mesg + ']');
end;

end.



