unit isock;
{$mode ObjFPC}{$H+}

{ Copyright David Bannon
  License:
  This code is licensed under MIT License, see https://opensource.org/license/mit
  or  https://spdx.org/licenses/MIT.html  SPDX short identifier: MIT
}

{ This unit will provide a thread that will monitor the isocket and respond when
  a message is received. The thread will create a INetServerApp, it sets up all
  the socket infrasture. When a message arrives, OnConnect is called, it reads
  the message, parses it. Then attemp to get a
  lock on the CtrlDataArray (using  LockedBySocket) if LockedByCapture permits.
  if lock is successful, will update array. If
  lock is unsuccessful, no problem, drop data on floor.
  CtrlDataArray, LockedBySocket and LockedByCapture are in pi_data_Utils.
  The message is three comma seperated integers.
  ,CollectorTemp,TankTemp,%Pump     (temps are in milli degrees, % in percentage points)


  History :
    2024-12-08  Now using data from PumpCtrl, now percent based.
}

interface

uses ssockets, Classes, sysutils {, BaseUnix};


const
  ThePort : integer=4100;

//type    TCaptureMesgProc = procedure(const St : string) of object;

type TCtrlData = record
    Collector : longint;
    Tank : longint;
    PercentPump : integer;
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
    LongArray : array [0..2] of longint;
    StArray : TStringArray;

    procedure UpdateCtrlArray();
    begin
        EnterCriticalSection(SocketCriticalSection);
        try
//            if LockedByCapture then begin           // will, occasionally happen, its OK if occasionally
//                writeln('ERROR UpdateCtrlArray - Unable to lock CtrlDataArray, OK');
//                exit;
//            end;
            if LongArray[2] > 100 then LongArray[2] := 100;                     // bug in ctrl sometimes gives 101%
            if DoDebug then writelog('NOTICE : TINetServerApp.ProcessMessage UpdateCtrlArray - looking for a slot '
                    + LongArray[0].ToString + ' ' + LongArray[1].ToString + ' ' + LongArray[1].ToString);
            while LockedByCapture do sleep(20);
            LockedBySocket := True;
            i := 0;
            while i < 3 do begin
                if not CtrlDataArray[i].Valid then begin
                     //CtrlDataArray[i].Pump := PumpSt;
                     //CtrlDataArray[i].PumpWas := WasSt;
                     CtrlDataArray[i].Collector   := LongArray[0];
                     CtrlDataArray[i].Tank        := LongArray[1];
                     CtrlDataArray[i].PercentPump := LongArray[2];
                     CtrlDataArray[i].Valid := True;
                     if DebugSock then writelog('NOTICE : TINetServerApp.ProcessMessage - found a slot');
                     // writeln('iSock -  UpdateCtrlArray. PercentPump is ', LongArray[2]);
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
    StArray := Mesg.Split(',');
    if length(StArray) > 2 then begin          // Not much of a sanity check but ...
        if TryStrToInt(StArray[0], LongArray[0])
            and TryStrToInt(StArray[1], LongArray[1])
            and TryStrToInt(StArray[2], LongArray[2])
            then begin                // OK, we have the three numbers.
                    UpdateCtrlArray();        // don't need those parameters
                exit;
            end;
    end;
    // Only get to here if things have gone hopelessly wrong.
    writelog('ERROR : TINetServerApp.ProcessMessage - bad CtrlData string [' + Mesg + ']');
end;

end.



