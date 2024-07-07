unit pi_data_utils;

{$mode objfpc}{$H+}

// cat /sys/bus//w1/devices/28-00000400bce7/temperature 
// 25000
// https://simonprickett.dev/controlling-raspberry-pi-gpio-pins-from-bash-scripts-traffic-lights/
{$WARN 6058 off : Call to subroutine "$1" marked as inline is not inlined}

interface

uses
 Sysutils, unix;

const
    //FFNAME = '/sys/bus//w1/devices/28-00000400bce7/temperature';
    DEV_PATH = '/sys/bus/w1/devices/';
    PIN_PATH = '/sys/class/gpio/';
    PIN_HW_PUMP = '17';           // Board Pin 11       (test=LED) HW_PUMP
    PIN_HW_HEATER = '22';         // Board Pin 15       Switch
    PIN_WATER_1 = '25';           // Board Pin 22
    PIN_WATER_2 = '8';            // Board Pin 24
    // Above numbers are GPIO, Broardcom numbers. The Px numb are header no.
    InvalidTemp=-1000000;           // An unset sensor temperature

type TRaspiPortControl=(RaspiPortRead, RaspiPortWrite, RaspiPortReset);

                        // These are returned by ControlPort(), may indicate port is
                        // ready to use and whether you should reset port at completion
type TRaspiPortStatus = (RaspiPortSuccess,  // Port was available, now set as requested
                        RaspiPortAlready,   // Port was already set as requested
                        RaspiPortWrong,     // Port was and is still set to wrong mode
                        RaspiPortNoSet,     // Port looks OK but we cannot set it ???
                        RaspiPortNoIO,      // Error accessing ports, possibly no I/O hardware
                        RaspiPortNoAccess); // Errro accessing ports, possibly permissions issue



type
  //PSensorRec = ^TSensorRec;
  TSensorRec = Record
        ID : string;    // eg 28-001414a820ff
        Name : string;  // eg Ambient
        Value : longint;    // raw numbers from sensor or -1 if invalid, milli degrees C
        Present : boolean;  // Is this sensor present ?
  end;

type TSensorArray = array of TSensorRec;

                // Displays, to console, a summary of the sensors right now.
procedure ShowSensorInformation();

                // Passed an empty dynamic array, it first puts details of known
                // sensors in it, then looks at all available sensors marking any
                // it finds as present. This may include the know one and any others.
function PopulateSensorArray(var DataArray : TSensorArray) : integer;

                // Attempts to read the temperature of each sensor in the passed array.
function ReadDevice(DName : string) : integer;

                // Must call this before using a port (PortNo, RaspiPortRead|RaspiPortWrite)
                // and before exiting (PortNo,  RaspiPortReset).
function ControlPort(PortNo : string; AnAction : TRaspiPortControl) : TRaspiPortStatus;

function ReadRaspiPort(Port : string; out Value : char) : boolean;

var
    DevArray : TStringArray;
    Dev : string;
    TempSensors : array of string = ('28-001414a820ff', '28-0014154270ff', '28-0014153fc6ff', '28-000004749871', '28-001414af48ff');
    TempNames : array of string = ('Hot Out', 'Roof', 'Tank Low', 'Ambient', 'Solar', 'Collector', 'Tank');
    DoDebug : boolean = false;      // Might be set in raspicapture.lpr

implementation

function ReadFromFile(const FFName : string; out ch : char) : boolean;
var
    F : TextFile;
begin
    if not FileExists(FFname) then begin
        writeln('pi_data_util ReadFromFile - ERROR : port file ' + FFName + ' - does not exist');
        //if Application.HasOption('D', 'debug') then
        //    writelog('pi_data_util ReadFromFile - ERROR : port file ' + FFName + ' - does not exist');
        exit(False);
    end;
    Result := True;
    AssignFile(F, FFName);
    try try
        reset(F);
        readln(F, Ch);
    except
        on E: EInOutError do begin
            writeln('pi_data_util ReadFromFile - ERROR : ' + FFName + ' - ' +  E.Message);
            result := False;
        end;
    end;
    finally
        closeFile(f);
    end;
end;

const MAX_REWRITE_TRIES=10;

function writeToFile(const FFName, Content : string) : boolean;
var
    F : TextFile;
    Tries : integer = 0;
    ErrorNo : integer;
