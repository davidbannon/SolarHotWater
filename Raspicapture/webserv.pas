unit webserv;
{ Copyright David Bannon
  License:
  This code is licensed under MIT License, see https://opensource.org/license/mit
  or  https://spdx.org/licenses/MIT.html  SPDX short identifier: MIT
}
{ This unit is an alternative to isock unit. Instead of depending on a TCPIP
  soecket call from the PumpCtrl, here we depend on the (esp32) PumpCtrl
  running a basic web service, we ask it for the current data, remains to be
  seen how often we can do so.
  Because the interacton between boxes is connectionless, should be more
  reliable. Especially after a power off event.
  Find the C Code and circuit drawing for the ESP32-S3 module in other
  directories of this repo.

}
{$mode ObjFPC}{$H+}

interface

uses
    Classes, SysUtils, Data_Utils, fphttpclient, ssockets, fpopenssl;

type TContentType = (                   // the type of data we might ask a web downloader to get for us.
            ctText,                     // just plain text (utf8 ?)
            ctXML,                      // XML content, such as a note
            ctJSON,                     // JSON, much loved in GIThub
            ctHTML);                    // HTML, not sure if this us needed.

Type              { TWebServThread }
    TWebServThread = class(TThread)
        private
            procedure InsertData(SomeStr : string);
        protected
            procedure Execute; override;
        public
            Constructor Create(CreateSuspended : boolean);
            Destructor Destroy;override;
    end;


function Downloader(URL : string; out SomeString : String; const ConType : TContentType; const {%H-}Header : string = '') : boolean;

const
    ServIP = 'http://192.168.2.23/data';   // Locked in that IP and hostname hwctrl however, router sees it as esp32s3-07DA94 ??
                                           // neither seem to propergate across LAN so use IP.

var
    NetErrorString : string = '';
//    CtrlDataCritical : TCriticalSection;      // needs use syncobjs
    ThreadCount : integer = 0;                // 0..1

implementation

uses pi_data_utils;

{ Start a thread that reads the WebService server, merges the data in the array and
  exits.
  The merge data is protected by a CriticalSection.
  We do not allow a second thread, inc a counter (in ThreadCount) and don't start
  new one if that counter is not zero.
}

{ TWebServThread }

procedure TWebServThread.InsertData(SomeStr: string);
var
    i : integer = 0;
    LongArray : array [0..3] of longint;        // the size and use of each element if defined in Control Code
    StArray : TStringArray;

    procedure UpdateCtrlArray();
    begin
        if GrabLock(ThreadLock, 200, 6) then begin
            try
                while i <= high(CtrlDataArray) do begin
                    if (not CtrlDataArray[i].Valid) then begin
                         CtrlDataArray[i].Collector   := LongArray[0];
                         CtrlDataArray[i].Tank        := LongArray[1];
                         CtrlDataArray[i].PercentPump := LongArray[2];
                         CtrlDataArray[i].PumpJams    := LongArray[3];
                         CtrlDataArray[i].Valid       := True;
                         break;
                    end;
                    inc(i);          // note we just drop it on the floor if we cannot find an empty slot.
                end;
                if DebugWebService and (i = high(CtrlDataArray) + 1) then
                    writelog('TWebServThread.InsertData - cannot find empty slot for CtrlData');
            finally
                // CtrlDataCritical.Leave;
                InterLockedExchange(ThreadLock, 0);   // release it
            end;
        end;
    end;

begin
    writelog('TWebServThread.InsertData - has CtrlData string [' + SomeStr + ']');
    StArray := SomeStr.Split(',');
    if (length(StArray) = 4) then begin     // Not much of a sanity check but ...
        if TryStrToInt(StArray[0], LongArray[0])
            and TryStrToInt(StArray[1], LongArray[1])
            and TryStrToInt(StArray[2], LongArray[2])
            and TryStrToInt(StArray[3], LongArray[3])
            then begin                             // OK, we have the four numbers.
                UpdateCtrlArray();
                exit;
            end;
    end;
    // Only get to here if things have gone hopelessly wrong.
    writelog('ERROR : TWebServThread.InsertData - bad CtrlData string [' + SomeStr + ']');
 end;


