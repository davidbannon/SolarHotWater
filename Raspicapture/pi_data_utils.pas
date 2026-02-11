unit pi_data_utils;

{$mode objfpc}{$H+}


{ Copyright David Bannon
  License:
  This code is licensed under MIT License, see https://opensource.org/license/mit
  or  https://spdx.org/licenses/MIT.html  SPDX short identifier: MIT
}



// Has a couple of raspi specific functions but probably sensible to move them
// back into main raspicapture unit. Covers -

// * Known temp sensor IDs
// * Ports we use for i/o
//

// Totally off topic ----

//        I use the same port control code to control the Water system
//        (it needed to change hardware so that it defaults to off) -
//        * On power up, ports are unexported, in a high impedeance state
//        * Except for gpio0-gpio8 that have a pull up resistor ??              << note this when allocating ports !
//        * To use them, we first export, then write in or out to direction
//        * Can provide pull up resistor.


// In version 1 the Water app has water turned ON at power on, relies on a script
// to force them off.
// Have now reversed the on/off and moved to new ports that don't have a pullup R.



{$WARN 6058 off : Call to subroutine "$1" marked as inline is not inlined}

interface

uses
 Sysutils, unix, Raspi_Utils;

const
    {$define VERSION2}
    {$ifdef VERSION2}
    //            GPIO No.         40 pin connector
    PIN_HW_PUMP   = 17;         // Board Pin 11   input from Current Transformer in Pump line.
    PIN_HW_HEATER = 11;         // Board Pin 15   input from Current Transformer in Water Heater Line, not implemented yet.
    PIN_WATER_1   = 27;         // Board Pin 13
    PIN_WATER_2   = 22;         // Board Pin 15
    {$else}
    PIN_HW_PUMP   = 17;         // Board Pin 11       (test=LED) HW_PUMP
    PIN_HW_HEATER = 22;         // Board Pin 15       Switch
    PIN_WATER_1   = 25;         // Board Pin
    PIN_WATER_2   =  8;         // Board Pin 24
    {$endif}
    // 17, 22, 25 and 8 are GPIO numbers, ie Broadcom
    // 11, 15, 22, 24 are numbers on the board's header.
    // Above numbers are GPIO, Broardcom numbers. The Px numb are header no.
    InvalidTemp=-1000000;           // An unset sensor temperature


type TSensorArray = array of TSensorRec;

                // Passed an empty dynamic array, it first puts details of known
                // sensors in it, then looks at all available sensors marking any
                // it finds as present. This may include the know one and any others.
function PopulateSensorArray(var DataArray : TSensorArray; NotRaspi : boolean) : integer;

procedure WriteLog(msg: string);    // writes a date stamped log.

var
                                    // an array of the 5 DS18B20 sensors we know should be present on my Raspi
                                    // on x86_64 we auto mark these Present, just a little lie to test
    TempSensors : array of string = ('28-001414a820ff', '28-0014154270ff', '28-0014153fc6ff', '28-000004749871', '28-001414af48ff');
    TempNames :   array of string = ('Hot Out', 'Roof', 'Tank Low', 'Ambient', 'Solar', 'Collector', 'Tank');
    DoDebug : boolean = false;                // Might be set in raspicapture.lpr

//    LockedBySocket : boolean = false;         // rough and ready locking, socket has access
//    LockedByCapture : boolean = false;        // rough and ready locking, capture code has access

implementation

procedure WriteLog(msg: string);           // ToDo : hardwired user name ?
var
    FFileName : string = '';
    F : TextFile;
begin
//    if Application.HasOption('L', 'log_file') then
//        FFileName := GetOptionValue('d', 'directory')
//    else
    if  directoryExists('/home/dbannon/logs/') then
        FFileName := '/home/dbannon/logs/new_capture.log'
            else FFileName := 'new_capture.log';
    AssignFile(F, FFileName);
    // need a try here ...
    if FileExists(FFileName) then
        Append(F)
    else  Rewrite(F);
    writeln(F, DateTimeToStr(now()) + ' - ' + Msg);
    closeFile(F);
end;

function PopulateSensorArray(var DataArray : TSensorArray; NotRaspi : boolean) : integer;
var
    Index : integer;
    Info : TSearchRec;
    Found : boolean = false;

    procedure AddToDataArray(ID, Name : string; V : longint; P : boolean);
    begin
        DataArray[Index].ID := ID;
        DataArray[Index].Name := Name;
        DataArray[Index].Value := V;
        DataArray[Index].Present := P;
        DataArray[Index].Points := 0;
    end;

begin
    // First, the ones we know about
    setlength(DataArray, length(TempSensors));
    for Index := low(TempSensors) to high(TempSensors) do begin
        AddToDataArray(TempSensors[Index], TempNames[Index], 0 {InvalidTemp}, NotRaspi);
        // On non raspi, make out those 5 are present for easy testing.
    end;
    // OK, thats the theory, what can we find ?
    if not NotRaspi then                              // double negative, do this if RasPi
        try
            if FindFirst(DEV_PATH + '28-*', faAnyFile and faDirectory, Info)=0 then begin
                repeat
                    for Index := low(DataArray) to high(DataArray) do begin
                        if DataArray[Index].ID = Info.Name then begin
                            DataArray[Index].Present := True;
                            Found := True;
                            break;
                        end;
                    end;
                    if Not Found then begin                        // really just for testing ...
                        setlength(DataArray, length(DataArray) + 1);
                        Index := high(DataArray);
                        AddToDataArray(Info.Name, 'Unknown', InvalidTemp, True);
                    end;
                until FindNext(Info) <> 0;
            end;
        finally
            FindClose(Info);
        end;
    Result := length(DataArray);        // All may not be present however
end;

end.






