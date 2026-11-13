
#include <WiFi.h>
#include <Wire.h>
#include <Adafruit_BMP085.h>
#include <PubSubClient.h>
#include <math.h>

// ================= PIN =================
#define SDA_PIN       15
#define SCL_PIN       16
#define LED_PIN       12
#define BUZZER_PIN    13

// ================= WIFI =================
const char* ssid = "Wokwi-GUEST";
const char* password = "";

// ================= MQTT =================
const char* mqtt_server = "broker.hivemq.com";
const int mqtt_port = 1883;

const char* topic_data = "runner/data";
const char* topic_led = "runner/led/cmd";
const char* topic_buzzer = "runner/buzzer/cmd";
const char* topic_status = "runner/status";

// ================= SENSOR =================
Adafruit_BMP085 bmp;

WiFiClient espClient;
PubSubClient client(espClient);

// ================= STRUCT =================
struct SensorData {
  float temperature;
  float pressure;
  float altitude;
};

struct AlertData {
  float temperature;
  float altitude;
};

// ================= QUEUE =================
QueueHandle_t dataQueue;
QueueHandle_t dataAlert;

// ================= CONTROL =================
volatile bool manualLED = false;
volatile bool manualBuzzer = false;

bool autoWarning = false;

// ================= MQTT CALLBACK =================
void mqttCallback(char* topic, byte* payload,
                  unsigned int length) {

  String message = "";

  for (unsigned int i = 0; i < length; i++) {
    message += (char)payload[i];
  }

  if (strcmp(topic, topic_led) == 0) {
    manualLED = (message == "1" || message == "ON");
    Serial.println(manualLED ? "LED MANUAL ON" :
                                "LED MANUAL OFF");
  }

  if (strcmp(topic, topic_buzzer) == 0) {
    manualBuzzer = (message == "1" || message == "ON");
    Serial.println(manualBuzzer ? "BUZZER MANUAL ON" :
                                  "BUZZER MANUAL OFF");
  }
}

// ================= MQTT CONNECT =================
void mqttReconnect() {

  if (client.connected()) return;

  String clientId = "ESP32_Runner_";
  clientId += String((uint32_t)ESP.getEfuseMac(), HEX);

  if (client.connect(clientId.c_str())) {

    Serial.println("MQTT Connected!");

    client.subscribe(topic_led);
    client.subscribe(topic_buzzer);

    client.publish(topic_status, "ONLINE");

  } else {
    Serial.print("MQTT failed, state = ");
    Serial.println(client.state());
  }
}

// =================================================
// TASK 1: READ SENSOR - CORE 1
// =================================================
void TaskReadData(void *pvParameters) {

  SensorData data;
  AlertData alert;

  while (1) {

    data.temperature = bmp.readTemperature();
    data.pressure = bmp.readPressure();
    data.altitude = bmp.readAltitude(101325.0);

    // Serial Monitor
    Serial.println("\n===== RUNNER MONITOR =====");

    Serial.print("Nhiet do: ");
    Serial.print(data.temperature);
    Serial.println(" C");

    Serial.print("Ap suat: ");
    Serial.print(data.pressure / 100.0);
    Serial.println(" hPa");

    Serial.print("Do cao: ");
    Serial.print(data.altitude);
    Serial.println(" m");

    // Send full data to MQTT Queue
    if (xQueueSend(dataQueue, &data, 0) != pdPASS) {
      Serial.println("WARNING: dataQueue FULL");
    }

    // Send alert data
    alert.temperature = data.temperature;
    alert.altitude = data.altitude;

    // Queue length = 1, always keep latest sample
    xQueueOverwrite(dataAlert, &alert);

    vTaskDelay(pdMS_TO_TICKS(1000));
  }
}

