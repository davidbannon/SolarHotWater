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
  IPCServer = 'raspicapture';   // Plus unix user name

//type    TCaptureMesgProc = procedure(const St : string) of object;



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

implementation

uses pi_data_utils;

{ ------------------- TSocketThread -------------------------------------------}

procedure TSocketThread.Execute;
begin
    ServerApp := TINetServerApp.Create(ThePORT);
    //writeln('TSocketThread.Execute - will call ServerApp.Run');
    ServerApp.Run;
    //writeln('TSocketThread.Execute - ServerApp.Run has returned');
end;

constructor TSocketThread.Create(CreateSuspended: boolean);
begin
    inherited Create(CreateSuspended);
    FreeOnTerminate := False;           // I seem to need this, other wise thread terminates before it should.
end;

destructor TSocketThread.Destroy;
begin
    ServerApp.Free;
    inherited Destroy;
    if DoDebug then writeln('TSocketThread.Destroy - Finished');
end;


// -----------------  T I NetServer App ----------------------------------------

constructor TINetServerApp.Create(Port: longint);
begin
  writeln('raspicapture : Starting tcp socket on port ', Port, ' ctrl-c or kill to quit');
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
  // writeln('connecting ...');
  Repeat
    Count:=Data.Read(Buf[1], 255);
    if Count = 0 then break;
    SetLength(Buf, Count);
    if DoDebug then writeln('TINetServerApp.OnConnect - [', Buf, ']');
    ProcessMessage(Buf);
  Until (Count=0);                     // note we only expect one short message at a time.
  Data.Free;
  // FServer.StopAccepting;             // we want it to continue listening.
  //writeln('TINetServerApp.OnConnect - done.');
end;

procedure TINetServerApp.Run;
begin
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
    SubSt : string = '';
    Stage : integer = 1;
    LongArray : array [0..1] of longint;

    procedure UpdateCtrlArray(St : string);
    begin
        EnterCriticalSection(SocketCriticalSection);
        try
            if LockedByCapture then begin                 // will, occasionally happen, its OK if occasionally
                writeln('UpdateCtrlArray - Unable to lock CtrlDataArray, OK');
                exit;
            end;
            LockedBySocket := True;
            i := 0;
            if DoDebug then writeln('UpdateCtrlArray - looking for a slot ', LongArray[0]                                                           , ' ', LongArray[1], ' ', St);
            while i < 3 do begin
                if not CtrlDataArray[i].Valid then begin
                     CtrlDataArray[i].Pump := St;
                     CtrlDataArray[i].Collector := LongArray[0];
                     CtrlDataArray[i].Tank := LongArray[1];
                     CtrlDataArray[i].Valid := True;
                     if DoDebug then writeln('TINetServerApp.ProcessMessage - found a slot');
                     break;
                end;
                inc(i);
            end;
            // if we did not find a free slot, just drop it on floor.                // update CtrlDataArray
        finally
            LockedBySocket := False;
            LeaveCriticalSection(SocketCriticalSection);
        end;
    end;

begin
    while i < Mesg.Length do begin
        if Stage < 3 then begin
            if Mesg[i] in [ '0'..'9'] then
                SubSt := SubSt + Mesg[i]
            else if Mesg[i] = ',' then begin
                if not TryStrToInt(SubSt, LongArray[Stage-1]) then break;
                // writeln('TINetServerApp.ProcessMessage - Stage=', Stage, ' Long=', LongArray[Stage-1]);
                inc(Stage); SubSt := '';
            end else break;              // invalid data
            inc(i);  continue;
        end else begin                   // now pointing to string at end, deal with it.
            // writeln('TINetServerApp.ProcessMessage - calling updateCtrlArray ', LongArray[0], ' ', LongArray[1]);
            UpdateCtrlArray(copy(Mesg, i, 20));  // Pump State < 20
            exit;
        end;
    end;                                 // below here because of invalid data
    writeln('*** TINetServerApp.ProcessMessage - bad CtrlData string [' + Mesg + ']');
end;

end.



