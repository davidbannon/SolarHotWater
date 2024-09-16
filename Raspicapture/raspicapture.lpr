program raspicapture;

{$mode objfpc}{$H+}

{ A small command line (needs fpc only) that reads the Paspberry Pi's temp sensors
  and can also plot the resulting cvs files to png images.
  I find it easy to use Lazarus on my laptop as the editor, have the working dir
  mounted (using sshfs) on a loggertest pi with the compiler installed.

  On the Pi, ensure ExDrive is mounted (so we leave the SDCard alone) and run -
  $> sshfs dell:Pascal/SolarHotWater ExDrive/Pascal/DELL

  Down in that dir,  I have a script, compile.bash that should be run from the Pi
  $> bash ./compile.bash

  It contains these command lines -

  FPC="/media/dbannon/68058302-90c2-48af-9deb-fb6c477efea1/libqt5pas1/raspitest/FPC/fpc-3.2.2/bin/fpc"
  "$FPC" -MObjFPC -Scghi -CX -Cg -O3 -XX -l -vewnhibq -Fu.  -FU./lib/arm-linux-gnueabihf -FE.  -oraspicapture raspicapture.lpr

  On a RaspPI OS without GUI, you probably won't have /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'
  So, copy the file from elsewhere and put it in that place.

  Note that we record 20 readings per hour, one every 3 minutes. Each 3 minute data
  point is built from 3 readings, one per minute. A new index.html is written
  each time but the graphs are only updated (via cron) every 30 minutes.

  Crontab -
  =========
  # Finish off yesterdays graph, one minute after 1:00am
1 0 * * * /home/dbannon/bin/raspicapture -y -d /home/dbannon/http/

  # Every half hour, refresh todays graph, 3 minutes after half hour
3,33 * * * * /home/dbannon/bin/raspicapture -p -d /home/dbannon/http/

  On The Pi
  ==========
  Its necessary, on the pi, to insert the two necessary kernel modules as root -

  modprobe w1_gpio
  modprobe w1_therm

  Easy to put these into (an executable) /etc/rc.local
  I also start the raspicapture -c -d /home/dbannon/http/  there, as dbannon, using
  a bash script, startup, that waits a while after boot watching the clock to be sure
  time has been appropiatly set.

  Currently, the python 2.7 dependent web server and script that ensures the
  watering ports are off are also started there. Be nice to get rid of those
  python dependencies.

}
{$WARN 5024 off : Parameter "$1" not used}
uses
    {$IFDEF UNIX}cthreads, {$ENDIF}
    Classes, SysUtils, CustApp, DateUtils, pi_data_utils, Plotter, BaseUnix, Unix,
    isock, Raspi_Utils;


(* type TCtrlData = record
    Collector : longint;
    Tank : longint;
    Pump : string;
    Valid : boolean;
    end;            *)

type

    { Traspicapture }

    Traspicapture = class(TCustomApplication)
    protected
        procedure DoRun; override;
    public
        constructor Create(TheOwner: TComponent); override;
        destructor Destroy; override;
        procedure WriteHelp; virtual;
    private

        NotRaspi : boolean;
        SensorArray : TSensorArray;         // dynamic array, 1 rec per sensor. Collects data from know sensors.

                                            // Calculates effective ctrl data and appends
                                            // it to the passed string. noop in x86
        procedure AddCtrlData(var DataSt: string);
                                            // divides each total in array by its own number of points
        procedure CalculateSensors;
        procedure CheckData;
        function CollectTemps(): boolean;
                    // Returns a full file name to the current data (csv) file.
        function DataFileName(ADate: TDateTime): string;
        procedure DisplayIOPortList;
        procedure EnterCaptureLoop(Interval : TDateTime);

                        // If passed a csv filename, plots that, otherwie it must be either a
                        // -p or a -y on command line. Note we assume, if not -p it must be -y then.
                        // The passed csv file name will not include a path but we will have cd'ed.
        procedure PlotIt(FFName : string = '');

        function PumpAndHeater(): string;

        procedure ReportPortStatus(Status: TRaspiPortStatus);
        procedure ResetSensorData();
                        { Inputs : global AnArray. Outputs : writes a line to data file, writes a header.html file
                          When this is called, AnArray will have data for sensors 0..4 and (test mode) any
                          additional test sensors. We write an entry for all sensors incuding 0..4 even if
                          not present. So, in test mode, position in string of 1..5 is invalid and we expect
                          to find one extra, valid, sensor. Then, in all cases, we find P and H, single char
                          0 or 1, 0 representing item turned ON.
                          Then, optionally, we will have three more data points, Collector and Tank temp and
                          pump status. If those are present, they are expected to be valid.
                          In all cases, temps are long int, in milli degrees C.
                          Does not validate the data. Potential infinite lock spin. }
        procedure SaveContentToFile;
                        // Writes, to stdout, the char in Heater and Pump ports.
        procedure ShowIOPorts();
        procedure ShowSensors();
                        { Ctrl data comes from the actual HW controller via a inet socket.
                          result can be 0, 1, 2, 3 - 0 says no data, invalid, 1 says its based
                          on only 1 data point etc, ideally we want three ! Zeros the data points
                          as it goes. Caller may like to report a less than 3 result. }
        function AverageCtrlData(out D: TCtrlData): integer;
        procedure WriteHeaderFile();
        procedure ZeroCtrlData();
