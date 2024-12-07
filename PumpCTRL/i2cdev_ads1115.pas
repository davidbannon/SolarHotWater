unit i2cdev_ADS1115;

{$mode objfpc}{$H+}
{$warn 6058 off}      // no warnings about not inlining.

{
conversiondelay  (tested on a 4 core PiZero 2)
This code waits a while after triggering a conversion. Hope its long enough.
sps_8 needs to be 150mS
sps_128 needs to be 10mS   (no safety margin applied.
Correct way to do this is to monitor the ALERT/RDY pin and set it to
conversion ready pin, see ADS1115 data sheet, 9.3.8 Conversion Ready Pin
}
interface

uses
  Classes, SysUtils, {baseUnix,} i2cdev_base;

const
  ADS1115_ADDRESS = $48;    // 1001 000 (ADDR pin tied to GND, 3 other possiblities, see data sheet)


  ADS1115_REG_POINTER_CONVERT = $00;
  ADS1115_REG_POINTER_CONFIG = $01;
  ADS1115_REG_POINTER_LOWTHRESH = $02;
  ADS1115_REG_POINTER_HITHRESH = $03;

  //  ADS1115_REG_CONFIG_OS_MASK      = $8000;
  ADS1115_REG_CONFIG_OS_SINGLE = $8000;  // Write: Set to start a single-conversion
  //   ADS1115_REG_CONFIG_OS_BUSY      = $0000;  // Read: Bit = 0 when conversion is in progress
  ADS1115_REG_CONFIG_OS_NOTBUSY = $8000;
  // Read: Bit = 1 when device is not performing a conversion

  //   ADS1115_REG_CONFIG_MUX_MASK     = $7000;
                                            // Bits 14, 13, 12
  ADS1115_REG_CONFIG_MUX_DIFF_0_1 = $0000;  // Differential P = AIN0, N = AIN1 (default;
  ADS1115_REG_CONFIG_MUX_DIFF_0_3 = $1000;  // Differential P = AIN0, N = AIN3  0001 0000 0000 0000
  ADS1115_REG_CONFIG_MUX_DIFF_1_3 = $2000;  // Differential P = AIN1, N = AIN3
  ADS1115_REG_CONFIG_MUX_DIFF_2_3 = $3000;  // Differential P = AIN2, N = AIN3
  ADS1115_REG_CONFIG_MUX_SINGLE_0 = $4000;  // Single-ended AIN0
  ADS1115_REG_CONFIG_MUX_SINGLE_1 = $5000;  // Single-ended AIN1
  ADS1115_REG_CONFIG_MUX_SINGLE_2 = $6000;  // Single-ended AIN2
  ADS1115_REG_CONFIG_MUX_SINGLE_3 = $7000;  // Single-ended AIN3                0111 0000 0000 0000

  //    ADS1115_REG_CONFIG_PGA_MASK     = $0E00;
                                          // Bits 11, 10, 9
  ADS1115_REG_CONFIG_PGA_6_144V = $0000;  // +/-6.144V range = Gain 2/3
  ADS1115_REG_CONFIG_PGA_4_096V = $0200;  // +/-4.096V range = Gain 1
  ADS1115_REG_CONFIG_PGA_2_048V = $0400;  // +/-2.048V range = Gain 2 (default;
  ADS1115_REG_CONFIG_PGA_1_024V = $0600;  // +/-1.024V range = Gain 4
  ADS1115_REG_CONFIG_PGA_0_512V = $0800;  // +/-0.512V range = Gain 8
  ADS1115_REG_CONFIG_PGA_0_256V = $0A00;  // +/-0.256V range = Gain 16

  //   ADS1115_REG_CONFIG_MODE_MASK    = $0100;
  //   ADS1115_REG_CONFIG_MODE_CONTIN  = $0000;  // Continuous conversion mode
  ADS1115_REG_CONFIG_MODE_SINGLE = $0100;  // Power-down single-shot mode (default;

  ADS1115_REG_CONFIG_DR_MASK = $00E0;
                                        // bits 7,6,5
  ADS1115_REG_CONFIG_DR_8SPS = $0000;  // 8 samples per second
  ADS1115_REG_CONFIG_DR_16SPS = $0020;  // 16 samples per second, 0010 0000
  ADS1115_REG_CONFIG_DR_32SPS = $0040;  // 32 samples per second, 0100 0000
  ADS1115_REG_CONFIG_DR_64SPS = $0060;  // 64 samples per second, 0110 0000
  ADS1115_REG_CONFIG_DR_128SPS = $0080;  // 128 samples per second (default)
  ADS1115_REG_CONFIG_DR_250SPS = $00A0;  // 250 samples per second
  ADS1115_REG_CONFIG_DR_475SPS = $00C0;  // 475 samples per second
  ADS1115_REG_CONFIG_DR_860SPS = $00E0;  // 860 samples per second, 1110 0000

  //   ADS1115_REG_CONFIG_CMODE_MASK   = $0010;
  //    ADS1115_REG_CONFIG_CMODE_TRAD   = $0000;  // Traditional comparator with hysteresis (default;
  ADS1115_REG_CONFIG_CMODE_WINDOW = $0010;  // Window comparator

  //  ADS1115_REG_CONFIG_CPOL_MASK    = $0008;
  //   ADS1115_REG_CONFIG_CPOL_ACTVLOW = $0000;  // ALERT/RDY pin is low when active (default;
  ADS1115_REG_CONFIG_CPOL_ACTVHI = $0008;  // ALERT/RDY pin is high when active

  //    ADS1115_REG_CONFIG_CLAT_MASK    = $0004;  // Determines if ALERT/RDY pin latches once asserted
  //    ADS1115_REG_CONFIG_CLAT_NONLAT  = $0000;  // Non-latching comparator (default;
  ADS1115_REG_CONFIG_CLAT_LATCH = $0004;  // Latching comparator

  //  ADS1115_REG_CONFIG_CQUE_MASK    = $0003;
  //   ADS1115_REG_CONFIG_CQUE_1CONV   = $0000;  // Assert ALERT/RDY after one conversions
  ADS1115_REG_CONFIG_CQUE_2CONV = $0001;  // Assert ALERT/RDY after two conversions
  ADS1115_REG_CONFIG_CQUE_4CONV = $0002;  // Assert ALERT/RDY after four conversions
  ADS1115_REG_CONFIG_CQUE_NONE = $0003;  // Disable the comparator

type

  { TADS1115 }
   {
    GAIN_TWOTHIRDS    = ADS1115_REG_CONFIG_PGA_6_144V,
  GAIN_ONE          = ADS1115_REG_CONFIG_PGA_4_096V,
  GAIN_TWO          = ADS1115_REG_CONFIG_PGA_2_048V,
  GAIN_FOUR         = ADS1115_REG_CONFIG_PGA_1_024V,
  GAIN_EIGHT        = ADS1115_REG_CONFIG_PGA_0_512V,
  GAIN_SIXTEEN      = ADS1115_REG_CONFIG_PGA_0_256V
  }

  TADSgain = (
    GAIN_TWOTHIRDS = ADS1115_REG_CONFIG_PGA_6_144V,     // that is 6.144v FSD, but we cannot exceed VDD !
    GAIN_ONE =       ADS1115_REG_CONFIG_PGA_4_096V,
    GAIN_TWO =       ADS1115_REG_CONFIG_PGA_2_048V,     // in this mode, we clip at 2.047 with 3v3 applied
    GAIN_FOUR =      ADS1115_REG_CONFIG_PGA_1_024V,
    GAIN_EIGHT =     ADS1115_REG_CONFIG_PGA_0_512V,
    GAIN_SIXTEEN =   ADS1115_REG_CONFIG_PGA_0_256V
    );

  TADSmuxmode = (
    mux0_1 = ADS1115_REG_CONFIG_MUX_DIFF_0_1,  // Differential P = AIN0, N = AIN1 (default;
    mux0_3 = ADS1115_REG_CONFIG_MUX_DIFF_0_3,  // Differential P = AIN0, N = AIN3
    mux1_3 = ADS1115_REG_CONFIG_MUX_DIFF_1_3,  // Differential P = AIN1, N = AIN3
    mux2_3 = ADS1115_REG_CONFIG_MUX_DIFF_2_3   // Differential P = AIN2, N = AIN3
    );

  TADSsamplepersecond = (
    sps_8 = ADS1115_REG_CONFIG_DR_8SPS,        // 8 samples per second
    sps_16 = ADS1115_REG_CONFIG_DR_16SPS,      // 16 samples per second
    sps_32 = ADS1115_REG_CONFIG_DR_32SPS,      // 32 samples per second
    sps_64 = ADS1115_REG_CONFIG_DR_64SPS,      // 64 samples per second
    sps_128 = ADS1115_REG_CONFIG_DR_128SPS,    // 128 samples per second (default;
    sps_250 = ADS1115_REG_CONFIG_DR_250SPS,    // 250 samples per second
    sps_475 = ADS1115_REG_CONFIG_DR_475SPS,     // 475 samples per second
    sps_860 = ADS1115_REG_CONFIG_DR_860SPS     // 860 samples per second
    );

  TADS1115 = class(TIc2Base)

  private
    FbitShift: smallint;
    FconversionDelay: integer;
    Fgain: tADSgain;
    Fsamplepersecond: TADSsamplepersecond;

    function ADSstartComparator(channel: Byte; Highthreshold: Byte): integer;
    procedure SetbitShift(const AValue: smallint);
    procedure SetconversionDelay(const AValue: integer);
    procedure Setgain(const AValue: tADSgain);
    procedure Setsamplepersecond(const AValue: TADSsamplepersecond);

  public

    constructor Create(); override;
    constructor Create(aADS1115_ADDRESS: Byte); override;
    property conversionDelay: integer read FconversionDelay write SetconversionDelay;
    property bitShift: smallint read FbitShift write SetbitShift;
    property samplepersecond: TADSsamplepersecond
      read Fsamplepersecond write Setsamplepersecond;
    property gain: tADSgain read Fgain write Setgain;
    function ADSread_SingleEnded(channel: Byte; Raw : boolean = false): word;
    function Getconfig(): word;
    function configToStr(): string;
    function getLastConversionResults(Raw : boolean = false): word;
    function  ADSreadDifferential(muxmode: TADSmuxmode): integer;
  end;

implementation



{ TADS1115 }

procedure TADS1115.Setgain(const AValue: tADSgain);
begin
  if Fgain = AValue then
    exit;
  Fgain := AValue;
end;

procedure TADS1115.Setsamplepersecond(const AValue: TADSsamplepersecond);
begin
  if Fsamplepersecond = AValue then
    exit;
  Fsamplepersecond := AValue;
end;

constructor TADS1115.Create();
begin
  Create(ADS1115_ADDRESS);
end;

constructor TADS1115.Create(aADS1115_ADDRESS: Byte);
begin
  inherited Create(aADS1115_ADDRESS);
  Fgain := GAIN_ONE;
  FconversionDelay := 5;
  FbitShift := 4;                // Hmm, why ?
  Fsamplepersecond := sps_128;
end;


function TADS1115.ADSread_SingleEnded(channel: Byte; Raw : boolean = false): word;
var
  config {, rawdata}: word;
begin
  connect;
  if (channel > 4) {or (channel < 0)} then       // hmm, byte unsigned, cannot be < 0
  begin
    Result := 0;
    Exit;
  end;
  config := 0;
  config := ADS1115_REG_CONFIG_CQUE_NONE or ADS1115_REG_CONFIG_MODE_SINGLE;   // Single-shot mode
    // Disable the comparator (default val)
    //                    ADS1115_REG_CONFIG_CLAT_NONLAT  or // Non-latching (default val)
    //                    ADS1115_REG_CONFIG_CPOL_ACTVLOW or // Alert/Rdy active low   (default val)
    //                    ADS1115_REG_CONFIG_CMODE_TRAD   or // Traditional comparator (default val)

  if Ord(Fsamplepersecond) > 0 then
    config := config or (Ord(Fsamplepersecond));

  if Ord(Fgain) > 0 then
    config := config or (Ord(Fgain));
//  ;
  case channel of
    0: config := config or ADS1115_REG_CONFIG_MUX_SINGLE_0;
    1: config := config or ADS1115_REG_CONFIG_MUX_SINGLE_1;
    2: config := config or ADS1115_REG_CONFIG_MUX_SINGLE_2;
    3: config := config or ADS1115_REG_CONFIG_MUX_SINGLE_3;
  end;

  // Set 'start single-conversion' bit
  config := config or ADS1115_REG_CONFIG_OS_SINGLE;

  I2C_Write16(hdev, ADS1115_REG_POINTER_CONFIG, config);
  Result := getLastConversionResults(Raw);
end;



{/**************************************************************************/
/*!
    @brief  Sets up the comparator to operate in basic mode, causing the
            ALERT/RDY pin to assert (go from high to low) when the ADC
            value exceeds the specified threshold.

            This will also set the ADC in continuous conversion mode.
*/
/**************************************************************************/ }

function TADS1115.ADSstartComparator(channel: Byte; Highthreshold   : Byte  ) : integer ;
 var
  config {, rawdata}: word;

begin
   connect;

  if (channel > 4) {or (channel < 0)} then
  begin
    Result := 0;
    Exit;
  end;
  config := 0;

  config :=  ADS1115_REG_CONFIG_CLAT_LATCH;

          // ADS1115_REG_CONFIG_CQUE_1CONV   or // Comparator enabled and asserts on 1 match
                 //   ADS1115_REG_CONFIG_CLAT_LATCH   or // Latching mode
                 //   ADS1115_REG_CONFIG_CPOL_ACTVLOW | // Alert/Rdy active low   (default val)
                 //   ADS1115_REG_CONFIG_CMODE_TRAD   | // Traditional comparator (default val)
                 //   ADS1115_REG_CONFIG_DR_1600SPS   | // 1600 samples per second (default)
                 //   ADS1115_REG_CONFIG_MODE_CONTIN ; // Continuous conversion mode
                 ;



  if Ord(Fsamplepersecond) > 0 then
    config := config or (Ord(Fsamplepersecond));

  if Ord(Fgain) > 0 then
    config := config or (Ord(Fgain));
  ;
  case channel of

    0:
      config := config or ADS1115_REG_CONFIG_MUX_SINGLE_0;

    1:
      config := config or ADS1115_REG_CONFIG_MUX_SINGLE_1;

    2:
      config := config or ADS1115_REG_CONFIG_MUX_SINGLE_2;

    3:
      config := config or ADS1115_REG_CONFIG_MUX_SINGLE_3;

  end;



   I2C_Write16(hdev, ADS1115_REG_POINTER_HITHRESH, (Highthreshold shl FbitShift)  );

  I2C_Write16(hdev, ADS1115_REG_POINTER_CONFIG, config);

 // Result := getLastConversionResults;
end;



 {/**************************************************************************/
/*!
    @brief  Reads the conversion results, measuring the voltage
            difference between the P (AIN2) and N (AIN3) input.  Generates
            a signed value since the difference can be either
            positive or negative.
*/
/**************************************************************************/ }
function TADS1115.ADSreadDifferential(muxmode: TADSmuxmode): integer;
var

  config {, rawdata} : word;
begin
  // Start with default values

  connect;


  config := 0;

  config := ADS1115_REG_CONFIG_CQUE_NONE or
    // Disable the comparator (default val)
    //                    ADS1115_REG_CONFIG_CLAT_NONLAT  or // Non-latching (default val)
    //                    ADS1115_REG_CONFIG_CPOL_ACTVLOW or // Alert/Rdy active low   (default val)
    //                    ADS1115_REG_CONFIG_CMODE_TRAD   or // Traditional comparator (default val)


    ADS1115_REG_CONFIG_MODE_SINGLE;   // Single-shot mode (
  if Ord(Fsamplepersecond) > 0 then
    config := config or (Ord(Fsamplepersecond));

  if Ord(Fgain) > 0 then
    config := config or (Ord(Fgain));

  if Ord(muxmode) > 0 then
    config := config or (Ord(muxmode));

  //   ADS1115_REG_CONFIG_MUX_DIFF_0_1 = $0000;  // Differential P = AIN0, N = AIN1 (default;
  //  ADS1115_REG_CONFIG_MUX_DIFF_0_3 = $1000;  // Differential P = AIN0, N = AIN3
  //  ADS1115_REG_CONFIG_MUX_DIFF_1_3 = $2000;  // Differential P = AIN1, N = AIN3
  //  ADS1115_REG_CONFIG_MUX_DIFF_2_3 = $3000;  // Differential P = AIN2, N = AIN3


  // Set 'start single-conversion' bit
  config := config or ADS1115_REG_CONFIG_OS_SINGLE;


  // Write config register to the ADC
  I2C_Write16(hdev, ADS1115_REG_POINTER_CONFIG, config);
  Result := getLastConversionResults;

end;


{/**************************************************************************/
/*!
    @brief  In order to clear the comparator, we need to read the
            conversion results.  This function reads the last conversion
            results without changing the config value.
*/
/**************************************************************************/ }
function TADS1115.getLastConversionResults(Raw : boolean = false): word;
var
  rawdata: word;
//  Tick, Tock : qword;
begin
  // Wait for the conversion to complete

  sleep(FconversionDelay);
//  Tick := GetTickCount64();
  rawdata := I2C_Read16(hdev, ADS1115_REG_POINTER_CONVERT);
//  Tock := GetTickCount64();
//  writeln('TADS1115.getLastConversionResults rawdata=', rawdata);      // Davo
  if (not Raw) and (FbitShift <> 0) then
    Result := rawdata shr FbitShift              // here we divide by 32 so answer is in mV
  else                                           // or, only by 16 if we are in in real single ended mode
    Result := rawdata;
//   writeln('getLastConversionResults took ', (Tock-Tick), 'mS');
end;

procedure TADS1115.SetbitShift(const AValue: smallint);
begin
  if FbitShift = AValue then
    exit;
  FbitShift := AValue;
end;

procedure TADS1115.SetconversionDelay(const AValue: integer);
begin
  if FconversionDelay = AValue then
    exit;
  FconversionDelay := AValue;
end;

function TADS1115.Getconfig(): word;
begin
  connect;
  Result := I2C_Read16(hdev, ADS1115_REG_POINTER_CONFIG);
end;

function TADS1115.configToStr(): string;
var
  i: integer;
  tmpconfig: word;
begin

  tmpconfig := Getconfig;

  Result := '';
  for i := 15 downto 0 do
  begin
    if tmpconfig and (1 shl i) <> 0 then
    begin
      Result := Result + '1';
    end
    else
    begin
      Result := Result + '0';
    end;
    case i of
      0: Result := Result + '<Comparator queue and disable ' + #13#10;
      2: Result := Result + '<Latching comparato ' + #13#10;
      3: Result := Result + '<Comparator polarity ' + #13#10;
      4: Result := Result + '<Comparator mode ' + #13#10;
      5: Result := Result + '<Data rate ' + #13#10;
      8: Result := Result + '<Device operating mode ' + #13#10;
      9: Result := Result + '< gain   ' + #13#10;
      12: Result := Result + '<multiplexer configuration ' + #13#10;
      15: Result := Result + '<os ' + #13#10;

    end;
  end;

end;

end.

