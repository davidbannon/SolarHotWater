unit i2cdev_base;

{$mode objfpc}{$H+}

interface


uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  Classes, SysUtils
  , baseUnix;

type

  { TIc2Base }

  TIc2Base = class

  private
    Fhdev: Byte;
    Fi2cadd: Byte;
  public



    constructor Create(); virtual; abstract;
    constructor Create(ai2cadd: Byte); virtual; overload;
    destructor Destroy(); override;
    property hdev: Byte read Fhdev write Fhdev;
    property i2cadd: Byte read Fi2cadd;

    function connect: boolean;

    procedure disconect;



  end;

function I2C_Open(iDevAddr: Byte): Byte;
procedure I2C_Close(fh: Byte);
function I2C_Read8(fh: Byte ): byte;  overload ;
function I2C_Read8(fh: Byte; reg: byte): byte;  overload ;
function I2C_Read16(fh: Byte; reg: byte): word;

function I2C_Write8(fh: Byte; reg: byte; Data: byte): boolean;       overload ;
function I2C_Write8(fh: Byte;  Data: byte): boolean;    overload ;
function I2C_Write16(fh: Byte; reg: byte; Data: word): boolean;

// ----  test function
//function I2C_Write16_2(fh: Byte; reg: byte; Data1,data2: word): boolean;
// --- 8bit functions
//function BitOn_8(const val: byte; const TheBit: Byte): byte;
//function BitOff_8(const val: byte; const TheBit: Byte): byte;
procedure  BitOn_8(var Value: byte; const TheBit: Byte);
procedure  BitOff_8(var Value: byte; const TheBit: Byte);

function IsBitSet_8(const Value: byte; const TheBit: Byte): Boolean;
 
// wrapper
procedure  delayMicroseconds (micorseconds : Integer  );


implementation

procedure I2C_Close(fh: Byte);
begin
  fpclose(fh);
end;

function I2C_Open(iDevAddr: Byte): Byte;
const
  I2C_SLAVE = 1795;
var
  devPath: string = '/dev/i2c-1';
  // devPath: string = '/dev/i2c-2';
begin
  // writeln('I2C_Open called, add=', iDevAddr);
  Result := fpopen(devPath, O_RDWR);
  if Result < 1 then
  begin
    writeln('I2C_Open error');
    raise Exception.Create('I2C_Open ERROR ');

  end;
  fpIOCtl(Result, I2C_SLAVE, pointer(iDevAddr));

end;

function I2C_Write8(fh: Byte; reg: byte; Data: byte): boolean;
var
  buf: packed array [0..1] of byte;

begin

  buf[0] := reg;
  buf[1] := Data;


  if fpwrite(fh, buf, 2) <> 2 then
  begin
    writeln('I2C_Write8 1 error');
    raise Exception.Create('I2C_Write8 ERROR');

  end;

  Result := True;

end;

function I2C_Write8(fh: Byte;  Data: byte): boolean;
begin
  if fpwrite(fh, data, 1) <> 1 then
  begin
    writeln('I2C_Write8 2 error');
    raise Exception.Create('I2C_Write8 ERROR');

  end;

  Result := True;

end;

procedure  delayMicroseconds (micorseconds : Integer  );
begin
  // dummy waper
   sleep( round( micorseconds / 1000) );


end;

function I2C_Write16(fh: Byte; reg: byte; Data: word): boolean;
var
  buf: packed array [0..2] of byte;
  Res : integer;
begin
  // writeln('I2C_Write16 called fh=', fh, ' and reg is ', reg, ' and Data is ', format('[%x]', [Data]), ' or ', Data);
  buf[0] := reg;
  buf[1] := hi(Data);
  buf[2] := lo(Data);
  Res := fpwrite(fh, buf, 3);
  // writeln('I2C_Write16 called wrote ', Res);
//  if fpwrite(fh, buf, 3) <> 3 then begin
  if Res <> 3 then begin
    writeln('I2C_Write16 error');
    raise Exception.Create('I2C_Write16 ERROR');
  end;
  Result := True;
