program adc;
{$MODE OBJFPC}
{$H+}
{$MEMORY 10000,10000}

{ For Raspi Pico
  Max Value longword=4,294,967,295 integer=2,147,483,647 cardinal=4,294,967,295 cpu32

  To read the attached debug pico, "tio /dev/ttyACM0", ctrl-T to get menu, ctrl-t-q to quit.
  Make sure you are in the dialout group to use serial port (ie USB).
  Plug in the debug pico to see debug info.
}

uses
  pico_gpio_c,
  pico_uart_c,
  pico_adc_c,
  pico_timer_c,
  pico_c;


type TPumpState = (psOff, psCollectHot, psCollectFreeze);

const
  BAUD_RATE=115200;
  // ADC_REF_VOLT=2490;      // milliVolts
  // ADC_REF_VOLT=3300;   // milliVolts
  PumpOnDelta = 3000;     // Collector has to be this much hotter than tank to turn pump on
  PumpOffDelta = 2000;    // Collector has to be this much hotter than tank for Pump to remain on
  MaxTankTemp = 90000;    // Don't send any more hot water to tank !
  AntiFreezeTrigger = 3000;     // Colder than this, we must pump some warm water up
  AntiFreezeRelease = 4000;     // Warmer than this, we can stop pumping
  PumpPort = TPicoPin.GP19;        // GP19 conflicts with SPI-0 and I2C-1  (and UART 0 ??)
  PtSelectPort = TPicoPin.GP22;    // GP22 conflicts with SPI-0 and I2C-1  (and UART 1 ??)

var
  //milliVolts,milliCelsius : longWord;
  strValue : string;
  //PtZeroCount : longWord;
  CollectorTemp, TankTemp : integer;
  {PumpOn,} LEDOn : boolean;
  AntiFreezeOn : Boolean = False;
  PumpState : TPumpState = psOff;

const CntsPerReading = 10;

            // Returns indicated Temp i/p in milli degrees C
function GetExternalTemperature(const ADCInput:integer; SelectSensor : boolean):integer;
    { PtTemp = (((181.15*CNT)  / (273+BOXT)) - 1000) * 100 / 385   -- NO, drop adjusting for ambient, its CPU Temp !
    Pt temp = (Cnts*158)-259740 milli degrees   }
var
    Cnt : longWord = 0;
    i : integer;
begin
    gpio_put(PtSelectPort, SelectSensor);       // switch constant current to correct sensor
    adc_select_input(ADCInput);
    busy_wait_us_32(100);                       // Settle ....
    //Cnt := 0;
    for i := 1 to CntsPerReading do
        Cnt := Cnt + adc_read();
    adc_select_input(2);                // Input ADC2 is tied to gnd, account for any offset
    for i := 1 to CntsPerReading do
        Cnt := Cnt - adc_read();
    Result := ((Cnt * 158) div 10) - 259740;    // thats milli degrees

    uart_puts(uart, ' Count=');
    str(Cnt,strValue);
    uart_puts(uart,strValue + ' T=');
    str(Result, strValue);
    uart_puts(uart, strValue);
    uart_puts(uart, ' ');

//    Result := Result div 1000;          // Return degrees but maybe, later, we'll work in milli degrees
end;


procedure ReportToUart();
var
    AStr : string = '';
    Buff : string = '';
