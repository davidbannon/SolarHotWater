unit Plotter;

{ Copyright David Bannon
  License:
  This code is licensed under MIT License, see https://opensource.org/license/mit
  or  https://spdx.org/licenses/MIT.html  SPDX short identifier: MIT
}


{ Unit that takes a cvs file full of temperature datapoints (five per row) and plots
them into a PNG file. Single char (still comma seperated) beyond that are plotted
in a single horizontal line.

Depends on pi_data_utils that defines my known sensor IDs and the places they are.

History :
    2024-12-08  Change way Pump is plotted, now using data from PumpCtrl, percent based.
    2025-02-01  Fixed bug with missing Ctrl Data, added label for Collector Data, don't crash with missing data file

}

{$mode ObjFPC}{$H+}

interface



uses
    classes, sysutils,
     FPImage, FPCanvas, FPImgCanv,
     FPWritePNG, ftfont;


type TPlotLabel = record
    Name : string;
    YPlot : integer;              // Where the plot finished
    YText : integer;              // Where the Text starts after spacing
    Colour : TFPColor;
end;

type TPlotLabelArray = array of TPlotLabel;    // We will store (and adjust pos of) Labels here

type TDataRow = record
    Time : string;
    Data : array[0..9] of longint;    // 5 temp points, 3 ctrl data (inc %pump not plotted conventionally)  ??
    Pump : char;
    Heater : char;
end;

type TTempDataArray = array of TDataRow;    // dynamic, we'll load all a data file into here.

type TFPColorArray = array of TFPColor;

type

{ TPlot }

 TPlot = class
    public
      constructor Create();
      destructor Destroy;  override;


    private
      OriginX {, OriginY} : integer;     // There is some memory curruption issue, moving OriginY to Const 'hids' it ???
      canvas : TFPCustomCanvas;
      AFont: TFreeTypeFont;
      NumbDataRows : integer;
      image : TFPCustomImage;
      writer : TFPCustomImageWriter;
      DataArray : TTempDataArray;
      fFFileName : string;
      PlotLabels : TPlotLabelArray;
      PlotColours : TFPColorArray;
      PlotLabelNumb : integer;
      MaxPlots : integer;              // Index of last columns of analogue data we have to plot, 0..MaxPlots
      OldPumpPlot : boolean;           // Use DataArray[x].Pump to plot pump activity. PumpCtrl data not available
      ImageAvailable : boolean;        // Indicates we have a usable image, better save it.
      procedure AdjustLableSpacing();
      procedure DrawPumpPlot();
      procedure fFullFileName(FFname : string);
      procedure DrawAxis();
      function InsertLabel(NewPos: integer): integer;
      function LoadFile(FFileName : string) : integer;  // returns number of lines to plot.
      procedure DrawPlot(Column : integer);     // 1..5 inclusive

    Public
      property FullFileName : string write fFullFileName;
end;



{ for an image size, 640x480
Here we assume a csv file with one data row per 3 minutes (its an average of
three one minute measures) and that maps to 20 data points per hour, one pixel
per datapoint, 20x24=480 pixels wide, 80 pixels either side for margin, labels.
Temp range between -10 and +70 degress, 80, 5 pixels per degree, 400 high plus
40 pixel margin top and bottom.

Data looks like this, one row every time interval, at least five data data columns
Note the InvalidTemps at 22:43 -

22:37,37083,22020,25437,21166,24291
22:40,37062,21958,25458,21249,24250
22:43,-308666,-318750,-316375,-319125,-317208
22:46,36958,21791,25437,20999,24125
22:49,36875,21708,25437,20770,24083
13:28,43374,21291,41166,16458,57395,1,0,34150,44931,OFF
13:31,43145,21562,41354,16145,52520,0,0,49655,44970,COLLECTHOT
13:37,42770,21937,41812,16416,57500,1,0,38189,45383,

at 13:28 we have Ctrl Data and Pump is OFF
at 13:31 we also have Ctrl Data, Pump is on
at 13:37 Ctrl Data but pump state is undefined, assume off

or, post Dec 2024, like this -
12:51,45979,33791,57812,24604,59687,0,0,63622,60214,53

After the two single digits, we have CollectTemp,TankTemp,PercentPump
the las being a one or two digit percentage that pump was determined to be on
by the PumpCTRL (not from the current transformer).

for now, we will start showing a sixth plot line, Collector Temp, item [8] remembering it may not be there.

Initial 5 data points in log -
    T1   Hot water out.
    T2   Roof
    T3   Tank Low
    T4   Ambient
    T5   Pipe from collector to tank
}

implementation


uses pi_data_utils;