// =================================================
// TASK 2: SEND MQTT - CORE 0
// =================================================
void TaskSendData(void *pvParameters) {

  SensorData data;

  char payload[160];

  bool wifiStarted = false;
  unsigned long lastWiFiAttempt = 0;
  unsigned long lastMQTTAttempt = 0;

  while (1) {

    // WiFi connection
    if (WiFi.status() != WL_CONNECTED) {

      if (!wifiStarted ||
          millis() - lastWiFiAttempt > 10000) {

        Serial.println("Connecting WiFi...");

        WiFi.begin(ssid, password);

        wifiStarted = true;
        lastWiFiAttempt = millis();
      }

      vTaskDelay(pdMS_TO_TICKS(100));
      continue;
    }

    // MQTT server configuration
    if (!client.connected()) {

      if (millis() - lastMQTTAttempt > 3000 ||
          lastMQTTAttempt == 0) {

        lastMQTTAttempt = millis();

        Serial.println("Connecting MQTT...");
        mqttReconnect();
      }
    }

    // Maintain MQTT connection and receive commands
    if (client.connected()) {

      client.loop();

      // Receive sensor data from Queue
      if (xQueueReceive(dataQueue, &data,
                        pdMS_TO_TICKS(100))) {

        snprintf(payload, sizeof(payload),
          "{\"temperature\":%.2f,"
          "\"pressure\":%.2f,"
          "\"altitude\":%.2f}",
          data.temperature,
          data.pressure / 100.0,
          data.altitude
        );

        if (client.publish(topic_data, payload)) {
          Serial.println("MQTT Published:");
          Serial.println(payload);
        }
      }

      client.loop();
    }

    vTaskDelay(pdMS_TO_TICKS(10));
  }
}

// =================================================
// TASK 3: ALERT - CORE 1
// =================================================
void TaskAlert(void *pvParameters) {

  AlertData alert;

  float altitudeBaseline = 0;

  bool firstReading = true;
  int sampleCount = 0;

  unsigned long altitudeWarningUntil = 0;

  while (1) {

    if (xQueueReceive(dataAlert, &alert,
                      portMAX_DELAY) == pdPASS) {

      // Temperature warning
      bool temperatureWarning =
          (alert.temperature > 35 ||
           alert.temperature < 15);

      // Altitude change detection over 5 seconds
      if (firstReading) {

        altitudeBaseline = alert.altitude;
        firstReading = false;

      } else {

        sampleCount++;

        if (sampleCount >= 5) {

          float altitudeChange =
              fabs(alert.altitude - altitudeBaseline);

          if (altitudeChange > 5.0) {

            Serial.println("WARNING: ALTITUDE CHANGE!");

            altitudeWarningUntil = millis() + 5000;
          }

          altitudeBaseline = alert.altitude;
          sampleCount = 0;
        }
      }

      bool altitudeWarning =
          (millis() < altitudeWarningUntil);

      // Combine automatic warnings
      autoWarning =
          temperatureWarning || altitudeWarning;

      // Manual control + automatic warning
      digitalWrite(LED_PIN,
                   (manualLED || autoWarning) ? HIGH : LOW);

      digitalWrite(BUZZER_PIN,
                   (manualBuzzer || autoWarning) ? HIGH : LOW);

      if (temperatureWarning) {
        Serial.println("WARNING: TEMPERATURE!");
      }

      if (autoWarning) {
        Serial.println("RUNNER ALERT!");
      }
    }
  }
}

// =================================================
// SETUP
// =================================================
void setup() {

  Serial.begin(115200);

  pinMode(LED_PIN, OUTPUT);
  pinMode(BUZZER_PIN, OUTPUT);

  digitalWrite(LED_PIN, LOW);
  digitalWrite(BUZZER_PIN, LOW);

  // I2C
  Wire.begin(SDA_PIN, SCL_PIN);

  // BMP180 initialization
  if (!bmp.begin()) {

    Serial.println("ERROR: BMP180 NOT FOUND!");

    while (1) {
      delay(1000);
    }
  }

  Serial.println("BMP180 READY!");

  // MQTT
  client.setServer(mqtt_server, mqtt_port);
  client.setCallback(mqttCallback);
  client.setBufferSize(256);

  // Create Queues
  dataQueue = xQueueCreate(5, sizeof(SensorData));
  dataAlert = xQueueCreate(1, sizeof(AlertData));

  if (dataQueue == NULL || dataAlert == NULL) {
    Serial.println("ERROR: CREATE QUEUE FAILED!");
    while (1) {
      delay(1000);
    }
  }

  // Task 1: Sensor - Core 1
  xTaskCreatePinnedToCore(
    TaskReadData,
    "ReadData",
    4096,
    NULL,
    2,
    NULL,
    1
  );

  // Task 2: MQTT - Core 0
  xTaskCreatePinnedToCore(
    TaskSendData,
    "SendData",
    8192,
    NULL,
    1,
    NULL,
    0
  );

  // Task 3: Alert - Core 1
  xTaskCreatePinnedToCore(
    TaskAlert,
    "Alert",
    4096,
    NULL,
    2,
    NULL,
    1
  );

  Serial.println("===== RUNNER SYSTEM STARTED =====");
}

// =================================================
// LOOP
// =================================================
void loop() {
  vTaskDelay(pdMS_TO_TICKS(1000));
}