procedure TWebServThread.Execute;
var SomeStr : string = '';
begin
    if Terminated then exit;
    InterlockedIncrement(ThreadCount);
//    self.Synchronize();           // does this work in plain fpc app ?


    FreeOnTerminate := True;
    if Downloader(ServIP, SomeStr, ctText) then
        InsertData(SomeStr);
    InterlockedDecrement(ThreadCount);
end;

constructor TWebServThread.Create(CreateSuspended: boolean);
begin
    inherited Create(CreateSuspended);
end;

destructor TWebServThread.Destroy;
begin
     inherited Destroy;
end;


// -----------------------------------------------------------------------------

function SayDebugSafe(st: string) : boolean;
begin
    // {$ifdef LCL}Debugln{$else}writeln{$endif}(St);     // LCL is defined because we use some gtk2 libs to generate image
    writelog(St);
    result := false;
end;

// if Downloader(ServIP, SomeString, ctText) then all good.
function Downloader(URL : string; out SomeString : String; const ConType : TContentType; const Header : string = '') : boolean;
var
    Client: TFPHTTPClient;
begin
    //InitSSLInterface;
    // curl -i -u $GH_USER https://api.github.com/repos/davidbannon/libappindicator3/contents/README.note
    Client := TFPHttpClient.Create(nil);
//    Client.UserName := UserName;
//    Client.Password := Password; // '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';     eg a github token
    Client.AddHeader('User-Agent','Mozilla/5.0 (compatible; fpweb)');
    case ConType of
        ctXML : Client.AddHeader('Content-Type','application/xml; charset=UTF-8');
        ctText : Client.AddHeader('Content-Type','application/text; charset=UTF-8');
        ctJSON : Client.AddHeader('Content-Type','application/json; charset=UTF-8');
        ctHTML : Client.AddHeader('Content-Type','application/HTML; charset=UTF-8');
    end;
    Client.AllowRedirect := true;
    Client.ConnectTimeout := 3000;     // mS ? was 3000, not for a non-existant server ?
    Client.IOTimeout := 4000;          // mS ? was 0 - no idea what these are for.
    SomeString := '';
    try
        try
            SomeString := Client.Get(URL);
            //SayDebugSafe('Downloader Code:' + inttostr(Client.ResponseStatusCode) + ' - ' + SomeString);
        except
            on E: EHTTPClient do begin                                          // eg, File Not Found, we have asked for an unavailablee
                NetErrorString := 'Downloader - EHTTPClient Error ' + E.Message
                    + ' ResultCode ' + inttostr(Client.ResponseStatusCode);
                exit(SayDebugSafe(NetErrorString));
            end;
            on E: ESocketError do begin
                NetErrorString := 'Downloader - SocketError ' + E.Message     // eg failed dns, timeout etc
                    + ' ResultCode ' + inttostr(Client.ResponseStatusCode);
                SomeString := 'Is server available ?';
                exit(SayDebugSafe(NetErrorString));
                end;
            on E: EInOutError do begin
                NetErrorString := 'Downloader - InOutError ' + E.Message;
                // might generate "TGithubSync Downloader - InOutError Could not initialize OpenSSL library"
                SomeString := 'Failed to initialise OpenSSL';           // is error message translated ?
                exit(SayDebugSafe(NetErrorString));
                end;
            on E: ESSL do begin
                NetErrorString := 'Downloader - SSLError ' + E.Message;         // eg openssl problem, maybe FPC cannot work wil
                SomeString := 'Failed to work with OpenSSL';
                exit(SayDebugSafe(NetErrorString));
                end;
            on E: Exception do begin
                NetErrorString := 'Downloader Unexpected Exception ' + E.Message + ' downloading ' + URL;
                NetErrorString := NetErrorString + ' HTTPS error no ' + inttostr(Client.ResponseStatusCode);
                exit(SayDebugSafe(NetErrorString));
                end;
        end;
        Result := Client.ResponseStatusCode = 200;
    finally
        Client.Free;
    end;
end;



end.

