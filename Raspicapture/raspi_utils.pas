unit Raspi_Utils;

{$mode ObjFPC}{$H+}

{ A library unit that knows how to talk to Raspi Ports and to DS18B20 temp sensor
  devices connected to the Raspi.
  Defines some types so that make handling the above a bit easier.
}

// cat /sys/bus//w1/devices/28-00000400bce7/temperature
// 25000
// https://simonprickett.dev/controlling-raspberry-pi-gpio-pins-from-bash-scripts-traffic-lights/

interface

uses
    Classes, SysUtils;

const
    // eg '/sys/bus//w1/devices/28-00000400bce7/temperature';
    DEV_PATH = '/sys/bus/w1/devices/';
    PIN_PATH = '/sys/class/gpio/';
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
  TSensorRec = Record
        ID : string;        // eg 28-001414a820ff
        Name : string;      // eg Ambient
        Value : longint;    // raw numbers from sensor or -1 if invalid, milli degrees C
        Points : integer;   // number of data points collected for this sensor
        Present : boolean;  // Is this sensor present ?
  end;

                  // connect DS18B20 to header pins 1 (3v3), 7 (GPIO.4), 9 (gnd)
                  // a single 4k7 resistor between 3v3 and GPIO.4

                  // Reads the temperature from DS18B20 device. As bad reads not uncommon
                  // we will try again if necessary, this produces a close to 100% result.
                  // Most likely failure is read returns an empty string, just re-read.
                  // Less frequently, FileExits() says its not there, try again.
                  // Data returned is an integer representing milli degrees C, InvalidTemp
                  // means something still managed to go wrong. DName is either a full file
                  // name to the device or the device ID, eg 28-001414a820ff
                  // Resets error st before it starts.
function ReadDS18B20(DName : string) : integer;

                  // Must call this before using a port (PortNo, RaspiPortRead|RaspiPortWrite)
                  // and before exiting (PortNo,  RaspiPortReset). Note : GPIO or Broardcom
                  // numbers, not on board, header numbers. Use GPIO numbers exclusivly !
                  // eg GPIO.2 is physical header pin 3
function ControlPort(PortNo : string; AnAction : TRaspiPortControl) : TRaspiPortStatus;

                    // Returns with either '0', '1' or, if error, '-'. '0' indicates port is low.
                    // Assumes port is already setup for data input. Returns F on error.
function ReadRaspiPort(Port : string; out Value : char) : boolean;

                  // Returns True if the Port can be accessed and returns with its state, 'in', 'out', '';
                  // If True and State = '' then the port is 'unexported', ie, not in use.
                  // If it ret False, an error, reason is in State ('no gpio' or 'no access')
function TestRaspiPort(PortNo : string; out State : string) : boolean;

                // Displays, to console, a summary of the DS18B20 sensors right now.
procedure ShowSensorInformation();


                // returns the last Error and clears the error string;
function Get_RasPi_Utils_Error() : string;

var
    RasPi_Utils_Error : string = '';    // may show previous errors if not cleared.

implementation

function ReadFromFile(const FFName : string; out ch : char) : boolean;
var
    F : TextFile;
begin
    if not FileExists(FFname) then begin
        RasPi_Utils_Error :=  'pi_data_util ReadFromFile - ERROR : port file ' + FFName + ' - does not exist';
        // writeln('pi_data_util ReadFromFile - ERROR : port file ' + FFName + ' - does not exist');
        exit(False);
    end;
    Result := True;
    AssignFile(F, FFName);
    try try
        reset(F);
        readln(F, Ch);
    except
        on E: EInOutError do begin
            RasPi_Utils_Error := 'Raspi_utils ReadFromFile - ERROR : ' + FFName + ' - ' +  E.Message;
            // writeln('pi_data_util ReadFromFile - ERROR : ' + FFName + ' - ' +  E.Message);
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
        RasPi_Utils_Error := 'Raspi_Utils I/O ERROR Code ' + inttostr(ErrorNo) + ' ' + FFName;
        // writeln('I/O ERROR Code ' + inttostr(ErrorNo) + ' ' + FFName);
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

function Get_RasPi_Utils_Error(): string;
begin
    Result := RasPi_Utils_Error;
    RasPi_Utils_Error := '';
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

// Returns with either '0', '1' or, if error, '-'. '0' indicates port is low.
// Assumes port is already setup for data input. Returns F on error.
function ReadRaspiPort(Port : string; out Value : char) : boolean;
// The Value comes back as 0 if port is low (ie pump or heater is on).
begin
    Result := ReadFromFile(PIN_PATH + 'gpio' + Port + '/value', Value);
    if not Result then Value := '-';
end;

function ReadDS18B20(DName : string) : integer;
var
    InFile: TextFile;
    st : string;
    FFileName : string;

    procedure DoTheRead();
    begin
        RasPi_Utils_Error := '';
        if FileExists(FFileName) then begin
            AssignFile(InFile, FFileName);
            try
                reset(InFile);
                readln(InFile, St);
                if St = '' then begin         // its not unusual for a read to fail
                    reset(InFile);            // in almost all cases, a reading again is succeessful
                    readln(InFile, St);
                end;
                closeFile(InFile);
            except
                on E: EInOutError do begin
                    RasPi_Utils_Error := 'RasPi_Utils_Error : File Error when reading ' + DNAme + ' : ' + E.Message;
                    writeln(RasPi_Utils_Error);
                    Result := InvalidTemp;
                    exit;
                end;
            end;


(*            if St = '-15' then begin       // I see, maybe twice a day, any one sensor return -15 and its wrong !
                Result := InvalidTemp;
                RasPi_Utils_Error := 'WARNING : RasPi_Utils_Error : ReadDevice - returned -15';
                exit;
            end;         *)                  // deal with this in calling unit


            if St = '' then begin
                Result := InvalidTemp;
                RasPi_Utils_Error := 'RasPi_Utils_Error : ReadDevice - empty string';
            end else
                try
                    Result := strtoint(St);
                except on EConvertError do begin
                        Result := InvalidTemp;
                        RasPi_Utils_Error := 'RasPi_Utils_Error : Exception converting read : [' + St + ']';
                    end;
                end;
        end else begin
            Result := InvalidTemp;
            RasPi_Utils_Error := 'RasPi_Utils_Error : device ' + DName + ' does not exist';
        end;
    end;

begin
    Result := 0;                // No, this cannot be returned, DoTheRead() will set it to something.
    if pos('sys', DName) < 1 then
        DName := DEV_PATH + DName;
    FFileName := DName + '/' + 'temperature';
    DoTheRead();
    if Result = InvalidTemp then            // we try again.
        DoTheRead();
end;


function GetDS18B20Devices(out DevArray: TStringArray) : integer;
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

procedure ShowSensorInformation();
var
    DevArray : TStringArray;
    Dev : string;
begin
    writeln('Found ' + inttostr(GetDS18B20Devices(DevArray)) + ' devices');
    for Dev in DevArray do
        writeln('Dev : ' + Dev, ReadDS18B20(Dev));
end;

end.

