program Unit1;

{$mode ObjFPC}{$H+}


uses

    {$IFDEF UNIX}cthreads,{$ENDIF} Classes, SysUtils,
    CustApp, simpleipc;

type

 { Traspicapture }

 Traspicapture = class(TCustomApplication)
    protected
        procedure DoRun; override;
    public
        CommsServer : TSimpleIPCServer;
        constructor Create(TheOwner: TComponent); override;
        destructor Destroy; override;
    private
        procedure CommMessageReceived(Sender: TObject);
        procedure StartIPCServer();
  end;

var
Application: TRaspiCapture;

{ Traspicapture }


constructor Traspicapture.Create(TheOwner: TComponent);
begin
    inherited Create(TheOwner);
    StartIPCServer();
end;

destructor Traspicapture.Destroy;
begin
    inherited Destroy;
end;

procedure Traspicapture.DoRun;
begin
    inherited DoRun;
    writeln('Traspicapture.DoRun - starting');
    sleep(60000);
    writeln('Traspicapture.DoRun - ending');
    terminate;
end;

procedure Traspicapture.CommMessageReceived(Sender : TObject);
Var
    S, Sub1, Sub2 : String;
    L1, L2 : longint;
    i : integer = 0;
begin
    writeln('Here in CommMessageRecieved, a message was received');
    CommsServer .ReadMessage;
    S := CommsServer .StringMessage;
    // S should contain something like this '25750,25433,OFF'

    writeln('Traspicapture.CommMessageReceived received ' + S);


{    Sub1 := S.Substring(0, S.IndexOf(',')-1);
    if not TryStrToInt(Sub1, L1) then begin
        writeln('ERROR, ControlData has invalid data : [' + Sub1 + ']');
        exit;
    end;
    S := S.Remove(0, S.IndexOf(','));
    Sub2 := S.Substring(0, S.IndexOf(',')-1);

    if not TryStrToInt(Sub1, L2) then begin
        writeln('ERROR, ControlData has invalid data : [' + Sub2 + ']');
        exit;
    end;
    S := S.Remove(0, S.IndexOf(','));

    if S = '' then begin
        writeln('ERROR, ControlData has empty Pump');
        exit;
    end;
    while i < 3 do begin
        writeln('Traspicapture.CommMessageReceived - looking for a slot to save data');
        if not CtrlDataArray[i].Valid then begin
             CtrlDataArray[i].Valid := True;
             CtrlDataArray[i].Pump := S;
             CtrlDataArray[i].Collector := L1;
             CtrlDataArray[i].Tank := L2;
             writeln('Traspicapture.CommMessageReceived - found one');
             break;
        end;
        inc(i);
    end;                  }
    // if we did not find a free slot, just drop it on floor.
end;

procedure Traspicapture.StartIPCServer();
begin
        writeln('Traspicapture.StartIPCServer - starting IPC');
        CommsServer  := TSimpleIPCServer.Create(Nil);
        CommsServer.ServerID := 'raspicapture' {$ifdef UNIX} + '-' + GetEnvironmentVariable('USER'){$endif}; // on multiuser system, unique
        CommsServer.OnMessageQueued := @CommMessageReceived;
        CommsServer.Global:=True;                  // anyone can connect
        CommsServer.StartServer({$ifdef WINDOWS}False{$else}True{$endif});  // start listening, threaded
        //CommsServer.StartServer(false);
        if CommsServer.Threaded then writeln('Traspicapture.StartIPCServer - running threaded');
end;

begin
 Application:=Traspicapture.Create(nil);
 Application.Title:='raspicapture';

 Application.Run;

 writeln('Freeing the application.');
 Application.Free;
end.


