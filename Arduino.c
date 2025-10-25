/*
 * ESP32 Health Monitor - 9 Beeps when BLE data is sent to connected device
 * Now with MAX30102 Heart Rate Sensor
 * Updated: Heart rate alerts for readings outside 60-100 BPM range
 */

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <DHT.h>
#include <Wire.h>
#include "MAX30105.h"
#include "heartRate.h"

// Sensor and component pins
#define DHT11PIN 5
#define BUZZER_PIN 18
#define DHT_TYPE DHT11
DHT dht(DHT11PIN, DHT_TYPE);

// MAX30102 Particle Sensor
MAX30105 particleSensor;

// Heart rate calculation variables
const byte RATE_SIZE = 4;
byte rates[RATE_SIZE];
byte rateSpot = 0;
long lastBeat = 0;
float beatsPerMinute = 0;
int beatAvg = 0;

// BLE Service and Characteristic UUIDs
#define SERVICE_UUID        "12345678-1234-1234-1234-123456789012"
#define CHARACTERISTIC_UUID "12345678-1234-1234-1234-123456789013"

// BLE global variables
BLEServer *pServer = NULL;
BLECharacteristic *pCharacteristic = NULL;
bool deviceConnected = false;
bool oldDeviceConnected = false;

// Buzzer configuration - 9 beeps pattern
#define BEEP_FREQUENCY 1500
#define BEEP_DURATION 150
#define BEEP_PAUSE 100
#define NUM_BEEPS 9

// Sensor data variables
float temperature = NAN;
float humidity = NAN;

// Timing control variables
unsigned long lastDHTRead = 0;
unsigned long lastBLEUpdate = 0;
unsigned long lastHeartRateReading = 0;
const unsigned long HEART_RATE_READING_INTERVAL = 20000; // 20 seconds between heart rate displays

// Alert thresholds - UPDATED TO 60-100 RANGE
#define HEART_NORMAL_LOW 60
#define HEART_NORMAL_HIGH 100

#define HUMIDITY_LOW 50.0
#define HUMIDITY_HIGH 65.0

#define TEMP_ALERT_THRESHOLD 30.0
#define CONSECUTIVE_TEMP_REQUIRED 5
#define BLE_UPDATE_INTERVAL 60000UL       // 1 minute between BLE updates

// Alert tracking variables
int consecutiveHighTempCount = 0;
bool lastHeartAlert = false;
bool lastTempAlert = false;

// Buzzer control
bool shouldPlayBuzzer = false;

/**
 * BLE Server Callbacks - Handle connection and disconnection events
 */
class MyServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    Serial.println("\n>>> BLE CLIENT CONNECTED <<<");
    Serial.println("✓ Device: HealthMonitor");
    Serial.println("✓ Data transmission: Every 1 minute");
    Serial.println("✓ Buzzer: 9 beeps when data is sent to connected device");
    Serial.println("✓ Sensors: DHT11, MAX30102 Heart Rate");
    Serial.println("✓ Normal Heart Rate Range: 60-100 BPM");
    Serial.println("✓ Ready for health monitoring\n");
    
    lastBLEUpdate = millis() - BLE_UPDATE_INTERVAL;
  };
  
  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println("\n>>> BLE CLIENT DISCONNECTED <<<");
    Serial.println("====BLE advertising restarted");
    Serial.println("====Waiting for new connections...\n");
    
    lastHeartAlert = false;
    lastTempAlert = false;
    consecutiveHighTempCount = 0;
    shouldPlayBuzzer = false; // Reset buzzer flag on disconnect
  }
};

/**
 * Setup function - Initializes all components
 */
