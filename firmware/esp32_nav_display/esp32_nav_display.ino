#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SH110X.h>

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#include <ArduinoJson.h>

// ======================================================
// Hardware
// ======================================================

constexpr uint8_t SCREEN_WIDTH = 128;
constexpr uint8_t SCREEN_HEIGHT = 64;
constexpr int8_t OLED_RESET_PIN = -1;
// ESP32-C3 wiring currently used:
// OLED SDA -> GPIO4, OLED SCL -> GPIO5.
constexpr uint8_t I2C_SDA_PIN = 4;
constexpr uint8_t I2C_SCL_PIN = 5;
constexpr uint8_t OLED_I2C_ADDRESS_PRIMARY = 0x3C;
constexpr uint8_t OLED_I2C_ADDRESS_FALLBACK = 0x3D;
constexpr uint8_t OLED_CONTRAST_NORMAL = 0xCF;
constexpr uint8_t OLED_CONTRAST_DIM = 0x10;

Adafruit_SH1106G display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET_PIN);

// Keep the drawing code independent from the concrete OLED controller.
constexpr uint16_t OLED_WHITE = SH110X_WHITE;
bool displayAvailable = false;

// ======================================================
// Product behavior
// ======================================================

// Keep this false for real riding. Set true only when bench-testing the OLED
// without a phone connected.
constexpr bool ENABLE_DEMO_MODE = false;

constexpr uint32_t DEMO_STEP_INTERVAL_MS = 1000;
constexpr int DEMO_DISTANCE_DELTA_M = 10;

// If the phone stops sending navigation packets, stop showing a stale turn.
constexpr uint32_t LIVE_PACKET_TIMEOUT_MS = 8000;

// OLED power policy. BLE keeps running while the display is dim/off.
constexpr uint32_t DISPLAY_DIM_AFTER_IDLE_MS = 15000;
constexpr uint32_t DISPLAY_OFF_AFTER_IDLE_MS = 60000;
constexpr uint32_t DISPLAY_REFRESH_MS = 120;

constexpr int MAX_DISTANCE_M = 9999;
constexpr uint8_t MAX_ROUTE_PREVIEW_POINTS = 6;

// ======================================================
// BLE contract - must match the Flutter app.
// ======================================================

constexpr char DEVICE_NAME[] = "ESP32_NAV";
constexpr char SERVICE_UUID[] = "12345678-1234-1234-1234-123456789abc";
constexpr char CHARACTERISTIC_UUID[] = "abcd1234-5678-1234-5678-abcdef123456";

BLEServer* bleServer = nullptr;
BLEAdvertising* bleAdvertising = nullptr;

bool bleConnected = false;

enum class DisplayPowerState : uint8_t {
  On,
  Dim,
  Off,
};

DisplayPowerState displayPowerState = DisplayPowerState::On;
uint32_t lastDisplayActivityMs = 0;

// ======================================================
// Navigation state
// ======================================================

enum class Direction : uint8_t {
  Up,
  Left,
  Right,
  BearLeft,
  BearRight,
  UTurn,
  Stop,
  Arrived,
  Unknown,
};

struct NavState {
  Direction direction;
  int distanceMeters;
};

NavState nav = {Direction::Stop, 0};

struct ScreenPoint {
  int16_t x;
  int16_t y;
};

ScreenPoint routePreviewPoints[MAX_ROUTE_PREVIEW_POINTS];
uint8_t routePreviewPointCount = 0;

uint32_t lastLivePacketMs = 0;
bool hasReceivedNavPacket = false;
uint32_t rejectedPacketCount = 0;
char lastError[48] = "";

struct DemoStep {
  Direction direction;
  int distanceMeters;
};

const DemoStep demoRoute[] = {
    {Direction::Up, 1000},
    {Direction::BearLeft, 300},
    {Direction::Left, 80},
    {Direction::Up, 500},
    {Direction::Right, 120},
    {Direction::UTurn, 40},
    {Direction::Arrived, 0},
};

size_t demoStepIndex = 0;

// Arduino's .ino preprocessor sometimes generates function prototypes before
// custom enum classes are declared, which breaks types like Direction and
// DisplayPowerState. Keep explicit prototypes here so the generated sketch
// compiles reliably in Arduino IDE.
Direction parseDirection(const char* value);
const char* directionName(Direction direction);
void setDisplayPower(DisplayPowerState state);
void drawDirection(Direction direction);
void drawMiniRouteMap();

// ======================================================
// Direction helpers
// ======================================================