const
  PPH = 20;        // Pixel per hour
  IWidth = 640;    // Image Width, 0 at left
  IHeight = 480;   // Image Height, 0 at top
  DataPump = 9;    // Index, in DataArray.Data[] where PercentagePump is put
  OriginY = 480-48;
{ TPlot }

constructor TPlot.Create();
begin
    if DoDebug then writeln('TPlot.Create - Create.');
                                // packages/fcl-image/src/fpcolors.inc, colSilver,
    PlotColours := TFPColorArray.Create(colRed, colDkGreen, colBlue, colMaroon, colMagenta, colOlive);
    if DoDebug then writeln('TPlot.Create - Create Done.');
end;

procedure TPlot.DrawAxis();
var
    i : integer;
    YValue : integer;
begin
    //https://wiki.freepascal.org/fcl-image
    if DoDebug then writeln('TPlot.DrawAxis - starting');
    ftfont.InitEngine;
    FontMgr.SearchPath:='/usr/share/fonts/truetype/dejavu/';
    AFont:=TFreeTypeFont.Create;
    image := TFPMemoryImage.Create (IWidth, IHeight);   // 20 pixels per hour horiz
    OriginX := Image.Width div 20;
//    OriginY := Image.Height - (Image.Height div 10);
    Canvas := TFPImageCanvas.Create (image);
    Writer := TFPWriterPNG.Create;
    if DoDebug then writeln('TPlot.DrawAxis - setting up Canvas.');
    with canvas do begin
        Brush.FPColor:=colWhite;
        Brush.Style:=bsSolid;
        Rectangle(0,0,Image.Width,Image.Height);  // draw a white rectangle full size
        pen.mode    := pmCopy;
        pen.style   := psSolid;
        pen.FPColor := colBlack;
        Line(OriginX, OriginY, OriginX + 24*PPH, OriginY);   // X axis
        Line(OriginX, OriginY, OriginX, Image.Height div 6);
        Font:=AFont;
        Font.Name := 'DejaVuSans';
        // Expects to find  /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
        Font.Size := 16;
        if DoDebug then writeln('TPlot.DrawAxis - doing X.');
        for i := 1 to 24 do begin
            Pen.width := 1;
            Line(OriginX + (i*20), OriginY, OriginX + (i*20), OriginY + 5);
            if i mod 4 = 0 then begin
                 Pen.width := 3;
                 Line(OriginX + (i*20), OriginY, OriginX + (i*20), OriginY + 5);
                 TextOut(OriginX + (i*20) - 10, OriginY+30, inttostr(i));
            end;
        end;
        Pen.width := 1;
        pen.FPColor := colLtGray;
        pen.style   := psDash;
        if DoDebug then writeln('TPlot.DrawAxis - doing Y.');
        for i := 0 to 14 do begin       // each tick is 5 degrees, 5 pixes each degree
            YValue := OriginY;
            YValue := YValue - (i*25);

{            if DoDebug then writeln('TPlot.DrawAxis - Tick ', i, ' OriginY=', OriginY);
            if DoDebug then writeln('TPlot.DrawAxis - Y calc =', OriginY - 1);
            if DoDebug then writeln('TPlot.DrawAxis - Y calc =', OriginY - 0);
            if DoDebug then writeln('TPlot.DrawAxis - Y calc =', OriginY-(0*25));
            if DoDebug then writeln('TPlot.DrawAxis - Y calc =', OriginY-(i*25));
            if DoDebug then writeln('TPlot.DrawAxis - Tick ', i, ' X=', OriginX, ' Y=', OriginY-(i*25), ' x=', OriginX+480, ' y=', OriginY - (i*25));
}            Line(OriginX, YValue , OriginX+480, YValue);
//            Line(OriginX, OriginY-(i*25) , OriginX+480, OriginY - (i*25));
            if i mod 2 = 0 then
                 TextOut(5, OriginY - (i*25)+10, inttostr(i*5));
        end;
        if DoDebug then writeln('TPlot.DrawAxis - Text Out.');
        TextOut(100,25, ExtractFileName(fFFileName));
    end;
    if DoDebug then writeln('TPlot.DrawAxis - finshed.');
end;

destructor TPlot.Destroy;
begin
    if ImageAvailable then
         image.SaveToFile (fFFileName.TrimRight('cvs') + 'png', writer);
    Canvas.Free;
    image.Free;
    writer.Free;
    AFont.Free;
end;

// Always returns an index into PlotLabels, space will be made, adjusts PlotLabelNumb
function TPlot.InsertLabel(NewPos : integer) : integer;
var
    i : integer = 0;