void setup() {
  Serial.begin(115200);
  delay(1000);
  
  // Initialize pins
  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);  // Ensure buzzer is off initially
  dht.begin();

  // Initialize MAX30102 heart rate sensor
  initHeartRateSensor();

  // Print startup information
  Serial.println("\n==================================================");
  Serial.println("       ESP32 HEALTH MONITOR - INITIALIZED");
  Serial.println("==================================================");
  Serial.println("Device: HealthMonitor");
  Serial.println("Sensors: DHT11 (Temp/Humidity), MAX30102 (Heart Rate)");
  Serial.println("Buzzer: 9 BEEPS when BLE data is sent to connected device");
  Serial.println("BLE: Enabled with 1-minute data intervals");
  Serial.println("Heart Rate: MAX30102 with 20-second reading intervals");
  Serial.println("Normal Heart Rate Range: 60-100 BPM");
  Serial.println("==================================================\n");

  // Initialize BLE
  initBLE();
}

/**
 * Initialize MAX30102 heart rate sensor
 */
void initHeartRateSensor() {
  Serial.println("Initializing MAX30102 Heart Rate Sensor...");
  
  if (!particleSensor.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("MAX30102 was not found. Please check wiring/power.");
    while (1);
  }
  
  particleSensor.setup();
  particleSensor.setPulseAmplitudeRed(0x0A);
  particleSensor.setPulseAmplitudeGreen(0);
  
  Serial.println("MAX30102 Heart Rate Sensor initialized successfully");
  Serial.println("Place your finger on the sensor for heart rate readings");
}

/**
 * Initialize BLE service and start advertising
 */
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
  Serial.println("===Device now advertising as 'HealthMonitor'");
  Serial.println("===Waiting for BLE connections...\n");
}

/**
 * Main loop - Handles sensor reading, alert detection, and BLE communication
 */
void loop() {
  unsigned long currentTime = millis();

  // Read and process heart rate data from MAX30102
  readHeartRateSensor();
  
  // Read DHT11 sensor every 2 seconds
  if (currentTime - lastDHTRead > 2000UL) {
    readDHTSensor();
    lastDHTRead = currentTime;
  }

  // Display heart rate reading every 20 seconds
  if (currentTime - lastHeartRateReading >= HEART_RATE_READING_INTERVAL) {
    displayHeartRateReading();
    lastHeartRateReading = currentTime;
  }

  // Check for various health alerts
  bool currentHeartAlert = checkHeartAlert();
  bool currentHumidityAlert = checkHumidityAlert();
  bool currentTempAlert = checkTemperatureAlert();

  // Send BLE data every minute if device is connected
  if (deviceConnected && (currentTime - lastBLEUpdate >= BLE_UPDATE_INTERVAL)) {
    Serial.println("\n>>> SENDING BLE DATA - PLAYING 9 BEEPS <<<");
    shouldPlayBuzzer = true; // Set flag to play buzzer
    sendBLEData(currentHeartAlert, currentTempAlert, currentHumidityAlert);
    lastBLEUpdate = currentTime;
  }

  // Handle buzzer playback
  if (shouldPlayBuzzer) {
    playNineBeeps();
    shouldPlayBuzzer = false; // Reset flag after playing
  }

  // Update previous alert states
  lastHeartAlert = currentHeartAlert;
  lastTempAlert = currentTempAlert;

  // Handle BLE connection state changes
  handleBLEConnection();

  // Print debug information every 10 seconds
  static unsigned long lastDebugPrint = 0;
  if (currentTime - lastDebugPrint > 10000UL) {
    printDebugInfo(currentHeartAlert, currentTempAlert, currentHumidityAlert);
    lastDebugPrint = currentTime;
  }

  delay(50);
}

/**
 * Read and process heart rate data from MAX30102
 */
