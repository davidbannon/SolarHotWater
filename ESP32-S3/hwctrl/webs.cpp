#include "webs.h"
#include "credentials.h"
const char* hostname = "hwctrl";   // TP-Link insists its esp32s3-07E2AC
/*
A basic web server, Web Service really that returns contents of a status
string when asked for http://<IP>/data.

Runs on second core as an independent process.

Don't use serial.print from both CPU, seems no locking. Maybe do some ?
We run the WebService on the (non-default) CPU 0
Responds to <ip>/data
*/

// These are defined in credentils.h, needed to connect to local DNS
// they are not pushed to github !
// const char *ssid = "?";
// const char *password = "?";

WebServer server(80);    // Port to listen on
char DataChar[80];
bool ServiceReady = false;
char StatusChar[180];
TaskHandle_t WebTask;     // run our web service
SemaphoreHandle_t mutex_webs_data; 

void handleRoot() {
  server.send(200, "text/plain", "hello from esp32!");
}

void handleData() {
  if (xSemaphoreTake(mutex_webs_data, 2500) == pdTRUE) {  // must check, we specified a timeout
    server.send(200, "text/plain", DataChar);
    xSemaphoreGive(mutex_webs_data);
  } else
    server.send(200, "text/plain", "data not available");
}

void handleNotFound() {
  String message = "Command Not Found\n\n";
  message += "URI: ";
  message += server.uri();
  message += "\nMethod: ";
  message += (server.method() == HTTP_GET) ? "GET" : "POST";
  message += "\nArguments: ";
  message += server.args();
  message += "\n";
  for (uint8_t i = 0; i < server.args(); i++) {
    message += " " + server.argName(i) + ": " + server.arg(i) + "\n";
  }
  server.send(404, "text/plain", message);
}

// Only "public function", called as part of a Task definition
void StartServer( void * pvParameters) {
  StatusChar[0] = 0;
  WiFi.mode(WIFI_STA);
  WiFi.config(INADDR_NONE, INADDR_NONE, INADDR_NONE, INADDR_NONE);
  WiFi.setHostname(hostname);
  WiFi.begin(ssid, password);
  // Serial.println("");
  while (WiFi.status() != WL_CONNECTED) {   // Wait for connection
    delay(500);
    sprintf(StatusChar, "Status : no net or DHCP available. ");
    // Serial.print(" no net ");
  } 
  //sprintf(StatusChar, "Connected to %s with IP %s ", ssid, WiFi.localIP().toString().c_str());
  //Serial.println(StatusChar);
  server.on("/", handleRoot);      // Just the address, no param
  server.on("/data", handleData);  // our current measured data
  server.on("/inline", []() {
    server.send(200, "text/plain", "this works as well");
  });
  server.onNotFound(handleNotFound);   // function to handle not found
  server.begin();
  // Serial.print("HTTP server started on core ");
  sprintf(StatusChar, " IP = %s %s", WiFi.localIP().toString().c_str(), WiFi.getHostname() );
  // sprintf(StatusChar, "Connected to %s with IP %s, core %d ", ssid, WiFi.localIP().toString().c_str(), xPortGetCoreID());
  delay(100);
  ServiceReady = true;
  while (1) {
    delay(2);  //allow the cpu to switch to other tasks  
    server.handleClient();
  }
}

//   Create a Task like this -
//   xTaskCreatePinnedToCore(
//                    StartServer, /* Task function. */
//                    "WebTask",   /* name of task. */
//                    10000,       /* Stack size of task */
//                    NULL,        /* parameter of the task */
//                    1,           /* priority of the task */
//                    &WebTask,    /* Task handle to keep track of created task, defined and declared ad TaskHandle_t */
//                    0);          /* pin task to core 0 */     

/*
When running, eg a browser pointing to http://<ip-address>/data will return
contents of DataChar string.

Don't change (or read) DataChar without locking it first. See above. 

StatusChar will have the ip-address (or error message if it failed).
Allow time for it to decided its OK, there is apparently no locking
between CPUs with the serial.print() command.
*/


