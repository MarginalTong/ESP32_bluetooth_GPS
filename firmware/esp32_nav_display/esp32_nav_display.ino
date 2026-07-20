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
constexpr uint8_t I2C_SDA_PIN = 21;
constexpr uint8_t I2C_SCL_PIN = 22;
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
char lastError[32] = "";

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
      setLastError("bad dir");
      Serial.print("[BLE] Unknown dir: ");
      Serial.println(dirText);
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

int16_t drawOffsetX = 0;
int16_t drawOffsetY = 0;

void drawThickLine(int16_t x0, int16_t y0, int16_t x1, int16_t y1) {
  x0 += drawOffsetX;
  y0 += drawOffsetY;
  x1 += drawOffsetX;
  y1 += drawOffsetY;

  display.drawLine(x0, y0, x1, y1, OLED_WHITE);
  display.drawLine(x0 - 1, y0, x1 - 1, y1, OLED_WHITE);
  display.drawLine(x0 + 1, y0, x1 + 1, y1, OLED_WHITE);
  display.drawLine(x0, y0 - 1, x1, y1 - 1, OLED_WHITE);
  display.drawLine(x0, y0 + 1, x1, y1 + 1, OLED_WHITE);
}

void drawArrowUp() {
  drawThickLine(64, 52, 64, 18);
  drawThickLine(64, 18, 54, 28);
  drawThickLine(64, 18, 74, 28);
}

void drawArrowLeft() {
  // Turn-left instruction: ride forward, then bend left.
  drawThickLine(72, 52, 72, 40);
  drawThickLine(72, 40, 66, 32);
  drawThickLine(66, 32, 56, 28);
  drawThickLine(56, 28, 36, 28);
  drawThickLine(36, 28, 50, 18);
  drawThickLine(36, 28, 50, 38);
}

void drawArrowRight() {
  // Turn-right instruction: ride forward, then bend right.
  drawThickLine(56, 52, 56, 40);
  drawThickLine(56, 40, 62, 32);
  drawThickLine(62, 32, 72, 28);
  drawThickLine(72, 28, 92, 28);
  drawThickLine(92, 28, 78, 18);
  drawThickLine(92, 28, 78, 38);
}

void drawBearLeft() {
  drawThickLine(64, 50, 64, 12);
  drawThickLine(64, 12, 56, 20);
  drawThickLine(64, 12, 72, 20);
  drawThickLine(64, 30, 42, 18);
  drawThickLine(42, 18, 46, 18);
  drawThickLine(42, 18, 42, 22);
}

void drawBearRight() {
  drawThickLine(64, 50, 64, 12);
  drawThickLine(64, 12, 56, 20);
  drawThickLine(64, 12, 72, 20);
  drawThickLine(64, 30, 86, 18);
  drawThickLine(86, 18, 82, 18);
  drawThickLine(86, 18, 86, 22);
}

void drawUTurn() {
  drawThickLine(64, 52, 64, 24);
  drawThickLine(64, 24, 40, 24);
  drawThickLine(40, 24, 40, 42);
  drawThickLine(40, 42, 30, 32);
  drawThickLine(40, 42, 50, 32);
}

void drawStop() {
  display.fillRect(44 + drawOffsetX, 16 + drawOffsetY, 40, 40, OLED_WHITE);
}

void drawArrived() {
  drawThickLine(30, 36, 52, 54);
  drawThickLine(52, 54, 94, 18);
}

