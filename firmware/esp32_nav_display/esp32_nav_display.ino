#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#include <ArduinoJson.h>
#include <time.h>
#include <sys/time.h>
#include <stdint.h>
#include <math.h>
#include <esp_system.h>

// BEGIN MAP MOTION - kept inline so this sketch can be copied on its own.
// Display-only interpolation. Never used for maneuver or distance decisions.
struct MapMotion {
  static constexpr uint32_t durationMs = 180;
  float current[20] = {};
  float start[20] = {};
  float target[20] = {};
  uint8_t routes = 0, roads = 0, direction = 0;
  uint32_t started = 0;
  bool valid = false, active = false;

  bool tick(uint32_t now) {
    if (!active) return false;
    const uint32_t elapsed = now - started;
    const float t = elapsed >= durationMs ? 1.0f : float(elapsed) / durationMs;
    const float eased = t * t * (3.0f - 2.0f * t);
    for (int i = 0; i < 20; ++i)
      current[i] = start[i] + (target[i] - start[i]) * eased;
    active = elapsed < durationMs;
    return true;
  }

  void accept(const float* points, uint8_t routeCount, uint8_t roadCount,
              uint8_t newDirection, uint32_t now) {
    tick(now);
    bool snap = !valid || routes != routeCount || roads != roadCount ||
                direction != newDirection;
    bool changed = snap;
    for (int i = 0; i < 20; ++i) {
      changed = changed || points[i] != target[i];
      // Large geometry jumps are route changes, not motion to animate.
      snap = snap || fabsf(points[i] - current[i]) > 24.0f;
    }
    if (!changed) return;
    routes = routeCount;
    roads = roadCount;
    direction = newDirection;
    for (int i = 0; i < 20; ++i) {
      start[i] = snap ? points[i] : current[i];
      target[i] = points[i];
      if (snap) current[i] = points[i];
    }
    started = now;
    valid = true;
    active = !snap;
  }
};
// END MAP MOTION

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
// Primary indications are white; side-road edges fade through grayscale.
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
constexpr uint32_t DISPLAY_REFRESH_MS = 33;

constexpr int MAX_DISTANCE_M = 9999;
constexpr uint8_t MAX_ROUTE_PREVIEW_POINTS = 6;
// Two junction arms match the reference cluster view and keep the compact JSON
// safely below conservative iOS BLE write-without-response payload sizes.
constexpr uint8_t MAX_SIDE_ROAD_SEGMENTS = 2;

// ======================================================
// BLE contract - must match the Flutter app.
// ======================================================

char DEVICE_NAME[20] = "NAV";
char deviceIdentity[13] = "";
char pairingCode[7] = "";
bool pairingActive = false;
bool pairingVerified = false;
uint32_t pairingStartedMs = 0;
constexpr char PAIRING_UUID[] = "abcd1234-5678-1234-5678-abcdef123457";
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
bool rerouting = false;
bool clockSynced = false;

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