begin
    inc(PlotLabelNumb);       // was Initially 0, now (1) becomes (2) (shown for second insert)
    setlength(PlotLabels, PlotLabelNumb);
    if (PlotLabelNumb = 1) or (NewPos > PlotLabels[PlotLabelNumb-2].YPlot) then begin
        Result := PlotLabelNumb-1;
    end else begin           // we need to search for an insert position and make room.
        while NewPos > PlotLabels[i].YPlot do
              inc(i);        // we know there is at least one entry and we must move at least one down.
        Result := i;         // Insertion index 0..x    (0)
        i := PlotLabelNumb-1;     // index of new slot  (i=1)
        repeat
              PlotLabels[i].YPlot := PlotLabels[i-1].YPlot;
              PlotLabels[i].Name  := PlotLabels[i-1].Name;
              PlotLabels[i].Colour  := PlotLabels[i-1].Colour;
              dec(i);
        until i = Result;
    end;
end;

const LabelSpacing=30;       // Vertical center to center

// we arrive here with PlotLabels array sorted, high YPos at high index.
procedure TPlot.AdjustLableSpacing();
var
    i : integer;
    BadSpacing : boolean = false;
begin
    for i := 0 to PlotLabelNumb -1 do
        PlotLabels[i].YText := PlotLabels[i].YPlot;
    repeat
          i := 0;
          BadSpacing := false;
          while i < PlotLabelNumb -1 do begin
              if (PlotLabels[i+1].YText - PlotLabels[i].YText) < LabelSpacing then begin
                 PlotLabels[i].YText := PlotLabels[i].YText - 10;
                 BadSpacing := True;
                 break;
              end;
              inc(i);          // we stay in this loop until i points to last entry, cannot compare that
          end;
    until not BadSpacing;
end;

(* This is really, really messy. Trying to support every possible data format I have
  ever used is too hard.  From now (Dec 2024) on, I will support ONLY the 11 field

  Date,T0,T1,T2,T3,T4,p,h,CTemp,TTemp,Pump

  Where Temps are in milliDegrees p and h are digits 0 or 1 and Pump is a string or
  a number. The last three CTemp,TTemp,Pump may be empty (if PumpCtrl is not talking
  to us). Pump may be a string (older, ignored) or a number (newer, used).
*)
function TPlot.LoadFile(FFileName: string): integer;
var
    F : TextFile; s: string;
    StL : TstringList;

    procedure ProcessDataLine();   // At this point, we have data in STL, get it into DataArray
    var i : integer;
    begin
        if STL.Count = 11 then begin
            // readln(F, s);
            // writeln('TPlot.LoadFile S=' + S + ']');
            DataArray[Result].Time := Stl[0];
            for i := 1 to 5 do
                DataArray[Result].Data[i-1] := strtointdef(Stl[i], InvalidTemp);
            // STL index 6, in older data sets, has '0' or '1', 0 meaning pump on.
            // this data column will be ignored if we have usable PumpCtrl data.
            DataArray[Result].Pump := Stl[6][1];
            // we are not doing anything with h data, STL index 7, might be Heater one day.
            // Collector goes into index 5 from Stl index 8, if its there.
            DataArray[Result].Data[5] := strtointDef(StL[8], 0);
            // We don't plot (PumpCtrl)TankTemp, index 9.
            // PumpCtrl PercentPump might be at StL index 10, otherwise its text.
            // We put it into DataArray index 9 (DataPump) to leave room for additional conventional plots.
            if (StL[10] <> '')                                // might be empty if Ctrl is not talking to us.
                and (STL[10][1] in ['0'..'9']) then
                DataArray[Result].Data[DataPump] := strtointDef(STL[10], InvalidTemp);    // if text, set to InvalidTemp, ignored in plot
            inc(Result);
        end;             // end of if STL.Count = 11, what if its not ??

    end;

begin
    MaxPlots := 5;                 // default, an index, 0..5, 5 sensors + collector.
    if DoDebug then writeln('TPlot.LoadFile - opening ', FFileName);
    setlength(DataArray, 500);     // Thats a full day at 3 minute datapoints,
    AssignFile(F, FFileName);
    reset(F);
    StL := TstringList.Create;
    StL.Delimiter := ',';
    Result := 0;
    readln(F, S);
    Stl.DelimitedText := S;        // have a look at first line, check format
    if Stl.Count <> 11 then begin
       writeln('ERROR, file format invalid, support, now only 11 fields, ', FFileName);
       Stl.Free;
       CloseFile(F);
       exit(0);
    end;
    ProcessDataLine();
    while not eof(F) do begin                              // chomp through the rest of the file
        readln(F, s);
        Stl.DelimitedText := S;
        ProcessDataLine();
        if Result >= 500-1 then break;         // Thats an error, data set is bigger than expected.
        // if eof(F) then writeln('AT END OF FILE ', S);
    end;
    CloseFile(F);
    STl.Free;
    if (DataArray[Result-1].Data[5] = 0) and (DataArray[0].Data[5] = 0) then
        MaxPlots := 4;
    if (DataArray[Result-1].Data[DataPump] = InvalidTemp) and (DataArray[0].Data[DataPump] = InvalidTemp) then
        OldPumpPlot := True;
