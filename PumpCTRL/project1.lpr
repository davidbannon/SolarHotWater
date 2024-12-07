program project1;

{$mode objfpc}{$H+}

uses
    {$IFDEF UNIX}
    cthreads,
    {$ENDIF}
    Classes, SysUtils, CustApp
    { you can add units after this };

type

    { TPumpCtrl }

    TPumpCtrl = class(TCustomApplication)
    protected
        procedure DoRun; override;
    public
        constructor Create(TheOwner : TComponent); override;
        destructor Destroy; override;
        procedure WriteHelp; virtual;
    end;

{ TPumpCtrl }

var
    DebugMode : boolean = false;
    ReportIP : string = 'dell';       // thats my laptop, will set to logger later

procedure TPumpCtrl.DoRun;
var
    ErrorMsg : String;
begin
    // quick check parameters
    ErrorMsg := CheckOptions('hdr:', 'help');
    if ErrorMsg <> '' then begin
        ShowException(Exception.Create(ErrorMsg));
        Terminate;
        Exit;
    end;

    // parse parameters
    if HasOption('h', 'help') then begin
        WriteHelp;
        Terminate;
        Exit;
    end;

    if HasOption('d') then DebugMode := True;
    if HasOption('-r') then ReportIP := GetOptionValue('r');

    // stop program loop
    Terminate;
end;

constructor TPumpCtrl.Create(TheOwner : TComponent);
begin
    inherited Create(TheOwner);
    StopOnException := True;
end;

destructor TPumpCtrl.Destroy;
begin
    inherited Destroy;
end;

procedure TPumpCtrl.WriteHelp;
begin
    { add your help code here }
    writeln('Usage: ', ExeName, ' -h');
    writeln(' -d      Debug Mode');
    writeln(' -r ip   Report To');
end;

var
    Application : TPumpCtrl;
begin
    Application := TPumpCtrl.Create(nil);
    Application.Title := 'Pump Ctrl';
    Application.Run;
    Application.Free;
end.

