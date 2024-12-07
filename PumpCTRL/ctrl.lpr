program adc;
{$MODE OBJFPC}
{$H+}
{$MEMORY 10000,10000}


uses Raspi_Utils, i2cdev_ads1115, BaseUnix, SysUtils;

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


type TPumpState = (psOff, psCollectHot, psCollectFreeze);

const
                                // All temperatures here are in milli degrees C
  PumpOnDelta = 3000;           // Collector has to be this much hotter than tank to turn pump on
  PumpOffDelta = 2000;          // Collector has to be this much hotter than tank for Pump to remain on
  MaxTankTemp = 90000;          // Don't send any more hot water to tank !
  AntiFreezeTrigger = 3000;     // Colder than this, we must pump some warm water up
  AntiFreezeRelease = 4000;     // Warmer than this, we can stop pumping
  PumpPort = 15        ;        // gpio15
  PtSelectPort = 14;            //

var
  CollectorTemp, TankTemp : integer;   // temp in milli degrees C
  LEDOn : boolean = false;
  PumpState : TPumpState = psOff;
  ADS: TADS1115 = nil;
  ExitNow : boolean = false;           // set in signal handler, loops looks at it.

  // Gets ADC and converts reading to milli degress C
function ADC2Temp(SelectSensor : byte) : integer;
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
      writeln('ADC2Temp Final Temp = ', Result);
end;

                // Called repeatedly until power off.
procedure ControlLoop;
// Might change globals : PumpState, CollectorTemp, TankTemp, LEDOn
begin
    CollectorTemp := ADC2Temp(0);                // milli degree
    TankTemp := ADC2Temp(1);
    if PumpState = psOff then begin                               // We may turn it on
        if CollectorTemp < AntiFreezeTrigger then                 // Its freezing out there !
            PumpState := psCollectFreeze
        else if (CollectorTemp > (TankTemp + PumpOnDelta)) then   // Collector is hotter than tank.
                PumpState := psCollectHot;
    end else begin                                                // the pump is on, either psCollectFreeze or psCollectHot
        if (PumpState = psCollectHot)
                and (CollectorTemp < TankTemp + PumpOffDelta) then
                    PumpState := psOff
        else                                                  // ie psCollectFreeze
            if CollectorTemp > AntiFreezeRelease then
                PumpState := psOff;
    end;
    if TankTemp > MaxTankTemp then                                // a safety measure
        PumpState := psOff;
    LEDOn := Not LEDOn;
    SetRaspiPort(PumpPort, PumpState in [psCollectHot, psCollectFreeze]);  // Make it so
end;


procedure CleanUp;
begin
    ControlPort(PtSelectPort, RasPiPortReset);
    ControlPort(PumpPort, RasPiPortReset);
    if ADS <> nil then ADS.Free;
    Halt(1);
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
  //PumpOn := False;
    ADS := nil;
    LEDOn := False;
    if (ControlPort(PumpPort, RaspiPortWrite) in [RaspiPortSuccess, RaspiPortAlready])
        and SetRaspiPort(PumpPort, False)
        and (ControlPort(PtSelectPort,  RaspiPortWrite) in [RaspiPortSuccess, RaspiPortAlready])
        and SetRaspiPort(PtSelectPort, True) then
            ADS := TADS1115.Create()
    else begin
        writeln('Failed to initialise the i/o ports');
        exit;
    end;
    if ADS <> nil then begin
        ADS.conversionDelay := 150;        // see note top of i2cdev_ADS1115.pas
        ADS.samplepersecond := sps_16;
        ADS.gain := GAIN_TWO;              //  thats 0 to 2.048v
    end else begin
        writeln('Failed to initialise the ADC');
        exit;
    end;
    CollectorTemp := ADC2Temp(0);                // milli degree
    TankTemp := ADC2Temp(1);
    if (CollectorTemp < -20000) or (CollectorTemp > 200000)     // -20 to 200
            or (TankTemp < -20000) or (TankTemp > 200000) then begin
        writeln('Failed to get sensible numbers in the ADC');
        exit;
    end;

    if FpSignal(SigInt, @HandleSigInt) = signalhandler(SIG_ERR) then begin
        Writeln('Failed to install signal error: ', fpGetErrno);
        Halt(1);
    end;
    if FpSignal(SigTerm, @HandleSigInt) = signalhandler(SIG_ERR) then begin
        Writeln('Failed to install signal error: ', fpGetErrno);
        Halt(1);
    end;
    repeat
        ControlLoop;
        sleep(1000);
        if ExitNow then begin
            CleanUp();      // does not return
            writeln('Woops, this should not be here !');
        end;
  until False;


end.