//        procedure WriteLog(msg: string);
        procedure WriteWebpage();
    end;

{ Traspicapture }



const AverageOver=3;          // we take 3 measurements, each waiting a minute
      NumbTries = 2;          // Number of times we might ask ReadSensor for its value.

var
      ExitNow : boolean;      // set by interrupt handlers to tell loop to exit.
      //CtrlDataArray : array [0..2] of TCtrlData are both declared in isock.pas
      Application: TRaspiCapture;
      SocketThread : TSocketThread;





procedure Traspicapture.WriteHelp;
begin
    writeln('Is a not Raspi : '+ booltostr(NotRaspi, true));
    writeln('Usage: ', ExeName, ' -h');
    writeln('-c --capture     Capture 3 data and write to a file, default just a report.');
    writeln('-m --minutes   * Number of minutes between each measurment, default one.');
    writeln('-d --directory * Dir to save capture file in. Defaults to current.');
//    writeln('-L --log_file  * To write logs to, default my log dir');
    writeln('-t --testmode    Captures (if enabled) on 10 second per data measure');
    writeln('-D --debug       Prints, to std out, some "as we go" information.');
    writeln('-p --plot        Plot from todays csv to png');
    writeln('-y --yesterday   Plot from yesterdays csv to png');
    writeln('-i --ioport      Display the io ports, 0=active or low.');
    writeln('-n --no_socket   Do not listen on tcp socket');
    writeln('eg raspicapture -c -d /home/dbannon/http/  to start an indefinite capture run.');
    writeln('If run without -c will just read and exit.');
    writeln('Always assumes 5 preset sensors present, reports absence with -1000000');
    Terminate;
    Exit;
end;


// --- (ie File, Console) ---  O U T   P U T   M E T H O D S -------------------




const OutName = 'index.html';

procedure Traspicapture.WriteWebpage;
var
    InFile, OutFile : TextFile;
    St : string;
    ADate : TDateTime;
    APath : string = '';

    function PNGName(DaysAgo : integer) : string;
    begin
        result := FormatDateTime('yyyy-mm-dd', ADate-DaysAgo) + '.png';
    end;