begin
    {$I-}
    Result := True;
    AssignFile(F, FFName);
    while Tries < MAX_REWRITE_TRIES do begin
        rewrite(F);
        ErrorNo := IOResult;
        if ErrorNo=0 then break;
        inc(Tries);
        sleep(10*Tries);
    end;
    if Tries = MAX_REWRITE_TRIES then begin
        result := False;
        writeln('I/O ERROR Code ' + inttostr(ErrorNo) + ' ' + FFName);
    end else begin
        write(F, Content);
        closeFile(f);
    end;
    {$I+}
end;

function SetGPIO(GpioNo : string; Input : boolean) : boolean;
begin
    result := false;
    // writeln('SetGPIO Testing ' + PIN_PATH + 'gpio' + GpioNo);
    if not DirectoryExists(PIN_PATH + 'gpio' + GpioNo) then begin
        writeln('Exporting GPIO ' + GpioNo);
        Result := writeToFile(PIN_PATH + 'export', GpioNo);
    end else Result := True;
    if not DirectoryExists(PIN_PATH + 'gpio' + GpioNo) then begin
        writeln('Failed to export to ' + PIN_PATH + 'gpio' + GpioNo);
        exit(False);
    end;
//    sleep(100);              // 30mS is not enough.
    if Result then 
        if Input then
            Result := WriteToFile(PIN_PATH + 'gpio' + GpioNo + '/' + 'direction', 'in')
        else Result := WriteToFile(PIN_PATH + 'gpio' + GpioNo + '/' + 'direction', 'out');
    // Note: after export, a Pin is 'in', so possibly don't need to set it.
end; 

function UnSetGPIO(GpioNo : string) : boolean;
begin
    if not DirectoryExists(PIN_PATH + 'gpio' + GpioNo) then begin
        writeln('Export does not exit ' + PIN_PATH + 'gpio' + GpioNo);
        exit(False);
    end;
    Result := writeToFile(PIN_PATH + 'unexport', GpioNo);
    if DirectoryExists(PIN_PATH + 'gpio' + GpioNo) then begin
        writeln('Export has not gone away ! ' + PIN_PATH + 'gpio' + GpioNo);
        exit(False);
    end;
end;

// Returns True if the Port can be accessed and returns with its state, 'in', 'out', '';
// If it ret False, an error, reason is in State ('no gpio' or 'no access')
function TestRaspiPort(PortNo : string; out State : string) : boolean;
var
   F : TextFile;
   //St : string;
begin
    State := 'no gpio';
    if not DirectoryExists(PIN_PATH) then exit(false);                          // if past here, gpio must exist
    State := '';
    if not DirectoryExists(PIN_PATH + 'gpio' + PortNo) then exit(true);         // port unexported
    AssignFile(F, PIN_PATH + 'gpio' + PortNo +'/direction');
    result := true;
    try try
       reset(F);
       readln(F, State);
    except
       on E: EInOutError do begin
           State := 'no access';
           // writeln('pi_data_util ReadFromFile - ERROR : ' + FFName + ' - ' +  E.Message);
           result := False;
       end;
   end;
   finally
       closeFile(F);
   end;
end;




{ Raspi i/o Ports are initially 'unexported', we setup one by writing its port number
to /sys/class/gpio/export and then write write either in or out to
/sys/class/gpioNN/direction. When done, we write the port number to /sys/class/gpio/unexport
}

// Must call this before using a port (PortNo, RaspiPortRead|RaspiPortWrite)
// and before exiting (PortNo,  RaspiPortReset). Public Function.
function ControlPort(PortNo : string; AnAction : TRaspiPortControl) : TRaspiPortStatus;
var
   State, Intended : string;
begin
    if not TestRaspiPort(PortNo, State) then begin
        if State = 'no access' then exit(RaspiPortNoAccess)
        else exit(RaspiPortNoIO);
    end;
    // OK, we can access the ports, State maybe '', 'in' or 'out'
    if AnAction = RaspiPortReset then begin
        if State = '' then exit(RaspiPortAlready);
        writeToFile(PIN_PATH + 'unexport', PortNo);
        if DirectoryExists(PIN_PATH + 'gpio' + PortNo) then
            exit(RaspiPortNoSet)
        else exit(RaspiPortSuccess);
    end else begin                                  // must be either RaspiPortRead RaspiPortWrite
        if AnAction = RaspiPortRead then
            Intended := 'in'
        else Intended := 'out';
        if State = Intended then exit(RaspiPortAlready);
        if (State = '') then begin
            writeToFile(PIN_PATH + 'export', PortNo);      // Export will create the target dir
            if WriteToFile(PIN_PATH + 'gpio' + PortNo + '/' + 'direction', Intended) then
                exit(RaspiPortSuccess)
            else exit(RaspiPortNoSet);
        end;
    end;
    result := RaspiPortWrong;         // its already set and but set to what we want
