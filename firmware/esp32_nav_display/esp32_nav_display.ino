// 1: Waveshare ESP32-S3-Touch-LCD-1.46; 0: original ideaspark ST7789.
#ifndef NAV_WAVESHARE_146
#define NAV_WAVESHARE_146 1
#endif
#include <SPI.h>
#include <Adafruit_GFX.h>
#if NAV_WAVESHARE_146
#include <Wire.h>
#include <Arduino_GFX_Library.h>
#if !defined(CONFIG_IDF_TARGET_ESP32S3)
#error "Select ESP32S3 Dev Module for the Waveshare 1.46 board"
#endif
#else
#include <Adafruit_ST7789.h>
#endif

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#include <ArduinoJson.h>
#include <Preferences.h>
#include <esp_random.h>
#include <mbedtls/md.h>
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

// Keep the old panel's layout; give the round panel a square map/instruction
// layout instead of letterboxing the 240x135 strip in the middle of the LCD.
constexpr int16_t SCREEN_WIDTH = 240;
#if NAV_WAVESHARE_146
constexpr int16_t SCREEN_HEIGHT = 240;
#else
constexpr int16_t SCREEN_HEIGHT = 135;
#endif

// The phone still sends route-preview points in the old 128x64 coordinate
// system, so keep that contract and scale those points into the large TFT map.
constexpr int16_t ROUTE_SOURCE_WIDTH = 128;
constexpr int16_t ROUTE_SOURCE_HEIGHT = 64;

#if NAV_WAVESHARE_146
constexpr int8_t TFT_DATA0_PIN = 46;
constexpr int8_t TFT_DATA1_PIN = 45;
constexpr int8_t TFT_DATA2_PIN = 42;
constexpr int8_t TFT_DATA3_PIN = 41;
constexpr int8_t TFT_SCLK_PIN = 40;
constexpr int8_t TFT_CS_PIN = 21;
constexpr int8_t TFT_BACKLIGHT_PIN = 5;
constexpr int8_t BOARD_I2C_SDA_PIN = 11;
constexpr int8_t BOARD_I2C_SCL_PIN = 10;
// EXIO2 is bit 1 of TCA9554 at 0x20, NOT ESP32 GPIO2.
constexpr uint8_t LCD_RESET_MASK = 1U << 1;
constexpr uint8_t IO_EXPANDER_ADDRESS = 0x20;
constexpr int16_t PANEL_SIZE = 412;
constexpr int16_t PANEL_VIEW_WIDTH = 380;
constexpr int16_t PANEL_VIEW_HEIGHT = 380;
constexpr int16_t PANEL_VIEW_X = (PANEL_SIZE - PANEL_VIEW_WIDTH) / 2;
constexpr int16_t PANEL_VIEW_Y = (PANEL_SIZE - PANEL_VIEW_HEIGHT) / 2;
constexpr int16_t PANEL_VISIBLE_RADIUS = PANEL_SIZE / 2 - 3;
static_assert(PANEL_VIEW_WIDTH * SCREEN_HEIGHT == PANEL_VIEW_HEIGHT * SCREEN_WIDTH,
              "Preserve the logical canvas aspect ratio");
Arduino_ESP32QSPI lcdBus(TFT_CS_PIN, TFT_SCLK_PIN, TFT_DATA0_PIN,
                        TFT_DATA1_PIN, TFT_DATA2_PIN, TFT_DATA3_PIN);
Arduino_SPD2010 tft(&lcdBus, GFX_NOT_DEFINED);
#else
// ideaspark / ESP32 built-in 1.14-inch ST7789 configuration. If your board is
// mirrored or upside-down, change TFT_ROTATION to 3.
constexpr int8_t TFT_MOSI_PIN = 23;
constexpr int8_t TFT_SCLK_PIN = 18;
constexpr int8_t TFT_CS_PIN = 15;
constexpr int8_t TFT_DC_PIN = 2;
constexpr int8_t TFT_RESET_PIN = 4;
constexpr int8_t TFT_BACKLIGHT_PIN = 32;
constexpr uint8_t TFT_ROTATION = 1;
Adafruit_ST7789 tft(TFT_CS_PIN, TFT_DC_PIN, TFT_RESET_PIN);
#endif
constexpr uint8_t BACKLIGHT_NORMAL = 255;
constexpr uint8_t BACKLIGHT_DIM = 24;

GFXcanvas16 display(SCREEN_WIDTH, SCREEN_HEIGHT);

constexpr uint16_t COLOR_BG = 0x0000;
constexpr uint16_t COLOR_WHITE = 0xFFFF;
constexpr uint16_t COLOR_ROUTE = COLOR_WHITE;
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
// Waveshare's BOOT button pulls GPIO0 low. Never hold it while resetting,
// because GPIO0 is also the ESP32-S3 download-mode strap.
constexpr int8_t BOOT_BUTTON_PIN = 0;
volatile bool pairingActive = false;
volatile bool pairingVerified = false;
volatile bool pairingButtonReleased = false;
volatile uint32_t pairingStartedMs = 0;
uint32_t bootLowSinceMs = 0;
constexpr char PAIRING_UUID[] = "abcd1234-5678-1234-5678-abcdef123457";
constexpr char SERVICE_UUID[] = "12345678-1234-1234-1234-123456789abc";
constexpr char CHARACTERISTIC_UUID[] = "abcd1234-5678-1234-5678-abcdef123456";

BLEServer* bleServer = nullptr;
BLEAdvertising* bleAdvertising = nullptr;
BLECharacteristic* pairingCharacteristic = nullptr;

bool bleConnected = false;
bool hadBleConnection = false;

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

// Placed after the enum declarations: the Arduino preprocessor inserts its
// generated prototypes before the first function definition.
// BEGIN PACKET AUTH - kept inline so this sketch can be copied on its own.
// Must match the App's PacketSigner byte for byte. A navigation write is
// "<json>|<16 hex>": the tag is the first 8 bytes of
// HMAC-SHA256(key, sessionNonce || json). The key is issued at a BOOT-confirmed
// pairing; the nonce is new on every connection, so recorded packets cannot be
// replayed into a later session. The JSON's counter "n" is checked by the
// caller after parsing.
constexpr size_t AUTH_KEY_BYTES = 16;
constexpr size_t AUTH_NONCE_BYTES = 8;
constexpr size_t AUTH_TAG_BYTES = 8;

// Provided by the sketch (mbedtls) or the host test (CommonCrypto).
bool navHmacSha256(const uint8_t* key, size_t keyLength, const uint8_t* a,
                   size_t aLength, const uint8_t* b, size_t bLength,
                   uint8_t out[32]);