end;

(*
function TPlot.LoadFile(FFileName: string): integer;
// ToDo : this needs a lot more error checking !
// Incoming data file line is comma seperated and potentially several formats -
// time,t0,T1,T2,T3,T4,[p,h,|T5,p,h][,CTemp,TTemp,Pump]
// So, we always have 5 temp reading, even in test mode (where they are invalid)
// We might have one more ignored test temp. (Temps are a long int, in milli degrees.)
// Then we have single char Pump and Heater (0 indicating its on).
// Then we might have three more items, Collector and Tank temp *.nn and then pump state string
// So, string might have
//   - 8 entries - normal run, 5 valid temps, P, H
//   - 9 entries - test run, 5 invalid tems, one valid one, P, H                <<< ??
//   - 11 entries - normal run, 5 valid temps, P, H, CTemp, TTemp, Pump         <<< Pump may be a string or a number !
//   - 12 entries - test run, 5 invalid temps, 1 valid temp, P, H, CTemp, TTemp, Pump   <<< ??
var
    F : TextFile; s: string;
    StL : TstringList;
    i : integer;
begin
    MaxPlots := 4;                 // default, an index, 0..4, until proven otherwise.
    if DoDebug then writeln('TPlot.LoadFile - opening ', FFileName);
    setlength(DataArray, 500);     // Thats a full day at 3 minute datapoints,
    AssignFile(F, FFileName);
    reset(F);
    StL := TstringList.Create;
    StL.Delimiter := ',';
    Result := 0;
    while not eof(F) do begin
        readln(F, s);
        Stl.DelimitedText := S;
        // writeln('TPlot.LoadFile S=' + S + ']');
        DataArray[Result].Time := Stl[0];
        for i := 0 to 4 do
            DataArray[Result].Data[i] := strtoint(Stl[i+1]);     // +1 because first element is Time
        // OK, after here format may change. If there are six temps, ignore #6
        // So, jump (i) to point to, initially Pump ch.
        case Stl.Count of                                        // must set it to Pump index
            8, 11 : i := 6;
            9, 12 : i := 7;                                      // Skip over testing temp entry
        else begin
            writeln('Invalid Line in ' + FFileName + ' [' + S + ']');
            exit(0);
            end;
        end;
        DataArray[Result].Pump := Stl[i][1];
        inc(i);
        DataArray[Result].Heater := Stl[i][1];
        inc(i);                              // if i points to valid data, we have ctrldata too
        if i < StL.Count then begin          // if count = 9, last legal index is 8
           if Stl[i] = '' then
                DataArray[Result].Data[i-3] := 0                     // empty ? that is legal
           else
                DataArray[Result].Data[i-3] := strtoint(Stl[i]);     // Collector
           inc(i);
           if Stl[i] = '' then
                DataArray[Result].Data[i-3] := 0
           else
                DataArray[Result].Data[i-3] := strtoint(Stl[i]);     // Tank
            MaxPlots := 5;                                           // ie, 0..5 inclusive, 6 lines, not inc Ctrl Tank
         end;                                                        // We are not using, now, Ctrl Pump
        inc(Result);
        if Result >= 500 then break;         // Thats an error, data set is bigger than expected.
    end;
    CloseFile(F);
    STl.Free;
end;  *)

const PumpY=40;
//  HeaterY=50;


procedure TPlot.DrawPumpPlot();
var
    i : integer;
    Scale : integer;
begin
    for i := 0 to NumbDataRows-1 do begin
        if InvalidTemp = DataArray[i].Data[DataPump] then continue;
        if DataArray[i].Data[DataPump] > 0 then begin
            Scale := (DataArray[i].Data[DataPump] div 20) + 1;            // to get 0..5 pixels ?
            Canvas.Line(OriginX+i, PumpY, OriginX+i, PumpY+Scale);
        end;
    end;
end;

procedure TPlot.DrawPlot(Column: integer);    // 0..MaxPlots  gets called for each column.
// X=0 and y=0 is top right corner.
var
    i : integer;
    Y : integer = 0;
    X : integer = 0;
