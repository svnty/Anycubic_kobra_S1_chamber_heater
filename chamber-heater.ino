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
  Serial.print("Target Temperature: ");
  Serial.println(targetTemperature);
  Serial.print("Current Temperature:");
  Serial.println(currentTemperature);

  sensors.requestTemperatures(); 
  currentTemperature = sensors.getTempCByIndex(0);
  if (targetTemperature < 40) {
    digitalWrite(RELAY_OUTPUT, LOW);
  } else {
    if (currentTemperature < (targetTemperature - 2.5)) {
      digitalWrite(RELAY_OUTPUT, HIGH); 
    } else if (currentTemperature > (targetTemperature + 2.5)) {
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
    
    // Scan the complete request for the target variable
    int index = fullRequest.indexOf("target=");
    if (index != -1) {
      int endIndex = fullRequest.length();
      int spaceIndex = fullRequest.indexOf(" ", index);
      int ampIndex = fullRequest.indexOf("&", index);
      int newlineIndex = fullRequest.indexOf("\r", index);
      
      if (spaceIndex != -1 && spaceIndex < endIndex) endIndex = spaceIndex;
      if (ampIndex != -1 && ampIndex < endIndex) endIndex = ampIndex;
      if (newlineIndex != -1 && newlineIndex < endIndex) endIndex = newlineIndex;
      
      String targetStr = fullRequest.substring(index + 7, endIndex);
      targetStr.trim();
      targetTemperature = targetStr.toFloat();
    }

    // Send the response
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
    client.print("Relay: ");
    if (targetTemperature < 40) {
      client.println("OFF");
    } else {
      client.println("ON");
    }
    
    delay(10); 
    client.stop();
  }
  
  delay(200);
}