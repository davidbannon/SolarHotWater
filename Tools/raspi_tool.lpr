program raspi_tool;

{$mode objfpc}{$H+}

{ Its necessary, on the pi, to insert the two necessary kernel modules as root -

modprobe w1_gpio
modprobe w1_therm

Easy to put these into (an executable) /etc/rc.local
}


uses
    {$IFDEF UNIX}
    cthreads,
    {$ENDIF}
    Classes, SysUtils, CustApp, Raspi_Utils, serial;

type

    { TRasPiTool }

    TRasPiTool = class(TCustomApplication)
    protected
        procedure DoRun; override;
    public
        constructor Create(TheOwner : TComponent); override;
        destructor Destroy; override;
        procedure WriteHelp; virtual;
        function PortOptionToInt(Opt : char) : integer;
    end;

{ TRasPiTool }



procedure ListTempSensors();
begin
    ShowSensorInformation();
end;

function TRasPiTool.PortOptionToInt(Opt : char) : integer;  // ToDo : remove this and use function un raspi_utils
begin
    try
        Result := strtoint(GetOptionValue(Opt));
        except on EConvertError do begin
                writeln('Cannot convert ',GetOptionValue(Opt), ' to a port number (0..', MaxPortNumb, ')');
                Terminate;
                exit;
                end;
    end;
    if (Result < 0) or (Result > MaxPortNumb) then begin
        writeln('Error, ', Result, ' is not a valid port number');
        Terminate;
        exit;
    end;
end;

procedure TRasPiTool.DoRun;
var
    ErrorMsg : String;
    SensorID : string;
    Port : integer;
    Res : TRaspiPortStatus;
begin
    // quick check parameters
    ErrorMsg := CheckOptions('hlr:s:S:c:t:', 'help');
    if ErrorMsg <> '' then begin
        // ShowException(Exception.Create(ErrorMsg));
        writeln(ErrorMsg);
        Terminate;
        Exit;
    end;

    // parse parameters
    if HasOption('h', 'help') then begin
        WriteHelp;
        Terminate;
        Exit;
    end;

    if HasOption('l') then begin
        ListTempSensors();
        Terminate;
        exit;
    end;

    // Below here, gpio functions.

    if RasPi_Utils_Error <> '' then begin
        writeln('Raspi_Utils report error - ' + Get_RasPi_Utils_Error());
        Terminate;
        exit;
    end;



    if HasOption('r') then begin
//        Port := GetOptionValue('r');
//        writeln('Port gpio' + Port + ' = ' + booltostr(SetRasPiPort(Port), true));
        Terminate;
        exit;
    end;

    if HasOption('s') then begin
        Port := PortOptionToInt('s');
        Res := ControlPort(Port, RaspiPortWrite);
        if Res in [RaspiPortAlready, RaspiPortSuccess] then begin
            if not SetRaspiPort(Port, False) then
                writeln('Error writing to gpio', Port);
        end else begin
            writeln('Unable to set gpio', Port, ' to write mode')
        end;
        Terminate;
        exit;
    end;

    if HasOption('S') then begin
        Port := PortOptionToInt('S');
        Res := ControlPort(Port, RaspiPortWrite);
        if Res in [RaspiPortAlready, RaspiPortSuccess] then begin
            if not SetRaspiPort(Port, True) then
                writeln('Error writing to gpio', Port);
        end else begin
            writeln('Unable to set gpio', Port, ' to write mode')
        end;
        Terminate;
        exit;
    end;
    if HasOption('c') then begin
        Port := PortOptionToInt('c');
        Res := ControlPort(Port, RaspiPortReset);
        if not (Res in [RaspiPortAlready, RaspiPortSuccess]) then begin
            writeln('Unable to reset gpio', Port)
        end;
        Terminate;
        exit;
    end;

    if HasOption('t') then begin
        SensorID := GetOptionValue('t');
        writeln(ReadDS18B20(SensorID));
        Terminate;
        exit;
    end;


    WriteHelp;
    // stop program loop
    Terminate;
end;

constructor TRasPiTool.Create(TheOwner : TComponent);
begin
    inherited Create(TheOwner);
    StopOnException := True;
end;

destructor TRasPiTool.Destroy;
begin
    inherited Destroy;
end;

procedure TRasPiTool.WriteHelp;
begin
    { add your help code here }
    writeln('Usage: ', ExeName, ' -h');
    writeln('This tool requires w1_gpio and w1_therm kernel modules.');
    writeln(' -l       List Temp Sensors Present');
    writeln(' -t  28-...  Show a Sensor Temperature');
    writeln(' -r  port Read gpio port status.');
    writeln(' -s  port Set port Low');
    writeln(' -S  port Set port High');
    writeln(' -c  port Clear port, un-export it');
//    writeln(' -e       List Exported gpio ports');   // ToDo : scan /sys/class/gpio/gpio* ....
    writeln('Port always means gpio number, ie 27');
    writeln('Raspi_Utils reports gpio base is ', GPIO_Base);
end;

var
    Application : TRasPiTool;
begin
    Application := TRasPiTool.Create(nil);
    Application.Title := 'Raspi Tool';
    Application.Run;
    Application.Free;
end.

