/*
 * ESP32 Health Monitor
 * MAX30102 Heart Rate + DHT11 Temperature/Humidity
 * BLE transmission every 1 minute with 10 beeps
 * Critical alert (5 beeps) when heart rate < 50 BPM
 */

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <DHT.h>
#include <Wire.h>
#include "MAX30105.h"
#include "heartRate.h"

// Pin definitions
#define DHT11PIN 5
#define BUZZER_PIN 18
#define DHT_TYPE DHT11

DHT dht(DHT11PIN, DHT_TYPE);
MAX30105 particleSensor;

// Heart rate calculation
const byte RATE_SIZE = 4;
byte rates[RATE_SIZE];
byte rateSpot = 0;
long lastBeat = 0;
float beatsPerMinute = 0;
int beatAvg = 0;

// BLE configuration
#define SERVICE_UUID        "12345678-1234-1234-1234-123456789012"
#define CHARACTERISTIC_UUID "12345678-1234-1234-1234-123456789013"

BLEServer *pServer = NULL;
BLECharacteristic *pCharacteristic = NULL;
bool deviceConnected = false;
bool oldDeviceConnected = false;

// Buzzer patterns
#define BEEP_FREQUENCY 4000
#define BEEP_DURATION 150
#define BEEP_PAUSE 100
#define NUM_BEEPS 10

#define CRITICAL_BEEP_FREQUENCY 9000
#define CRITICAL_BEEP_DURATION 200
#define CRITICAL_BEEP_PAUSE 100
#define CRITICAL_NUM_BEEPS 20

// Sensor data
float temperature = NAN;
float humidity = NAN;

// Timing control
unsigned long lastDHTRead = 0;
unsigned long lastBLEUpdate = 0;
unsigned long lastHeartRateReading = 0;
unsigned long lastCriticalHeartAlert = 0;
const unsigned long HEART_RATE_READING_INTERVAL = 10000;
const unsigned long CRITICAL_HEART_ALERT_INTERVAL = 30000;

// Health thresholds
#define HEART_NORMAL_LOW 60
#define HEART_NORMAL_HIGH 100
#define HEART_CRITICAL_LOW 50
#define HUMIDITY_LOW 30.0
#define HUMIDITY_HIGH 70.0
#define TEMP_NORMAL_LOW 28.0
#define TEMP_NORMAL_HIGH 37.0
#define CONSECUTIVE_TEMP_REQUIRED 5
#define BLE_UPDATE_INTERVAL 60000UL

// Alert tracking
int consecutiveHighTempCount = 0;
bool lastHeartAlert = false;
bool lastTempAlert = false;
bool shouldPlayBuzzer = false;
bool shouldPlayCriticalAlert = false;

// BLE Server Callbacks
class MyServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    Serial.println("\n>>> BLE CLIENT CONNECTED <<<");
    lastBLEUpdate = millis() - BLE_UPDATE_INTERVAL;
  };
  
  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println("\n>>> BLE CLIENT DISCONNECTED <<<");
    Serial.println("====Waiting for new connections...\n");
    
    lastHeartAlert = false;
    lastTempAlert = false;
    consecutiveHighTempCount = 0;
    shouldPlayBuzzer = false;
    shouldPlayCriticalAlert = false;
  }
};

void setup() {
  Serial.begin(115200);
  delay(1000);
  
  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);
  dht.begin();

  initHeartRateSensor();

  Serial.println("\n==================================================");
  Serial.println("       ESP32 HEALTH MONITOR - INITIALIZED");
  Serial.println("==================================================");

  initBLE();
}

// Initialize MAX30102 sensor
void initHeartRateSensor() {
  Serial.println("Initializing MAX30102 Heart Rate Sensor...");
  
  if (!particleSensor.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("MAX30102 was not found. Please check wiring/power.");
    while (1);
  }
  
  particleSensor.setup();
  particleSensor.setPulseAmplitudeRed(0x0A);
  particleSensor.setPulseAmplitudeGreen(0);
  
  Serial.println("MAX30102 initialized successfully");
}

// Initialize BLE service
void initBLE() {
  BLEDevice::init("HealthMonitor");
  BLEDevice::setPower(ESP_PWR_LVL_P7);
  
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  
  BLEService *pService = pServer->createService(SERVICE_UUID);

  pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY |
    BLECharacteristic::PROPERTY_INDICATE
  );
  
  pCharacteristic->addDescriptor(new BLE2902());
  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();
  
  Serial.println("====BLE Service initialized successfully");
}

