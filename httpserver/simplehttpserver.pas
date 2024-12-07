program simplehttpserver;

{ this demo, almostly completely unchanged from the $FPC/packages/fcl-web/examples/httpserver
  is ideal to serve up simple web pages on my logger.
  Notes : I needed to copy   ../echo/webmodule/wmecho.*  into dir before building
          I added a default of index.html
          I disabled the (very questionable) use of FCount to kill the server after
            serving five files. Who knows why this was here.
          Added (back) code to determine service dir and port on command line.
  DRB, 2024-12-07
}

{$mode objfpc}{$H+}
{$define UseCThreads}

uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  sysutils, Classes, fphttpserver, fpmimetypes, wmecho;

Type

  { TTestHTTPServer }

  TTestHTTPServer = Class(TFPHTTPServer)
  private
    FBaseDir : String;
//    FCount : Integer;
    FMimeLoaded : Boolean;
    FMimeTypesFile: String;
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
end;

procedure TTestHTTPServer.CheckMimeLoaded;
begin
  If (Not MimeLoaded) and (MimeTypesFile<>'') then
    begin
    MimeTypes.LoadFromFile(MimeTypesFile);
    FMimeLoaded:=true;
    end;
end;

procedure TTestHTTPServer.HandleRequest(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);

Var
  F : TFileStream;
  FN : String;

begin
  FN:=ARequest.Url;
  if FN = '/' then
    FN := '/index.html';                                // DRB
  If (length(FN)>0) and (FN[1]='/') then
    Delete(FN,1,1);
  DoDirSeparators(FN);
  FN:=BaseDir+FN;
  if FileExists(FN) then
    begin
    // writeln(' TTestHTTPServer.HandleRequest and file exits.');
    F:=TFileStream.Create(FN,fmOpenRead);
    try
      CheckMimeLoaded;
      AResponse.ContentType:=MimeTypes.GetMimeType(ExtractFileExt(FN));
      Writeln('Serving file: "',Fn,'". Reported Mime type: ',AResponse.ContentType);
      AResponse.ContentLength:=F.Size;
      AResponse.ContentStream:=F;
      AResponse.SendContent;
      AResponse.ContentStream:=Nil;
    finally
      F.Free;
    end;
    end
  else
    begin
    Writeln('Failed to Serve file: "', Fn, '". Reported Mime type: ',AResponse.ContentType);
    AResponse.Code:=404;
    AResponse.SendContent;
    end;
//  Inc(FCount);              This was some auto shutdown, I have no idea why
//  If FCount>=5 then
//    Active:=False;
end;

begin
  Serv:=TTestHTTPServer.Create(Nil);
  try
    Serv.BaseDir:=ExtractFilePath(ParamStr(0));

{$ifdef unix}
    Serv.MimeTypesFile:='/etc/mime.types';
{$endif}
    Serv.Port:=8080;
    if ParamCount > 0 then
      Serv.BaseDir:=ParamStr(1);
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