begin
    Canvas.pen.style   := psSolid;
    if Column < 5 then
        Canvas.Pen.width := 3
    else Canvas.Pen.width := 1;
    Canvas.Pen.FPColor := PlotColours[Column];
    for i := 0 to NumbDataRows-1 do begin
        //if (i > 370) and                                    // MaxPlots is Collector Line
        //   (Column = MaxPlots) then writeln('-Datarow ', i, ' Data=', DataArray[i].Data[Column]);
        // Not sure why, missing data (from collector) is set to zero rather than InvalidData
        if 0 = DataArray[i].Data[Column] then begin                   // Exactly Zero, in a 70000..-10000 range
            X := OriginX+i;                                           // must still move to right
            if (i+1) < NumbDataRows then                              // can we read the next one ?
                Y := Originy - DataArray[i+1].Data[Column] div 200;   // and, if possible, get a good starting point
            continue;                                                 // but, in the end, do not plot a zero data
        end;
        if (X <> 0) or (Y <> 0) then
             Canvas.Line(X, Y, OriginX+i, Originy - DataArray[i].Data[Column] div 200);
        X := OriginX+i;
        Y := Originy - DataArray[i].Data[Column] div 200;
        // carefull, the number in the column is in milli degrees ! at 5 pixels a degree, 1 pixel is 200mC
        if OldPumpPlot then begin
            if DataArray[i].Pump = '0' then begin                  // This is pump powerline
                 Canvas.DrawPixel(OriginX+i, PumpY, colBlack);
                 Canvas.DrawPixel(OriginX+i, PumpY+1, colBlack);
                 //writeln('TPlot.DrawPlot : pump plot at ', OriginX+i);
            end;
        end;
{        if DataArray[i].Heater = '0' then                     // Uncomment to display heater power line
             Canvas.DrawPixel(OriginX+i, HeaterY, colBlack);   }
    end;
    //if DoDebug then writeln('TPlot.DrawPlot : NDR=', NumbDataRows, ' C=', Column);
//    if Column < MaxPlots then begin                                              // todo : remove this temp hack, no label on Collector Temp !
        // Build an array of data column labels.

    if DataArray[NumbDataRows-1].Data[Column] = 0 then exit;
        i := InsertLabel(OriginY-(DataArray[NumbDataRows-1].Data[Column] div 200));
        PlotLabels[i].Name := TempNames[Column];
        PlotLabels[i].YPlot := OriginY-(DataArray[NumbDataRows-1].Data[Column] div 200);
        PlotLabels[i].Colour := PlotColours[Column];
//    end;
end;

procedure TPlot.fFullFileName(FFname: string);
var
    i : integer;
begin
     // DoDebug := True;
     if DoDebug then writeln('TPlot.fFullFileName - plotting ', FFname);
     fFFileName := FFName;
     DrawAxis();                                                    // ToDo : if font is not available, this will crash !
     ImageAvailable := True;                                        // always create a Canvas so a blank image even if no data file
     if not FileExists(FFName) then begin
         writeln('ERROR, Cannot fine data file ', FFName);
         ImageAvailable := True;
         exit;
     end;
     if DoDebug then writeln('TPlot.fFullFileName - loading file [', FFname, ']');
     NumbDataRows := LoadFile(FFName);
     if NumbDataRows = 0 then begin
         writeln('ERROR, Invalid Data in ', FFName);
         ImageAvailable := True;
         exit;
     end;
     if DoDebug then writeln('TPlot.fFullFileName - doing plots.');
     for i := 0 to MaxPlots do                  // draw the line
        DrawPlot(i);
     AdjustLableSpacing();                      // now, the labels
     if DoDebug then writeln('TPlot.fFullFileName - doing labels.');
     for i := 0 to PlotLabelNumb-1 do begin
         Canvas.Font.FPColor := PlotLabels[i].Colour;
         canvas.TextOut(OriginX + (PPH*25)+5, PlotLabels[i].YText, PlotLabels[i].Name);
         Canvas.pen.FPColor := PlotLabels[i].Colour;
         Canvas.Pen.Width := 1;
         Canvas.Line(OriginX + NumbDataRows, PlotLabels[i].YPlot, OriginX + (PPH*25), PlotLabels[i].YText);
     end;
     if DoDebug then writeln('TPlot.fFullFileName - pump plotting ');
     // Pump Power Line
     if not OldPumpPlot then DrawPumpPlot();   // Old pump plot model happens in DrawPlot();
     if DoDebug then writeln('TPlot.fFullFileName - pump plotted ');
     Canvas.Font.FPColor := colBlack;
     Canvas.TextOut(OriginX + (PPH*25)+5, PumpY, 'Pump');

end;



end.