Direction parseDirection(const char* value) {
  if (value == nullptr) return Direction::Unknown;
  if (strcmp(value, "UP") == 0) return Direction::Up;
  if (strcmp(value, "LEFT") == 0) return Direction::Left;
  if (strcmp(value, "RIGHT") == 0) return Direction::Right;
  if (strcmp(value, "BEAR_LEFT") == 0) return Direction::BearLeft;
  if (strcmp(value, "BEAR_RIGHT") == 0) return Direction::BearRight;
  if (strcmp(value, "UTURN") == 0) return Direction::UTurn;
  if (strcmp(value, "STOP") == 0) return Direction::Stop;
  if (strcmp(value, "ARRIVED") == 0) return Direction::Arrived;
  return Direction::Unknown;
}

const char* directionName(Direction direction) {
  switch (direction) {
    case Direction::Up:
      return "UP";
    case Direction::Left:
      return "LEFT";
    case Direction::Right:
      return "RIGHT";
    case Direction::BearLeft:
      return "BEAR_LEFT";
    case Direction::BearRight:
      return "BEAR_RIGHT";
    case Direction::UTurn:
      return "UTURN";
    case Direction::Stop:
      return "STOP";
    case Direction::Arrived:
      return "ARRIVED";
    default:
      return "UNKNOWN";
  }
}

void setLastError(const char* message) {
  strlcpy(lastError, message, sizeof(lastError));
}

void setBadDirectionError(const char* value) {
  snprintf(lastError, sizeof(lastError), "bad:%.24s",
           value == nullptr ? "" : value);
}

bool isLiveFresh() {
  return lastLivePacketMs > 0 && millis() - lastLivePacketMs <= LIVE_PACKET_TIMEOUT_MS;
}

bool shouldKeepDisplayAwake() {
  return ENABLE_DEMO_MODE || bleConnected || hasReceivedNavPacket ||
         nav.direction == Direction::Arrived;
}

bool isStandby() {
  return !ENABLE_DEMO_MODE && !bleConnected;
}

bool isWaitingForNavigation() {
  return !ENABLE_DEMO_MODE && bleConnected && !hasReceivedNavPacket;
}

void setDisplayPower(DisplayPowerState state) {
  if (!displayAvailable) return;
  if (displayPowerState == state) return;
  displayPowerState = state;

  switch (state) {
    case DisplayPowerState::On:
      display.oled_command(0xAF);  // display on
      display.oled_command(0x81);  // set contrast
      display.oled_command(OLED_CONTRAST_NORMAL);
      break;
    case DisplayPowerState::Dim:
      display.oled_command(0xAF);  // display on
      display.oled_command(0x81);  // set contrast
      display.oled_command(OLED_CONTRAST_DIM);
      break;
    case DisplayPowerState::Off:
      display.oled_command(0xAE);  // display off
      break;
  }
}

void wakeDisplay() {
  lastDisplayActivityMs = millis();
  setDisplayPower(DisplayPowerState::On);
}

// ======================================================
// BLE
// ======================================================

void startBleAdvertising() {
  if (bleAdvertising == nullptr) return;
  bleAdvertising->start();
  Serial.println("[BLE] Advertising started");
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override {
    bleConnected = true;
    wakeDisplay();
    setLastError("");
    Serial.println("[BLE] Central connected");
  }

  void onDisconnect(BLEServer* server) override {
    bleConnected = false;
    hasReceivedNavPacket = false;
    lastLivePacketMs = 0;
    routePreviewPointCount = 0;
    nav = {Direction::Stop, 0};
    wakeDisplay();
    setLastError("BLE disconnected");
    Serial.println("[BLE] Central disconnected");

    // Critical for iPhone reconnects. While connected, an ESP32 peripheral
    // normally stops advertising. After disconnect it must advertise again,
    // otherwise the app cannot find it until the ESP32 is power-cycled.
    delay(100);
    startBleAdvertising();
  }
};

class NavWriteCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    String value = characteristic->getValue();
    value.trim();

    if (value.length() == 0) {
      rejectedPacketCount++;
      setLastError("empty packet");
      return;
    }

    if (value.length() > 220) {
      rejectedPacketCount++;
      setLastError("packet too large");
      Serial.println("[BLE] Rejected oversized packet");
      return;
    }

    StaticJsonDocument<384> doc;
    DeserializationError error = deserializeJson(doc, value);
    if (error) {
      rejectedPacketCount++;
      setLastError("bad json");
      Serial.print("[BLE] JSON error: ");
      Serial.println(error.c_str());
      Serial.print("[BLE] Raw: ");
      Serial.println(value);
      return;
    }

    const char* dirText = doc["dir"] | "";
    Direction direction = parseDirection(dirText);
    if (direction == Direction::Unknown) {
      rejectedPacketCount++;
      setBadDirectionError(dirText);
      Serial.print("[BLE] Unknown dir: ");
      Serial.println(dirText);
      Serial.print("[BLE] Raw: ");
      Serial.println(value);
      return;
    }

    if (!doc["dist"].is<int>()) {
      rejectedPacketCount++;
      setLastError("bad dist");
      Serial.println("[BLE] Missing/invalid dist");
      return;
    }

    int distance = doc["dist"].as<int>();
    distance = constrain(distance, 0, MAX_DISTANCE_M);

    nav = {direction, distance};
    routePreviewPointCount = 0;
    JsonArray points = doc["p"].as<JsonArray>();
    if (!points.isNull()) {
      const size_t maxValues = MAX_ROUTE_PREVIEW_POINTS * 2;
      const size_t valueCount =
          points.size() > maxValues ? maxValues : points.size();
      for (size_t i = 0; i + 1 < valueCount; i += 2) {
        if (!points[i].is<int>() || !points[i + 1].is<int>()) break;
        routePreviewPoints[routePreviewPointCount] = {
            static_cast<int16_t>(
                constrain(points[i].as<int>(), 0, SCREEN_WIDTH - 1)),
            static_cast<int16_t>(
                constrain(points[i + 1].as<int>(), 0, SCREEN_HEIGHT - 1)),
        };
        routePreviewPointCount++;
      }
    }
    lastLivePacketMs = millis();
    hasReceivedNavPacket = true;
    wakeDisplay();
    setLastError("");

    Serial.print("[NAV] ");
    Serial.print(directionName(nav.direction));
    Serial.print(" ");
    Serial.print(nav.distanceMeters);
    Serial.println("m");
  }
};

void setupBle() {
  BLEDevice::init(DEVICE_NAME);
  // Stability first: use positive TX power so the phone can rediscover the
  // device reliably after power switch cycles and app backgrounding.
  BLEDevice::setPower(ESP_PWR_LVL_P3);

  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new ServerCallbacks());

  BLEService* service = bleServer->createService(SERVICE_UUID);

  BLECharacteristic* characteristic = service->createCharacteristic(
      CHARACTERISTIC_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  characteristic->setCallbacks(new NavWriteCallbacks());

  service->start();

  bleAdvertising = BLEDevice::getAdvertising();
  bleAdvertising->addServiceUUID(SERVICE_UUID);
  bleAdvertising->setScanResponse(true);
  bleAdvertising->setMinPreferred(0x06);
  bleAdvertising->setMinPreferred(0x12);
  startBleAdvertising();
}

// ======================================================
// Drawing
// ======================================================

void drawThickLine(int16_t x0, int16_t y0, int16_t x1, int16_t y1) {
  display.drawLine(x0, y0, x1, y1, OLED_WHITE);
  if (abs(x1 - x0) > abs(y1 - y0)) {
    display.drawLine(x0, y0 - 1, x1, y1 - 1, OLED_WHITE);
    display.drawLine(x0, y0 + 1, x1, y1 + 1, OLED_WHITE);
  } else {
    display.drawLine(x0 - 1, y0, x1 - 1, y1, OLED_WHITE);
    display.drawLine(x0 + 1, y0, x1 + 1, y1, OLED_WHITE);
  }
}

void drawArrowUp() {
  drawThickLine(38, 58, 38, 40);
  drawThickLine(38, 40, 30, 48);
  drawThickLine(38, 40, 46, 48);
}

void drawArrowLeft() {
  // Turn-left instruction: ride forward, then bend left.
  drawThickLine(50, 58, 50, 51);
  drawThickLine(50, 51, 44, 45);
  drawThickLine(44, 45, 24, 45);
  drawThickLine(24, 45, 36, 37);
  drawThickLine(24, 45, 36, 53);
}

void drawArrowRight() {
  // Turn-right instruction: ride forward, then bend right.
  drawThickLine(26, 58, 26, 51);
  drawThickLine(26, 51, 32, 45);
  drawThickLine(32, 45, 52, 45);
  drawThickLine(52, 45, 40, 37);
  drawThickLine(52, 45, 40, 53);
}

