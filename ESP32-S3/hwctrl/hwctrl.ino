// #include <Arduino.h>
#include <Adafruit_ADS1X15.h>
#include "webs.h"

/*  Program to control the circulation pump in a solar hot water
    system. Uses a ESP32-S3 two core module.
    Inputs - temperature of two Pt Wire sensors, Ik ohm at zero C. with 1mA current
    same current directed through a 0.1% 1K ref resistor. 
    A/D connected via I2C
    Outputs - Turns pump on and off via a relay, LED echo's relay. Writes status info to Serial
    out, watch using a serial mnitor. Writes a status string that can be read with a Web
    browser ("ip:80/data"), CollectorTemp,TankTemp,PumpPercent,NumberPumpJams.   
*/

//On the esp32c3, INT_MAX is 2147483647
#undef RGB_BUILTIN
#define RGB_BUILTIN 21     // On esp32-s3 zero its 21, varies !
#define I2C_SDA 7          // gp7 to (ADS1115) SDA
#define I2C_SCL 8          // gp8 to (ADS1115) SCL
//#define LED 2            // gp2 has my external LED, probably will drop this
#define READY_PIN 3        // ALERT/RDY A/D signal for new sample notification, 10k pull up resistor
#define CntsPerMeasure 10  
#define CollADC 0          // ADC1115 port to read, single ended
#define TankADC 1
#define RefADC  2 
#define CollEnable 10      // gp port to send high to direct current through Coll Pt sensor
#define TankEnable 11      // gp port to send high to direct current through Tank Pt sensor
#define RefEnable  12      // gp port to send high to direct current through Ref  Pt sensor
#define PumpPort    1      // This controls the water pump
#define CurrOn false
#define CurrOff true 



enum TPumpState {psOff, psCollectHot, psCollectFreeze};
enum TPumpState PumpState = psOff;
// int PumpWasOn   = 0;                 // ?
int LogPumpJam  = 0;                 // for reporting only, numb jams since boot
int JamCatchUp  = 0;                 // Inc'ed every loop, prevents Jam process retriggering immediatly
int LoopCount   = 0;                 // Inc'ed every loop, when hits MaxLoopCount triggers %Pump Calc
int PumpPercent = 0;                 // calc'ed using PumpOnCount when LoopCount hits MaxLoopCount
int PumpOnCount = 0;                 // numb of times in current loop pump was On

/* the pump control loop is called ABOUT every second. Maybe this needs looking at.
   We count the calls only updating PumpPercent when we hit MaxLoopCount 
*/




  //#define  BAUD_RATE 115200;
  // ADC_REF_VOLT=2490;      // milliVolts
  // ADC_REF_VOLT=3300;   // milliVolts
#define  MaxLoopCount      30      // How many loops before we calculate a PumpPercent
#define  PumpOnDelta       5.0     // Collector has to be this much hotter than tank to turn pump on
#define  PumpOffDelta      2.0     // Collector has to be this much hotter than tank for Pump to remain on
#define  MaxTankTemp       90.0    // Don't send any more hot water to tank ! (never seen > 65)
#define  AntiFreezeTrigger 3.0     // Colder than this, we must pump some warm water up
#define  AntiFreezeRelease 4.0     // Warmer than this, we can stop pumping
// #define  PtSelectPort      22      // TPicoPin.GP22    // GP22 conflicts with SPI-0 and I2C-1  (and UART 1 ??)
#define  CntsPerReading    10      // We take multiple ADC readings


Adafruit_ADS1115 ads;      // 16-bit version 

// This is required on ESP32 to put the ISR in IRAM. Define as
// empty for other platforms. Be careful - other platforms may have
// other requirements.
#ifndef IRAM_ATTR
#define IRAM_ATTR
#endif

volatile bool new_data = false;
bool LED_ON = false;

void IRAM_ATTR NewDataReadyISR() {  // ADS Interrupt response function 
  new_data = true;                  // Says new ADC data is available
  //Serial.println("Data available.");
}

