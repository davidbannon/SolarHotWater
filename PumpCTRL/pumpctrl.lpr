program pumpctrl;

{ This app uses a Raspberry Pi Zero (2W) to control solar hot water pump.
    * i2c comms with an ADS1115 16bit A/D converter to read two Pt1000 sensors.
      This uses the default i2c pins, gpio2, sda1 and gpio3, scl.
    * Uses gpio14 port to switch the constant current between two sensors.
    * Has a socket client that sends status data to Logger on tcpip port _____.
    * Drives a small relay that switches 240v to the pump from gpio port15.
    * Turns the pump ON if solar collector is hotter than tank water.
    * Turns the pump ON if the solar collector is in danger of freezing.
    * Might read a DS18B20 temp sensor to monitor temp inside its box. (gpio4)
    * Reports its internal status when sent a particular signal.

    Physical Connector to Pi, I need 2x6pin to i/o board.

    1      - 3v3
         2 - 5v
    3      - SDA1   (ADS1115)
         4 - 5v
    5      - SCL1   (ADS1115)
         6 - GND
    7      - GPIO 4 (1w data line)
         8 - gpio14  (Switch const current, config out, low=??, high=??
    9      - GND
        10 - gpio15 (Ctrl relay, high=relay energised, pump on)
    11     - gpio17 (LED showing measure cycle)
        12 - gpio18 (spare)

    An LED in parellal with the relay coil shows pump is on.
    Another LED flashes on/off in each measure cycle.

    ------------------------------
    13- gpio27
    15- gpio22
    17- 3v3

    Remember gpio0-8 have default pull up resistor at power on. Others either
    high impediance or pull down resistor.

    }

{$mode objfpc}{$H+}

uses
    {$IFDEF UNIX}
    cthreads,
    {$ENDIF}
    Classes, SysUtils, CustApp, Raspi_Utils, i2cdev_ads1115,
    BaseUnix,       // for Signal Names
    ssockets        // for sending reports to (eg) logger
    ;


type TPumpState = (psOff, psCollectHot, psCollectFreeze);

type

    { TPumpCtrl }

    TPumpCtrl = class(TCustomApplication)
    protected
        procedure DoRun; override;
    public
        constructor Create(TheOwner : TComponent); override;
        destructor Destroy; override;
        procedure WriteHelp; virtual;
    private
        // Gets ADC and converts reading to milli degress C
        function ADC2Temp(SelectSensor : byte) : integer;
        // Called repeatedly until power off.
        procedure ControlLoop();
        procedure CleanUp();
//        // Handles, in this case, SIGINT (ie ctrl-c) and SIGTERM
//        procedure HandleSigInt(aSignal: LongInt); cdecl;
        // initialises and checks gpio, ADC, always good on x86_64
        function SetupSystems() : boolean;
        procedure SendReport(Msg : string);
    end;

{ TPumpCtrl }

const
                                // All temperatures here are in milli degrees C
  PumpOnDelta = 3000;           // Collector has to be this much hotter than tank to turn pump on
  PumpOffDelta = 2000;          // Collector has to be this much hotter than tank for Pump to remain on
  MaxTankTemp = 90000;          // Don't send any more hot water to tank !
  AntiFreezeTrigger = 3000;     // Colder than this, we must pump some warm water up
  AntiFreezeRelease = 4000;     // Warmer than this, we can stop pumping
  PumpPort = 15        ;        // gpio15
  PtSelectPort = 14;            //
  CyclesPerReport = 10;         // Number of cycles we do before reporting to logger (?)



var
  CollectorTemp, TankTemp : integer;   // temp in milli degrees C
  LEDOn : boolean = false;
  PumpState : TPumpState = psOff;
  ADS: TADS1115 = nil;
  ExitNow : boolean = false;           // set in signal handler, loops looks at it.
  DebugMode : boolean = false;
  x86Mode   : boolean = false;
  ReportIP : string = 'dell';       // thats my laptop, will set to logger later
  ReportPort : integer = 4100;      // Lets check thats appropriate
  PumpWasOn : boolean = false;      // true if pump was on, at some stage in last report cycle.

{ ============================================================================= }

  // Handles, in this case, SIGINT (ie ctrl-c) and SIGTERM
procedure HandleSigInt(aSignal: LongInt); cdecl;
begin
      case aSignal of
          SigInt : Writeln('Ctrl + C used, will clean up and shutdown.');
          SigTerm : writeln('TERM signal, will clean up and shutdown.');
      else
          writeln('Some signal received ??');
      end;
      ExitNow := True;        // Loop will see this and exit when it sees fit.
end;

function ReportString() : string;
begin
      Result := inttostr(CollectorTemp) + ',' + inttostr(TankTemp) + ',';
      case PumpState of
          psOff           : Result := Result + 'OFF';
          psCollectHot  : Result := Result + 'COLLECTHOT';
          psCollectFreeze : Result := Result + 'COLLECTFREEZE';
      end;
      if (PumpState in [ psCollectHot, psCollectFreeze]) or PumpWasOn then
          Result := Result + '+WasOn'
      else Result := Result + '+OFF';
      PumpWasOn := False;
end;

procedure TPumpCtrl.DoRun;
var
    ErrorMsg : String;
    CyclesToNextReport : integer = CyclesPerReport;
begin
    ErrorMsg := CheckOptions('hdr:x', 'help');
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
    if HasOption('d') then DebugMode := True;
    if HasOption('x') then x86Mode := True;
    if HasOption('r') then ReportIP := GetOptionValue('r');
    SetupSystems();
    repeat                                    // This is our main loop here.
        ControlLoop();
        dec(CyclesToNextReport);
        if CyclesToNextReport < 1 then begin
            SendReport(ReportString()+#10);
            CyclesToNextReport := CyclesPerReport;
        end;
        sleep(1000);
        if ExitNow then begin
            CleanUp();      // does not return
            writeln('Woops, this should not be here !');
        end;
    until False;

    // stop program loop if we get to here.
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
    writeln(' -x      Run in x86 mode, no Raspi Hardware');
end;

function TPumpCtrl.ADC2Temp(SelectSensor : byte) : integer;
var
      Counts : word;
      Temp : extended;
begin
      Counts := ADS.ADSread_SingleEnded(SelectSensor, True);
      writeln('ADC2Temp  Count = ', Counts);

//      Temp := (Counts-32000) / 0.1232;     // convert to milli degrees, float 8.116883
      Temp := (Counts-16000)*16.2338;
//      writeln('ADC2Temp Temp = ', round(Temp));

      if Temp < 0.0 then Temp := Temp * 0.987
      else if Temp < 10.0 then Temp := Temp * 0.987
      else if Temp < 50.0 then Temp := Temp * 0.99
      else if Temp < 80.0 then Temp := Temp * 0.995
      else if Temp < 130.0 then                                   // do nothing
      else Temp := Temp * 1.006;
      Result := round(Temp);
      // writeln('ADC2Temp Final Temp = ', Result);
end;

procedure TPumpCtrl.ControlLoop();             // This is called, repeatedly until told to quit.
begin
    if X86Mode then begin
        CollectorTemp := 2500;                                   // milli degree
        TankTemp := 31000;
    end else begin
        CollectorTemp := ADC2Temp(0);                             // milli degree
        TankTemp := ADC2Temp(1);
    end;

    if PumpState = psOff then begin                               // We may turn it on here
        if CollectorTemp < AntiFreezeTrigger then                 // Its freezing out there !
            PumpState := psCollectFreeze
        else if (CollectorTemp > (TankTemp + PumpOnDelta)) then   // Collector is hotter than tank.
                PumpState := psCollectHot;
    end else begin                                                // the pump is on, either psCollectFreeze or psCollectHot
        if (CollectorTemp < (TankTemp + PumpOffDelta))
                and (CollectorTemp > AntiFreezeRelease) then
            PumpState := psOff;
    end;

    if TankTemp > MaxTankTemp then                                // a safety measure
        PumpState := psOff;
    LEDOn := Not LEDOn;
    if DebugMode then
        writeln('TPumpCtrl.ControlLoop - Collect=', CollectorTemp, ' Tank=', TankTemp, ' PumpState=', ord(PumpState));
    if not x86Mode then
        SetRaspiPort(PumpPort, PumpState in [psCollectHot, psCollectFreeze]);  // Make it so
    if PumpState in [psCollectHot, psCollectFreeze] then
        PumpWasOn := True;
end;

procedure TPumpCtrl.CleanUp();
begin
    if not x86Mode then begin
        ControlPort(PtSelectPort, RasPiPortReset);
        ControlPort(PumpPort, RasPiPortReset);
        if ADS <> nil then ADS.Free;
    end;
    SendReport('QUIT'#10);
    Halt(1);
end;

function TPumpCtrl.SetupSystems() : boolean;
begin
    if X86Mode then exit(True);
    ADS := nil;
    LEDOn := False;
    if (ControlPort(PumpPort, RaspiPortWrite) in [RaspiPortSuccess, RaspiPortAlready])
        and SetRaspiPort(PumpPort, False)
        and (ControlPort(PtSelectPort,  RaspiPortWrite) in [RaspiPortSuccess, RaspiPortAlready])
        and SetRaspiPort(PtSelectPort, True) then
            ADS := TADS1115.Create()
    else begin
        writeln('Failed to initialise the i/o ports');
        exit(false);
    end;
    if ADS <> nil then begin
        ADS.conversionDelay := 150;        // see note top of i2cdev_ADS1115.pas
        ADS.samplepersecond := sps_16;
        ADS.gain := GAIN_TWO;              //  thats 0 to 2.048v
    end else begin
        writeln('Failed to initialise the ADC');
        exit(false);
    end;
    CollectorTemp := ADC2Temp(0);                // milli degree
    TankTemp := ADC2Temp(1);
    if (CollectorTemp < -20000) or (CollectorTemp > 200000)     // -20 to 200
            or (TankTemp < -20000) or (TankTemp > 200000) then begin
        writeln('Failed to get sensible numbers in the ADC');
        exit(false);
    end;
    Result := true;
end;

procedure TPumpCtrl.SendReport(Msg : string);
{ Report may look like -
  CollectorTemp,TankTemp,[OFF|COLLECTHOT|COLLECTFREEZE]+[WasOn|OFF]
  eg 34023,27450,COLLECTHOT+WasOn }
var
    Sock :TInetSocket = nil;
begin

    try try
        Sock :=  TInetSocket.Create(ReportIP, ReportPort, 1000);   // this triggers an exception if server not listening, Sock is NOT created
        Sock.Write(MSg[1],Length(Msg));
        if DebugMode then writeln('TPumpCtrl.SendReport msg sent ', Msg);
        except on E: ESocketError do
            writeln('Failed to connect to socket. ', E.Message);
        end;
    finally
            Sock.Free;
    end;
end;

var
    Application : TPumpCtrl;
begin
    if FpSignal(SigInt, @HandleSigInt) = signalhandler(SIG_ERR) then begin
        Writeln('Failed to install signal error: ', fpGetErrno);
        exit;
    end;
    if FpSignal(SigTerm, @HandleSigInt) = signalhandler(SIG_ERR) then begin
        Writeln('Failed to install signal error: ', fpGetErrno);
        exit;
    end;
    Application := TPumpCtrl.Create(nil);
    Application.Title := 'Pump Ctrl';
    Application.Run;
    Application.Free;
end.