begin
    ADate := Now();
    if HasOption('d', 'directory') then begin
        APath := GetOptionValue('d', 'directory');
        if not APath.EndsWith(PathDelim) then
            APath := APath+PathDelim;
    end;
    if FileExists(APath + OutName) then
        deletefile(APath + OutName);
    if not FileExists(APath + 'index.template') then begin
        writelog('Traspicapture.WriteWebpage : ' + APath + 'index.template file does not exist.');
        writelog('So we will not update any web files here. Sorry about that.');
        exit;
    end;
    if HasOption('D', 'Debug') then writelog('Traspicapture.WriteWebpage opening ' + APath + 'index.template');
    AssignFile(InFile, APath + 'index.template');
    if HasOption('D', 'Debug') then writelog('Traspicapture.WriteWebpage opening ' + APath + OutName);
    AssignFile(OutFile, APath + OutName);
    reset(InFile);
    Rewrite(OutFile);
    if HasOption('D', 'Debug') then writelog('Traspicapture.WriteWebpage Webfile opened');
    while not eof(InFile) do begin
        readln(InFile, St);
        case St of
            'AMBIENT' : writeln(OutFile, 'Current ambient temp : <b>'
                    + FormatFloat('0.00', (SensorArray[3].Value {div AVERAGEOVER}) / 1000.0) + '</b>');
            'IMAGE_TODAY' : writeln(OutFile, '    <embed type="image/png" src="'
                    + PNGName(0) + '" />');
            'IMAGE_YESTERDAY' : writeln(OutFile, '    <embed type="image/png" src="'
                    + PNGName(1) + '" />');
            'IMAGE_2DAYS' : writeln(OutFile, '    <embed type="image/png" src="'
                    + PNGName(2) + '" />');
            'IMAGE_3DAYS' : writeln(OutFile, '    <embed type="image/png" src="'
                    + PNGName(3) + '" />');
        else
            writeln(OutFile, St);
        end;
    end;
    closeFile(OutFile);
    CloseFile(InFile);
    if HasOption('D', 'Debug') then writelog('Traspicapture.WriteWebpage finished with Web files');
end;

procedure Traspicapture.PlotIt(FFName: string);
var
    Plot : TPlot;
begin
    if DoDebug then writeln('Traspicapture.PlotIt');
    Plot := TPlot.Create;
    if Plot = nil then begin
      writeln('Traspicapture.PlotIt - cannot create TPlot.');
      exit;
    end else if DoDebug then writeln('Traspicapture.PlotIt TPlot Created');
    if FFName <> '' then
        Plot.FullFileName := FFName
    else
        if HasOption('p', 'plot') then
              Plot.FullFileName := DataFileName(now())
        else  Plot.FullFileName := DataFileName(now()- 1.0);    // Yesterday
    Plot.Free;
end;

procedure Traspicapture.ShowIOPorts;
var
    P, H : char;
begin
    if NotRaspi then
        writeln('Cannot show ports on non Raspi')
    else
        if ReadRaspiPort(PIN_HW_PUMP, P)
            and ReadRaspiPort(PIN_HW_HEATER, H) then
                  writeln('Ports Pump: ' + P + ' and heater: ' + H)
        else writeln('Error reading ports');
end;

// Shows status of ports we are interested in. 0=low. Reports 'unexported' if so.
procedure Traspicapture.DisplayIOPortList;
var
    Ports : TStringArray = ('22', '17', '8', '25');
    St, State : string;
    Ch : char;
begin
    for St in Ports do begin
        if not TestRaspiPort(St,  State) then
            writeln('GPIO ', St, ' does not appear to be valid')
        else begin
            if State = '' then writeln('GPIO ', St, ' is unexported, not in use.')
            else begin
                if not ReadRaspiPort(St, ch) then
                    writeln('Error reading port ' + St);
                if State = 'in' then
                    writeln('GPIO ', St, ' is set to IN, value = ', Ch);
                if State = 'out' then
                    writeln('GPIO ', St, ' is set to OUT, value = ', Ch);
            end;
        end;
    end;
end;

function Traspicapture.DataFileName(ADate: TDateTime): string;
begin
    if HasOption('d', 'directory') then begin
        Result := GetOptionValue('d', 'directory');
        if Result[length(Result)] <> PathDelim then
            Result := Result + PathDelim;
    end else Result := '';
    Result := Result + FormatDateTime('yyyy-mm-dd', ADate) + '.csv';
end;