void setup(void)  {
  Serial.begin(9600);
  DataChar[0] = 0;
  mutex_webs_data = xSemaphoreCreateMutex();
  // ToDo test for Null and abort ...
  pinMode(PumpPort, OUTPUT);
  pinMode(CollEnable, OUTPUT);
  digitalWrite(CollEnable, CurrOff);
  pinMode(TankEnable, OUTPUT);
  digitalWrite(TankEnable, CurrOff);
  pinMode(RefEnable, OUTPUT);
  digitalWrite(RefEnable, CurrOff);

  Serial.println("Timing: ");
  Serial.println(portTICK_PERIOD_MS);    // shows 1
  Serial.println(configTICK_RATE_HZ);    // shows 1000    => tick is 1mS
  // ---------------   Start the Web Service on CPU 0  
  xTaskCreatePinnedToCore(
                      StartServer, /* Task function. */
                      "WebTask",   /* name of task. */
                      10000,       /* Stack size of task */
                      NULL,        /* parameter of the task */
                      1,           /* priority of the task */
                      &WebTask,    /* Task handle to keep track of created task */
                      0);          /* pin task to core 0 */ 
  // ServiceReady will be set true when wifi and webservice is ready.
 
  // Serial.println(StatusChar);                       // what server is doing
  Serial.print("Main task running on core ");       // 0 or 1. 1 is default
  Serial.println(xPortGetCoreID());

  // Setup I2C on custom pins, defined above, might need to pass the Wire to 1306 code ?
  // https://randomnerdtutorials.com/esp32-i2c-communication-arduino-ide/#3
  Wire.begin(I2C_SDA, I2C_SCL);    // a=7, L=8
  
  Serial.println("ADC Range: 0 - 2.048 (15 bit because single ended,  625uV)");
  ads.setGain(GAIN_TWO);        // 2x gain   +/- 2.048V  1 step = 0.0625mV 
  ads.setDataRate(RATE_ADS1115_32SPS);    // about a 1 second cycle, 3 readings, calcs and println.
  //ads.setDataRate(RATE_ADS1115_8SPS);   // RATE_ADS1115_8SPS, RATE_ADS1115_16SPS, RATE_ADS1115_64SPS, RATE_ADS1115_250SPS, RATE_ADS1115_860SPS (0x00E0)
  // how to set continous mode to ignore first two reading ? eg
  // ADS1X15_REG_CONFIG_CQUE_2CONV (0x0001) ///< Assert ALERT/RDY after two conversions
  if (!ads.begin()) {
    Serial.println("Failed to initialize ADS.");
    while (1) {
      rgbLedWrite(RGB_BUILTIN,RGB_BRIGHTNESS,0,0);  // red
      delay(200);
      rgbLedWrite(RGB_BUILTIN,0,0,0); // Off / black
      delay(200);
    }
  }
  pinMode(READY_PIN, INPUT);
  // With default COMP_POL=0, get a rising edge every time a new sample is ready.
  attachInterrupt(digitalPinToInterrupt(READY_PIN), NewDataReadyISR, RISING);
}


// Returns the ADC count times CntsPerMeasure
int GetA2D(int Port) {          // 0..2, Coll, Tank, Ref, 
// Each reading takes about 370mS (as revealed by xTaskGetTickCount())
// That is almost all time taken. about 1.1 seconds per full cycle.
//  int GetA2D(uint16_t MuxPort) {
    int Count = 0;
    int Total = 0;
    int Numb = 0;
    uint16_t ADSPort = 0;
    int GPPort = 0; 
    // setup port : continous mode, alert after 2 reading ??
    switch (Port) {
      case 0: ADSPort = ADS1X15_REG_CONFIG_MUX_SINGLE_1;
              GPPort = CollEnable;
              break;
      case 1: ADSPort = ADS1X15_REG_CONFIG_MUX_SINGLE_0;
              GPPort = TankEnable;
              break;
      case 2: ADSPort = ADS1X15_REG_CONFIG_MUX_SINGLE_2;
              GPPort = RefEnable;
              break;              
    }
    new_data = false;        // ensure we don't get an old reading ?
    digitalWrite(GPPort, CurrOn);
    delay(10);   
    ads.startADCReading(ADSPort, true); 
    new_data = false;                      // ensure we don't get an old reading, ignore first 2 ?
    while (Count++ < (CntsPerMeasure+2)) { 
        while (!new_data) { }              //  wait for new_data        
        Numb = ads.getLastConversionResults();
        //ads.startADCReading(ADS1X15_REG_CONFIG_MODE_SINGLE, false);   // maybe this to shutdwn between readings ?        
        if (Count > 2) {                       // discard first two readings, first is always from previous series
          // if (Numb > Highest) Highest = Numb; if (Numb < Lowest) Lowest = Numb; Serial.print(Numb); Serial.print("  ");
          Total += Numb; 
        }; // else {Serial.print("*");}
        new_data = false;
    }
    //Serial.print("  GP="); Serial.print(GPPort); Serial.print("  ADC="); Serial.print(ADSPort);
    //Serial.print("  Holding..."); Serial.println(Total); 
    //delay(10000);
    digitalWrite(GPPort, CurrOff); 
    return Total;
}

