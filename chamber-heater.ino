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
  WiFi.setHostname("chamber-heater");
  WiFiManager wifiManager;
  bool success = wifiManager.autoConnect("chamber-heater");
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
  Serial.print("Target Temperature: ");
  Serial.println(targetTemperature);

  sensors.requestTemperatures(); 
  currentTemperature = sensors.getTempCByIndex(0);
  if (currentTemperature != DEVICE_DISCONNECTED_C) {
    if (targetTemperature < 40) {
      digitalWrite(RELAY_OUTPUT, LOW);
    } else {
      if (currentTemperature < (targetTemperature - 2.5)) {
        digitalWrite(RELAY_OUTPUT, HIGH); 
      } else if (currentTemperature > (targetTemperature + 2.5)) {
        digitalWrite(RELAY_OUTPUT, LOW);  
      }
    }
  }

  WiFiClient client = httpEndPoint.available();
  if (client) {
    String requestLine = "";
    while (client.connected() && client.available()) {
      char c = client.read();
      requestLine += c;
      if (c == '\n') break; 
    }
    
    if (requestLine.indexOf("POST") != -1) {
      int index = requestLine.indexOf("target=");
      if (index != -1) {
        int spaceIndex = requestLine.indexOf(" ", index);
        String targetStr = requestLine.substring(index + 7, spaceIndex);
        targetTemperature = targetStr.toFloat();
        Serial.print("Updated Target Temp to: ");
        Serial.println(targetTemperature);
      }
    }

    client.println("HTTP/1.1 200 OK");
    client.println("Content-Type: text/plain");
    client.println("Connection: close");
    client.println();
    client.print("Current Temp: "); 
    client.print(currentTemperature); 
    client.println(" C");
    client.print("Target Temp: "); 
    client.print(targetTemperature); 
    client.println(" C");
    client.print("Previous Relay Status: "); 
    client.println(digitalRead(RELAY_OUTPUT) ? "OPEN" : "CLOSED");
    client.print("Next Relay State:");
    client.println(targetTemperature >= 40 ? "OPEN" : "CLOSED");

    client.stop(); 
  }
  
  delay(200);
}