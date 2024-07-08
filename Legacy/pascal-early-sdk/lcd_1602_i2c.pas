unit lcd_1602_i2c;
(*
 * Copyright (c) 2020 Raspberry Pi (Trading) Ltd.
 *
 * SPDX-License-Identifier: BSD-3-Clause

 Derived from Raspberry Pi's example C code and is, therefore this Pascal version
 is stamped with the same license. Some extra notes by David Bannon.

 *)

{$MODE OBJFPC}
{$H+}


interface
uses
  pico_i2c_c,
  pico_timer_c,
//  pico_uart_c,
  pico_c;

(* Example code to drive a 1602 LCD panel via a I2C

   NOTE: The panel must be capable of being driven at 3.3v NOT 5v. The Pico
   GPIO (and therefor I2C) cannot be used at 5v without level shifting the i2C
   lines. If you run the panel at 3.3v and its almost impossible to see the
   text, then you probably have a 5v panel ! Not to worry, see -

   https://circuitdigest.com/tutorial/bi-directional-logic-level-controller-using-mosfet
   or purchase a very cheap ready made module.

   This unit depends on the object files from i2c and gpio in addition to the standard ones.

   Which i2c instance used is determined elsewhere, see demo app. Also, the demo app
   sets the GP ports up. Important you use appropriate ports for i2c instance.
   The instance will have been passed to i2c before being used to set the global,
   'Inst' declared below.  (Would it make sense to do that in the i2c unit ?).



   GPIO 4 (pin 6)-> SDA on LCD bridge board
   GPIO 5 (pin 7)-> SCL on LCD bridge board
   3.3v (pin 36) -> VCC on LCD bridge board
   GND (pin 38)  -> GND on LCD bridge board
*)

    // commands
const LCD_CLEARDISPLAY = $01;
    LCD_RETURNHOME = $02;
    LCD_ENTRYMODESET = $04;
    LCD_DISPLAYCONTROL = $08;
    LCD_CURSORSHIFT = $10;
    LCD_FUNCTIONSET = $20;
    LCD_SETCGRAMADDR = $40;
    LCD_SETDDRAMADDR = $80;

    // flags for display entry mode
    LCD_ENTRYSHIFTINCREMENT = $01;
    LCD_ENTRYLEFT = $02;

    // flags for display and cursor control
    LCD_BLINKON = $01;
    LCD_CURSORON = $02;
    LCD_DISPLAYON = $04;

    LCD_MOVERIGHT = $04;        // flags for display and cursor shift
    LCD_DISPLAYMOVE = $08;

    LCD_5x10DOTS = $04;         // flags for function set
    LCD_2LINE = $08;
    LCD_8BITMODE = $10;

    LCD_BACKLIGHT = $08;        // flag for backlight control

    LCD_ENABLE_BIT = $04;
    LCD_addr = $27;             // By default these LCD display drivers are on bus address 0x27

    // Modes for lcd_send_byte
    LCD_CHARACTER = 1;          // We are sending a character to display
    LCD_COMMAND = 0;            // we are sending a command to act on.
    MAX_LINES = 2;
    MAX_CHARS = 16;

    // --------- P U B L I C    P R O C E D U R E S  ---------------------------

    // Initialise the display and pass the i2c instance 'cos we need it here.
procedure lcd1602_init();

    // go to location on LCD, for 1602, its 0..1, 0..15
procedure lcd1602_set_cursor(line : integer; position : integer);
    // Display a string at the current cursor position.
procedure lcd1602_string(St : string);
procedure lcd1602_clear();

var
    // Pi2C : ^Ti2C_Inst;
    Inst : Ti2C_Inst;      // keep a copy of the Instance because i2c_write_byte needs it.


implementation   // ============================================================

// Quick helper function for single byte transfers
procedure i2c_write_byte(val : byte);
begin
     //i2c_write_blocking(Pi2c^, LCD_addr, val, 1, false);  // does not work as expected.
     i2c_write_blocking(Inst, LCD_addr, val, 1, false);

end;


const DELAY_US = 600;  // seems OK at 500 but at 300 display is garbled. DRB

procedure lcd_toggle_enable(val : byte);          // (uint8_t val)
begin
    // Toggle enable pin on LCD display. We cannot do this too quickly or things don't work
    busy_wait_us_32(DELAY_US);
    i2c_write_byte(val or LCD_ENABLE_BIT);
    busy_wait_us_32(DELAY_US);
    i2c_write_byte(val and (not LCD_ENABLE_BIT));      // (val & ~LCD_ENABLE_BIT) ~ is bit wise not
    busy_wait_us_32(DELAY_US);
end;


// The display is sent a byte as two separate nibble transfers, the data is in highPart
// and the LowPart contains control information (ie Command or char) and backlight.
procedure lcd_send_byte(val : byte; mode : byte);           // (uint8_t val, int mode)
var
    HighPart, LowPart : byte;
begin
    HighPart := mode or (val and $F0) or LCD_BACKLIGHT;          // mode might be 1 or 0; LCD_BACKLIGHT os $08
    LowPart :=  mode or (val shl 4) or LCD_BACKLIGHT;
    i2c_write_byte(HighPart);
    lcd_toggle_enable(HighPart);
    i2c_write_byte(LowPart);
    lcd_toggle_enable(LowPart);
end;

procedure lcd1602_clear();
begin
    lcd_send_byte(LCD_CLEARDISPLAY, LCD_COMMAND);
end;

// go to location on LCD
procedure lcd1602_set_cursor(line : integer; Position : integer); // (int line, int position)
begin
    if Line = 0 then
        lcd_send_byte($80 + Position, LCD_COMMAND)
    else
        lcd_send_byte($C0 + Position, LCD_COMMAND);
end;

procedure lcd1602_string(St : string);
var
  i : integer;
begin
    for i := 1 to length(St) do
        lcd_send_byte(byte(St[i]), LCD_CHARACTER);
end;

procedure lcd1602_init();
begin
//    Pi2c := @Ani2c;   // Tried passing record in with _init() but does not work as expected
    lcd_send_byte($03, LCD_COMMAND);
    lcd_send_byte($03, LCD_COMMAND);
    lcd_send_byte($03, LCD_COMMAND);
    lcd_send_byte($02, LCD_COMMAND);
    lcd_send_byte(LCD_ENTRYMODESET or LCD_ENTRYLEFT, LCD_COMMAND);
    lcd_send_byte(LCD_FUNCTIONSET or LCD_2LINE, LCD_COMMAND);
    lcd_send_byte(LCD_DISPLAYCONTROL or LCD_DISPLAYON, LCD_COMMAND);
    lcd1602_clear();
end;


end.