inline int authHexNibble(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// Returns the length of the authenticated JSON before '|', or -1.
inline int verifyPacketTag(const uint8_t key[AUTH_KEY_BYTES],
                           const uint8_t nonce[AUTH_NONCE_BYTES],
                           const char* packet, size_t length) {
  constexpr size_t suffix = 1 + AUTH_TAG_BYTES * 2;
  if (packet == nullptr || length <= suffix + 1) return -1;
  const size_t jsonLength = length - suffix;
  if (packet[jsonLength] != '|') return -1;
  uint8_t tag[AUTH_TAG_BYTES];
  for (size_t i = 0; i < AUTH_TAG_BYTES; ++i) {
    const int high = authHexNibble(packet[jsonLength + 1 + i * 2]);
    const int low = authHexNibble(packet[jsonLength + 2 + i * 2]);
    if (high < 0 || low < 0) return -1;
    tag[i] = static_cast<uint8_t>(high << 4 | low);
  }
  uint8_t mac[32];
  if (!navHmacSha256(key, AUTH_KEY_BYTES, nonce, AUTH_NONCE_BYTES,
                     reinterpret_cast<const uint8_t*>(packet), jsonLength,
                     mac)) {
    return -1;
  }
  // Constant time: do not reveal how many leading tag bytes were right.
  uint8_t difference = 0;
  for (size_t i = 0; i < AUTH_TAG_BYTES; ++i) difference |= mac[i] ^ tag[i];
  return difference == 0 ? static_cast<int>(jsonLength) : -1;
}

// Key rotation that a dropped link cannot break. A BOOT pairing issues a new
// key, but the phone may disconnect before it stores it. So the last proven
// key stays valid until the new key is used on a later, non-pairing
// connection, which proves the phone kept it. Pure state: the sketch persists
// it to NVS and guards it with stateMux.
enum class AuthKeyMatch : uint8_t { None, Current, Previous };

struct KeyRing {
  uint8_t current[AUTH_KEY_BYTES] = {};
  uint8_t previous[AUTH_KEY_BYTES] = {};
  bool hasCurrent = false;
  bool currentProven = false;
  bool hasPrevious = false;

  void rotate(const uint8_t fresh[AUTH_KEY_BYTES]) {
    // Keep the newest key a phone is known to hold. An unproven current key
    // only replaces `previous` when there is nothing better to keep.
    if (hasCurrent && (currentProven || !hasPrevious)) {
      memcpy(previous, current, AUTH_KEY_BYTES);
      hasPrevious = true;
    }
    memcpy(current, fresh, AUTH_KEY_BYTES);
    hasCurrent = true;
    currentProven = false;
  }

  AuthKeyMatch match(const uint8_t nonce[AUTH_NONCE_BYTES], const char* packet,
                     size_t length, int* jsonLength) const {
    if (hasCurrent) {
      *jsonLength = verifyPacketTag(current, nonce, packet, length);
      if (*jsonLength >= 0) return AuthKeyMatch::Current;
    }
    if (hasPrevious) {
      *jsonLength = verifyPacketTag(previous, nonce, packet, length);
      if (*jsonLength >= 0) return AuthKeyMatch::Previous;
    }
    *jsonLength = -1;
    return AuthKeyMatch::None;
  }

  // Record an accepted write. Returns true when the ring changed and must be
  // persisted: the current key was used outside the connection that issued
  // it, so the previous key can be retired.
  bool noteUsed(AuthKeyMatch which, bool pairingConnection) {
    if (which != AuthKeyMatch::Current || pairingConnection || currentProven) {
      return false;
    }
    currentProven = true;
    if (hasPrevious) {
      memset(previous, 0, AUTH_KEY_BYTES);
      hasPrevious = false;
    }
    return true;
  }
};
// END PACKET AUTH

// Explicit: the generated prototype would precede the KeyRing declaration.
bool persistKeyRing(const KeyRing& ring);

constexpr uint8_t MAP_VALUE_COUNT =
    MAX_ROUTE_PREVIEW_POINTS * 2 + MAX_SIDE_ROAD_SEGMENTS * 4;
static_assert(MAP_VALUE_COUNT == 20, "MapMotion stores 20 map values");

// BLE callbacks run on the Bluetooth stack's FreeRTOS task. They only publish
// into this mailbox under stateMux; loop() takes a snapshot each iteration and
// owns every navigation, timeout, error and backlight variable.
struct BleMailbox {
  bool connected = false;
  uint32_t disconnects = 0;
  bool clockSynced = false;
  bool navReady = false;
  NavState nav = {Direction::Stop, 0};
  bool rerouting = false;
  float map[MAP_VALUE_COUNT] = {};
  uint8_t routes = 0, roads = 0;
  bool errorReady = false;
  char error[48] = "";
  bool wake = false;
  // keyRing changed in the BLE task; loop() writes it to NVS.
  bool persistKeys = false;
};
// Also guards every read and write of the pairing flags and packet-auth
// key/nonce below, which the BLE task and loop() share.
portMUX_TYPE stateMux = portMUX_INITIALIZER_UNLOCKED;

// Issued by BOOT-confirmed pairings and kept in NVS; until the first one every
// navigation write is rejected. Persisted only from loop().
Preferences authStore;
KeyRing keyRing;
// True on the connection where BOOT issued the current key: its own use there
// does not prove the phone stored it.
bool pairingConnection = false;
// New random value on every connection; read by the phone before signing.
uint8_t sessionNonce[AUTH_NONCE_BYTES] = {};
// Highest accepted counter "n" this connection. BLE task only: connect and
// write callbacks run on the same Bluetooth host task.
uint32_t sessionCounter = 0;
BleMailbox mailbox;
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
void drawMiniRouteMap(bool showRider = true);
#if NAV_WAVESHARE_146
void drawRoundCenteredText(const char* value, uint8_t size, int16_t top);
#endif

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

// BLE task only: hand an error message to loop().
void publishError(const char* message) {
  portENTER_CRITICAL(&stateMux);
  strlcpy(mailbox.error, message, sizeof(mailbox.error));
  mailbox.errorReady = true;
  portEXIT_CRITICAL(&stateMux);
  displayDirty = true;
}

void publishBadDirectionError(const char* value) {
  char message[sizeof(lastError)];
  snprintf(message, sizeof(message), "bad:%.24s", value == nullptr ? "" : value);
  publishError(message);
}

bool navHmacSha256(const uint8_t* key, size_t keyLength, const uint8_t* a,
                   size_t aLength, const uint8_t* b, size_t bLength,
                   uint8_t out[32]) {
  const mbedtls_md_info_t* info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  if (info == nullptr) return false;
  mbedtls_md_context_t context;
  mbedtls_md_init(&context);
  const bool ok = mbedtls_md_setup(&context, info, 1) == 0 &&
                  mbedtls_md_hmac_starts(&context, key, keyLength) == 0 &&
                  mbedtls_md_hmac_update(&context, a, aLength) == 0 &&
                  mbedtls_md_hmac_update(&context, b, bLength) == 0 &&
                  mbedtls_md_hmac_finish(&context, out) == 0;
  mbedtls_md_free(&context);
  return ok;
}

// NVS layout (namespace "navauth"): "k" current key, "kp" whether the current
// key is proven, "p" the previous key while the current one is unproven.
void loadAuthKey() {
  KeyRing loaded;
  if (authStore.begin("navauth", true)) {
    loaded.hasCurrent = authStore.getBytes("k", loaded.current,
                                           AUTH_KEY_BYTES) == AUTH_KEY_BYTES;
    // Keys stored before rotation existed are proven: their phone has them.
    loaded.currentProven = authStore.getBool("kp", true);
    loaded.hasPrevious = authStore.getBytes("p", loaded.previous,
                                            AUTH_KEY_BYTES) == AUTH_KEY_BYTES;
  }
  authStore.end();
  portENTER_CRITICAL(&stateMux);
  keyRing = loaded;
  portEXIT_CRITICAL(&stateMux);
  Serial.println(loaded.hasCurrent ? "[AUTH] Pairing key loaded"
                                   : "[AUTH] Not paired yet");
}

// loop() only. Writes every field so a partial earlier write cannot linger.
bool persistKeyRing(const KeyRing& ring) {
  if (!authStore.begin("navauth", false)) return false;
  bool ok = !ring.hasCurrent ||
            authStore.putBytes("k", ring.current, AUTH_KEY_BYTES) == AUTH_KEY_BYTES;
  ok = ok && authStore.putBool("kp", ring.currentProven) > 0;
  if (ring.hasPrevious) {
    ok = ok && authStore.putBytes("p", ring.previous, AUTH_KEY_BYTES) ==
                   AUTH_KEY_BYTES;
  } else if (authStore.isKey("p")) {
    ok = ok && authStore.remove("p");
  }
  authStore.end();
  return ok;
}

// Rotate to a fresh key on a BOOT pairing. Persisted before it is exposed: a
// power cut right after the phone saves it must not lose it. The previously
// proven key keeps working until the new one is proven (see KeyRing).
bool issueAuthKey() {
  uint8_t fresh[AUTH_KEY_BYTES];
  esp_fill_random(fresh, sizeof(fresh));
  KeyRing next;
  portENTER_CRITICAL(&stateMux);
  next = keyRing;
  portEXIT_CRITICAL(&stateMux);
  next.rotate(fresh);
  memset(fresh, 0, sizeof(fresh));
  if (!persistKeyRing(next)) return false;
  portENTER_CRITICAL(&stateMux);
  keyRing = next;
  portEXIT_CRITICAL(&stateMux);
  memset(&next, 0, sizeof(next));
  return true;
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

// The stack keeps the last read response as the attribute value. Wipe it
// between connections so a later client (e.g. a Read Blob at an offset)
// cannot see a response that carried the pairing key.
void clearPairingValue() {
  if (pairingCharacteristic != nullptr) pairingCharacteristic->setValue("{}");
}

void startBleAdvertising() {
  if (bleAdvertising == nullptr) return;
  bleAdvertising->start();
  Serial.println("[BLE] Advertising started");
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override {
    uint8_t nonce[AUTH_NONCE_BYTES];
    esp_fill_random(nonce, sizeof(nonce));
    sessionCounter = 0;
    portENTER_CRITICAL(&stateMux);
    memcpy(sessionNonce, nonce, sizeof(sessionNonce));
    pairingActive = false;
    pairingVerified = false;
    pairingConnection = false;
    mailbox.connected = true;
    mailbox.error[0] = '\0';
    mailbox.errorReady = true;
    mailbox.wake = true;
    portEXIT_CRITICAL(&stateMux);
    displayDirty = true;
    clearPairingValue();
    Serial.println("[BLE] Central connected");
  }

  void onDisconnect(BLEServer* server) override {
    portENTER_CRITICAL(&stateMux);
    pairingActive = false;
    pairingVerified = false;
    pairingButtonReleased = false;
    mailbox.connected = false;
    // loop() clears the maneuver and geometry when this counter changes.
    mailbox.disconnects++;
    // A packet queued before the drop is obsolete and must not be shown.
    mailbox.navReady = false;
    strlcpy(mailbox.error, "BLE disconnected", sizeof(mailbox.error));
    mailbox.errorReady = true;
    mailbox.wake = true;
    portEXIT_CRITICAL(&stateMux);
    displayDirty = true;
    clearPairingValue();
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
      publishError("empty packet");
      return;
    }

    // 360 bytes of JSON plus the counter and the 17-byte signature suffix.
    if (value.length() > 400) {
      rejectedPacketCount++;
      publishError("packet too large");
      Serial.println("[BLE] Rejected oversized packet");
      return;
    }

    KeyRing ring;
    uint8_t nonce[AUTH_NONCE_BYTES];
    portENTER_CRITICAL(&stateMux);
    ring = keyRing;
    memcpy(nonce, sessionNonce, sizeof(nonce));
    portEXIT_CRITICAL(&stateMux);
    if (!ring.hasCurrent) {
      rejectedPacketCount++;
      publishError("not paired");
      return;
    }
    // Anyone in range can write to this characteristic; only a phone that
    // paired with a BOOT press can produce a valid tag for this session.
    int jsonLength = -1;
    const AuthKeyMatch keyUsed =
        ring.match(nonce, value.c_str(), value.length(), &jsonLength);
    uint8_t matchedCurrent[AUTH_KEY_BYTES];
    memcpy(matchedCurrent, ring.current, sizeof(matchedCurrent));
    memset(&ring, 0, sizeof(ring));
    if (keyUsed == AuthKeyMatch::None) {
      rejectedPacketCount++;
      publishError("bad signature");
      Serial.println("[BLE] Rejected unauthenticated packet");
      return;
    }

    StaticJsonDocument<768> doc;
    DeserializationError error =
        deserializeJson(doc, value.c_str(), static_cast<size_t>(jsonLength));
    if (error) {
      rejectedPacketCount++;
      publishError("bad json");
      Serial.print("[BLE] JSON error: ");
      Serial.println(error.c_str());
      Serial.print("[BLE] Raw: ");
      Serial.println(value);
      return;
    }

    // A signed packet from earlier in this session must not be replayed.
    if (!doc["n"].is<uint32_t>() || doc["n"].as<uint32_t>() <= sessionCounter) {
      rejectedPacketCount++;
      publishError("replayed packet");
      memset(matchedCurrent, 0, sizeof(matchedCurrent));
      return;
    }
    sessionCounter = doc["n"].as<uint32_t>();

    // A fully accepted write with the current key on an ordinary connection
    // proves the phone stored it, retiring the previous key. Skip it if a
    // BOOT rotation replaced the current key since it was matched.
    portENTER_CRITICAL(&stateMux);
    if (memcmp(keyRing.current, matchedCurrent, AUTH_KEY_BYTES) == 0 &&
        keyRing.noteUsed(keyUsed, pairingConnection)) {
      mailbox.persistKeys = true;
    }
    portEXIT_CRITICAL(&stateMux);
    memset(matchedCurrent, 0, sizeof(matchedCurrent));

    // Phone-local wall time, separate from navigation: never starts guidance
    // or refreshes the live-navigation packet timeout.
    if (doc["clock"].is<uint32_t>()) {
      const uint32_t seconds = doc["clock"].as<uint32_t>();
      if (seconds < 1700000000UL) {
        publishError("bad clock");
        return;
      }
      timeval now = {static_cast<time_t>(seconds), 0};
      settimeofday(&now, nullptr);
      portENTER_CRITICAL(&stateMux);
      mailbox.clockSynced = true;
      mailbox.wake = true;
      portEXIT_CRITICAL(&stateMux);
      displayDirty = true;
      return;
    }

    const char* dirText = doc["dir"] | "";
    Direction direction = parseDirection(dirText);
    if (direction == Direction::Unknown) {
      rejectedPacketCount++;
      publishBadDirectionError(dirText);
      Serial.print("[BLE] Unknown dir: ");
      Serial.println(dirText);
      Serial.print("[BLE] Raw: ");
      Serial.println(value);
      return;
    }

    if (!doc["dist"].is<int>()) {
      rejectedPacketCount++;
      publishError("bad dist");
      Serial.println("[BLE] Missing/invalid dist");
      return;
    }

    int distance = doc["dist"].as<int>();
    distance = constrain(distance, 0, MAX_DISTANCE_M);

    const bool reroutingPacket = doc["rerouting"] | false;
    ScreenPoint routePreviewPoints[MAX_ROUTE_PREVIEW_POINTS];
    uint8_t routePreviewPointCount = 0;
    ScreenSegment sideRoadSegments[MAX_SIDE_ROAD_SEGMENTS];
    uint8_t sideRoadSegmentCount = 0;
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

    // Publish the whole packet at once so loop() never sees a new direction
    // with the previous distance, flags or geometry.
    constexpr uint8_t roadOffset = MAX_ROUTE_PREVIEW_POINTS * 2;
    portENTER_CRITICAL(&stateMux);
    memset(mailbox.map, 0, sizeof(mailbox.map));
    for (uint8_t i = 0; i < routePreviewPointCount; ++i) {
      mailbox.map[i * 2] = routePreviewPoints[i].x;
      mailbox.map[i * 2 + 1] = routePreviewPoints[i].y;
    }
    for (uint8_t i = 0; i < sideRoadSegmentCount; ++i) {
      mailbox.map[roadOffset + i * 4] = sideRoadSegments[i].start.x;
      mailbox.map[roadOffset + 1 + i * 4] = sideRoadSegments[i].start.y;
      mailbox.map[roadOffset + 2 + i * 4] = sideRoadSegments[i].end.x;
      mailbox.map[roadOffset + 3 + i * 4] = sideRoadSegments[i].end.y;
    }
    mailbox.nav = {direction, distance};
    mailbox.rerouting = reroutingPacket;
    mailbox.routes = routePreviewPointCount;
    mailbox.roads = sideRoadSegmentCount;
    mailbox.navReady = true;
    mailbox.error[0] = '\0';
    mailbox.errorReady = true;
    mailbox.wake = true;
    portEXIT_CRITICAL(&stateMux);
    displayDirty = true;

    Serial.print("[NAV] ");
    Serial.print(directionName(direction));
    Serial.print(" ");
    Serial.print(distance);
    Serial.print("m route=");
    Serial.print(routePreviewPointCount);
    Serial.print(" roads=");
    Serial.println(sideRoadSegmentCount);
  }
};

// Pairing: a physical BOOT press confirms the phone in front of the display,
// which then receives the key that signs every navigation write (see PACKET
// AUTH). Kept separate from the navigation characteristic. Every read also
// returns this connection's session nonce.
class PairingCallbacks : public BLECharacteristicCallbacks {
  void onRead(BLECharacteristic* characteristic) override {
    uint8_t nonce[AUTH_NONCE_BYTES];
    uint8_t key[AUTH_KEY_BYTES];
    portENTER_CRITICAL(&stateMux);
    // pairingVerified is cleared on every connect/disconnect, so the key is
    // only ever readable on the connection where BOOT was just pressed.
    const bool verified = pairingVerified && keyRing.hasCurrent;
    memcpy(nonce, sessionNonce, sizeof(nonce));
    memcpy(key, keyRing.current, sizeof(key));
    portEXIT_CRITICAL(&stateMux);

    char nonceHex[AUTH_NONCE_BYTES * 2 + 1];
    char keyHex[AUTH_KEY_BYTES * 2 + 1];
    for (size_t i = 0; i < AUTH_NONCE_BYTES; ++i)
      snprintf(nonceHex + i * 2, 3, "%02x", nonce[i]);
    for (size_t i = 0; i < AUTH_KEY_BYTES; ++i)
      snprintf(keyHex + i * 2, 3, "%02x", key[i]);
    memset(key, 0, sizeof(key));

    char response[160];
    if (verified) {
      snprintf(response, sizeof(response),
               "{\"id\":\"%s\",\"verified\":true,\"s\":\"%s\",\"k\":\"%s\"}",
               deviceIdentity, nonceHex, keyHex);
    } else {
      snprintf(response, sizeof(response),
               "{\"id\":\"%s\",\"verified\":false,\"s\":\"%s\"}",
               deviceIdentity, nonceHex);
    }
    memset(keyHex, 0, sizeof(keyHex));
    characteristic->setValue(response);
  }
  void onWrite(BLECharacteristic* characteristic) override {
    const auto value = characteristic->getValue();
    StaticJsonDocument<128> doc;
    if (value.length() > 80 || deserializeJson(doc, value.c_str())) return;
    const char* action = doc["pair"] | "";
    if (strcmp(action, "start") == 0) {
      portENTER_CRITICAL(&stateMux);
      pairingStartedMs = millis();
      pairingActive = true;
      pairingVerified = false;
      pairingButtonReleased = false; // Require a fresh press after arming.
      bootLowSinceMs = 0;
      mailbox.wake = true;
      portEXIT_CRITICAL(&stateMux);
      displayDirty = true;
    }
  }
};

void setupBle() {
  BLEDevice::init(DEVICE_NAME);
  // Stability first: use positive TX power so the phone can rediscover the
  // device reliably after power switch cycles and app backgrounding.
  BLEDevice::setPower(ESP_PWR_LVL_P3);
  // Accept a large MTU so a signed packet (~170 bytes) arrives in one write.
  // The local default is 23, which would force Android into slower queued
  // long writes. iOS negotiates its own (typically 185).
  BLEDevice::setMTU(517);

  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new ServerCallbacks());

  BLEService* service = bleServer->createService(SERVICE_UUID);
  BLECharacteristic* pairing = service->createCharacteristic(
      PAIRING_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE);
  pairing->setCallbacks(new PairingCallbacks());
  pairingCharacteristic = pairing;

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
#if NAV_WAVESHARE_146
constexpr int16_t MAP_BOTTOM = 166;
constexpr uint8_t ROUTE_STROKE = 7;
constexpr uint8_t FALLBACK_ROUTE_STROKE = 4;
#else
constexpr int16_t MAP_BOTTOM = 94;
constexpr uint8_t ROUTE_STROKE = 6;
constexpr uint8_t FALLBACK_ROUTE_STROKE = 2;
#endif
// Zoom geometry around the rider, without enlarging the instruction strip.
#if NAV_WAVESHARE_146
constexpr float MAP_ZOOM = 1.90f;
#else
constexpr float MAP_ZOOM = 1.50f;
#endif
constexpr int16_t MAP_CLIP_BOTTOM = MAP_BOTTOM - 4;
constexpr int16_t ARROW_CENTER_X = 66;
constexpr int16_t DISTANCE_X = 132;

int16_t mapPreviewX(float x) {
  const float center = (MAP_LEFT + MAP_RIGHT) / 2.0f;
  const float projected = MAP_LEFT + 6 + (x - 18) * (MAP_RIGHT - MAP_LEFT - 12) / 92.0f;
  return lroundf(center + (projected - center) * MAP_ZOOM);
}

int16_t mapPreviewY(float y) {
  const float anchor = MAP_BOTTOM - 12;
#if NAV_WAVESHARE_146
  // Use the extra round-screen height for the map, but retain the rider at
  // the bottom so the instruction strip cannot be covered by road geometry.
  const float projected = MAP_TOP + 25 + (y - 2) * (MAP_BOTTOM - MAP_TOP - 47) / 32.0f;
  return lroundf(anchor + (projected - anchor) * 1.90f);
#else
  const float projected = MAP_TOP + 4 + (y - 2) * (MAP_BOTTOM - MAP_TOP - 16) / 32.0f;
  return lroundf(anchor + (projected - anchor) * MAP_ZOOM);
#endif
}

void presentDisplay() {
#if NAV_WAVESHARE_146
  // Small scanline buffer avoids a second full framebuffer allocation. Native
  // RGB565 words are passed to draw16bitRGBBitmap (not the big-endian variant).
  static uint16_t row[PANEL_VIEW_WIDTH];
  const uint16_t* source = display.getBuffer();
  if (!source) return;
  for (int y = 0; y < PANEL_VIEW_HEIGHT; ++y) {
    const int sourceY = y * SCREEN_HEIGHT / PANEL_VIEW_HEIGHT;
    const int panelY = PANEL_VIEW_Y + y - PANEL_SIZE / 2;
    for (int x = 0; x < PANEL_VIEW_WIDTH; ++x) {
      const int panelX = PANEL_VIEW_X + x - PANEL_SIZE / 2;
      const bool inside = panelX * panelX + panelY * panelY <=
                          PANEL_VISIBLE_RADIUS * PANEL_VISIBLE_RADIUS;
      row[x] = inside
                   ? source[sourceY * SCREEN_WIDTH + x * SCREEN_WIDTH / PANEL_VIEW_WIDTH]
                   : COLOR_BG;
    }
    tft.draw16bitRGBBitmap(PANEL_VIEW_X, PANEL_VIEW_Y + y, row, PANEL_VIEW_WIDTH, 1);
  }
#else
  tft.drawRGBBitmap(0, 0, display.getBuffer(), SCREEN_WIDTH, SCREEN_HEIGHT);
#endif
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
  // endpoint. Use that direction only: road-segment lengths vary wildly and
  // must not change the length of the schematic ray on this small display.
  const float dx = x1 - x0;
  const float dy = y1 - y0;
  const float length = sqrtf(dx * dx + dy * dy);
  if (length < 1.0f) return;
  const float ux = dx / length;
  const float uy = dy / length;
#if NAV_WAVESHARE_146
  constexpr float visibleLength = 48.0f;
#else
  constexpr float visibleLength = 30.0f;
#endif
  const float endX = x0 + ux * visibleLength;
  const float endY = y0 + uy * visibleLength;
  // A clipped ray looks like a randomly short road. Omit it if its full
  // schematic length cannot fit in the map (or the round panel's aperture).
  constexpr float margin = 6.0f;
  if (x0 < margin || x0 >= SCREEN_WIDTH - margin ||
      y0 < margin || y0 >= MAP_CLIP_BOTTOM - margin ||
      endX < margin || endX >= SCREEN_WIDTH - margin ||
      endY < margin || endY >= MAP_CLIP_BOTTOM - margin) return;
#if NAV_WAVESHARE_146
  constexpr float visibleRadius = SCREEN_WIDTH / 2.0f - margin;
  const float startCircleX = x0 - SCREEN_WIDTH / 2.0f;
  const float startCircleY = y0 - SCREEN_HEIGHT / 2.0f;
  const float endCircleX = endX - SCREEN_WIDTH / 2.0f;
  const float endCircleY = endY - SCREEN_HEIGHT / 2.0f;
  if (startCircleX * startCircleX + startCircleY * startCircleY >
          visibleRadius * visibleRadius ||
      endCircleX * endCircleX + endCircleY * endCircleY >
          visibleRadius * visibleRadius) return;
#endif
  x1 = lroundf(endX);
  y1 = lroundf(endY);
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

int16_t instructionX(int16_t x) {
#if NAV_WAVESHARE_146
  return 66 + (x - 66) * 5 / 4;
#else
  return x;
#endif
}

int16_t instructionY(int16_t y) {
#if NAV_WAVESHARE_146
  return 180 + (y - 93) * 5 / 4;
#else
  return y;
#endif
}

void drawInstructionLine(int16_t x0, int16_t y0, int16_t x1, int16_t y1,
                         uint8_t thickness = 3) {
  drawThickLine(instructionX(x0), instructionY(y0), instructionX(x1),
                instructionY(y1), COLOR_WHITE,
#if NAV_WAVESHARE_146
                thickness + 1
#else
                thickness
#endif
  );
}

void fillInstructionTriangle(int16_t x0, int16_t y0, int16_t x1, int16_t y1,
                             int16_t x2, int16_t y2) {
  display.fillTriangle(instructionX(x0), instructionY(y0),
                       instructionX(x1), instructionY(y1),
                       instructionX(x2), instructionY(y2), COLOR_WHITE);
}

void drawArrowUp() {
  drawInstructionLine(ARROW_CENTER_X, 128, ARROW_CENTER_X, 98);
  drawInstructionLine(ARROW_CENTER_X, 98, ARROW_CENTER_X - 15, 113);
  drawInstructionLine(ARROW_CENTER_X, 98, ARROW_CENTER_X + 15, 113);
}

void drawArrowLeft() {
  drawInstructionLine(82, 128, 82, 116);
  drawInstructionLine(82, 116, 74, 106);
  drawInstructionLine(74, 106, 42, 106);
  drawInstructionLine(42, 106, 60, 93);
  drawInstructionLine(42, 106, 60, 119);
}

void drawArrowRight() {
  drawInstructionLine(48, 128, 48, 116);
  drawInstructionLine(48, 116, 56, 106);
  drawInstructionLine(56, 106, 88, 106);
  drawInstructionLine(88, 106, 70, 93);
  drawInstructionLine(88, 106, 70, 119);
}

void drawBearLeft() {
  drawInstructionLine(66, 128, 66, 118, 4);
  drawInstructionLine(66, 118, 62, 112, 4);
  drawInstructionLine(62, 112, 50, 100, 4);
  fillInstructionTriangle(43, 96, 61, 99, 46, 114);
}

void drawBearRight() {
  drawInstructionLine(66, 128, 66, 118, 4);
  drawInstructionLine(66, 118, 70, 112, 4);
  drawInstructionLine(70, 112, 82, 100, 4);
  fillInstructionTriangle(89, 96, 71, 99, 86, 114);
}

void drawUTurn() {
  drawInstructionLine(82, 128, 82, 100);
  drawInstructionLine(82, 100, 44, 100);
  drawInstructionLine(44, 100, 44, 120);
  drawInstructionLine(44, 120, 31, 107);
  drawInstructionLine(44, 120, 57, 107);
}

void drawStop() {
  display.fillRoundRect(instructionX(42), instructionY(98),
                        instructionX(90) - instructionX(42),
                        instructionY(128) - instructionY(98), 5, COLOR_WHITE);
}

void drawArrived() {
  drawInstructionLine(34, 114, 56, 130);
  drawInstructionLine(56, 130, 94, 94);
}

void drawUnknown() {
  display.setTextSize(2);
  display.setCursor(instructionX(22), instructionY(105));
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
      drawThickLine(centerX, bottom, centerX, 55, COLOR_ROUTE, FALLBACK_ROUTE_STROKE);
      drawThickLine(centerX, 55, centerX - 18, 42, COLOR_ROUTE, FALLBACK_ROUTE_STROKE);
      drawThickLine(centerX - 18, 42, left, 42, COLOR_ROUTE, FALLBACK_ROUTE_STROKE);
      break;
    case Direction::Right:
      drawThickLine(centerX, bottom, centerX, 55, COLOR_ROUTE, FALLBACK_ROUTE_STROKE);
      drawThickLine(centerX, 55, centerX + 18, 42, COLOR_ROUTE, FALLBACK_ROUTE_STROKE);
      drawThickLine(centerX + 18, 42, right, 42, COLOR_ROUTE, FALLBACK_ROUTE_STROKE);
      break;
    case Direction::BearLeft:
      drawThickLine(centerX, bottom, centerX, 58, COLOR_ROUTE, FALLBACK_ROUTE_STROKE);
      drawThickLine(centerX, 58, centerX - 44, top, COLOR_ROUTE, FALLBACK_ROUTE_STROKE);
      break;
    case Direction::BearRight:
      drawThickLine(centerX, bottom, centerX, 58, COLOR_ROUTE, FALLBACK_ROUTE_STROKE);
      drawThickLine(centerX, 58, centerX + 44, top, COLOR_ROUTE, FALLBACK_ROUTE_STROKE);
      break;
    case Direction::UTurn:
      drawThickLine(centerX, bottom, centerX, 36, COLOR_ROUTE, FALLBACK_ROUTE_STROKE);
      drawThickLine(centerX, 36, left + 28, 36, COLOR_ROUTE, FALLBACK_ROUTE_STROKE);
      drawThickLine(left + 28, 36, left + 28, 68, COLOR_ROUTE, FALLBACK_ROUTE_STROKE);
      break;
    default:
      drawThickLine(centerX, bottom, centerX, top, COLOR_ROUTE, FALLBACK_ROUTE_STROKE);
      break;
  }
}

void drawMiniRouteMap(bool showRider) {
  drawSideRoadSegments();

  if (mapMotion.routes >= 2) {
    for (uint8_t i = 0; i + 1 < mapMotion.routes; i++) {
      const float* p = mapMotion.current + i * 2;
      drawThickLine(mapPreviewX(p[0]), mapPreviewY(p[1]),
                    mapPreviewX(p[2]), mapPreviewY(p[3]), COLOR_ROUTE, ROUTE_STROKE);
    }
  } else {
    drawFallbackMapRoute(nav.direction);
  }

  if (showRider) {
    const int16_t markerX = (MAP_LEFT + MAP_RIGHT) / 2;
    const int16_t markerY = MAP_BOTTOM - 12;
    // Only live guidance may show a rider marker. A cached snapshot no longer
    // establishes the bike's current position relative to this road shape.
#if NAV_WAVESHARE_146
    display.fillTriangle(markerX, markerY - 21, markerX - 18, markerY + 14,
                         markerX + 18, markerY + 14, COLOR_BG);
    display.fillTriangle(markerX, markerY - 12, markerX - 10, markerY + 6,
                         markerX + 10, markerY + 6, COLOR_WHITE);
#else
    display.fillTriangle(markerX, markerY - 15, markerX - 13, markerY + 10,
                         markerX + 13, markerY + 10, COLOR_BG);
    display.fillTriangle(markerX, markerY - 8, markerX - 7, markerY + 4,
                         markerX + 7, markerY + 4, COLOR_WHITE);
#endif
  }

  // Legacy preview coordinates can extend below the map. Keep them out of
  // the instruction strip without drawing a visible frame or separator.
  display.fillRect(0, MAP_CLIP_BOTTOM, SCREEN_WIDTH, SCREEN_HEIGHT - MAP_CLIP_BOTTOM,
                   COLOR_BG);
}

void drawDistance(int distanceMeters, bool blinkState) {
  display.setTextColor(COLOR_WHITE);
#if NAV_WAVESHARE_146
  // The circle narrows at the bottom. Right-align the large number inside a
  // fixed safe column and place the small unit above its lower edge.
  display.setTextSize(4);
  if (nav.direction == Direction::Arrived) {
    display.setCursor(120, 176);
    display.print("ARR");
    return;
  }
  if (distanceMeters <= 30) {
    if (blinkState) {
      display.setCursor(120, 176);
      display.print("NOW");
    }
    return;
  }
  if (distanceMeters < 1000) {
    const int16_t digits = distanceMeters < 100 ? 2 : 3;
    display.setCursor(192 - digits * 24, 176);
    display.print(distanceMeters);
    display.setTextSize(2);
    display.setCursor(196, 183);
    display.print("m");
  } else {
    display.setCursor(120, 176);
    display.print(distanceMeters / 1000.0, 1);
    display.setTextSize(2);
    display.setCursor(194, 183);
    display.print("km");
  }
#else
  display.setTextSize(3);
  display.setCursor(DISTANCE_X, 104);
  if (nav.direction == Direction::Arrived) {
    display.println("ARR");
    return;
  }

  if (distanceMeters <= 30) {
    if (blinkState) {
      display.println("NOW");
    }
  } else if (distanceMeters < 1000) {
    display.print(distanceMeters);
    display.println("m");
  } else {
    display.print(distanceMeters / 1000.0, 1);
    display.println("k");
  }
#endif
}

void drawBottomError() {
  if (lastError[0] == '\0') return;

  display.setTextColor(COLOR_ACCENT);
#if NAV_WAVESHARE_146
  // The square canvas corners fall outside the round aperture: (8, 230) was
  // never visible. Centre the message below the distance, where the circle is
  // still ~148 px wide, and keep it to the 24 size-1 glyphs that fit there.
  char visible[25];
  strlcpy(visible, lastError, sizeof(visible));
  drawRoundCenteredText(visible, 1, 218);
#else
  display.setTextSize(1);
  display.setCursor(8, SCREEN_HEIGHT - 10);
  display.print(lastError);
#endif
}

#if NAV_WAVESHARE_146
uint16_t roundTextHeight(const char* value, uint8_t size) {
  int16_t x, y;
  uint16_t width, height;
  display.setTextSize(size);
  display.getTextBounds(value, 0, 0, &x, &y, &width, &height);
  return height;
}

void drawRoundCenteredText(const char* value, uint8_t size, int16_t top) {
  int16_t x, y;
  uint16_t width, height;
  display.setTextSize(size);
  display.getTextBounds(value, 0, 0, &x, &y, &width, &height);
  display.setCursor((SCREEN_WIDTH - width) / 2 - x, top - y);
  display.print(value);
}

void drawRoundCenteredStatus(const char* primary, uint8_t primarySize,
                             const char* secondary = nullptr,
                             uint8_t secondarySize = 1) {
  const int16_t primaryHeight = roundTextHeight(primary, primarySize);
  const int16_t secondaryHeight = secondary == nullptr
                                      ? 0
                                      : roundTextHeight(secondary, secondarySize);
  const int16_t gap = secondary == nullptr ? 0 : 18;
  const int16_t top = (SCREEN_HEIGHT - primaryHeight - gap - secondaryHeight) / 2;
  drawRoundCenteredText(primary, primarySize, top);
  if (secondary != nullptr)
    drawRoundCenteredText(secondary, secondarySize, top + primaryHeight + gap);
}
#endif

void drawStandbyClock() {
  display.setTextColor(COLOR_WHITE);
#if NAV_WAVESHARE_146
  if (clockSynced) {
    char clockText[6];
    const time_t now = time(nullptr);
    struct tm localClock;
    gmtime_r(&now, &localClock);
    snprintf(clockText, sizeof(clockText), "%02d:%02d", localClock.tm_hour,
             localClock.tm_min);
    drawRoundCenteredStatus(clockText, 7,
                            bleConnected ? "ready to go" : nullptr, 2);
  } else {
    drawRoundCenteredStatus("MOTO NAV", 3,
                            bleConnected ? "ready to go" : "CONNECT PHONE",
                            bleConnected ? 2 : 1);
  }
#else
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
#endif
}

void drawStandby() {
  if (hadBleConnection) {
    // A dropped BLE link must never look like the normal clock/ready screen.
    // onDisconnect has already removed the last maneuver and map geometry.
#if NAV_WAVESHARE_146
    drawRoundCenteredStatus("CONNECTION LOST", 2, "RECONNECT PHONE", 1);
#else
    display.setTextSize(2);
    display.setCursor(24, 36);
    display.print("CONNECTION LOST");
    display.setTextSize(1);
    display.setCursor(53, 77);
    display.print("RECONNECT PHONE");
#endif
    return;
  }
  drawStandbyClock();
}

void drawWaitingForNavigation(bool paired) {
  if (paired) {
    drawStandbyClock();
    return;
  }
  // Connected, but this display ignores every navigation write until a phone
  // pairs with a BOOT press. Do not pretend to be "ready to go".
#if NAV_WAVESHARE_146
  drawRoundCenteredStatus("NOT PAIRED", 2, "PAIR IN THE APP", 1);
#else
  display.setTextSize(2);
  display.setCursor(60, 40);
  display.print("NOT PAIRED");
  display.setTextSize(1);
  display.setCursor(75, 80);
  display.print("PAIR IN THE APP");
#endif
}

void renderDisplay(bool blinkState) {
  if (!displayAvailable) return;
  if (displayPowerState == DisplayPowerState::Off) return;

  display.fillScreen(COLOR_BG);
  display.setTextColor(COLOR_WHITE);

  portENTER_CRITICAL(&stateMux);
  const bool showPairing = pairingActive;
  const bool paired = keyRing.hasCurrent;
  portEXIT_CRITICAL(&stateMux);
  if (showPairing) {
#if NAV_WAVESHARE_146
    drawRoundCenteredText(DEVICE_NAME, 1, 60);
    drawRoundCenteredStatus("PRESS BOOT", 2, "TO PAIR", 1);
#else
    display.setTextSize(1);
    display.setCursor(12, 12);
    display.print(DEVICE_NAME);
    display.setTextSize(2);
    display.setCursor(54, 51);
    display.print("PRESS BOOT");
    display.setTextSize(1);
    display.setCursor(67, 108);
    display.print("TO PAIR");
#endif
    presentDisplay();
    return;
  }

  if (isStandby()) {
    drawStandby();
    presentDisplay();
    return;
  }

  if (isWaitingForNavigation()) {
    drawWaitingForNavigation(paired);
    presentDisplay();
    return;
  }

  if (rerouting) {
    // The phone may send the last reliable route shape while it searches for
    // a replacement. It is context, not a live rider position or turn cue.
    if (mapMotion.routes >= 2) {
      drawMiniRouteMap(false);
#if NAV_WAVESHARE_146
      drawRoundCenteredText(livePacketTimedOut ? "WAITING PHONE" : "CACHED ROUTE",
                            1, 177);
      drawRoundCenteredText("UPDATING...", 1, 200);
#else
      display.setTextSize(1);
      display.setCursor(livePacketTimedOut ? 71 : 76, 104);
      display.print(livePacketTimedOut ? "WAITING PHONE" : "CACHED ROUTE");
      display.setCursor(83, 118);
      display.print("UPDATING...");
#endif
    } else {
#if NAV_WAVESHARE_146
      drawRoundCenteredText("UPDATING...", 1,
                            (SCREEN_HEIGHT - roundTextHeight("UPDATING...", 1)) / 2);
#else
      display.setTextSize(1);
      display.setCursor(84, 62);
      display.print("UPDATING...");
#endif
    }
    presentDisplay();
    return;
  }

  if (nav.direction == Direction::Stop) {
    // Explicit STOP means there is no safe guidance to show.
#if NAV_WAVESHARE_146
    const char* message = "NO GUIDANCE";
    drawRoundCenteredText(message, 1,
                          (SCREEN_HEIGHT - roundTextHeight(message, 1)) / 2);
#else
    display.setTextSize(1);
    display.setCursor(84, 62);
    display.print("NO GUIDANCE");
#endif
    presentDisplay();
    return;
  }

  // The app stops sending after ARRIVED, so that final screen never goes stale.
  if (livePacketTimedOut && nav.direction != Direction::Arrived) {
    // The phone has gone quiet while still connected (app frozen, killed or
    // GPS stalled). While stopped, the app's heartbeat keeps packets coming
    // only when it has a fresh fix. Keep the maneuver as context, but never
    // present it as live: no rider marker, no countdown, an explicit label.
    drawMiniRouteMap(false);
    drawDirection(nav.direction);
    display.setTextColor(COLOR_WHITE);
#if NAV_WAVESHARE_146
    // Same right-hand column as the distance, clear of the arrow and inside
    // the round aperture.
    display.setTextSize(2);
    display.setCursor(112, 178);
    display.print("NO UPDATE");
    display.setTextSize(1);
    display.setCursor(120, 204);
    display.print("CHECK PHONE");
#else
    display.setTextSize(2);
    display.setCursor(DISTANCE_X, 100);
    display.print("NO UPD");
    display.setTextSize(1);
    display.setCursor(DISTANCE_X, 122);
    display.print("CHECK PHONE");
#endif
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

  // Keep the last direction: only an explicit STOP packet replaces it.
  // renderDisplay() marks it as stale instead. The app re-sends every ~2 s
  // while stopped, backed by a fresh fix, so a timeout means a real problem.
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

#if NAV_WAVESHARE_146
bool readExpanderRegister(uint8_t reg, uint8_t& value) {
  Wire.beginTransmission(IO_EXPANDER_ADDRESS);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom(IO_EXPANDER_ADDRESS, uint8_t(1)) != 1) return false;
  value = Wire.read();
  return true;
}

bool writeExpanderRegister(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(IO_EXPANDER_ADDRESS);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

bool resetRoundPanel() {
  // Preserve every unrelated expander pin (touch reset, SD CS, etc.).
  uint8_t output, config;
  if (!readExpanderRegister(0x01, output) ||
      !readExpanderRegister(0x03, config)) return false;
  if (!writeExpanderRegister(0x01, output & ~LCD_RESET_MASK) ||
      !writeExpanderRegister(0x03, config & ~LCD_RESET_MASK)) return false;
  delay(50);
  if (!writeExpanderRegister(0x01, output | LCD_RESET_MASK)) return false;
  delay(120);
  return true;
}
#endif

bool initDisplay() {
  if (!display.getBuffer()) {
    Serial.println("[TFT] Canvas allocation failed");
    return false;
  }
#if NAV_WAVESHARE_146
  Serial.println("[TFT] init Waveshare 1.46 SPD2010 QSPI...");
  pinMode(TFT_BACKLIGHT_PIN, OUTPUT);
  analogWrite(TFT_BACKLIGHT_PIN, 0);
  if (!Wire.begin(BOARD_I2C_SDA_PIN, BOARD_I2C_SCL_PIN, 400000) ||
      !resetRoundPanel()) {
    Serial.println("[TFT] TCA9554 reset failed (address 0x20)");
    return false;
  }
  if (!tft.begin(40000000)) {
    Serial.println("[TFT] QSPI initialization failed");
    return false;
  }
  tft.fillScreen(COLOR_BG);
  analogWrite(TFT_BACKLIGHT_PIN, BACKLIGHT_NORMAL);
  Serial.println("[TFT] SPD2010 412x412 ready");
#else
  Serial.println("[TFT] init ST7789...");
  pinMode(TFT_BACKLIGHT_PIN, OUTPUT);
  analogWrite(TFT_BACKLIGHT_PIN, BACKLIGHT_NORMAL);

  SPI.begin(TFT_SCLK_PIN, -1, TFT_MOSI_PIN, TFT_CS_PIN);
  tft.init(SCREEN_HEIGHT, SCREEN_WIDTH);
  tft.setRotation(TFT_ROTATION);
  tft.fillScreen(COLOR_BG);
  Serial.println("[TFT] ST7789 ready");
#endif
  return true;
}

// ======================================================
// Arduino lifecycle
// ======================================================

void setup() {
  pinMode(BOOT_BUTTON_PIN, INPUT_PULLUP);
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

  loadAuthKey();
  setupBle();
  Serial.println("[BOOT] Ready");
}

void updatePairing() {
  bool changed = false;
  bool confirmed = false;
  // The BLE task can re-arm pairing at any moment; keep this check atomic.
  portENTER_CRITICAL(&stateMux);
  const uint32_t connection = mailbox.disconnects;
  if (pairingActive && millis() - pairingStartedMs >= 60000) {
    pairingActive = false;
    changed = true;
  }
  if (pairingActive) {
    if (digitalRead(BOOT_BUTTON_PIN) == HIGH) {
      pairingButtonReleased = true;
      bootLowSinceMs = 0;
    } else if (pairingButtonReleased) {
      if (bootLowSinceMs == 0) bootLowSinceMs = millis();
      if (millis() - bootLowSinceMs >= 80) {
        pairingActive = false;
        pairingButtonReleased = false;
        changed = confirmed = true;
      }
    }
  }
  portEXIT_CRITICAL(&stateMux);
  if (changed) displayDirty = true;
  if (!confirmed) return;

  // The NVS write happens outside the critical section. Publish "verified"
  // (which makes the new key readable) only if the phone that started pairing
  // is still connected. If it left, the rotation is harmless: the previously
  // proven key keeps working until the new one is proven (see KeyRing).
  bool stillConnected;
  portENTER_CRITICAL(&stateMux);
  stillConnected = mailbox.disconnects == connection && mailbox.connected;
  portEXIT_CRITICAL(&stateMux);
  if (!stillConnected) {
    Serial.println("[BLE] Pairing phone left before confirmation");
    return;
  }
  if (!issueAuthKey()) {
    setLastError("pairing key save failed");
    Serial.println("[AUTH] Could not store pairing key");
    return;
  }
  bool sameConnection;
  portENTER_CRITICAL(&stateMux);
  sameConnection = mailbox.disconnects == connection && mailbox.connected;
  if (sameConnection) {
    pairingVerified = true;
    pairingConnection = true;
  }
  portEXIT_CRITICAL(&stateMux);
  Serial.println(sameConnection ? "[BLE] Pairing confirmed with BOOT"
                                : "[BLE] Pairing phone left before confirmation");
}

// Applies everything the BLE task published since the previous iteration.
void applyBleMailbox() {
  static uint32_t seenDisconnects = 0;
  BleMailbox snapshot;
  portENTER_CRITICAL(&stateMux);
  snapshot = mailbox;
  mailbox.navReady = false;
  mailbox.errorReady = false;
  mailbox.wake = false;
  mailbox.persistKeys = false;
  KeyRing ringToPersist;
  if (snapshot.persistKeys) ringToPersist = keyRing;
  portEXIT_CRITICAL(&stateMux);

  if (snapshot.persistKeys) {
    // A failed write only delays retiring the previous key: the RAM ring is
    // already correct and both keys stay accepted after a reboot.
    if (persistKeyRing(ringToPersist)) {
      Serial.println("[AUTH] New pairing key proven; previous key retired");
    } else {
      Serial.println("[AUTH] Could not persist proven key; will retry");
      portENTER_CRITICAL(&stateMux);
      mailbox.persistKeys = true;
      portEXIT_CRITICAL(&stateMux);
    }
    memset(&ringToPersist, 0, sizeof(ringToPersist));
  }

  if (snapshot.disconnects != seenDisconnects) {
    // Counted, so a drop and reconnect between two iterations still clears
    // the last maneuver and map geometry.
    seenDisconnects = snapshot.disconnects;
    hasReceivedNavPacket = false;
    lastLivePacketMs = 0;
    livePacketTimedOut = false;
    nav = {Direction::Stop, 0};
    rerouting = false;
    displayDirty = true;
  }
  if (snapshot.connected) hadBleConnection = true;
  bleConnected = snapshot.connected;
  clockSynced = snapshot.clockSynced;
  if (snapshot.errorReady) setLastError(snapshot.error);
  if (snapshot.navReady) {
    nav = snapshot.nav;
    rerouting = snapshot.rerouting;
    lastLivePacketMs = millis();
    livePacketTimedOut = false;
    hasReceivedNavPacket = true;
    displayDirty = true;
  }
  if (snapshot.wake) wakeDisplay();

  if (isStandby() || isWaitingForNavigation() ||
      (nav.direction == Direction::Stop && !rerouting)) {
    mapMotion.valid = false;
    mapMotion.active = false;
  }
  if (snapshot.navReady) {
    mapMotion.accept(snapshot.map, snapshot.routes, snapshot.roads,
                     static_cast<uint8_t>(snapshot.nav.direction), millis());
  }
}

void loop() {
  updatePairing();
  applyBleMailbox();
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
