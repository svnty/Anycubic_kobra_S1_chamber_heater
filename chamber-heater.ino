#include <WiFi.h>
#include <ESPmDNS.h> // Include the built-in mDNS library
#include <OneWire.h>
#include <DallasTemperature.h>
#include <WiFiManager.h>
#include <FastLED.h>

#define NUM_LEDS 1
#define DATA_PIN 48
#define RELAY_OUTPUT 6
#define ONE_WIRE_BUS 7

CRGB leds[NUM_LEDS];
OneWire oneWire(ONE_WIRE_BUS);
DallasTemperature sensors(&oneWire);
WiFiServer httpEndPoint(80);
float currentTemperature = 0.0;
float targetTemperature = 0.0;
unsigned long printTime = 0;
unsigned long checkTempInterval = 500;
unsigned long lastCheckTemp = 0;

void setup() {
  Serial.begin(115200);

  while (!Serial && millis() < 4000) {
    delay(10);
  }

  pinMode(RELAY_OUTPUT, OUTPUT);
  digitalWrite(RELAY_OUTPUT, LOW); // relay off at start
  sensors.begin(); 
  FastLED.addLeds<NEOPIXEL, DATA_PIN>(leds, NUM_LEDS);
  FastLED.clear();

  // WiFi
  WiFi.setHostname("test-esp");
  WiFiManager wifiManager;
  bool success = wifiManager.autoConnect("test-esp");
  if (!success) {
    leds[0] = CRGB::Red;
    FastLED.show();
    delay(2500);
    ESP.restart();
  }
  if (!MDNS.begin("chamber-heater")) {
    leds[0] = CRGB::Red;
    FastLED.show();
    delay(2500);
    ESP.restart();
  }
  httpEndPoint.begin();

  leds[0] = CRGB::Green;
  FastLED.show();
}

void loop() {
  if (printTime > 0 && (long)(millis() - printTime) >= 0) {
    targetTemperature = 0.0;
    printTime = 0;
  }

  if ((unsigned long)(millis() - lastCheckTemp) > checkTempInterval) {
    sensors.requestTemperatures(); 
    currentTemperature = sensors.getTempCByIndex(0);
    lastCheckTemp = millis();
  }

  if (targetTemperature < 40) {
    digitalWrite(RELAY_OUTPUT, LOW);
  } else {
    if (printTime > 0) {
      if (currentTemperature < (targetTemperature - 2.5)) {
        digitalWrite(RELAY_OUTPUT, HIGH); 
      } else if (currentTemperature > (targetTemperature + 2.5)) {
        digitalWrite(RELAY_OUTPUT, LOW);  
      }
    } else {
      digitalWrite(RELAY_OUTPUT, LOW);  
    }
  }

  WiFiClient client = httpEndPoint.available();
  if (client) {
    String fullRequest = "";
    unsigned long timeout = millis();
    
    // Read EVERYTHING (Headers + Body Payload) into one string
    while (client.connected() && millis() - timeout < 500) {
      while (client.available()) {
        char c = client.read();
        fullRequest += c;
        timeout = millis(); // Reset timeout while data is streaming in
      }
    }
    
    int targetIndex = fullRequest.indexOf("target=");
    if (targetIndex != -1) {
      int endIndex = fullRequest.length();
      int spaceIndex = fullRequest.indexOf(" ", targetIndex);
      int ampIndex = fullRequest.indexOf("&", targetIndex);
      int newlineIndex = fullRequest.indexOf("\r", targetIndex);
      
      if (spaceIndex != -1 && spaceIndex < endIndex) endIndex = spaceIndex;
      if (ampIndex != -1 && ampIndex < endIndex) endIndex = ampIndex;
      if (newlineIndex != -1 && newlineIndex < endIndex) endIndex = newlineIndex;
      
      String targetStr = fullRequest.substring(targetIndex + 7, endIndex);
      targetStr.trim();
      targetTemperature = targetStr.toFloat();
    }

    int timerIndex = fullRequest.indexOf("timer=");
    if (timerIndex != -1) {
      int endIndex = fullRequest.length();
      int spaceIndex = fullRequest.indexOf(" ", timerIndex);
      int ampIndex = fullRequest.indexOf("&", timerIndex);
      int newlineIndex = fullRequest.indexOf("\r", timerIndex);
      
      if (spaceIndex != -1 && spaceIndex < endIndex) endIndex = spaceIndex;
      if (ampIndex != -1 && ampIndex < endIndex) endIndex = ampIndex;
      if (newlineIndex != -1 && newlineIndex < endIndex) endIndex = newlineIndex;
      
      String timerStr = fullRequest.substring(timerIndex + 6, endIndex);
      timerStr.trim();
      long timer = timerStr.toInt();

      if (timer > 0) {
        printTime = millis() + ((unsigned long)(timer * 1000)) + (30 * 60 * 1000); // this timer is incase the printer's wifi disconnects, the ESP can continue until the print timer ends
      } else {
        printTime = 0;
      }
    }

    // Send the response
    client.println("HTTP/1.1 200 OK");
    client.println("Content-Type: text/plain");
    client.println("Connection: close");
    client.println();
    client.print("Time Remaining: ");
    if (printTime > 0 && (long)(millis() - printTime) < 0) {
      client.print((printTime - millis()) / 1000);
    } else {
      client.print("0");
    }
    client.println(" S");
    client.print("Current Temp: ");
    client.print(currentTemperature);
    client.println(" C");
    client.print("Target Temp: ");
    client.print(targetTemperature);
    client.println(" C");
    client.print("Relay: "); // we return an esimate of the relays state based on target temp, the actual state is irrelevant 
    if (targetTemperature < 40) {
      client.println("OFF");
    } else {
      if (printTime > 0) {
        client.println("ON");
      } else {
        client.println("OFF");
      }
    }
    
    delay(10); 
    client.stop();
  }
}