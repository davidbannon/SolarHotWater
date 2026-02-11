unit data_utils;
{ Copyright David Bannon
  License:
  This code is licensed under MIT License, see https://opensource.org/license/mit
  or  https://spdx.org/licenses/MIT.html  SPDX short identifier: MIT
}
{$mode ObjFPC}{$H+}

interface

uses
    Classes, SysUtils, syncobjs;

type TCtrlData = record
    Collector : longint;
    Tank : longint;
    PercentPump : integer;
    PumpJams : integer;
    Valid : boolean;
    end;


var
    DebugWebService : boolean = false;
    CtrlDataArray : array [0..2] of TCtrlData;   // shared with raspicapture, protected by LockedByCapture, LockedBySocket
    ThreadLock    : longword = 0;                // a lock semaphore to protect CtrlDataArray

    LoopTime : integer = 15000;                  // time we rest between each get data process
    { We log a data point into the csv file every 3 minutes (or, if debug, every  30 sec ?)
      We take three readings and average them. So, a reading every one minute.
      So, wanting 3 (a different 3) CtrlData points, we should be running with
      a loopTime of 20,000, lets do 15,000 and see how we go.

      NO, this model sucks !  7500 in -t mode, 7500x6 in 1 min mode, what if its et to more ???
    }

function GetLock(HowLong : integer; CS : TCriticalSection) : boolean;

        { Returns True if we get lock, calling process MUST release that lock.
          Keeps trying to get the lock for indicated mSec, returns False
          if we time out. While based on ASM, wide platform support. }
function GrabLock(var LockVar : longword; Timeout : integer; LockID : integer = 1) : boolean;

implementation

const WaitSteps = 10;

function GetLock(HowLong : integer; CS : TCriticalSection) : boolean;
var
    Cnt : integer = 0;
begin
    while Cnt < HowLong do begin          // downside here is that we are not checking (Thread) Terminate
        if CS.TryEnter() then break;
        sleep(WaitSteps);
        inc(Cnt, WaitSteps);
    end;
    result := Cnt < HowLong;
end;


function GrabLock(var LockVar : longword; Timeout : integer; LockID : integer = 1) : boolean;
begin
    while TimeOut > 0 do begin
        // Appears to always return value of existing LocVar, sets LockVar to
        // second parameter iff LocVar = Third Parameter.
        if InterlockedCompareExchange(LockVar, LockID, 0) = 0  then break;
        dec(TimeOut);
        sleep(1);
        // InterLockedIncrement(MissedGrab);      // testing only
    end;
    result := TimeOut <> 0;
end;

end.