void loop() {
  unsigned long currentTime = millis();

  readHeartRateSensor();
  
  if (currentTime - lastDHTRead > 2000UL) {
    readDHTSensor();
    lastDHTRead = currentTime;
  }

  if (currentTime - lastHeartRateReading >= HEART_RATE_READING_INTERVAL) {
    displayHeartRateReading();
    lastHeartRateReading = currentTime;
  }

  bool currentHeartAlert = checkHeartAlert();
  bool currentHumidityAlert = checkHumidityAlert();
  bool currentTempAlert = checkTemperatureAlert();

  if (checkCriticalHeartRate() && (currentTime - lastCriticalHeartAlert >= CRITICAL_HEART_ALERT_INTERVAL)) {
    shouldPlayCriticalAlert = true;
    lastCriticalHeartAlert = currentTime;
  }

  if (deviceConnected && (currentTime - lastBLEUpdate >= BLE_UPDATE_INTERVAL)) {
    Serial.println("\n>>> SENDING BLE DATA - PLAYING 10 BEEPS <<<");
    shouldPlayBuzzer = true;
    sendBLEData(currentHeartAlert, currentTempAlert, currentHumidityAlert);
    lastBLEUpdate = currentTime;
  }

  if (shouldPlayCriticalAlert) {
    playCriticalHeartAlert();
    shouldPlayCriticalAlert = false;
  }

  if (shouldPlayBuzzer) {
    playNineBeeps();
    shouldPlayBuzzer = false;
  }

  lastHeartAlert = currentHeartAlert;
  lastTempAlert = currentTempAlert;

  handleBLEConnection();

  static unsigned long lastDebugPrint = 0;
  if (currentTime - lastDebugPrint > 10000UL) {
    printDebugInfo(currentHeartAlert, currentTempAlert, currentHumidityAlert);
    lastDebugPrint = currentTime;
  }

  delay(50);
}

// Read heart rate from MAX30102
void readHeartRateSensor() {
  long irValue = particleSensor.getIR();

  if (checkForBeat(irValue) == true) {
    long delta = millis() - lastBeat;
    lastBeat = millis();

    beatsPerMinute = 60 / (delta / 1000.0);

    if (beatsPerMinute < 255 && beatsPerMinute > 20) {
      rates[rateSpot++] = (byte)beatsPerMinute;
      rateSpot %= RATE_SIZE;

      beatAvg = 0;
      for (byte x = 0 ; x < RATE_SIZE ; x++)
        beatAvg += rates[x];
      beatAvg /= RATE_SIZE;
    }
  }

  if (irValue < 50000) {
    beatAvg = 0;
  }
}

// Check for critical heart rate
bool checkCriticalHeartRate() {
  long irValue = particleSensor.getIR();
  return (irValue >= 50000 && beatAvg > 0 && beatAvg < HEART_CRITICAL_LOW);
}

// Display heart rate reading
void displayHeartRateReading() {
  long irValue = particleSensor.getIR();
  
  if (irValue < 50000) {
    Serial.println("HEART RATE READING");
    Serial.println("==================================");
    Serial.println("No finger detected on sensor!");
    Serial.println("==================================");
  } else if (beatAvg > 0) {
    Serial.println("HEART RATE READING");
    Serial.println("==================================");
    Serial.print("IR Value: ");
    Serial.println(irValue);
    Serial.print("Current BPM: ");
    Serial.println(beatsPerMinute);
    Serial.print("Average BPM: ");
    Serial.println(beatAvg);
    
    Serial.print("Status: ");
    if (beatAvg < HEART_CRITICAL_LOW) {
      Serial.println("CRITICAL LOW (Below 50 BPM) ");
    } else if (beatAvg < HEART_NORMAL_LOW) {
      Serial.println("LOW (Below 60 BPM)");
    } else if (beatAvg > HEART_NORMAL_HIGH) {
      Serial.println("HIGH (Above 100 BPM)");
    } else {
      Serial.println("NORMAL (60-100 BPM)");
    }
    Serial.println("==================================");
  } else {
    Serial.println("HEART RATE READING");
    Serial.println("==================================");
    Serial.println("Please keep finger steady on sensor...");
    Serial.println("==================================");
  }
  Serial.println();
}

// Read DHT11 sensor
void readDHTSensor() {
  float tempReading = dht.readTemperature();
  float humidityReading = dht.readHumidity();
  
  if (!isnan(tempReading)) {
    temperature = tempReading;
  }
  if (!isnan(humidityReading)) {
    humidity = humidityReading;
  }
}

// Check heart rate alert (60-100 BPM range)
bool checkHeartAlert() {
  return (beatAvg > 0 && (beatAvg < HEART_NORMAL_LOW || beatAvg > HEART_NORMAL_HIGH));
}

// Check humidity alert (50-65% range)
bool checkHumidityAlert() {
  return (!isnan(humidity) && 
         (humidity < HUMIDITY_LOW || humidity > HUMIDITY_HIGH));
}

// Check temperature alert (outside normal range)
bool checkTemperatureAlert() {
  if (!isnan(temperature)) {
    // Alert if temperature is outside the normal range (28-37°C)
    if (temperature < TEMP_NORMAL_LOW || temperature > TEMP_NORMAL_HIGH) {
      consecutiveHighTempCount++;
    } else {
      consecutiveHighTempCount = 0;
    }
  }
  
  return (consecutiveHighTempCount >= CONSECUTIVE_TEMP_REQUIRED);
}

// Handle BLE connection state
void handleBLEConnection() {
  if (!deviceConnected && oldDeviceConnected) {
    delay(500);
    pServer->startAdvertising();
    oldDeviceConnected = deviceConnected;
  }
  
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
  }
}