{  writes something like this (content after '+' added 24Aug24
12:56,45750,23729,22478,19270,29249,1,0,35977,25228,COLLECTHOT+WasOn
12:59,45395,23833,23187,19416,28020,0,0,27192,25960,OFF+OFF
}
{ Now expects to find numbers in SensorArray pre-calculated. }

procedure Traspicapture.SaveContentToFile();
var
    FFileName : string = '';
    TimeSt, DataSt : string;
    F : TextFile;
    TheNow : TDateTime;
    Index : integer = 0;
begin
    TheNow := now();
    DataSt := '';
    TimeSt := FormatDateTime('hh:mm', TheNow);
    FFileName := DataFileName(TheNow);
    for Index := low(SensorArray) to high(SensorArray) do
        if (Index < 5)  or SensorArray[Index].Present then                 // Always first five 0-4, remainder just testing
            DataSt := DataSt + ',' + inttostr(SensorArray[Index].Value);

    DataSt := DataSt +PumpAndHeater();                 // Pump and Heater. 0 means on, powered.
    while LockedBySocket do sleep(5);                  // Wait for Socket to finish, should be very quick and only occasionally
    LockedByCapture := True;
    AddCtrlData(DataSt);
    LockedByCapture := False;
    if HasOption('D', 'debug') then writelog('Saving data to ' + FFileName + ' [' + DataSt + ']');
    AssignFile(F, FFileName);
    if FileExists(FFileName) then
        Append(F)
    else  Rewrite(F);
    writeln(F, TimeSt + DataSt);
    closeFile(F);
end;

procedure Traspicapture.WriteHeaderFile();
var
    FFileName : string = '';
    F : TextFile;
begin
    if high(SensorArray) >= 4 then begin                     // always true ??
        if HasOption('d', 'directory') then begin
            FFileName := GetOptionValue('d', 'directory');
            if FFileName[length(FFileName)] <> PathDelim then
                FFileName := FFileName + PathDelim;
            FFileName := FFileName + 'header.html';
        end else FFileName := 'header.html';
        AssignFile(F, FFileName);
        Rewrite(F);
        writeln(F, '<HTML><BODY><h1>Davos Temperature Logger '
            + FormatFloat('0.00', (SensorArray[3].Value {div AVERAGEOVER}) / 1000)   // '3' is index of ambiant
            + '</h1></BODY></HTML>');
        closeFile(F);
    end;
    // if HasOption('D', 'debug') then writelog('Finished saving data, will call WriteWebpage()');
    WriteWebpage();
    // if HasOption('D', 'debug') then writelog('Finished WriteWebpage()');
end;

{ Saved Data looks like this, one row every time interval, at least five data data columns
Note the InvalidTemps at 22:43 -

22:37,37083,22020,25437,21166,24291
22:40,37062,21958,25458,21249,24250
22:43,-308666,-318750,-316375,-319125,-317208
22:46,36958,21791,25437,20999,24125
22:49,36875,21708,25437,20770,24083  }


// Iterates over the array of sensors checking the data present for each one.
// Expects each to have valid data if Present and reports anomolies.
procedure Traspicapture.CheckData;                                               // maybe we don't this anymore ?
// Rules - if Sensor was Present at startup, it better have data now, priority
//       - if there is one Sensor from the presets (first 5) then there better be all.
var
    index : integer;
    PresentFirstFive : boolean = false;
    AbsentFirstFive : boolean = false;
begin
    for Index := low(SensorArray) to high(SensorArray) do begin
        if SensorArray[Index].Present and (SensorArray[Index].Value = InvalidTemp) then
            writelog('ERROR no temp for sensor that was available at start '
                + SensorArray[Index].ID);
        if (Index < 5) and SensorArray[Index].Present then  PresentFirstFive := True;
        if (Index < 5) and (not SensorArray[Index].Present) then  AbsentFirstFive := True;
    end;
    if  PresentFirstFive and AbsentFirstFive then
         writelog('ERROR at least one sensor from first 5 is working and at least one other is not.');
end;


// -------------------- P I   S P C I F I C   I / 0 ----------------------------
// eg i/o ports, temp readings

procedure Traspicapture.ReportPortStatus(Status: TRaspiPortStatus);
begin
    case Status of
        RaspiPortSuccess : writelog('Port was available, now set as requested');
        RaspiPortAlready : writelog('Port was already set as requested');
        RaspiPortWrong   : writelog('Port was and is still set to wrong mode');
        RaspiPortNoSet   : writelog('Port looks OK but we cannot set it ???');
        RaspiPortNoIO    : writelog('Error accessing ports, possibly no I/O hardware');
        RaspiPortNoAccess: writelog('Error accessing ports, are you a member of the gpio group');
    end;
end;

procedure Traspicapture.ResetSensorData();
var i : integer;
begin
    for i := low(SensorArray) to high(SensorArray) do begin
        SensorArray[i].Points := 0;
        SensorArray[i].Value := 0;
    end;
end;

function Traspicapture.CollectTemps() : boolean;
var Tries : integer = 0;
    i : integer;
    RetValue : longint;
    St : string;
begin
    Result := false;
    if NotRaspi then begin
        for i := low(SensorArray) to high(SensorArray) do begin
            if SensorArray[i].Present then begin
                SensorArray[i].Value := SensorArray[i].Value + (i*10000);
                inc(SensorArray[i].Points);
                if SensorArray[i].Points >= AverageOver then Result := True;
            end;
        end;
        exit();
    end;

    for i := low(SensorArray) to high(SensorArray) do begin
        Tries := 0;
        if SensorArray[i].Present then begin
            while Tries < NumbTries do begin                // as NumbTries is 2, we only re-try once.
                RetValue := ReadDS18B20(SensorArray[i].ID);
                if RasPi_Utils_Error <> '' then             // ReadDS18B20() felt the need to retry
                    writelog('WARNING : CollectTemps() DS18B20 ' +  SensorArray[i].ID + ' : ' + RasPi_Utils_Error);
                if (RetValue <> InvalidTemp)                // ReadDS18B20() might set InvalidTemp
                        and (RetValue > -20000)             // but it sometimes set a nonsense very neg number !
                        and (RetValue <> -15) then break;   // break out of while loop and use data
                inc(Tries);
                writelog('WARNING : CollectTemps() DS18B20() ' +  SensorArray[i].ID + 'return invalid ' + RetValue.ToString + ', try ' + Tries.ToString);
            end;
            if Tries < NumbTries then begin                 // use the data, else give up and try next sensor.
                if HasOption('D', 'debug') then begin
                    St := 'notice : reading ';
                    St := St.PadRight(17 + (i*6));
                    writelog(St + RetValue.ToString);
                end;
                SensorArray[i].Value := SensorArray[i].Value + RetValue;
                inc(SensorArray[i].Points);
                if SensorArray[i].Points >= AverageOver then Result := True;        // Any one there and we call it
            end else begin
                writelog('ERROR : CollectTemps() ' +  SensorArray[i].ID + ' failed to get a reading for item ' + i.ToString);
                writelog('ERROR : ' + Get_RasPi_Utils_Error());
            end;
        end;
    end;
end;

// Where data exits in sensor array, averages it by dividing by number of data points.
// Is pre-processing one data line, ready to save to file.
procedure Traspicapture.CalculateSensors();
var
    i : integer;
begin
    for i := low(SensorArray) to high(SensorArray) do begin
        if SensorArray[i].Present then
            if SensorArray[i].Points > 0 then begin
                SensorArray[i].Value := SensorArray[i].Value div SensorArray[i].Points;
                if SensorArray[i].Points < AverageOver then
                    WriteLog('WARNING only ' + inttostr(SensorArray[i].Points) + ' data points for item '
                            + inttostr(i) + ' value=' + inttostr(SensorArray[i].Value));
            end else WriteLog('WARNING Zero Data Points for item ' + inttostr(i));
    end;
end;

function Traspicapture.PumpAndHeater() : string;
var
    P, H : char;
begin
    if NotRaspi then
        exit(',0,0');                                // That is, both 'on' !
    if (not ReadRaspiPort(PIN_HW_PUMP, P)) then begin
        if HasOption('D', 'debug') then writelog('Traspicapture.PumpAndHeater() failed to read pump port.');
        writeln('Traspicapture.PumpAndHeater() failed to read pump port.');
        P := ' ';
    end;
    if (not ReadRaspiPort(PIN_HW_HEATER, H)) then begin
        if HasOption('D', 'debug') then writelog('Traspicapture.PumpAndHeater() failed to read heater port.');
        writeln('Traspicapture.PumpAndHeater() failed to read heater port.');
        H := ' ';
    end;
    Result := ',' + P + ',' + H;
end;


procedure Traspicapture.ShowSensors();
var
    index : integer;
    TempSt : string;
begin
    writeln('Showing Sensors = ' + inttostr(length(SensorArray)) + ' and MAXINT=' + inttostr(MAXINT));
    for Index := low(SensorArray) to high(SensorArray) do begin
        if SensorArray[Index].Value <> InvalidTemp then
            TempSt := floattostr(SensorArray[Index].Value / 1000.0)
        else TempSt := 'n.a';
        writeln(SensorArray[Index].ID + ' ' + SensorArray[Index].Name + ' ' + TempSt);
    end;
    CheckData;
end;

// --------- C T R L   D A T A  gets sent from HW Ctrl box  --------------------

function Traspicapture.AverageCtrlData(out D : TCtrlData): integer;
var i : integer = 0;
begin
    D.Collector := 0;
    D.Tank  := 0;
    D.Pump  := 'OFF';
    D.PumpWas := 'OFF';
    D.Valid := false;
    while I < 3 do begin
        if CtrlDataArray[i].Valid then begin
            D.Collector += CtrlDataArray[i].Collector;
            D.Tank += CtrlDataArray[i].Tank;
            if CtrlDataArray[i].Pump <> 'OFF' then
                D.Pump := CtrlDataArray[i].Pump;       // we show Pump On when any one datapoint in array is ON
            if CtrlDataArray[i].PumpWas <> 'OFF' then
                D.PumpWas := CtrlDataArray[i].PumpWas;        // as above, means pump was on, however breifly, during whole cycle
            D.Valid := True;
            CtrlDataArray[i].Collector := 0;
            CtrlDataArray[i].Tank := 0;
            CtrlDataArray[i].Valid := False;
            CtrlDataArray[i].Pump := 'OFF';           // Pump state when ctrl data was sent
            CtrlDataArray[i].PumpWas := 'OFF';        // If not OFF, means pump was on some time during previous cycle
        end else break;
        inc(i);
    end;
    result := i;
    if i > 1 then begin            // 2 or 3
        D.Collector := D.Collector div i;
        D.Tank := D.Tank div i;
    end;
end;

procedure Traspicapture.ZeroCtrlData();
var i : integer = 0;
begin
    for i := 0 to 2 do begin
        CtrlDataArray[i].Collector := 0;
        CtrlDataArray[i].Tank := 0;
        CtrlDataArray[i].Valid := False;
        CtrlDataArray[i].Pump := 'OFF';
    end;
end;

procedure Traspicapture.AddCtrlData(var DataSt : string);
var
    Data : TCtrlData;
    Points : integer;
begin
    if HasOption('n', 'no_socket') then exit;
    Points := AverageCtrlData(Data);
    if Points = 0 then begin
        DataSt := DataSt + ', , , ';
        writeln('No solar control data available');
        exit;
    end
    else if Points < 3 then
            writeln(Points, ' solar control points available');
    DataSt := DataSt + ',' + inttostr(Data.Collector);
    DataSt := DataSt + ',' + inttostr(Data.Tank);
    DataSt := DataSt + ',' + Data.Pump + '+' + Data.PumpWas;     // will be either "OFF" or "COLLECTHOT" as set in Pico code
                                            // NOTE : the plotter currently ignores content in the last two fields.
end;



// --------------------- S T A R T   U P   C O D E -----------------------------


procedure Traspicapture.EnterCaptureLoop(Interval: TDateTime);
// Occasionally, ReadDevice will return  InvalidTemp defined in pi_data as -1,000,000
// But that is now CollectTemps() problem

var
    NextMeasure : TDateTime;
    Pump, Heater : TRaspiPortStatus;
    //Tick, Tock : qword;
begin
    NextMeasure := Now() + Interval;
    writeln('raspicapture : in EnterCapturLoop.');
    writelog('raspicapture : in EnterCaptureLoop.');
    if HasOption('D', 'Debug') then
         writelog('NOTICE : Traspicapture.EnterCaptureLoop starting socket server');
    if HasOption('n', 'no_socket') then
         writelog('NOTICE : Not Listening for Ctrl Box temps over TCP')
    else begin
        SocketThread := TSocketThread.Create(True);
        SocketThread.Start;
    end;
    if not NotRaspi then begin                                  // Setup the i/o Ports
        Pump := ControlPort(PIN_HW_PUMP, RaspiPortRead);
        if Pump = RaspiPortWrong then begin                     // The loop has priority, it can force the port
             ControlPort(PIN_HW_PUMP,   RaspiPortReset);
             Pump := ControlPort(PIN_HW_PUMP, RaspiPortRead);
        end;
        Heater := ControlPort(PIN_HW_HEATER, RaspiPortRead);
        if Heater = RaspiPortWrong then begin                     // The loop has priority, it can force the port
             ControlPort(PIN_HW_HEATER,   RaspiPortReset);
             Pump := ControlPort(PIN_HW_HEATER, RaspiPortRead);
        end;
        if not ((Heater = RaspiPortSuccess) or (Heater = RaspiPortAlready))
            and ((Pump = RaspiPortSuccess) or (Heater = RaspiPortAlready)) then begin
                writelog('ERROR : cannot get access to the I/O Ports');
                ReportPortStatus(Pump);
                ReportPortStatus(Heater);
                exit;
            end;
    end;
//    Tick := GetTickCount64;

    repeat
        if HasOption('D', 'debug') then writelog('About to check a batch of data');
        // if not NotRaspi then CheckData();         // we grabbed some data in DoRun()
        if CollectTemps() then begin     // Collects some temp readings and ret T is we have enough to write a line
            CalculateSensors();          // for the line of data, divide each point by its numb of points
            SaveContentToFile();         // writes one line to output file
            WriteHeaderFile();           // updates the header file
            ResetSensorData();           // ready to start collecting for next data point
        end;                             // that block seems to take 10 to 20 seconds
//        Tock := GetTickCount64;
//        writelog('NOTICE : data cycle took ' + (Tock - Tick).ToString + 'mS');
        while Now() < NextMeasure do begin                  // Wait here until next reading cycle.
            if ExitNow then begin                           // trigger by SIGTERM, default for kill command or ctrl-c
                if not NotRaspi then begin
                    ControlPort(PIN_HW_PUMP,   RaspiPortReset); // Note we always reset at exit, important
                    ControlPort(PIN_HW_HEATER, RaspiPortReset);
                end;
                terminate;                                  // this is the only exit from reepeat loop,
                exit;                                       // 'terminate' is a signal to Application object
            end;
            sleep(20);                                      // Puts a limit on our timing accuracy but not a problem
        end;
        NextMeasure := Now() + Interval;
//        Tick := GetTickCount64;
//        writeln('Next measure due at ' + formatdateTime('hh:mm:ss', NextMeasure));
        if HasOption('D', 'debug') then writelog('---- Collecting a new batch of temps ----');
    until 1<>1;
end;

procedure Traspicapture.DoRun;        // must call Terminate if you want this to not be recalled.
var
    ErrorMsg: String;
    NumbMinutes : integer;
    Interval : TDateTime;
    Pump, Heater : TRaspiPortStatus;
begin
    // writeln('Traspicapture.DoRun');
    NotRaspi := {$i %FPCTARGETCPU%} = 'x86_64';
    ErrorMsg:=CheckOptions('hm:cd:tpyDLsin', 'no_socket help minutes capture directory testmode plot debug log_file symlinks ioports');
    if ErrorMsg<>'' then begin
        ShowException(Exception.Create(ErrorMsg));
        Terminate;
        Exit;
    end;
    if HasOption('i', 'ioports') then begin
        DisplayIOPortList;
        Terminate;
        Exit;

        // ------ Code below has problems, gave exception, seemed to reset an active port .....
        // We must be carefull to not reset the ports if they were active before we got here.
        // ------------ this code is not being executed -------------
        Heater := ControlPort(PIN_HW_HEATER, RaspiPortRead);
        Pump   := ControlPort(PIN_HW_PUMP,   RaspiPortRead);
        if ((Heater = RaspiPortSuccess) or (Heater = RaspiPortAlready))         // it was in read or we set it so.
            and ((Pump = RaspiPortSuccess) or (Pump = RaspiPortAlready)) then
                ShowIOPorts()
        else begin
            ReportPortStatus(Pump);
            ReportPortStatus(Heater);                                           // in this case, an error msg really
        end;
        if Heater = RaspiPortSuccess then ControlPort(PIN_HW_HEATER, RaspiPortReset);       // NOOOOOOO !
        if Pump = RaspiPortSuccess then ControlPort(PIN_HW_Pump, RaspiPortReset);

(*        if ControlPort(PIN_HW_HEATER, RaspiPortRead)
            and ControlPort(PIN_HW_PUMP,   RaspiPortRead) then begin
                // sleep(100);                  // Must let ports settle after setting, maybe system dependent
                ShowIOPorts()                   // but we have timimg delays below so don't need it here.
            end
        else writeln('Cannot setup i/o ports');
        ControlPort(PIN_HW_PUMP,   RaspiPortReset);
        ControlPort(PIN_HW_HEATER, RaspiPortReset);    *)
        Terminate;
        Exit;
    end;

    if HasOption('D', 'debug') then begin
        writeln('Traspicapture.DoRun - Starting up in Debug mode.');
        DoDebug := true;
        DebugSock := True;
    end;

    if HasOption('h', 'help') then begin
        WriteHelp;
        exit;
    end;

    if HasOption('m', 'minutes') then begin
        try
            NumbMinutes := strtoint(GetOptionValue('m', 'minutes'));
        except on E:  EConvertError do
            WriteHelp;
        end;
        Interval := EnCodeTime (0,NumbMinutes,0,0);
    end else
        Interval := EnCodeTime (0,1,0,0);

    if HasOption('p', 'plot') or HasOption('y', 'yesterday')then begin
        PlotIt;
        Terminate;
        exit;
    end;

    if  HasOption('t', 'testmode') then
        Interval := EnCodeTime (0,0,10,0);          // Test mode, 10 second interval

    PopulateSensorArray(SensorArray, NotRaspi);                   // One-off setup of array with Sensor IDs
    if HasOption('D', 'debug') then writelog('Sensor Array Length is ' + inttostr(Length(SensorArray)));

    if HasOption('D', 'debug') then writelog('Collecting Data');
    CollectTemps();
    if HasOption('c', 'capture') then  begin        // we are either capturing to file or a one off show
        WriteLog('Starting Capture Loop');
        EnterCaptureLoop(Interval);                 // does not return.
    end else
        ShowSensors();                              // relies on the CollectTemps() a few lines up
    Terminate;
    //exit;
end;

constructor Traspicapture.Create(TheOwner: TComponent);
begin
    inherited Create(TheOwner);
//    CommsServer := Nil;
    StopOnException:=True;
    ZeroCtrlData();
end;

destructor Traspicapture.Destroy;
begin
    if HasOption('D', 'Debug') then writelog('Traspicapture.Destroy : free CommServer');
//    freeandnil(CommsServer);
    inherited Destroy;
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
    if not Application.HasOption('n', 'no_socket') then begin
        SocketThread.Terminate;
        SocketThread.Free;
    end;
    ExitNow := True;        // Loop will see this and exit when it sees fit.
end;


begin
    Application:=Traspicapture.Create(nil);
    Application.Title:='raspicapture';

    if FpSignal(SigInt, @HandleSigInt) = signalhandler(SIG_ERR) then begin
      Writeln('Failed to install signal error: ', fpGetErrno);
      Halt(1);
    end;
    if FpSignal(SigTerm, @HandleSigInt) = signalhandler(SIG_ERR) then begin
      Writeln('Failed to install signal error: ', fpGetErrno);
      Halt(1);
    end;

    Application.Run;

    if DoDebug then writeln('Freeing the application.');
    Application.Free;                  // cleanup of Thread and Socket not necessary here.
end.

