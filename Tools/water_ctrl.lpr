program water_ctrl;

{$mode objfpc}{$H+}

uses
    {$IFDEF UNIX}
    cthreads,
    {$ENDIF}
    Classes, SysUtils, CustApp, Raspi_Utils, pi_data_utils, baseunix;


type

    { Twater_ctrl }

    Twater_ctrl = class(TCustomApplication)
    protected
        procedure DoRun; override;
    public
        constructor Create(TheOwner : TComponent); override;
        destructor Destroy; override;
        procedure WriteHelp; virtual;
        procedure WaterOn(Minutes : string);
    end;

{ Twater_ctrl }

var
    CurrentPort : integer = PIN_WATER_1;    // Alt is PIN_WATER_2   = 22
    ExitNow : boolean = false;              // used, eg ctrl-c, set in signal handler, acted on in WaterOn()

procedure Twater_ctrl.DoRun;
var
    ErrorMsg : String;
begin
    // quick check parameters
    ErrorMsg := CheckOptions('hAt:R', 'help');
    if ErrorMsg <> '' then begin
        ShowException(Exception.Create(ErrorMsg));
        Terminate;
        Exit;
    end;
    if HasOption('h', 'help') then begin
        WriteHelp;
        Terminate;
        Exit;
    end;
    if HasOption('R') then begin
        ControlPort(PIN_WATER_1, RaspiPortReset);
        ControlPort(PIN_WATER_2, RaspiPortReset);
    end;
    if HasOption('A') then CurrentPort := PIN_WATER_2;
    if HasOption('t') then WaterOn(GetOptionValue('t'));
    Terminate;
end;

constructor Twater_ctrl.Create(TheOwner : TComponent);
begin
    inherited Create(TheOwner);
    StopOnException := True;
end;

destructor Twater_ctrl.Destroy;
begin
    inherited Destroy;
end;

procedure Twater_ctrl.WriteHelp;
begin
    { add your help code here }
    writeln('Usage: ', ExeName, ' -h');
    writeln(' -A          Use Alt water system, east end of house');
    writeln(' -t Minutes  Turn water on for indicated minutes');
    writeln(' -R          Reset both ports (probably not necessary)');
end;

procedure Twater_ctrl.WaterOn(Minutes : string);
var Mins : integer;
begin
    try
        Mins := strtoint(Minutes);
        except on EConvertError do begin
            writeln('Error, ', Minutes, ' is not a usable number.');
            exit;
        end;
    end;
    ControlPort(CurrentPort, RaspiPortWrite);
    Mins := Mins * 60;
    SetRaspiPort(CurrentPort, True);
    while Mins > 0 do begin
        sleep(1000);
        if ExitNow then break;
        dec(Mins);
    end;
    ControlPort(CurrentPort, RaspiPortReset);
end;


// Handles, in this case, SIGINT (ie ctrl-c) and SIGTERM
procedure HandleSigInt(aSignal: LongInt); cdecl;
begin
    case aSignal of
        SigInt : Writeln('Ctrl + C used, will clean up and shutdown.');
        SigTerm : writeln('TERM signal, will clean up and shutdown.');
    else
        writeln('Some signal received ??');
    end;
    ExitNow := True;        // Watering Loop will see this and exit when it sees fit.
end;

var
    Application : Twater_ctrl;
begin
    if FpSignal(SigInt, @HandleSigInt) = signalhandler(SIG_ERR) then begin
        Writeln('Failed to install signal error: ', fpGetErrno);
        exit;
    end;
    if FpSignal(SigTerm, @HandleSigInt) = signalhandler(SIG_ERR) then begin
        Writeln('Failed to install signal error: ', fpGetErrno);
        exit;
    end;
    Application := Twater_ctrl.Create(nil);
    Application.Title := 'Water Ctrl';
    Application.Run;
    Application.Free;
end.