end;
{
function I2C_Write16_2(fh: Byte; reg: byte; Data1,data2: word): boolean;

var
  buf1: packed array [0..1] of byte;

  // buf : packed array [0..7] of byte ;



begin

  buf1[0] := reg;
  buf1[1] := lo(data1);
  if fpwrite(fh, buf1, 2) <> 2 then
  begin
    raise Exception.Create('I2C_Write16 ERROR');

  end;

   buf1[0] := reg + 1;
  buf1[1] := hi(data1);
  if fpwrite(fh, buf1, 2) <> 2 then
  begin
    raise Exception.Create('I2C_Write16 ERROR');

  end;

    buf1[0] := reg + 2;
  buf1[1] := lo(data2);
  if fpwrite(fh, buf1, 2) <> 2 then
  begin
    raise Exception.Create('I2C_Write16 ERROR');

  end;

    buf1[0] := reg + 3;
  buf1[1] := hi(data2);
  if fpwrite(fh, buf1, 2) <> 2 then
  begin
    raise Exception.Create('I2C_Write16 ERROR');

  end;



 {
  buf[0] := reg;
  buf[1] := lo(Data1);
  buf[2] := reg + 1;
  buf[3] := hi(Data1);
  buf[4] := reg + 2;
  buf[5] := lo(Data2);
  buf[6] := reg + 3;
  buf[7] := hi(Data2);



  if fpwrite(fh, buf1, 8) <> 8 then
  begin
    raise Exception.Create('I2C_Write16 ERROR');

  end;

     }
  Result := True;

end;
  }
function I2C_Read8(fh: Byte ): byte;
var
  buf: byte;

begin



  if fpread(fh, buf, 1) <> 1 then
  begin
    writeln('I2C_Read8 1 error');
    raise Exception.Create('I2C_Read8  read   ERROR');

  end;

  Result := buf;

end;

function I2C_Read8(fh: Byte; reg: byte): byte;
var
  buf: byte;

begin

  if fpwrite(fh, reg, 1) <> 1 then
  begin
    writeln('I2C_Read8 2 error');
    raise Exception.Create('I2C_Read8 REG  ERROR');

  end;

  if fpread(fh, buf, 1) <> 1 then
  begin
    raise Exception.Create('I2C_Read8  read   ERROR');

  end;

  Result := buf;

end;

function I2C_Read16(fh: Byte; reg: byte): word;
var
  buf: packed array [0..1] of byte = (0, 0);
begin
  if fpwrite(fh, reg, 1) <> 1 then
  begin
    writeln('I2C_Read16 1 error');
    raise Exception.Create('I2C_Read16 REG  ERROR');
  end;
  if fpread(fh, buf, 2) <> 2 then   // read two bytes
  begin
    writeln('I2C_Read16 2 error');
    raise Exception.Create('I2C_Read16  read   ERROR');
  end;
  Result := (buf[0] shl 8) or buf[1] + 1;   // DRB - the +1 to ensure we never roll back past zero.
end;                                        // something the ADS1115 is good at !

{ TIc2Base }



constructor TIc2Base.Create(ai2cadd: Byte);
begin

  Fi2cadd := ai2cadd;
  fhdev := 0;
  Inherited create;
end;

destructor TIc2Base.Destroy();
begin
  disconect;
  inherited;

end;

function TIc2Base.connect: boolean;
begin
  if (Fhdev = 0) and (Fi2cadd <> 0) then
  begin
    Fhdev := I2C_Open(Fi2cadd);

  end;
  Result := not (Fhdev = 0);
end;

procedure TIc2Base.disconect;
begin
  if Fhdev <> 0 then
    I2C_Close(Fhdev);
  Fhdev := 0;
end;
// ------------------------------BIT FUNCTIONS 8 BIT 
procedure  BitOn_8(var Value: byte; const TheBit: Byte);
begin
  Value := Value or (1 shl TheBit);
end;
procedure  BitOff_8(var Value: byte; const TheBit: Byte);
begin
  Value := Value and ((1 shl TheBit) xor $FF);
end;
function IsBitSet_8(const Value: byte; const TheBit: Byte): Boolean;
begin
  Result := (Value and (1 shl TheBit)) <> 0;
end;

// put bit ?



end.