void drawBearLeft() {
  drawThickLine(42, 58, 42, 40);
  drawThickLine(42, 40, 34, 48);
  drawThickLine(42, 40, 50, 48);
  drawThickLine(42, 50, 26, 40);
  drawThickLine(26, 40, 31, 40);
  drawThickLine(26, 40, 26, 45);
}

void drawBearRight() {
  drawThickLine(34, 58, 34, 40);
  drawThickLine(34, 40, 26, 48);
  drawThickLine(34, 40, 42, 48);
  drawThickLine(34, 50, 50, 40);
  drawThickLine(50, 40, 45, 40);
  drawThickLine(50, 40, 50, 45);
}

void drawUTurn() {
  drawThickLine(50, 58, 50, 42);
  drawThickLine(50, 42, 28, 42);
  drawThickLine(28, 42, 28, 54);
  drawThickLine(28, 54, 20, 46);
  drawThickLine(28, 54, 36, 46);
}

void drawStop() {
  display.fillRect(24, 40, 28, 20, OLED_WHITE);
}

void drawArrived() {
  drawThickLine(20, 50, 32, 60);
  drawThickLine(32, 60, 56, 38);
}

void drawUnknown() {
  display.setTextSize(1);
  display.setCursor(38, 28);
  display.println("UNKNOWN");
}

void drawDirection(Direction direction) {
  switch (direction) {
    case Direction::Up:
      drawArrowUp();
      break;
    case Direction::Left:
      drawArrowLeft();
      break;
    case Direction::Right:
      drawArrowRight();
      break;
    case Direction::BearLeft:
      drawBearLeft();
      break;
    case Direction::BearRight:
      drawBearRight();
      break;
    case Direction::UTurn:
      drawUTurn();
      break;
    case Direction::Stop:
      drawStop();
      break;
    case Direction::Arrived:
      drawArrived();
      break;
    default:
      drawUnknown();
      break;
  }
}

void drawMiniRouteMap() {
  if (routePreviewPointCount < 2) return;

  for (uint8_t i = 0; i + 1 < routePreviewPointCount; i++) {
    display.drawLine(routePreviewPoints[i].x, routePreviewPoints[i].y,
                     routePreviewPoints[i + 1].x,
                     routePreviewPoints[i + 1].y, OLED_WHITE);
  }

  // Current-position marker at the bottom of the top mini-map area.
  constexpr int16_t centerX = 64;
  constexpr int16_t bottom = 34;
  display.fillTriangle(centerX, bottom - 6, centerX - 4, bottom + 1,
                       centerX + 4, bottom + 1, OLED_WHITE);
}

void drawDistance(int distanceMeters, bool blinkState) {
  if (nav.direction == Direction::Arrived) {
    display.setTextSize(2);
    display.setCursor(68, 44);
    display.println("ARR");
    return;
  }

  if (distanceMeters <= 30) {
    if (blinkState) {
      display.setTextSize(2);
      display.setCursor(72, 44);
      display.println("NOW");
    }
  } else if (distanceMeters < 1000) {
    display.setTextSize(2);
    display.setCursor(68, 44);
    display.print(distanceMeters);
    display.println("m");
  } else {
    display.setTextSize(2);
    display.setCursor(68, 44);
    display.print(distanceMeters / 1000.0, 1);
    display.println("k");
  }
}

void drawTopStatus() {
  display.setTextSize(1);
  display.setCursor(0, 0);

  if (!bleConnected) {
    display.print("ADV");
  } else if (isLiveFresh()) {
    display.print("LIVE");
  } else {
    display.print("WAIT");
  }

}

void drawBottomError() {
  if (lastError[0] == '\0') return;

  display.setTextSize(1);
  display.setCursor(0, 54);
  display.print(lastError);
}

void drawStandby() {
  display.setTextSize(1);
  display.setCursor(34, 18);
  display.println("ESP32_NAV");

  display.setCursor(30, 34);
  display.println("BLE READY");
}

void drawWaitingForNavigation() {
  display.setTextSize(1);
  display.setCursor(34, 18);
  display.println("ESP32_NAV");

  display.setCursor(18, 34);
  display.println("WAITING NAV");
}

void renderDisplay(bool blinkState) {
  if (!displayAvailable) return;
  if (displayPowerState == DisplayPowerState::Off) return;

  display.clearDisplay();
  display.setTextColor(OLED_WHITE);

  if (isStandby()) {
    drawStandby();
    display.display();
    return;
  }

  if (isWaitingForNavigation()) {
    drawWaitingForNavigation();
    display.display();
    return;
  }

  drawTopStatus();
  drawMiniRouteMap();
  drawDirection(nav.direction);
  drawDistance(nav.distanceMeters, blinkState);

  drawBottomError();
  display.display();
}

