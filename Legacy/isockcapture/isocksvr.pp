Program server;


{
  Based on the FPC FCL TInetServer server program. This will listen on port 4100 till
  a client connects. It will receice the sent string, does not respond to the client.
  (but I wonder if it should....)
  Yet to happen -
  * The received string should be sent, via IPC, the the logger
  programme, 'capture' that runs on the Raspberry Pi 'logger'. Capture must be
  taught how to take such data and add it to the data it saves.
  * Slow it down, no point in pushing data to capture any faster than Capture
  save to disk. So, perhaps, run at about three times capture cycle rate. Let
  capture save and average three data points.
}

{$mode objfpc}{$H+}
uses ssockets, sysutils, BaseUnix, simpleipc;


const
  ThePort : integer=4100;
  IPCServer = 'raspicapture';   // Plus unix user name

Type

  { TINetServerApp }

  TINetServerApp = Class(TObject)
  Private
    FServer : TInetServer;
    function CanSendMessage(Msg: string): boolean;
  Public
    Constructor Create(Port : longint);
    Destructor Destroy;override;
    Procedure OnConnect (Sender : TObject; Data : TSocketStream);
    Procedure Run;
  end;


Constructor TInetServerApp.Create(Port : longint);
begin
  writeln('Starting on port ', Port, ' ctrl-c or kill to quit');
  FServer:=TINetServer.Create(Port);
  FServer.Linger := 1;
  FServer.OnConnect:=@OnConnect;
end;

Destructor TInetServerApp.Destroy;
begin
  writeln('cleaning up socket code');
  FServer.StopAccepting(false);
  FServer.Free;
end;

Procedure TInetServerApp.OnConnect (Sender : TObject; Data : TSocketStream);
Var Buf : ShortString='';
    Count : longint;
begin
  // writeln('connecting ...');
  Repeat
    Count:=Data.Read(Buf[1], 255);
    if Count = 0 then break;
    SetLength(Buf, Count);
    // Writeln('Server got : ', Buf, ' and count is ', Count);
    if CanSendMessage(Buf) then
        Writeln('Message received and Sent as IPC [' + Buf + ']')
    else Writeln('FAILED to Send as IPC');
  Until (Count=0) or (Pos('QUIT', Buf)<>0);
  Data.Free;
//  FServer.StopAccepting;             // we want it to continue listening.
end;

Procedure TInetServerApp.Run;
begin
    FServer.StartAccepting;            // This triggers its own loop, loops until FServer.StopAccepting;
end;

function TInetServerApp.CanSendMessage(Msg : string) : boolean;
var
    CommsClient : TSimpleIPCClient;
begin
    Result := False;
    try
        CommsClient  := TSimpleIPCClient.Create(Nil);
        CommsClient.ServerID := IPCServer {$ifdef UNIX} + '-' + GetEnvironmentVariable('USER'){$endif}; // on multiuser system, unique
        if CommsClient.ServerRunning then begin
            CommsClient.Active := true;
            CommsClient.SendStringMessage(Msg);
            CommsClient.Active := false;
            Result := True;
            // writeln('TInetServerApp.CanSendMessage - IPC sent ' + Msg);
        end;
    finally
        freeandnil(CommsClient);
    end;
end;

Var
  Application : TInetServerApp;

procedure HandleSigInt(aSignal: LongInt); cdecl;
begin
  case aSignal of
    SigInt : Writeln('Ctrl + C used');
    SigTerm : writeln('TERM signal');
  else
    writeln('Some signal received ??');
  end;
  Application.free;
  Halt(1);
end;

begin
  if FpSignal(SigInt, @HandleSigInt) = signalhandler(SIG_ERR) then begin
    Writeln('Failed to install signal error: ', fpGetErrno);
    Halt(1);
  end;
  if FpSignal(SigTerm, @HandleSigInt) = signalhandler(SIG_ERR) then begin
    Writeln('Failed to install signal error: ', fpGetErrno);
    Halt(1);
  end;


  Application:=TInetServerApp.Create(ThePort);
  try try
    Application.Run;
  except on
    ESocketError do begin
        writeln('Sorry, cannot bind to socket with port ' + IntToStr(ThePort));
  end
  end;
  finally
        Application.Free;
  end;
end.