end;

function ReadRaspiPort(Port : string; out Value : char) : boolean;
// The Value comes back as 0 if port is low (ie pump or heater is on).
begin
    Result := ReadFromFile(PIN_PATH + 'gpio' + Port + '/value', Value);
    if not Result then Value := '-';
end;

function GetDevices(out DevArray: TStringArray) : integer;
var
    Info : TSearchRec;
begin
    Result := 0;
    setlength(DevArray{%H-}, Result);
    if FindFirst(DEV_PATH + '28-*', faAnyFile and faDirectory, Info)=0 then begin
        repeat
            inc(Result);
            setlength(DevArray, Result);    // Yeah, I know, slow. But only 4 or so calls.
            DevArray[Result-1] := DEV_PATH+Info.Name;
        until FindNext(Info) <> 0;
    end;
    FindClose(Info);
end;    

function ReadDevice(DName : string) : integer;
var
    InFile: TextFile;
    st : string;
    FFileName : string;
begin
    if pos('sys', DName) < 1 then
        DName := DEV_PATH + DName;
    FFileName := DName + '/' + 'temperature'; 
    // writeln('Opening ' + FFileName);
    if FileExists(FFileName) then begin
        AssignFile(InFile, FFileName);
        try
            reset(InFile);
            readln(InFile, St);
            closeFile(InFile);
        except
            on E: EInOutError do begin
                writeln('File Error when reading ' + DNAme + ' : ' + E.Message);
                exit(InvalidTemp);
            end;
        end;
        if St = '' then
            Result := InvalidTemp
        else
            Result := strtoint(St);         // Brave ! No error check ?
    end else Result := InvalidTemp;
end;

procedure UsePorts();                   // Just a test function
var
    Count : integer = 0;
    Value : char;
begin
    while Count < 20 do begin
        writeToFile(PIN_PATH + 'gpio' + PIN_HW_PUMP + '/value' , '1');
        if ReadFromFile(PIN_PATH + 'gpio' + PIN_HW_HEATER + '/value', Value)
            then writeln('Value is ' + Value)
        else writeln('Error Reading');
        sleep(1000);
        writeToFile(PIN_PATH + 'gpio' + PIN_HW_PUMP + '/value' , '0');
        if ReadFromFile(PIN_PATH + 'gpio' + PIN_HW_HEATER + '/value', Value)
            then writeln('Value is ' + Value)
        else writeln('Error Reading');
        sleep(1000);
        inc(Count);
    end;
end;

procedure ShowSensorInformation();
begin
    writeln('Found ' + inttostr(GetDevices(DevArray)) + ' devices');
    for Dev in DevArray do
        ReadDevice(Dev);
end;

function PopulateSensorArray(var DataArray : TSensorArray) : integer;
var
    Index : integer;
    Info : TSearchRec;
    Found : boolean;

    procedure AddToDataArray(ID, Name : string; V : longint; P : boolean);
    begin
        DataArray[Index].ID := ID;
        DataArray[Index].Name := Name;
        DataArray[Index].Value := V;
        DataArray[Index].Present := P;
    end;

begin
    // First, the ones we know about
    setlength(DataArray, length(TempSensors));
    for Index := low(TempSensors) to high(TempSensors) do begin
        AddToDataArray(TempSensors[Index], TempNames[Index], InvalidTemp, False);
    end;
    // OK, thats the theory, what can we find ?
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
    FindClose(Info);
    Result := length(DataArray);        // All may not be present however
end;

end.


(*
begin
    writeln('Found ' + inttostr(GetDevices(DevArray)) + ' devices');
    for Dev in DevArray do
        ReadDevice(Dev);

    exit;

    if  not SetGPIO(PIN_HEATER_1, False) then                    // LED
        writeln('Error, failed to SetGPIO ' + PIN_HEATER_1);

    if  not SetGPIO(PIN_HEATER_2, TRUE) then                    // Switch
        writeln('Error, failed to SetGPIO ' + PIN_HEATER_2);

    UsePorts();

    // readln;

    if not UnSetGPIO(PIN_HEATER_1) then
        writeln('Error, failed to UnSet');

    if not UnSetGPIO(PIN_HEATER_2) then
        writeln('Error, failed to UnSet');



end.*)




