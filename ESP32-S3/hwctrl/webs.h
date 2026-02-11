#pragma once                              // seems to do nothing

/*  Header for my web service, all the work is done in WebServer

*/

#include <WiFi.h>
#include <NetworkClient.h>
#include <WebServer.h>
#include <ESPmDNS.h>

// The extern things here are all defined in webs.cpp
extern char StatusChar[180];              // will contain, eg IP address assigned to wifi
extern bool ServiceReady;                 // True when wifi and webs are ready
extern char DataChar[80];                 // The message the webs should send (lock it !)
extern TaskHandle_t WebTask;              // run our web service, just a handle but needed in both units.
extern SemaphoreHandle_t mutex_webs_data;  // Keep DataChar safe

void StartServer( void * pvParameters);

//extern TaskHandle_t ControlTask; // Measure temps and ctrl Pump, maybe just do this in main ?
// https://randomnerdtutorials.com/esp32-dual-core-arduino-ide/