// BLE publishes a complete geometry snapshot; only loop() owns animation.
portMUX_TYPE mapMux = portMUX_INITIALIZER_UNLOCKED;
float pendingMap[20] = {};
uint8_t pendingRoutes = 0, pendingRoads = 0, pendingDirection = 0;
bool pendingMapReady = false;
MapMotion mapMotion;

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
    pairingActive = false;
    pairingVerified = false;
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

    // Phone-local wall time, separate from navigation: never starts guidance
    // or refreshes the live-navigation packet timeout.
    if (doc["clock"].is<uint32_t>()) {
      const uint32_t seconds = doc["clock"].as<uint32_t>();
      if (seconds < 1700000000UL) {
        setLastError("bad clock");
        return;
      }
      timeval now = {static_cast<time_t>(seconds), 0};
      settimeofday(&now, nullptr);
      clockSynced = true;
      displayDirty = true;
      wakeDisplay();
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
    rerouting = doc["rerouting"] | false;
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

    portENTER_CRITICAL(&mapMux);
    memset(pendingMap, 0, sizeof(pendingMap));
    for (uint8_t i = 0; i < routePreviewPointCount; ++i) {
      pendingMap[i * 2] = routePreviewPoints[i].x;
      pendingMap[i * 2 + 1] = routePreviewPoints[i].y;
    }
    for (uint8_t i = 0; i < sideRoadSegmentCount; ++i) {
      pendingMap[12 + i * 4] = sideRoadSegments[i].start.x;
      pendingMap[13 + i * 4] = sideRoadSegments[i].start.y;
      pendingMap[14 + i * 4] = sideRoadSegments[i].end.x;
      pendingMap[15 + i * 4] = sideRoadSegments[i].end.y;
    }
    pendingRoutes = routePreviewPointCount;
    pendingRoads = sideRoadSegmentCount;
    pendingDirection = static_cast<uint8_t>(direction);
    pendingMapReady = true;
    portEXIT_CRITICAL(&mapMux);

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

// Physical-screen confirmation prevents accidental selection, not spoofing.
// This is deliberately separate from the navigation write characteristic.
class PairingCallbacks : public BLECharacteristicCallbacks {
  void onRead(BLECharacteristic* characteristic) override {
    char response[80];
    snprintf(response, sizeof(response), "{\"id\":\"%s\",\"verified\":%s}",
             deviceIdentity, pairingVerified ? "true" : "false");
    characteristic->setValue(response);
  }
  void onWrite(BLECharacteristic* characteristic) override {
    const auto value = characteristic->getValue();
    StaticJsonDocument<128> doc;
    if (value.length() > 80 || deserializeJson(doc, value.c_str())) return;
    const char* action = doc["pair"] | "";
    if (strcmp(action, "start") == 0) {
      snprintf(pairingCode, sizeof(pairingCode), "%06lu",
               static_cast<unsigned long>(esp_random() % 1000000));
      pairingStartedMs = millis();
      pairingActive = true;
      pairingVerified = false;
      wakeDisplay();
      displayDirty = true;
      return;
    }
    const char* code = doc["code"] | "";
    pairingVerified = pairingActive && millis() - pairingStartedMs < 60000 &&
                      strlen(code) == 6 && strcmp(code, pairingCode) == 0;
    pairingActive = false; // One attempt per generated code.
    displayDirty = true;
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
  BLECharacteristic* pairing = service->createCharacteristic(
      PAIRING_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE);
  pairing->setCallbacks(new PairingCallbacks());

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
// Zoom geometry around the rider, without enlarging the instruction strip.
constexpr float MAP_ZOOM = 1.50f;
constexpr int16_t MAP_CLIP_BOTTOM = MAP_BOTTOM - 4;
constexpr int16_t ARROW_CENTER_X = 66;
constexpr int16_t DISTANCE_X = 132;

int16_t scaleValue(int16_t value, int16_t inMin, int16_t inMax, int16_t outMin,
                   int16_t outMax) {
  if (inMax == inMin) return outMin;
  return outMin + static_cast<int32_t>(value - inMin) * (outMax - outMin) /
                      (inMax - inMin);
}

int16_t mapPreviewX(float x) {
  const float center = (MAP_LEFT + MAP_RIGHT) / 2.0f;
  const float projected = MAP_LEFT + 6 + (x - 18) * (MAP_RIGHT - MAP_LEFT - 12) / 92.0f;
  return lroundf(center + (projected - center) * MAP_ZOOM);
}

int16_t mapPreviewY(float y) {
  const float anchor = MAP_BOTTOM - 12;
  const float projected = MAP_TOP + 4 + (y - 2) * (MAP_BOTTOM - MAP_TOP - 16) / 32.0f;
  return lroundf(anchor + (projected - anchor) * MAP_ZOOM);
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
  // The phone orders each branch from its route junction towards its outer
  // endpoint. Continuous hollow rails fade outwards, beneath the white route.
  const float dx = x1 - x0;
  const float dy = y1 - y0;
  const float length = sqrtf(dx * dx + dy * dy);
  if (length < 1.0f) return;
  const float ux = dx / length;
  const float uy = dy / length;
  // These are schematic junction arms, not measured road endpoints. Extend
  // only their visual rays; leave the junction and branch direction unchanged.
  const float visibleLength = fmaxf(42.0f, fminf(length * 1.5f, length + 24.0f));
  x1 = lroundf(x0 + ux * visibleLength);
  y1 = lroundf(y0 + uy * visibleLength);
  constexpr float railOffset = 3.0f;
  constexpr float softWidth = 1.9f;
  // Clip before rasterizing: off-screen geometry never expands frame cost.
  const int16_t left = max(0, min(x0, x1) - 5);
  const int16_t right = min(int(SCREEN_WIDTH - 1), max(x0, x1) + 5);
  const int16_t top = max(0, min(y0, y1) - 5);
  const int16_t bottom = min(int(MAP_CLIP_BOTTOM - 1), max(y0, y1) + 5);
  uint16_t* pixels = display.getBuffer();
  for (int16_t y = top; y <= bottom; ++y) {
    for (int16_t x = left; x <= right; ++x) {
      const float px = x - x0;
      const float py = y - y0;
      const float along = px * ux + py * uy;
      if (along < 0.0f || along >= visibleLength) continue;
      const float edgeDistance = fabsf(fabsf(px * uy - py * ux) - railOffset);
      if (edgeDistance >= softWidth) continue;
      // Keep the first 45% bright; reserve the fade for the outer end.
      const float t = fmaxf(0.0f, (along / visibleLength - 0.45f) / 0.55f);
      const float fade = 1.0f - t * t * (3.0f - 2.0f * t);
      const uint8_t gray = lroundf(245.0f * fade * (1.0f - edgeDistance / softWidth));
      const uint16_t color = ((gray >> 3) << 11) | ((gray >> 2) << 5) | (gray >> 3);
      uint16_t& pixel = pixels[y * SCREEN_WIDTH + x];
      // Overlapping branches must not erase a brighter edge already drawn.
      if (color > pixel) pixel = color;
    }
  }
}

void drawSideRoadSegments() {
  for (uint8_t i = 0; i < mapMotion.roads; i++) {
    const float* p = mapMotion.current + 12 + i * 4;
    drawSideRoadLine(mapPreviewX(p[0]), mapPreviewY(p[1]),
                     mapPreviewX(p[2]), mapPreviewY(p[3]));
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
  drawThickLine(66, 128, 66, 118, COLOR_WHITE, 4);
  drawThickLine(66, 118, 62, 112, COLOR_WHITE, 4);
  drawThickLine(62, 112, 50, 100, COLOR_WHITE, 4);
  display.fillTriangle(43, 96, 61, 99, 46, 114, COLOR_WHITE);
}

void drawBearRight() {
  drawThickLine(66, 128, 66, 118, COLOR_WHITE, 4);
  drawThickLine(66, 118, 70, 112, COLOR_WHITE, 4);
  drawThickLine(70, 112, 82, 100, COLOR_WHITE, 4);
  display.fillTriangle(89, 96, 71, 99, 86, 114, COLOR_WHITE);
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

  if (mapMotion.routes >= 2) {
    for (uint8_t i = 0; i + 1 < mapMotion.routes; i++) {
      const float* p = mapMotion.current + i * 2;
      drawThickLine(mapPreviewX(p[0]), mapPreviewY(p[1]),
                    mapPreviewX(p[2]), mapPreviewY(p[3]), COLOR_ROUTE, 6);
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
  display.fillRect(0, MAP_CLIP_BOTTOM, SCREEN_WIDTH, SCREEN_HEIGHT - MAP_CLIP_BOTTOM,
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

void drawBottomError() {
  if (lastError[0] == '\0') return;

  display.setTextSize(1);
  display.setTextColor(COLOR_ACCENT);
  display.setCursor(8, SCREEN_HEIGHT - 10);
  display.print(lastError);
}

void drawStandbyClock() {
  display.setTextColor(COLOR_WHITE);
  if (clockSynced) {
    char text[6];
    const time_t now = time(nullptr);
    struct tm localClock;
    // The phone has already applied its local UTC offset.
    gmtime_r(&now, &localClock);
    snprintf(text, sizeof(text), "%02d:%02d", localClock.tm_hour,
             localClock.tm_min);
    display.setTextSize(7);
    display.setCursor(15, 30);
    display.print(text);
  } else {
    // No clock source until the phone syncs: show a calm standby title,
    // never a placeholder time. A synced clock keeps running after disconnect.
    display.setTextSize(3);
    display.setCursor(48, 39);
    display.print("MOTO NAV");
    if (!bleConnected) {
      display.setTextSize(1);
      display.setCursor(81, 91);
      display.print("CONNECT PHONE");
    }
  }
  if (bleConnected) {
    display.setTextSize(2);
    display.setCursor(54, 99);
    display.print("ready to go");
  }
}

void drawStandby() {
  drawStandbyClock();
}

void drawWaitingForNavigation() {
  drawStandbyClock();
}

void renderDisplay(bool blinkState) {
  if (!displayAvailable) return;
  if (displayPowerState == DisplayPowerState::Off) return;

  display.fillScreen(COLOR_BG);
  display.setTextColor(COLOR_WHITE);

  if (pairingActive) {
    display.setTextSize(1);
    display.setCursor(12, 12);
    display.print(DEVICE_NAME);
    display.setTextSize(4);
    display.setCursor(48, 48);
    display.print(pairingCode);
    display.setTextSize(1);
    display.setCursor(30, 108);
    display.print("ENTER CODE ON PHONE");
    presentDisplay();
    return;
  }

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

  if (rerouting || nav.direction == Direction::Stop) {
    // STOP/0 is also used by older apps while recalculating. It is not a
    // turn at zero metres: never render a fallback road, stop block or NOW.
    display.setTextSize(1);
    display.setCursor(84, 62);
    display.print(rerouting ? "UPDATING..." : "NO GUIDANCE");
    presentDisplay();
    return;
  }

  drawMiniRouteMap();
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
  const uint64_t chipId = ESP.getEfuseMac();
  snprintf(deviceIdentity, sizeof(deviceIdentity), "%04X%08lX",
           static_cast<unsigned int>((chipId >> 32) & 0xffff),
           static_cast<unsigned long>(chipId & 0xffffffff));
  snprintf(DEVICE_NAME, sizeof(DEVICE_NAME), "NAV-%s", deviceIdentity);
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
    drawStandbyClock();
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
  if (pairingActive && millis() - pairingStartedMs >= 60000) {
    pairingActive = false;
    displayDirty = true;
  }
  float nextMap[20];
  uint8_t routes, roads, direction;
  portENTER_CRITICAL(&mapMux);
  const bool hasMap = pendingMapReady;
  if (hasMap) {
    memcpy(nextMap, pendingMap, sizeof(nextMap));
    routes = pendingRoutes;
    roads = pendingRoads;
    direction = pendingDirection;
    pendingMapReady = false;
  }
  portEXIT_CRITICAL(&mapMux);
  if (isStandby() || isWaitingForNavigation() || rerouting ||
      nav.direction == Direction::Stop) {
    mapMotion.valid = false;
    mapMotion.active = false;
  }
  if (hasMap) {
    mapMotion.accept(nextMap, routes, roads, direction, millis());
    displayDirty = true;
  }
  if (mapMotion.tick(millis())) displayDirty = true;
  static time_t lastClockMinute = -1;
  const time_t clockMinute = time(nullptr) / 60;
  if (clockMinute != lastClockMinute) {
    lastClockMinute = clockMinute;
    if (isStandby() || isWaitingForNavigation()) displayDirty = true;
  }
  static bool blinkState = true;
  static uint32_t lastBlinkMs = 0;
  static uint32_t lastRenderMs = 0;

  if (millis() - lastBlinkMs > 300) {
    blinkState = !blinkState;
    lastBlinkMs = millis();
    if (!rerouting && nav.direction != Direction::Stop &&
        nav.direction != Direction::Arrived && nav.distanceMeters <= 30) {
      displayDirty = true;
    }
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

  delay(5);
}
