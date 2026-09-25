#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#include <ArduinoJson.h>

// ======================================================
// Hardware
// ======================================================

constexpr int16_t SCREEN_WIDTH = 240;
constexpr int16_t SCREEN_HEIGHT = 135;

// The phone still sends route-preview points in the old 128x64 coordinate
// system, so keep that contract and scale those points into the large TFT map.
constexpr int16_t ROUTE_SOURCE_WIDTH = 128;
constexpr int16_t ROUTE_SOURCE_HEIGHT = 64;

// ideaspark / ESP32 built-in 1.14-inch ST7789 configuration. If your board is
// mirrored or upside-down, change TFT_ROTATION to 3.
constexpr int8_t TFT_MOSI_PIN = 23;
constexpr int8_t TFT_SCLK_PIN = 18;
constexpr int8_t TFT_CS_PIN = 15;
constexpr int8_t TFT_DC_PIN = 2;
constexpr int8_t TFT_RESET_PIN = 4;
constexpr int8_t TFT_BACKLIGHT_PIN = 32;
constexpr uint8_t TFT_ROTATION = 1;
constexpr uint8_t BACKLIGHT_NORMAL = 255;
constexpr uint8_t BACKLIGHT_DIM = 24;

Adafruit_ST7789 tft(TFT_CS_PIN, TFT_DC_PIN, TFT_RESET_PIN);
GFXcanvas16 display(SCREEN_WIDTH, SCREEN_HEIGHT);

constexpr uint16_t COLOR_BG = ST77XX_BLACK;
constexpr uint16_t COLOR_WHITE = ST77XX_WHITE;
constexpr uint16_t COLOR_ROUTE = ST77XX_WHITE;
// All foreground indications are white; only the background is black.
constexpr uint16_t COLOR_ACCENT = COLOR_WHITE;
constexpr uint16_t COLOR_MUTED = COLOR_WHITE;
bool displayAvailable = false;
volatile bool displayDirty = true;

// ======================================================
// Product behavior
// ======================================================

// Keep this false for real riding. Set true only when bench-testing the TFT
// without a phone connected.
constexpr bool ENABLE_DEMO_MODE = false;

constexpr uint32_t DEMO_STEP_INTERVAL_MS = 1000;
constexpr int DEMO_DISTANCE_DELTA_M = 10;

// If the phone stops sending navigation packets, stop showing a stale turn.
constexpr uint32_t LIVE_PACKET_TIMEOUT_MS = 8000;

// TFT power policy. BLE keeps running while the display is dim/off.
constexpr uint32_t DISPLAY_DIM_AFTER_IDLE_MS = 15000;
constexpr uint32_t DISPLAY_OFF_AFTER_IDLE_MS = 60000;
constexpr uint32_t DISPLAY_REFRESH_MS = 120;

constexpr int MAX_DISTANCE_M = 9999;
constexpr uint8_t MAX_ROUTE_PREVIEW_POINTS = 6;
// Two junction arms match the reference cluster view and keep the compact JSON
// safely below conservative iOS BLE write-without-response payload sizes.
constexpr uint8_t MAX_SIDE_ROAD_SEGMENTS = 2;

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

struct ScreenSegment {
  ScreenPoint start;
  ScreenPoint end;
};

ScreenPoint routePreviewPoints[MAX_ROUTE_PREVIEW_POINTS];
uint8_t routePreviewPointCount = 0;
ScreenSegment sideRoadSegments[MAX_SIDE_ROAD_SEGMENTS];
uint8_t sideRoadSegmentCount = 0;