// Send health data via BLE
void sendBLEData(bool heartAlert, bool tempAlert, bool humidityAlert) {
  String jsonData = "{";
  jsonData += "\"h\":" + String(beatAvg);
  jsonData += ",\"t\":" + String(temperature, 1);
  jsonData += ",\"m\":" + String(humidity, 1);
  jsonData += ",\"a\":" + String(heartAlert ? 1 : 0);
  jsonData += ",\"tx\":" + String(tempAlert ? 1 : 0);
  jsonData += ",\"hm\":" + String(humidityAlert ? 1 : 0);
  jsonData += "}";

  Serial.println("JSON Payload: " + jsonData);
  Serial.print("Status: ");
  if (heartAlert) {
    if (beatAvg < HEART_NORMAL_LOW) {
      Serial.print("HEART_ALERT_LOW ");
    } else {
      Serial.print("HEART_ALERT_HIGH ");
    }
  }
  if (tempAlert) {
    if (temperature < TEMP_NORMAL_LOW) {
      Serial.print("TEMP_ALERT_LOW ");
    } else {
      Serial.print("TEMP_ALERT_HIGH ");
    }
  }
  if (humidityAlert) Serial.print("HUMIDITY_ALERT ");
  if (!heartAlert && !tempAlert && !humidityAlert) Serial.print("ALL_NORMAL");
  Serial.println();
  
  Serial.print("Normal Ranges - Heart: ");
  Serial.print(HEART_NORMAL_LOW);
  Serial.print("-");
  Serial.print(HEART_NORMAL_HIGH);
  Serial.print(" BPM, Temp: ");
  Serial.print(TEMP_NORMAL_LOW);
  Serial.print("-");
  Serial.print(TEMP_NORMAL_HIGH);
  Serial.println("°C");
  
  pCharacteristic->setValue((uint8_t*)jsonData.c_str(), jsonData.length());
  pCharacteristic->notify();
}

// Play critical heart rate alert
void playCriticalHeartAlert() {
  Serial.println("HEART RATE BELOW 50 BPM - PLAYING 5 URGENT BEEPS");
  Serial.print("Current Heart Rate: ");
  Serial.print(beatAvg);
  Serial.println(" BPM");
  
  for (int i = 1; i <= CRITICAL_NUM_BEEPS; i++) {
    Serial.print("CRITICAL BEEP ");
    Serial.println(i);
    
    tone(BUZZER_PIN, CRITICAL_BEEP_FREQUENCY, CRITICAL_BEEP_DURATION);
    delay(CRITICAL_BEEP_DURATION + CRITICAL_BEEP_PAUSE);
    noTone(BUZZER_PIN);
    
    if (i < CRITICAL_NUM_BEEPS) {
      delay(50);
    }
  }
  
  digitalWrite(BUZZER_PIN, LOW);
  Serial.println("Critical alert beeps completed");
  Serial.println("------------------------------------------\n");
}

// Play 10 beeps for BLE transmission
void playNineBeeps() {
  Serial.println("PLAYING 10 BEEPS - BLE DATA TRANSMISSION");
  
  for (int i = 1; i <= NUM_BEEPS; i++) {
    Serial.print("BEEP ");
    Serial.println(i);
    
    tone(BUZZER_PIN, BEEP_FREQUENCY, BEEP_DURATION);
    delay(BEEP_DURATION + BEEP_PAUSE);
    noTone(BUZZER_PIN);
    
    if (i < NUM_BEEPS) {
      delay(50);
    }
  }
  
  digitalWrite(BUZZER_PIN, LOW);
  Serial.println("10 beeps completed - Buzzer off");
  Serial.println("------------------------------------------");
}

// Print debug information
void printDebugInfo(bool heartAlert, bool tempAlert, bool humidityAlert) {
  Serial.print(" SENSOR READINGS | ");
  Serial.print("Heart: "); 
  if (beatAvg > 0) {
    Serial.print(beatAvg);
    Serial.print(" BPM");
  } else {
    Serial.print("No Signal");
  }
  Serial.print(" [");
  if (beatAvg > 0 && beatAvg < HEART_CRITICAL_LOW) {
    Serial.print("CRITICAL");
  } else if (heartAlert) {
    if (beatAvg < HEART_NORMAL_LOW) {
      Serial.print("LOW");
    } else {
      Serial.print("HIGH");
    }
  } else {
    Serial.print("Normal");
  }
  Serial.print("]");
  
  Serial.print(" | Temp: "); 
  if (isnan(temperature)) {
    Serial.print("N/A");
  } else {
    Serial.print(temperature, 1);
    Serial.print("°C");
  }
  Serial.print(" [");
  Serial.print(tempAlert ? "HIGH" : "OK");
  Serial.print("]");
  
  Serial.print(" | Humidity: "); 
  if (isnan(humidity)) {
    Serial.print("N/A");
  } else {
    Serial.print(humidity, 1);
    Serial.print("%");
  }
  Serial.print(" [");
  Serial.print(humidityAlert ? "ALERT" : "OK");
  Serial.print("]");
  
  Serial.print(" | BLE: ");
  Serial.println(deviceConnected ? "Connected" : "Waiting");
}