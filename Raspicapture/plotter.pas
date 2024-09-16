unit Plotter;

{$mode ObjFPC}{$H+}

{ Unit that takes a cvs file full of temperature datapoints (five per row) and plots
them into a PNG file. Single char (still comma seperated) beyond that are plotted
in a single horizontal line.

Depends on pi_data_utils that defines my known sensor IDs and the places they are.

}

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
    Data : array[0..9] of longint;    // 5 temp points, pump, heater, 2 ctrl data
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
      canvas : TFPCustomCanvas;
      OriginX, OriginY : integer;
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
      procedure AdjustLableSpacing();
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

for now, we will start showing a sixth plot line, Collector Temp, item [8] remembering it may not be there.
}

implementation


uses pi_data_utils;

const
  PPH = 20;        // Pixel per hour
  IWidth = 640;    // Image Width, 0 at left
  IHeight = 480;   // Image Height, 0 at top

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
begin
    //https://wiki.freepascal.org/fcl-image
    ftfont.InitEngine;
    FontMgr.SearchPath:='/usr/share/fonts/truetype/dejavu/';
    AFont:=TFreeTypeFont.Create;
    image := TFPMemoryImage.Create (IWidth, IHeight);   // 20 pixels per hour horiz
    OriginX := Image.Width div 20;
    OriginY := Image.Height - (Image.Height div 10);
    Canvas := TFPImageCanvas.Create (image);
    Writer := TFPWriterPNG.Create;
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
        for i := 0 to 14 do begin       // each tick is 5 degrees, 5 pixes each degree
            Line(OriginX, OriginY-(i*25) , OriginX+480, OriginY - (i*25));
            if i mod 2 = 0 then
                 TextOut(5, OriginY - (i*25)+10, inttostr(i*5));
        end;
        TextOut(100,25, ExtractFileName(fFFileName));
    end;
end;

destructor TPlot.Destroy;
begin
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
    for i := 0 to 4 do
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
//   - 11 entries - normal run, 5 valid temps, P, H, CTemp, TTemp, Pump
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
        inc(i);                              // if i points to valid date, we have ctrldata too
        if i < StL.Count then begin          // if count = 9, last legal index is 8
           if Stl[i] = '' then
                DataArray[Result].Data[i-3] := 0
           else
                DataArray[Result].Data[i-3] := strtoint(Stl[i]);        // Collector
           inc(i);                                               // Tank
           if Stl[i] = '' then
                DataArray[Result].Data[i-3] := 0
           else
                DataArray[Result].Data[i-3] := strtoint(Stl[i]);
            MaxPlots := 5;                                        // ie, 0..5 inclusive, 6 lines, not inc Ctrl Tank
         end;                                                     // We are not using, now, Ctrl Pump
        inc(Result);
        if Result >= 500 then break;         // Thats an error, data set is bigger than expected.
    end;
    CloseFile(F);
    STl.Free;
end;

const PumpY=40;
//  HeaterY=50;

procedure TPlot.DrawPlot(Column: integer);    // 0..4
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
        if (X <> 0) or (Y <> 0) then
             Canvas.Line(X, Y, OriginX+i, Originy - DataArray[i].Data[Column] div 200);
        X := OriginX+i;
        Y := Originy - DataArray[i].Data[Column] div 200;
        // carefull, the number in the column is in milli degrees ! at 5 pixels a degree, 1 pixel is 200mC
        if DataArray[i].Pump = '0' then begin                  // This is pump powerline
             Canvas.DrawPixel(OriginX+i, PumpY, colBlack);
             Canvas.DrawPixel(OriginX+i, PumpY+1, colBlack);
             //writeln('TPlot.DrawPlot : pump plot at ', OriginX+i);
        end;
{        if DataArray[i].Heater = '0' then                     // Uncomment to display heater power line
             Canvas.DrawPixel(OriginX+i, HeaterY, colBlack);   }
    end;
    if DoDebug then writeln('TPlot.DrawPlot : NDR=', NumbDataRows, ' C=', Column);
    if Column < MaxPlots then begin                                              // todo : remove this temp hack !!
        i := InsertLabel(OriginY-(DataArray[NumbDataRows-1].Data[Column] div 200));
        PlotLabels[i].Name := TempNames[Column];
        PlotLabels[i].YPlot := OriginY-(DataArray[NumbDataRows-1].Data[Column] div 200);
        PlotLabels[i].Colour := PlotColours[Column];
    end;
end;

procedure TPlot.fFullFileName(FFname: string);
var
    i : integer;
begin
     if DoDebug then writeln('TPlot.fFullFileName - plotting ', FFname);
     fFFileName := FFName;
     DrawAxis();
     NumbDataRows := LoadFile(FFName);
     for i := 0 to MaxPlots do                  // draw the line
        DrawPlot(i);
     AdjustLableSpacing();                      // now, the labels
     for i := 0 to 4 do begin
         Canvas.Font.FPColor := PlotLabels[i].Colour;
         canvas.TextOut(OriginX + (PPH*25)+5, PlotLabels[i].YText, PlotLabels[i].Name);
         Canvas.pen.FPColor := PlotLabels[i].Colour;
         Canvas.Pen.Width := 1;
         Canvas.Line(OriginX + NumbDataRows, PlotLabels[i].YPlot, OriginX + (PPH*25), PlotLabels[i].YText);
     end;
     // Pump Power Line
     Canvas.Font.FPColor := colBlack;
     Canvas.TextOut(OriginX + (PPH*25)+5, PumpY, 'Pump');

end;



end.

