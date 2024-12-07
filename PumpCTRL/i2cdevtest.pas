program i2cdevtest;

{$mode objfpc}{$H+}

uses {$IFDEF UNIX} {$IFDEF UseCThreads}
  cthreads, {$ENDIF} {$ENDIF}
  Classes,
  SysUtils,
  CustApp { you can add units after this },
  baseUnix,
//  i2cdev_base,
  i2cdev_ADS1115;

type

  { ic2dev }

  ic2dev = class(TCustomApplication)
  private
    ADS: TADS1115;
  protected
    procedure DoRun; override;
    procedure volt;
  public
  end;

  { ic2dev }

{   10 1024, 12=4096, 14=16384 16=65536
max    1023     4095     16383    65535
}

procedure ic2dev.volt;
var
    volt0, volt1, volt2, volt3: integer;
//    diff0_3, diff0_1, diff1_3, diff2_3: integer;
    vdiff: extended;
begin
    ADS.conversionDelay := 250;
    ADS.samplepersecond := sps_8;
    ads.gain := GAIN_TWO;              //  Davo - thats 0 to 2.048v I think, test
//    ads.gain := GAIN_TWOTHIRDS;
//    ads.gain := GAIN_ONE;

    volt0 := ADS.ADSread_SingleEnded(0);
    volt1 := ADS.ADSread_SingleEnded(1);
    volt2 := ADS.ADSread_SingleEnded(2);
    volt3 := ADS.ADSread_SingleEnded(3);

{    diff0_3 := ADS.ADSreadDifferential(mux0_3);
    diff0_1 := ADS.ADSreadDifferential(mux0_1);
    diff1_3 := ADS.ADSreadDifferential(mux1_3);
    diff2_3 := ADS.ADSreadDifferential(mux2_3);    }
    case ads.gain of
        GAIN_TWOTHIRDS: vdiff := (6144 / 2048); //6_144
        GAIN_ONE: vdiff := (4096 / 2048);   // 4_096
        GAIN_TWO: vdiff := 1.0 //    // Davo : hmm, 2048 / 2048 ?
    end;
    //     Ic2Write16(fh, ADS1015_REG_POINTER_CONFIG, 50083);
    //     volt1 := Ic2Read16(fh, ADS1015_REG_POINTER_CONVERT);
    writeln('A0(raw)=', volt0, ' (calc)=', round(volt0 * vdiff));
    writeln('A1(raw)=', volt1, ' (calc)=', round(volt1 * vdiff));
    writeln('A2(raw)=', volt2, ' (calc)=', round(volt2 * vdiff));
    writeln('A3(raw)=', volt3, ' (calc)=', round(volt3 * vdiff));

{    writeln('A1=', round(volt1 * vdiff));
    writeln('A2=', round(volt2 * vdiff));
    writeln('A3=', round(volt3 * vdiff));

    writeln('A0=', volt0);
    writeln('A1=', volt1);
    writeln('A2=', volt2);
    writeln('A3=', volt3);    }



{    writeln('diff0_3=', diff0_3);
    writeln('diff0_1=', diff0_1);
    writeln('diff1_3=', diff1_3);
    writeln('diff2_3=', diff2_3);        }
    writeln('_______________________');
end;



procedure ic2dev.DoRun;
begin
    ADS := TADS1115.Create();
    try
        volt;
    except
        writeln('Error initalizing i2c');
        ADS.Free;
    end;
    Terminate;
end;



var
  Application: ic2dev;

{$R *.res}

begin
    Application := ic2dev.Create(nil);
    Application.Title := 'ic2dev';
    Application.Run;
    Application.Free;
end.