/*
Single ended,taking 10 reading per measure, 2.048v FSD
1v will give me about 160000 counts (zero degrees)
15bit, 1.024v should give me 16384 or 163,840
At 0 degrees, Pt1000 is 1000 ohms, Cnts = 160000
At 100 degrees its 1385 ohms, Cnts = 221600
The range, 0..100 degrees is therefore 221600-160000=61600
One degree, on average, is therefore 616 counts (in that range)
So, for given Cnts, to covert to approx temperature, its 
Temp = (Cnts-160000)/616
eg at 0   degrees, (160000-16000)/616=0
eg at 50  degrees, (191040-160000)/616=50.390
eg at 100 degrees, (221600-160000)/616=100
Right at both ends (by design) but non-linear, 50 is high by 0.39 of a degree
*/

// Passed an ADC (Count * CntsPerMeasure) and returns a temperature  
double CalcTemp(int Cnts, int RefCnt) {
// Ref should be 160,000 but errors from ADC ref and current variations need to be corrected for.
  double ANumb = double(Cnts);
  ANumb = ANumb * (160000.0/double(RefCnt));
  // correct for ADC ref variations, current drift
  ANumb = ANumb - double(16000 * CntsPerMeasure);       // remove counts below zero degrees
  // Adjust ANumb for slope error
  ANumb = ANumb / (61.6 * CntsPerMeasure);              // now approx degrees, must allow for non-linear
  //Serial.print(ANumb);Serial.print(" "); 
  if (ANumb > 150) {ANumb += 3;}
  else if (ANumb > 130) {ANumb += 0.831;}
  else if (ANumb > 110) {ANumb += 0.338;}
  else if (ANumb > 100) {ANumb += 0.091;}
  else if (ANumb > 90) {ANumb += -0.065;}
  else if (ANumb > 80) {ANumb += -0.195;}
  else if (ANumb > 70) {ANumb += -0.273;}
  else if (ANumb > 60) {ANumb += -0.351;}
  else if (ANumb > 50) {ANumb += -0.377;}
  else if (ANumb > 40) {ANumb += -0.377;}
  else if (ANumb > 30) {ANumb += -0.351;}
  else if (ANumb > 20) {ANumb += -0.273;}
  else if (ANumb > 10) {ANumb += -0.195;}
  else if (ANumb > 0 ) {ANumb += -0.065;}
  else if (ANumb > -10) {ANumb += 0.091;}
  else {ANumb += 0.273;}
  return ANumb;
}

