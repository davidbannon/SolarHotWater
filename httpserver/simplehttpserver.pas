program simplehttpserver;

{ License
  This code is an almost identical copy of the same code distributed with FPC and,
  as such, is covered by the same license as (most?) the rest of FPC.
}

{ this demo, almostly completely unchanged from the $FPC/packages/fcl-web/examples/httpserver
  is ideal to serve up simple web pages on my logger.
  Notes : I needed to copy   ../echo/webmodule/wmecho.*  into dir before building
          I added a default of index.html
          If we land in a dir without index.html, give a list of files in there.
          Handle trailing slash as it should.
          I disabled the (very questionable) use of FCount to kill the server after
            serving five files. Who knows why this was here.
          Added a means to terminate gracefull, Ctrl-C or SIGTERM
          Added a touch of help on command line.
  DRB, 2025-02-06
}

{$mode objfpc}{$H+}
{$define UseCThreads}

uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  sysutils, Classes, fphttpserver, fpmimetypes, wmecho,
  BaseUnix;       // for Signal Names  Hmm, windows ?  No idea !

Type

  { TTestHTTPServer }

  TTestHTTPServer = Class(TFPHTTPServer)
  private
    FBaseDir : String;
//    FCount : Integer;
    FMimeLoaded : Boolean;
    FMimeTypesFile: String;
    procedure GenerateFileList(FFName: string; AResp: TFPHTTPConnectionResponse);
    function MyAppendPathDelim(APath: string): string;
    procedure SetBaseDir(const AValue: String);
  Protected
    Procedure DoIdle(Sender : TObject);
    procedure CheckMimeLoaded;

    Property MimeLoaded : Boolean Read FMimeLoaded;
  public
    procedure HandleRequest(Var ARequest: TFPHTTPConnectionRequest;
                            Var AResponse : TFPHTTPConnectionResponse); override;
    Property BaseDir : String Read FBaseDir Write SetBaseDir;
    Property MimeTypesFile : String Read FMimeTypesFile Write FMimeTypesFile;

  end;

Var
  Serv : TTestHTTPServer;
  ExitNow : boolean;           // A semaphore set when ctrl-C received

{ TTestHTTPServer }

procedure TTestHTTPServer.SetBaseDir(const AValue: String);
begin
  if FBaseDir=AValue then exit;
  FBaseDir:=AValue;
  If (FBaseDir<>'') then
    FBaseDir:=IncludeTrailingPathDelimiter(FBaseDir);
end;

procedure TTestHTTPServer.DoIdle(Sender: TObject);
begin
  // Writeln('Idle, waiting for connections');
    if ExitNow then Serv.Active := False;      // Shutdown by a signal
end;

procedure TTestHTTPServer.CheckMimeLoaded;
begin
  If (Not MimeLoaded) and (MimeTypesFile<>'') then
    begin
    MimeTypes.LoadFromFile(MimeTypesFile);
    FMimeLoaded:=true;
    end;
end;

function TTestHTTPServer.MyAppendPathDelim(APath : string) : string;    // here to avoid use lazfileutils
begin
    if APath[length(APath)] <> PathDelim then
        Result := APath + PathDelim
    else Result := APath;
end;

procedure TTestHTTPServer.GenerateFileList(FFName : string; AResp : TFPHTTPConnectionResponse);   // doppy, this should be a stream ....
var
    STL : tstringlist;
    Info : TSearchRec;
begin
    STL := TStringList.Create();
    STL.Insert(0, '<html><body><h1>File List</h1>');
    Stl.Add('<table>');
    If FindFirst (FFName + '*',faAnyFile, Info)=0 then begin
        Stl.Add('<tr>');
        repeat
            if (Info.Name = '.') or (Info.Name = '..') then continue;
            if (Info.Attr and faDirectory) = faDirectory then
                Stl.add('<td>Directory</td><td><a href="' + Info.Name + '/">' + Info.Name + '</td>')
            else begin
                Stl.add('<td>' + inttostr(Info.size) + '</td><td><a href="'+ Info.Name + '">' + Info.Name + '</a></td>');
            end;
            Stl.add('</tr>');
        until FindNext(info) <> 0;
    end;
    Stl.add('</table>');
    FindClose(Info);
    Stl.Add('</body></html>');
    AResp.Content := StL.Text;
    STL.Free;
    AResp.SendContent;
end;

