program pumpctrl;

{ Copyright David Bannon
  License:
This code is licensed under MIT License, see https://opensource.org/license/mit
or  https://spdx.org/licenses/MIT.html  SPDX short identifier: MIT
}

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

    40p Physical Connector to Pi, I need 2x6pin to i/o board.             i/O board

    1      - 3v3                                                           n.c.
         2 - 5v                                                            D
    3      - SDA1   (ADS1115), gpio2
         4 - 5v
    5      - SCL1   (ADS1115), gpio3
         6 - GND                                                           O, G, F
    7      - GPIO 4 (1w data line)                                         n.c.
         8 - gpio14  (Switch const I, Hi to Collector, Lo to Tank)         J
    9      - GND                                                           O, G, F
        10 - gpio15 (Ctrl relay, high=relay energised, pump on)            N
    11     - gpio17 (LED showing measure cycle)                            n.c.
        12 - gpio18 (spare)                                                n.c.
                                                                         No Connect - E, K
                                                                         Sensor In  - H, I

    An LED in parellal with the relay coil shows pump is on.
    Another LED flashes on/off in each measure cycle.

    ------------------------------
    13- gpio27
    15- gpio22
    17- 3v3

    Remember gpio0-8 have default pull up resistor at power on. Others either
    high impediance or pull down resistor.

    The PT1000 sensors have 1mA constant current and generate a voltage measured
    by the ADS1115. See https://www.sterlingsensors.co.uk/pt1000-resistance-table

    Zero Degrees. 1000 ohms, 1.000v
    80 degrees    1309 ohms  1.309v
    100  Degrees. 1385 ohms, 1.385v

    I2C_Write16 error - ?
        $> sudo raspi-config
            select interface options
            enable I2C

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

type TReportRec = record
    Counts     : integer;   // Number of control loops
    PState     : integer;   // Add either 0 or 100 for pump off or on
//    Tank       : longint;
end;

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
        procedure ControlLoop(var ReportRec : TReportRec);
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
  PumpOffDelta = 0;             // Collector has to be this much hotter than tank for Pump to remain on
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
//  PumpWasOn : boolean = false;      // true if pump was on, at some stage in last report cycle.



 var
    Application : TPumpCtrl;


{ ============================================================================= }


// ===================== R E P O R T I N G =====================================

function ReportString(ReportRec : TReportRec) : string;
begin
    Result := inttostr(CollectorTemp) + ',' + inttostr(TankTemp) + ',';
    case PumpState of
        psOff           : Result := Result + 'OFF,';
        psCollectHot    : Result := Result + 'COLLECTHOT,';
        psCollectFreeze : Result := Result + 'COLLECTFREEZE,';
    end;
    if ReportRec.Counts > 0 then
        Result := Result + inttostr(ReportRec.PState div ReportRec.Counts)
    else  begin
        Result := Result + '0';
        writeln('ERROR - ReportString() generating report with zero states');
    end;


//      if (PumpState in [ psCollectHot, psCollectFreeze]) or PumpWasOn then
//          Result := Result + '+WasOn'
//      else Result := Result + '+OFF';
//      PumpWasOn := False;
end;

procedure TPumpCtrl.SendReport(Msg : string);
{ Report may look like -
  CollectorTemp,TankTemp,[OFF|COLLECTHOT|COLLECTFREEZE]+[WasOn|OFF]
  eg 34023,27450,COLLECTHOT,50
  where the 50 represents pump on for 50% of time }
var
    Sock :TInetSocket = nil;
    Tick, Tock : qword;
begin
    Tick := GetTickCount64();
    try try                                                        // takes somewhere between 20mS and 200mS with no server listening
        Sock :=  TInetSocket.Create(ReportIP, ReportPort, 1000);   // this triggers an exception if server not listening, Sock is NOT created
        Sock.Write(MSg[1],Length(Msg));
//        if DebugMode then writeln('TPumpCtrl.SendReport msg sent ', Msg);
        except on E: ESocketError do
            writeln('Failed to connect to socket. ', E.Message);
        end;
    finally
            Sock.Free;
    end;
    Tock :=  GetTickCount64();
    if DebugMode then
        writeln(' TPumpCtrl.SendReport took ' + inttostr(Tock - Tick) + 'mS Report: ', Msg);
end;


// ======================== P R O C E S S    L O O P ===========================

function TPumpCtrl.ADC2Temp(SelectSensor : byte) : integer;
var
      Counts : word;
      Temp : extended;
begin
      Counts := ADS.ADSread_SingleEnded(SelectSensor, True);
      //writeln('ADC2Temp  Count = ', Counts);
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

procedure TPumpCtrl.ControlLoop(var ReportRec : TReportRec);         // This is called, repeatedly until told to quit.
{ var
      Tick, Tock : qword;   }
begin
{    if DebugMode then
        Tick := GetTickCount64();    }
    if X86Mode then begin
        CollectorTemp := 2500;                                   // milli degree,
        TankTemp := 31000;
    end else begin
        CollectorTemp := ADC2Temp(0);                            // Both calls in total is ~ 300mS
        TankTemp := ADC2Temp(1);
    end;
 {   if DebugMode then begin
        Tock := GetTickCount64();
        writeln('Measure (both sensors) took ' + inttostr(Tock-Tick) + 'mS');
    end;   }


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
    if not x86Mode then
        SetRaspiPort(PumpPort, PumpState in [psCollectHot, psCollectFreeze]);  // Make it so
    if PumpState in [psCollectHot, psCollectFreeze] then
        ReportRec.PState := ReportRec.PState + 100;
    inc(ReportRec.Counts);
    if DebugMode then
        writeln('TPumpCtrl.ControlLoop - Collect=', CollectorTemp, ' Tank=', TankTemp, ' PumpState=', ord(PumpState), ' PState=', ReportRec.PState, ' C=', ReportRec.Counts);
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


// Checks Options, sets up ports, manages process loop

procedure TPumpCtrl.DoRun;
var
    ErrorMsg : String;
    CyclesToNextReport : integer = CyclesPerReport;
    LoopTimer : QWord;
    ReportRec : TReportRec;
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
    ReportRec.Counts  := 0;
    ReportRec.PState  := 0;
    SetupSystems();
    repeat                                    // This is our main loop here.

        LoopTimer := GetTickCount64() + (6 * 1000);    // We aim for about a 6 second cycle ? Get 10 such cycles for each report, report once a minute.
        ControlLoop(ReportRec);
        dec(CyclesToNextReport);
        if CyclesToNextReport < 1 then begin
            SendReport(ReportString(ReportRec)+#10);
            CyclesToNextReport := CyclesPerReport;
            ReportRec.Counts  := 0;
            ReportRec.PState  := 0;
        end;
        while LoopTimer > GetTickCount64() do begin    // wait here for clock to catch up.
            sleep(10);
            if ExitNow then begin
                CleanUp();      // does not return
                writeln('Woops, this should not be here !');
            end;
        end;
    until False;

    // stop program loop if we get to here.
    Terminate;
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





// ============== H O U S E   K E E P I N G ====================================

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