void ControlLoop(double CollectorTemp, double TankTemp) {
    enum TPumpState OldPumpState = PumpState;
    switch (PumpState) {
        case psOff :                // if its OFF, we might turn it on
            if (CollectorTemp < AntiFreezeTrigger) 
                PumpState = psCollectFreeze;
            else if ((CollectorTemp > (TankTemp + PumpOnDelta)) 
                && (TankTemp < MaxTankTemp)) 
                    PumpState = psCollectHot;
            break;
        case (psCollectHot) :       // Already collecting, so we may turn it off.
            if ((CollectorTemp < (TankTemp + PumpOffDelta)) || (TankTemp > MaxTankTemp)) 
                PumpState = psOff;
            break;
        case (psCollectFreeze) :    // pumping 'cos of freeze ? We may turn it off.
            if (CollectorTemp > AntiFreezeRelease)
                PumpState = psOff;
            break;
        default :                                      // not possible ?  Anyway, we'll set it off.
            PumpState = psOff;
    }       // end of switch statement.
    if ((PumpState == psCollectHot) || (PumpState == psCollectFreeze)) {
            digitalWrite(PumpPort, true);              // Make it so.
            // PumpWasOn = PumpWasOn + 1;                 // Report() will reset that.
            PumpOnCount++;
    } else {                                
            digitalWrite(PumpPort, false);
    }
    // This happens if pump 'running continusly' but collector is still over 95c and tank is less than Max 
	if ((JamCatchUp++ > 100) && (CollectorTemp > 95.0) && (OldPumpState == psCollectHot) && (PumpState == psCollectHot) ) {
    	// This means (?) pump is powered  but not spinning. Bounce for 2 seconds
    	digitalWrite(PumpPort, false);
    	delay(2000);
    	digitalWrite(PumpPort, true);
    	LogPumpJam++;
    	JamCatchUp = 0;   // don't do this again until pump has had time to catch up, 100 cycles ?
  }
  if (LoopCount++ >= MaxLoopCount) {
      PumpPercent = (PumpOnCount*100) / LoopCount;
      LoopCount = 0;
      PumpOnCount = 0;
  }
}

// Critical that the pump ctrl loop continues even if our reporting
// systems are somehow not working or even blocking.
// No net ? We flash blue
// 

void loop(void) {
  // Serial.print(" TickA=");  Serial.print(xTaskGetTickCount());
  // TickType_t tickCount = xTaskGetTickCount();
  if ((LED_ON=(!LED_ON))) rgbLedWrite(RGB_BUILTIN,0,32,0);       // Green
  else rgbLedWrite(RGB_BUILTIN,0,0,0);                           // off
  // Serial.print(" TickB=");  Serial.print(xTaskGetTickCount());                          
  int    RefCnt = GetA2D(RefADC);                                // 370mS
  // Serial.print(" TickC=");  Serial.print(xTaskGetTickCount());
  double Collector = CalcTemp(GetA2D(CollADC), RefCnt);          // 370mS
  // Serial.print(" TickD=");  Serial.print(xTaskGetTickCount());
  double Tank =      CalcTemp(GetA2D(TankADC), RefCnt);          // 370mS
  // Serial.print(" TickE=");  Serial.print(xTaskGetTickCount());
  // double Ref =       CalcTemp(RefCnt, RefCnt);   // This just testing, should show 0.0
  // Serial.print(" TickF=");  Serial.print(xTaskGetTickCount());
  if (xSemaphoreTake(mutex_webs_data, 500) == pdTRUE) {     // must check, we specified a timeout
    // sprintf(DataChar, "%.2f, %.2f", Collector, Tank);       // will not really matter if we miss a few
    sprintf(DataChar, "%d,%d,%d,%d", int(Collector*1000.0), int(Tank*1000.0), PumpPercent, LogPumpJam);
    xSemaphoreGive(mutex_webs_data);
  } else Serial.println("Warning, cannot update webs data");
  
  if (!ServiceReady) {               // indicates a network fail or delay, flicker every second
    Serial.print(" No Network ");
    rgbLedWrite(RGB_BUILTIN,0,0,RGB_BRIGHTNESS); // Blue
    delay(210);
    rgbLedWrite(RGB_BUILTIN,0,0,0); // Off / black
    delay(210);
  } else
    Serial.print(StatusChar);  
  Serial.print(" Ref Cnt="); Serial.print(RefCnt);
  Serial.print(" Coll=");    Serial.print(Collector); 
  Serial.print(" Tank=");    Serial.print(Tank);
  Serial.print(" Cnt=");     Serial.println(LoopCount);
   
  ControlLoop(Collector, Tank);           // This controls the pump 
}

/* 
Generally, seems a FreeRTOS Tick is 1mS, determined by setting
in FreeRTOSConfig.h, configTICK_RATE_HZ to 1000, so, i Mutex,
I treat timeout as mS.

*/