uint32_t lastLivePacketMs = 0;
bool hasReceivedNavPacket = false;
bool livePacketTimedOut = false;
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
void presentDisplay();
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
  if (strncmp(lastError, message, sizeof(lastError)) == 0) return;
  strlcpy(lastError, message, sizeof(lastError));
  displayDirty = true;
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
  displayDirty = true;

  switch (state) {
    case DisplayPowerState::On:
      analogWrite(TFT_BACKLIGHT_PIN, BACKLIGHT_NORMAL);
      break;
    case DisplayPowerState::Dim:
      analogWrite(TFT_BACKLIGHT_PIN, BACKLIGHT_DIM);
      break;
    case DisplayPowerState::Off:
      analogWrite(TFT_BACKLIGHT_PIN, 0);
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
    displayDirty = true;
    wakeDisplay();
    setLastError("");
    Serial.println("[BLE] Central connected");
  }

  void onDisconnect(BLEServer* server) override {
    bleConnected = false;
    hasReceivedNavPacket = false;
    lastLivePacketMs = 0;
    livePacketTimedOut = false;
    routePreviewPointCount = 0;
    sideRoadSegmentCount = 0;
    nav = {Direction::Stop, 0};
    displayDirty = true;
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
    const auto rawValue = characteristic->getValue();
    String value(rawValue.c_str());
    value.trim();

    if (value.length() == 0) {
      rejectedPacketCount++;
      setLastError("empty packet");
      return;
    }

    if (value.length() > 360) {
      rejectedPacketCount++;
      setLastError("packet too large");
      Serial.println("[BLE] Rejected oversized packet");
      return;
    }

    StaticJsonDocument<768> doc;
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
    sideRoadSegmentCount = 0;
    JsonArray points = doc["p"].as<JsonArray>();
    if (!points.isNull()) {
      const size_t maxValues = MAX_ROUTE_PREVIEW_POINTS * 2;
      const size_t valueCount =
          points.size() > maxValues ? maxValues : points.size();
      for (size_t i = 0; i + 1 < valueCount; i += 2) {
        if (!points[i].is<int>() || !points[i + 1].is<int>()) break;
        routePreviewPoints[routePreviewPointCount] = {
            static_cast<int16_t>(
                constrain(points[i].as<int>(), 0, ROUTE_SOURCE_WIDTH - 1)),
            static_cast<int16_t>(
                constrain(points[i + 1].as<int>(), 0, ROUTE_SOURCE_HEIGHT - 1)),
        };
        routePreviewPointCount++;
      }
    }

    JsonArray roads = doc["r"].as<JsonArray>();
    if (!roads.isNull()) {
      const size_t maxValues = MAX_SIDE_ROAD_SEGMENTS * 4;
      const size_t valueCount =
          roads.size() > maxValues ? maxValues : roads.size();
      for (size_t i = 0; i + 3 < valueCount; i += 4) {
        if (!roads[i].is<int>() || !roads[i + 1].is<int>() ||
            !roads[i + 2].is<int>() || !roads[i + 3].is<int>()) {
          break;
        }
        sideRoadSegments[sideRoadSegmentCount] = {
            {static_cast<int16_t>(
                 constrain(roads[i].as<int>(), 0, ROUTE_SOURCE_WIDTH - 1)),
             static_cast<int16_t>(
                 constrain(roads[i + 1].as<int>(), 0, ROUTE_SOURCE_HEIGHT - 1))},
            {static_cast<int16_t>(
                 constrain(roads[i + 2].as<int>(), 0, ROUTE_SOURCE_WIDTH - 1)),
             static_cast<int16_t>(
                 constrain(roads[i + 3].as<int>(), 0, ROUTE_SOURCE_HEIGHT - 1))},
        };
        sideRoadSegmentCount++;
      }
    }

    lastLivePacketMs = millis();
    livePacketTimedOut = false;
    hasReceivedNavPacket = true;
    displayDirty = true;
    wakeDisplay();
    setLastError("");

    Serial.print("[NAV] ");
    Serial.print(directionName(nav.direction));
    Serial.print(" ");
    Serial.print(nav.distanceMeters);
    Serial.print("m route=");
    Serial.print(routePreviewPointCount);
    Serial.print(" roads=");
    Serial.println(sideRoadSegmentCount);
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

// Borderless map above a compact instruction strip, with no separator line.
constexpr int16_t MAP_LEFT = 0;
constexpr int16_t MAP_TOP = 0;
constexpr int16_t MAP_RIGHT = SCREEN_WIDTH - 1;
constexpr int16_t MAP_BOTTOM = 94;
constexpr int16_t ARROW_CENTER_X = 66;
constexpr int16_t DISTANCE_X = 132;

int16_t scaleValue(int16_t value, int16_t inMin, int16_t inMax, int16_t outMin,
                   int16_t outMax) {
  if (inMax == inMin) return outMin;
  return outMin + static_cast<int32_t>(value - inMin) * (outMax - outMin) /
                      (inMax - inMin);
}

int16_t mapPreviewX(int16_t x) {
  return scaleValue(x, 18, 110, MAP_LEFT + 6, MAP_RIGHT - 6);
}

int16_t mapPreviewY(int16_t y) {
  return scaleValue(y, 2, 34, MAP_TOP + 4, MAP_BOTTOM - 12);
}

void presentDisplay() {
  tft.drawRGBBitmap(0, 0, display.getBuffer(), SCREEN_WIDTH, SCREEN_HEIGHT);
}

void drawThickLine(int16_t x0, int16_t y0, int16_t x1, int16_t y1,
                   uint16_t color = COLOR_WHITE, uint8_t thickness = 3) {
  const int16_t radius = thickness / 2;
  for (int16_t dx = -radius; dx <= radius; dx++) {
    for (int16_t dy = -radius; dy <= radius; dy++) {
      display.drawLine(x0 + dx, y0 + dy, x1 + dx, y1 + dy, color);
    }
  }
}

void drawSideRoadLine(int16_t x0, int16_t y0, int16_t x1, int16_t y1) {
  // An unselected branch is drawn as two separated, broken edge-rays. The
  // black centre and small gaps distinguish it from the solid navigation route
  // without relying on different colors.
  constexpr int16_t parts = 4;
  const int16_t dx = x1 - x0;
  const int16_t dy = y1 - y0;
  const int16_t magnitude = max(abs(dx), abs(dy));
  if (magnitude == 0) return;

  // Three pixels to either side leaves a visible six-pixel black channel.
  constexpr int16_t railOffset = 3;
  const int16_t normalX = static_cast<int32_t>(-dy) * railOffset / magnitude;
  const int16_t normalY = static_cast<int32_t>(dx) * railOffset / magnitude;

  // Leave a short break at the route intersection, then draw each quarter at
  // 70% duty so even TFT bloom cannot merge the rays into solid white roads.
  const int16_t rawStartInset = 3 * 256 / magnitude;
  const int16_t startInset = rawStartInset < 48 ? rawStartInset : 48;
  const int16_t usable = 256 - startInset;

  for (int16_t rail = -1; rail <= 1; rail += 2) {
    for (int16_t part = 0; part < parts; part++) {
      const int16_t partStart = startInset + usable * part / parts;
      const int16_t partEnd =
          startInset + usable * (part * 10 + 7) / (parts * 10);
      const int16_t ax = x0 + static_cast<int32_t>(dx) * partStart / 256;
      const int16_t ay = y0 + static_cast<int32_t>(dy) * partStart / 256;
      const int16_t bx = x0 + static_cast<int32_t>(dx) * partEnd / 256;
      const int16_t by = y0 + static_cast<int32_t>(dy) * partEnd / 256;
      display.drawLine(ax + normalX * rail, ay + normalY * rail,
                       bx + normalX * rail, by + normalY * rail,
                       COLOR_WHITE);
    }
  }
}

void drawSideRoadSegments() {
  for (uint8_t i = 0; i < sideRoadSegmentCount; i++) {
    drawSideRoadLine(mapPreviewX(sideRoadSegments[i].start.x),
                     mapPreviewY(sideRoadSegments[i].start.y),
                     mapPreviewX(sideRoadSegments[i].end.x),
                     mapPreviewY(sideRoadSegments[i].end.y));
  }
}

void drawArrowUp() {
  drawThickLine(ARROW_CENTER_X, 128, ARROW_CENTER_X, 98);
  drawThickLine(ARROW_CENTER_X, 98, ARROW_CENTER_X - 15, 113);
  drawThickLine(ARROW_CENTER_X, 98, ARROW_CENTER_X + 15, 113);
}

void drawArrowLeft() {
  drawThickLine(82, 128, 82, 116);
  drawThickLine(82, 116, 74, 106);
  drawThickLine(74, 106, 42, 106);
  drawThickLine(42, 106, 60, 93);
  drawThickLine(42, 106, 60, 119);
}

void drawArrowRight() {
  drawThickLine(48, 128, 48, 116);
  drawThickLine(48, 116, 56, 106);
  drawThickLine(56, 106, 88, 106);
  drawThickLine(88, 106, 70, 93);
  drawThickLine(88, 106, 70, 119);
}

void drawBearLeft() {
  drawThickLine(ARROW_CENTER_X, 128, ARROW_CENTER_X, 96);
  drawThickLine(ARROW_CENTER_X, 96, ARROW_CENTER_X - 14, 110);
  drawThickLine(ARROW_CENTER_X, 96, ARROW_CENTER_X + 14, 110);
  drawThickLine(ARROW_CENTER_X, 114, 42, 96);
  drawThickLine(42, 96, 50, 96);
  drawThickLine(42, 96, 42, 104);
}

void drawBearRight() {
  drawThickLine(ARROW_CENTER_X, 128, ARROW_CENTER_X, 96);
  drawThickLine(ARROW_CENTER_X, 96, ARROW_CENTER_X - 14, 110);
  drawThickLine(ARROW_CENTER_X, 96, ARROW_CENTER_X + 14, 110);
  drawThickLine(ARROW_CENTER_X, 114, 90, 96);
  drawThickLine(90, 96, 82, 96);
  drawThickLine(90, 96, 90, 104);
}

void drawUTurn() {
  drawThickLine(82, 128, 82, 100);
  drawThickLine(82, 100, 44, 100);
  drawThickLine(44, 100, 44, 120);
  drawThickLine(44, 120, 31, 107);
  drawThickLine(44, 120, 57, 107);
}

void drawStop() {
  display.fillRoundRect(42, 98, 48, 30, 4, COLOR_WHITE);
}

void drawArrived() {
  drawThickLine(34, 114, 56, 130);
  drawThickLine(56, 130, 94, 94);
}

void drawUnknown() {
  display.setTextSize(2);
  display.setCursor(22, 105);
  display.println("?");
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

void drawFallbackMapRoute(Direction direction) {
  const int16_t centerX = (MAP_LEFT + MAP_RIGHT) / 2;
  const int16_t bottom = MAP_BOTTOM - 8;
  const int16_t top = MAP_TOP + 12;
  const int16_t left = MAP_LEFT + 28;
  const int16_t right = MAP_RIGHT - 28;

  switch (direction) {
    case Direction::Left:
      drawThickLine(centerX, bottom, centerX, 55, COLOR_ROUTE, 2);
      drawThickLine(centerX, 55, centerX - 18, 42, COLOR_ROUTE, 2);
      drawThickLine(centerX - 18, 42, left, 42, COLOR_ROUTE, 2);
      break;
    case Direction::Right:
      drawThickLine(centerX, bottom, centerX, 55, COLOR_ROUTE, 2);
      drawThickLine(centerX, 55, centerX + 18, 42, COLOR_ROUTE, 2);
      drawThickLine(centerX + 18, 42, right, 42, COLOR_ROUTE, 2);
      break;
    case Direction::BearLeft:
      drawThickLine(centerX, bottom, centerX, 58, COLOR_ROUTE, 2);
      drawThickLine(centerX, 58, centerX - 44, top, COLOR_ROUTE, 2);
      break;
    case Direction::BearRight:
      drawThickLine(centerX, bottom, centerX, 58, COLOR_ROUTE, 2);
      drawThickLine(centerX, 58, centerX + 44, top, COLOR_ROUTE, 2);
      break;
    case Direction::UTurn:
      drawThickLine(centerX, bottom, centerX, 36, COLOR_ROUTE, 2);
      drawThickLine(centerX, 36, left + 28, 36, COLOR_ROUTE, 2);
      drawThickLine(left + 28, 36, left + 28, 68, COLOR_ROUTE, 2);
      break;
    default:
      drawThickLine(centerX, bottom, centerX, top, COLOR_ROUTE, 2);
      break;
  }
}

void drawMiniRouteMap() {
  drawSideRoadSegments();

  if (routePreviewPointCount >= 2) {
    for (uint8_t i = 0; i + 1 < routePreviewPointCount; i++) {
      drawThickLine(mapPreviewX(routePreviewPoints[i].x),
                    mapPreviewY(routePreviewPoints[i].y),
                    mapPreviewX(routePreviewPoints[i + 1].x),
                    mapPreviewY(routePreviewPoints[i + 1].y), COLOR_ROUTE, 6);
    }
  } else {
    drawFallbackMapRoute(nav.direction);
  }

  const int16_t markerX = (MAP_LEFT + MAP_RIGHT) / 2;
  const int16_t markerY = MAP_BOTTOM - 12;
  // Paint the complete black silhouette last over the route, then inset the
  // white pointer on every side (including the tip and bottom edge).
  display.fillTriangle(markerX, markerY - 15, markerX - 13, markerY + 10,
                       markerX + 13, markerY + 10, COLOR_BG);
  display.fillTriangle(markerX, markerY - 8, markerX - 7, markerY + 4,
                       markerX + 7, markerY + 4, COLOR_WHITE);

  // Legacy preview coordinates can extend below the map. Keep them out of
  // the instruction strip without drawing a visible frame or separator.
  display.fillRect(0, MAP_BOTTOM, SCREEN_WIDTH, SCREEN_HEIGHT - MAP_BOTTOM,
                   COLOR_BG);
}

void drawDistance(int distanceMeters, bool blinkState) {
  display.setTextColor(COLOR_WHITE);
  if (nav.direction == Direction::Arrived) {
    display.setTextSize(3);
    display.setCursor(DISTANCE_X, 104);
    display.println("ARR");
    return;
  }

  if (distanceMeters <= 30) {
    if (blinkState) {
      display.setTextSize(3);
      display.setCursor(DISTANCE_X, 104);
      display.println("NOW");
    }
  } else if (distanceMeters < 1000) {
    display.setTextSize(3);
    display.setCursor(DISTANCE_X, 104);
    display.print(distanceMeters);
    display.println("m");
  } else {
    display.setTextSize(3);
    display.setCursor(DISTANCE_X, 104);
    display.print(distanceMeters / 1000.0, 1);
    display.println("k");
  }
}

void drawTopStatus() {
  display.setTextSize(1);
  display.setTextColor(COLOR_MUTED);
  display.setCursor(8, 8);

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
  display.setTextColor(COLOR_ACCENT);
  display.setCursor(8, SCREEN_HEIGHT - 10);
  display.print(lastError);
}

void drawStandby() {
  display.setTextColor(COLOR_WHITE);
  display.setTextSize(2);
  display.setCursor(54, 38);
  display.println("ESP32_NAV");

  display.setTextSize(1);
  display.setCursor(88, 72);
  display.println("BLE READY");
}

void drawWaitingForNavigation() {
  display.setTextColor(COLOR_WHITE);
  display.setTextSize(2);
  display.setCursor(54, 38);
  display.println("ESP32_NAV");

  display.setTextSize(1);
  display.setCursor(78, 72);
  display.println("WAITING NAV");
}

void renderDisplay(bool blinkState) {
  if (!displayAvailable) return;
  if (displayPowerState == DisplayPowerState::Off) return;

  display.fillScreen(COLOR_BG);
  display.setTextColor(COLOR_WHITE);

  if (isStandby()) {
    drawStandby();
    presentDisplay();
    return;
  }

  if (isWaitingForNavigation()) {
    drawWaitingForNavigation();
    presentDisplay();
    return;
  }

  drawMiniRouteMap();
  drawTopStatus();
  drawDirection(nav.direction);
  drawDistance(nav.distanceMeters, blinkState);

  drawBottomError();
  presentDisplay();
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
  displayDirty = true;
  if (nav.distanceMeters > 0) return;

  demoStepIndex++;
  if (demoStepIndex >= sizeof(demoRoute) / sizeof(demoRoute[0])) {
    demoStepIndex = 0;
  }
  nav.direction = demoRoute[demoStepIndex].direction;
  nav.distanceMeters = demoRoute[demoStepIndex].distanceMeters;
  displayDirty = true;
}

void updateLiveTimeout() {
  if (lastLivePacketMs == 0) return;
  if (isLiveFresh()) return;

  if (!livePacketTimedOut) {
    livePacketTimedOut = true;
    displayDirty = true;
  }

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
  Serial.println("[TFT] init ST7789...");
  pinMode(TFT_BACKLIGHT_PIN, OUTPUT);
  analogWrite(TFT_BACKLIGHT_PIN, BACKLIGHT_NORMAL);

  SPI.begin(TFT_SCLK_PIN, -1, TFT_MOSI_PIN, TFT_CS_PIN);
  tft.init(SCREEN_HEIGHT, SCREEN_WIDTH);
  tft.setRotation(TFT_ROTATION);
  tft.fillScreen(COLOR_BG);
  Serial.println("[TFT] ST7789 ready");
  return true;
}

// ======================================================
// Arduino lifecycle
// ======================================================

void setup() {
  Serial.begin(115200);
  delay(100);
  Serial.println();
  Serial.println("[BOOT] ESP32 navigation display");

  displayAvailable = initDisplay();
  if (!displayAvailable) {
    Serial.println("[TFT] init failed");
    Serial.println("[TFT] continuing without display so BLE still works");
  } else {
    display.fillScreen(COLOR_BG);
    display.setTextColor(COLOR_WHITE);
    display.setTextSize(2);
    display.setCursor(22, 40);
    display.println("Moto Nav Display");
    display.setTextSize(1);
    display.setCursor(72, 76);
    display.println("Starting BLE...");
    presentDisplay();
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
    if (nav.distanceMeters <= 30) displayDirty = true;
  }

  updateLiveTimeout();
  updateDemoMode();
  updateDisplayPower();

  if (displayDirty && millis() - lastRenderMs >= DISPLAY_REFRESH_MS) {
    lastRenderMs = millis();
    // Clear before drawing so a BLE callback arriving during the SPI transfer
    // schedules another frame instead of having its update erased here.
    displayDirty = false;
    renderDisplay(blinkState);
  }

  delay(30);
}