procedure TTestHTTPServer.HandleRequest(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
Var
  F : TFileStream;
  FN : String;

    // Looks at URL, if it can make it work by adding an index.html or a '/' (ie dir) does so,
    // returns True. If it returns false, nothing we can do, missing file or dir.
    function CheckURL() : boolean;
    begin
            Result := True;
            if (length(FN)>0) and (FN[1]='/') then
                Delete(FN,1,1);
            DoDirSeparators(FN);       // Make a path contain appropiate seperators.
            if FileExists(BaseDir + FN) then begin
                FN:=BaseDir+FN;
                exit(true);            // user has entered a usable filename
            end;
            if FileExists(BaseDir + FN + 'index.html') then begin
                FN:=BaseDir+FN + 'index.html';
                exit(true);            // a dir that does contain an index.html
            end;
            if DirectoryExists(BaseDir+FN) then begin
                FN := MyAppendPathDelim(BaseDir+FN);
                if FileExists(FN + 'index.html') then
                    FN := FN + 'index.html';
                exit(True);
            end;
            // If to here, user must have put an invalid file or dir in URL
            result := False;
    end;

begin
    FN:=ARequest.Url;
//    writeln('TTestHTTPServer.HandleRequest : User requested ', FN);
    if not CheckURL() then begin
        AResponse.Code:=404;                       // ToDo : this does not work
        writeln('TTestHTTPServer.HandleRequest : File or Dir not found [', FN, ']');
        AResponse.Content := '<html><body><h2>ERROR 404, File or Dir not found</h2></p>' + FN + '</p></body></html>';
        AResponse.SendContent;
        exit;            ;
    end;
    // Here, we believe we can help the user, either with a file or a dir list.
    if (length(FN) = 0) or (FN[length(FN)] = PathDelim) then begin            // trailing Sep says is just a dir.
//        Writeln('No file to serve, will do file list, FN=[', FN, ']');
        GenerateFileList(FN, AResponse);
        exit;
    end;
    // If to here, we seem to have a file to serve, do so !
    // writeln(' TTestHTTPServer.HandleRequest and file exists.');
    F:=TFileStream.Create(FN,fmOpenRead);
    try
        CheckMimeLoaded;
        AResponse.ContentType:=MimeTypes.GetMimeType(ExtractFileExt(FN));
//        Writeln('Serving file: "',Fn,'". Reported Mime type: ',AResponse.ContentType);
        AResponse.ContentLength:=F.Size;
        AResponse.ContentStream:=F;
        AResponse.SendContent;
        AResponse.ContentStream:=Nil;
    finally
        F.Free;
    end;
end;

procedure HandleSigInt(aSignal: LongInt); cdecl;
begin
    case aSignal of
        SigInt : Writeln('Ctrl + C used, will clean up and shutdown.');
        SigTerm : writeln('TERM signal, will clean up and shutdown.');
    else
        begin writeln('Some signal received ??'); exit; end;
    end;
    ExitNow := True;            // Watched by the Idle method
end;

{begin
     }

begin
    if FpSignal(SigInt, @HandleSigInt) = signalhandler(SIG_ERR) then begin
        Writeln('Failed to install signal error: ', fpGetErrno);
        exit;
    end;
    if FpSignal(SigTerm, @HandleSigInt) = signalhandler(SIG_ERR) then begin
        Writeln('Failed to install signal error: ', fpGetErrno);
        exit;
    end;


  Serv:=TTestHTTPServer.Create(Nil);
  try
    Serv.BaseDir:=ExtractFilePath(ParamStr(0));

{$ifdef unix}
    Serv.MimeTypesFile:='/etc/mime.types';
{$endif}
    Serv.Port:=8080;
    if ParamCount > 0 then begin
        if (ParamStr(1) = '-h') or (ParamStr(1) = '--help') or (ParamStr(1) = 'help') then begin
            writeln('Usage ', ExtractFileName(ParamStr(0)), ' [BaseDir] [Port]');
            exit;
        end;
      Serv.BaseDir:=ParamStr(1);
    end;
    if ParamCount > 1 then
      Serv.Port:=StrToIntDef(ParamStr(2),8080);
    Serv.Threaded:=False;
    Serv.AcceptIdleTimeout:=1000;
    Serv.OnAcceptIdle:=@Serv.DoIdle;
    writeln(ParamStr(0), ' starting, serving from ', Serv.BaseDir, ' on port ', Serv.Port);
    Serv.Active:=True;
  finally
    Serv.Free;
  end;
end.