void readHeartRateSensor() {
  long irValue = particleSensor.getIR();

  if (checkForBeat(irValue) == true) {
    // We sensed a beat!
    long delta = millis() - lastBeat;
    lastBeat = millis();

    beatsPerMinute = 60 / (delta / 1000.0);

    if (beatsPerMinute < 255 && beatsPerMinute > 20) {
      rates[rateSpot++] = (byte)beatsPerMinute;
      rateSpot %= RATE_SIZE;

      // Calculate average heart rate
      beatAvg = 0;
      for (byte x = 0 ; x < RATE_SIZE ; x++)
        beatAvg += rates[x];
      beatAvg /= RATE_SIZE;
    }
  }

  // If no finger detected, reset average
  if (irValue < 50000) {
    beatAvg = 0;
  }
}

/**
 * Display heart rate reading with clear formatting and status
 */
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
    
    // Display status based on range
    Serial.print("Status: ");
    if (beatAvg < HEART_NORMAL_LOW) {
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

/**
 * Read temperature and humidity from DHT11 sensor
 */
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

/**
 * Check for heart rate abnormalities - UPDATED TO 60-100 BPM RANGE
 * Returns: true if heart rate is outside normal 60-100 BPM range
 */
bool checkHeartAlert() {
  return (beatAvg > 0 && (beatAvg < HEART_NORMAL_LOW || beatAvg > HEART_NORMAL_HIGH));
}

/**
 * Check for humidity abnormalities
 * Returns: true if humidity is outside 50-65% range
 */
bool checkHumidityAlert() {
  return (!isnan(humidity) && 
         (humidity < HUMIDITY_LOW || humidity > HUMIDITY_HIGH));
}

/**
 * Check for temperature abnormalities using consecutive readings
 * Returns: true if temperature has been high for 5 consecutive readings
 */
bool checkTemperatureAlert() {
  if (!isnan(temperature)) {
    if (temperature > TEMP_ALERT_THRESHOLD) {
      consecutiveHighTempCount++;
    } else {
      consecutiveHighTempCount = 0;
    }
  }
  
  return (consecutiveHighTempCount >= CONSECUTIVE_TEMP_REQUIRED);
}

/**
 * Handle BLE connection and reconnection logic
 */
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

/**
 * Send health data via BLE in JSON format - Now includes BPM
 */
void sendBLEData(bool heartAlert, bool tempAlert, bool humidityAlert) {
  String jsonData = "{";
  jsonData += "\"h\":" + String(beatAvg);  // Now using BPM from MAX30102
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
  if (tempAlert) Serial.print("TEMP_ALERT ");
  if (humidityAlert) Serial.print("HUMIDITY_ALERT ");
  if (!heartAlert && !tempAlert && !humidityAlert) Serial.print("ALL_NORMAL");
  Serial.println();
  
  pCharacteristic->setValue((uint8_t*)jsonData.c_str(), jsonData.length());
  pCharacteristic->notify();
}

/**
 * Play 9 beeps pattern when BLE data is transmitted
 */
void playNineBeeps() {
  Serial.println("PLAYING 9 BEEPS - BLE DATA TRANSMISSION");
  
  for (int i = 1; i <= NUM_BEEPS; i++) {
    Serial.print("BEEP ");
    Serial.println(i);
    
    tone(BUZZER_PIN, BEEP_FREQUENCY, BEEP_DURATION);
    delay(BEEP_DURATION + BEEP_PAUSE);
    noTone(BUZZER_PIN);
    
    // Small pause between beeps
    if (i < NUM_BEEPS) {
      delay(50);
    }
  }
  
  // Ensure buzzer is completely off
  digitalWrite(BUZZER_PIN, LOW);
  Serial.println("9 beeps completed - Buzzer off");
  Serial.println("------------------------------------------");
}

/**
 * Print debug information to serial monitor - Now includes BPM status
 */
void printDebugInfo(bool heartAlert, bool tempAlert, bool humidityAlert) {
  Serial.print("================SENSOR READINGS | ");
  Serial.print("Heart: "); 
  if (beatAvg > 0) {
    Serial.print(beatAvg);
    Serial.print(" BPM");
  } else {
    Serial.print("No Signal");
  }
  Serial.print(" [");
  if (heartAlert) {
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