begin
    str(CollectorTemp, Buff);
    Buff := 'Collector Temp ' + Buff;
    str(TankTemp, AStr);
    Buff := Buff + ', Tank Temp ' + AStr;
    case PumpState of
        psOff : Buff := Buff + ', Pump OFF';
        psCollectHot : Buff := Buff + ', Pump Heating';
        psCollectFreeze : Buff := Buff + ', Pump AntiFreeze';
    end;
    uart_puts(uart, Buff);
    uart_puts(uart, #13#10);
end;

                // Called repeatedly until power off.
procedure ControlLoop;
// Might change globals : PumpState, CollectorTemp, TankTemp, LEDOn
begin
    //gpio_put(PtSelectPort,True);
    //busy_wait_us_32(100);
    CollectorTemp := GetExternalTemperature(1, True);
    //gpio_put(PtSelectPort,False);
    //busy_wait_us_32(100);
    TankTemp := GetExternalTemperature(0, False);
    if PumpState = psOff then begin
        if CollectorTemp < AntiFreezeTrigger then
            PumpState := psCollectFreeze
        else if (CollectorTemp > (TankTemp + PumpOnDelta))
            and (TankTemp < MaxTankTemp) then
                PumpState := psCollectHot;
    end else begin                                    // ie the pump is on, either psCollectFreeze or psCollectHot
        if PumpState = psCollectHot then begin
            if CollectorTemp < TankTemp + PumpOffDelta then
                PumpState := psOff;
        end else                                      // ie psCollectFreeze
            if CollectorTemp > AntiFreezeRelease then
                PumpState := psOff;
    end;
    LEDOn := Not LEDOn;
    gpio_put(PumpPort, PumpState in [psCollectHot, psCollectFreeze]);     // Make it so.
    gpio_put(TPicoPin.LED, LEDOn);
    ReportToUart();
    busy_wait_us_32(500000);                        // half a second
end;

begin
  //PumpOn := False;
  LEDOn := False;
  gpio_init(TPicoPin.LED);
  gpio_set_dir(TPicoPin.LED,TGPIODirection.GPIO_OUT);
  gpio_init(PumpPort);
  gpio_set_dir(PumpPort,TGPIODirection.GPIO_OUT);
  gpio_init(PtSelectPort);
  gpio_set_dir(PtSelectPort,TGPIODirection.GPIO_OUT);

  uart_init(uart, BAUD_RATE);
  gpio_set_function(TPicoPin.UART_TX, TGPIOFunction.GPIO_FUNC_UART);
  gpio_set_function(TPicoPin.UART_RX, TGPIOFunction.GPIO_FUNC_UART);

  adc_init;
  // Make sure GPIO is high-impedance, no pullups etc
  adc_gpio_init(TPicoPin.ADC0);
  adc_gpio_init(TPicoPin.ADC1);
  adc_gpio_init(TPicoPin.ADC1);     // Thats our offset input, tied to gnd
  // Turn on the Temperature sensor
  // adc_set_temp_sensor_enabled(true);
  // strValue := '';
  repeat
        ControlLoop;
        // gpio_put(TPicoPin.LED,true);
        // IntTemp := GetInternalTemperature();
        // gpio_put(PumpPort,true);
//        gpio_put(TPicoPin.LED,false);
//        busy_wait_us_32(500000);                        // half a second
  until False;
end.

// =============================================================================


{ A 12 bit A/D returns 4k counts FSD, 2.5v, around 1600 counts at 0 degrees }


    // Returns the Pico's internal temp sensor reading as celsius, used to compensate
    // for the current source temp dependance.  However, I suspect that this
    // returns the CPU temp, when ticking over, its, perhaps, 3 degrees hotter
    // than ambient ? Maybe a heatsink would help, perhaps just subtract 3 degrees ?
(* function GetInternalTemperature():integer;
begin
  adc_select_input(4);
  //milliVolts := (adc_read() * ADC_REF_VOLT) div 4096;
  //Temperature formula is : T = 27 - (ADC_voltage - 0.706)/0.001721
  //milliCelsius := 27000-(milliVolts-706)*581;
  result := (27000-(((adc_read() * ADC_REF_VOLT) div 4096)-706)*581) div 1000;  // one degree resolution is fine here
  uart_puts(uart, 'Internal Temp is ');
  str(Result,strValue);
  uart_puts(uart,strValue + ' ');
end;

procedure GetInfo();
begin
  // Select ADC input 0 (GPIO26)
   adc_select_input(0);
   // Avoiding floating point math as it currently seems to be in no good shape (on Cortex-M0, not only pico)
   milliVolts := (adc_read * 3300) div 4096;
   uart_puts(uart, 'GPIO26 voltage is ');
   str(milliVolts,strValue);
   uart_puts(uart,strValue);
   uart_puts(uart,' mV ');

   // Select internal temperature sensor
   adc_select_input(4);
   milliVolts := (adc_read * ADC_REF_VOLT) div 4096;
   uart_puts(uart, 'Temperature sensor voltage is ');
   str(milliVolts,strValue);
   uart_puts(uart,strValue);
   uart_puts(uart,' mV ');

   //Temperature formula is : T = 27 - (ADC_voltage - 0.706)/0.001721
   milliCelsius := 27000-(milliVolts-706)*581;

   uart_puts(uart, 'Temperature is ');
   str(milliCelsius div 1000,strValue);
   uart_puts(uart,strValue);


   uart_puts(uart,' °C');

   str(sizeof(integer), strvalue);
   uart_puts(uart, strvalue);
   uart_puts(uart, ' lw=');
   str(high(longword), strValue);
   uart_puts(uart, StrValue);

   uart_puts(uart, ' i=');
   str(high(integer), StrValue);
   uart_puts(uart, StrValue);

   uart_puts(uart, ' c=');
   str(high(cardinal), StrValue);
   uart_puts(uart, StrValue);
   {$IFDEF cpu64} StrValue := ' cpu64'; {$ENDIF}
   {$IFDEF cpu32} StrValue := ' cpu32'; {$ENDIF}
   {$IFDEF cpu16} StrValue := ' cpu16'; {$ENDIF}
   uart_puts(uart, StrValue);
   uart_puts(uart, #13#10);
end;   *)