// ======================================================
// State updates
// ======================================================

void updateDemoMode() {
  if (!ENABLE_DEMO_MODE || isLiveFresh()) return;

  static uint32_t lastDemoUpdateMs = 0;
  if (millis() - lastDemoUpdateMs < DEMO_STEP_INTERVAL_MS) return;
  lastDemoUpdateMs = millis();

  nav.distanceMeters -= DEMO_DISTANCE_DELTA_M;
  if (nav.distanceMeters > 0) return;

  demoStepIndex++;
  if (demoStepIndex >= sizeof(demoRoute) / sizeof(demoRoute[0])) {
    demoStepIndex = 0;
  }
  nav.direction = demoRoute[demoStepIndex].direction;
  nav.distanceMeters = demoRoute[demoStepIndex].distanceMeters;
}

void updateLiveTimeout() {
  if (lastLivePacketMs == 0) return;
  if (isLiveFresh()) return;

  // Do not clear the last direction just because the phone did not send a new
  // packet for a few seconds. The app intentionally throttles BLE writes when
  // the rider is not moving much. Only an explicit STOP packet should replace
  // the current navigation instruction.
  setLastError("");
}

void updateDisplayPower() {
  if (shouldKeepDisplayAwake()) {
    wakeDisplay();
    return;
  }

  const uint32_t idleMs = millis() - lastDisplayActivityMs;
  if (idleMs >= DISPLAY_OFF_AFTER_IDLE_MS) {
    setDisplayPower(DisplayPowerState::Off);
  } else if (idleMs >= DISPLAY_DIM_AFTER_IDLE_MS) {
    setDisplayPower(DisplayPowerState::Dim);
  } else {
    setDisplayPower(DisplayPowerState::On);
  }
}

bool initDisplay() {
  Serial.println("[I2C] scanning bus...");
  uint8_t foundCount = 0;
  for (uint8_t address = 1; address < 127; address++) {
    Wire.beginTransmission(address);
    const uint8_t error = Wire.endTransmission();
    if (error == 0) {
      foundCount++;
      Serial.print("[I2C] found device at 0x");
      if (address < 16) Serial.print("0");
      Serial.println(address, HEX);
    }
  }

  if (foundCount == 0) {
    Serial.println("[I2C] no devices found; check VCC/GND/SDA/SCL wiring");
    return false;
  }

  if (display.begin(OLED_I2C_ADDRESS_PRIMARY, true)) {
    Serial.println("[OLED] SH1106 display found at 0x3C");
    return true;
  }

  if (display.begin(OLED_I2C_ADDRESS_FALLBACK, true)) {
    Serial.println("[OLED] SH1106 display found at 0x3D");
    return true;
  }

  return false;
}

// ======================================================
// Arduino lifecycle
// ======================================================

void setup() {
  Serial.begin(115200);
  delay(100);
  Serial.println();
  Serial.println("[BOOT] ESP32 navigation display");

  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  Wire.setClock(100000);

  displayAvailable = initDisplay();
  if (!displayAvailable) {
    Serial.println("[OLED] init failed");
    Serial.println("[OLED] continuing without display so BLE still works");
  } else {
    display.clearDisplay();
    display.setTextColor(OLED_WHITE);
    display.setTextSize(1);
    display.setCursor(0, 0);
    display.println("Moto Nav Display");
    display.println("Starting BLE...");
    display.display();
  }
  wakeDisplay();

  if (ENABLE_DEMO_MODE) {
    nav.direction = demoRoute[0].direction;
    nav.distanceMeters = demoRoute[0].distanceMeters;
  }

  setupBle();
  Serial.println("[BOOT] Ready");
}

void loop() {
  static bool blinkState = true;
  static uint32_t lastBlinkMs = 0;
  static uint32_t lastRenderMs = 0;

  if (millis() - lastBlinkMs > 300) {
    blinkState = !blinkState;
    lastBlinkMs = millis();
  }

  updateLiveTimeout();
  updateDemoMode();
  updateDisplayPower();

  if (millis() - lastRenderMs >= DISPLAY_REFRESH_MS) {
    lastRenderMs = millis();
    renderDisplay(blinkState);
  }

  delay(30);
}