void drawUnknown() {
  display.setTextSize(1);
  display.setCursor(38 + drawOffsetX, 28 + drawOffsetY);
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

void drawDirectionAt(Direction direction, int16_t offsetX, int16_t offsetY) {
  const int16_t previousOffsetX = drawOffsetX;
  const int16_t previousOffsetY = drawOffsetY;
  drawOffsetX = offsetX;
  drawOffsetY = offsetY;
  drawDirection(direction);
  drawOffsetX = previousOffsetX;
  drawOffsetY = previousOffsetY;
}

void drawMiniRouteMap(Direction direction) {
  constexpr int16_t left = 82;
  constexpr int16_t top = 10;
  constexpr int16_t right = 124;
  constexpr int16_t bottom = 52;
  constexpr int16_t centerX = 103;

  display.drawRect(left - 3, top - 3, right - left + 7, bottom - top + 7,
                   OLED_WHITE);

  if (routePreviewPointCount >= 2) {
    for (uint8_t i = 0; i + 1 < routePreviewPointCount; i++) {
      display.drawLine(routePreviewPoints[i].x, routePreviewPoints[i].y,
                       routePreviewPoints[i + 1].x,
                       routePreviewPoints[i + 1].y, OLED_WHITE);
    }
    display.fillTriangle(centerX, bottom - 8, centerX - 4, bottom,
                         centerX + 4, bottom, OLED_WHITE);
    return;
  }

  switch (direction) {
    case Direction::Left:
      display.drawLine(centerX, bottom, centerX, 35, OLED_WHITE);
      display.drawLine(centerX, 35, 95, 28, OLED_WHITE);
      display.drawLine(95, 28, left, 28, OLED_WHITE);
      display.drawLine(centerX, 42, right - 2, 42, OLED_WHITE);
      break;
    case Direction::Right:
      display.drawLine(centerX, bottom, centerX, 35, OLED_WHITE);
      display.drawLine(centerX, 35, 111, 28, OLED_WHITE);
      display.drawLine(111, 28, right, 28, OLED_WHITE);
      display.drawLine(centerX, 42, left + 2, 42, OLED_WHITE);
      break;
    case Direction::BearLeft:
      display.drawLine(centerX, bottom, centerX, 34, OLED_WHITE);
      display.drawLine(centerX, 34, 92, top, OLED_WHITE);
      display.drawLine(centerX, 31, right - 2, 23, OLED_WHITE);
      break;
    case Direction::BearRight:
      display.drawLine(centerX, bottom, centerX, 34, OLED_WHITE);
      display.drawLine(centerX, 34, 114, top, OLED_WHITE);
      display.drawLine(centerX, 31, left + 2, 23, OLED_WHITE);
      break;
    case Direction::UTurn:
      display.drawLine(centerX, bottom, centerX, 24, OLED_WHITE);
      display.drawLine(centerX, 24, 90, 24, OLED_WHITE);
      display.drawLine(90, 24, 90, 43, OLED_WHITE);
      break;
    case Direction::Arrived:
      display.drawLine(88, 35, 99, 46, OLED_WHITE);
      display.drawLine(99, 46, 120, 18, OLED_WHITE);
      break;
    case Direction::Up:
    default:
      display.drawLine(centerX, bottom, centerX, top, OLED_WHITE);
      display.drawLine(centerX, 31, left + 2, 31, OLED_WHITE);
      display.drawLine(centerX, 22, right - 2, 22, OLED_WHITE);
      break;
  }

  display.fillTriangle(centerX, bottom - 8, centerX - 4, bottom,
                       centerX + 4, bottom, OLED_WHITE);
}

void drawDistance(int distanceMeters, bool blinkState) {
  if (nav.direction == Direction::Arrived) {
    display.setTextSize(1);
    display.setCursor(10, 54);
    display.println("ARRIVED");
    return;
  }

  if (distanceMeters <= 30) {
    if (blinkState) {
      display.setTextSize(2);
      display.setCursor(10, 48);
      display.println("NOW");
    }
  } else if (distanceMeters <= 100) {
    display.setTextSize(2);
    display.setCursor(8, 48);
    display.print(distanceMeters);
    display.println("m");
  } else {
    display.setTextSize(1);
    display.setCursor(18, 54);
    display.print(distanceMeters);
    display.println("m");
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
  drawDirectionAt(nav.direction, -34, 0);
  drawMiniRouteMap(nav.direction);
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
  Wire.setClock(400000);

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
