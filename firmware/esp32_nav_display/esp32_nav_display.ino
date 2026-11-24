#include "../platformio/board_config.h"
#include <SPI.h>
#include <Adafruit_GFX.h>
#if NAV_ROUND_DISPLAY
#include <Wire.h>
#include <Arduino_GFX_Library.h>
#if NAV_JC3636W518C
#include "../platformio/jc3636_panel_init.h"
#endif
#include <Fonts/FreeSans9pt7b.h>
#include <Fonts/FreeSansBold18pt7b.h>
#include <Fonts/FreeSansBold24pt7b.h>
#if !defined(CONFIG_IDF_TARGET_ESP32S3)
#error "Select an ESP32-S3 target for the round display boards"
#endif
#else
#include <Adafruit_ST7789.h>
#endif

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#include <ArduinoJson.h>
// Both builds compile the ROUTE RENDER block, which uses them.
#include "numeric_font.h"
#include "text_font.h"
#include <Preferences.h>
#include <esp_random.h>
#include <esp_system.h>
#include <mbedtls/md.h>
#include <time.h>
#include <sys/time.h>
#include <stdint.h>
#include <math.h>
#include <esp_system.h>
#include <esp_heap_caps.h>
#include "../platformio/ui_screens.h"
#include "../platformio/ui_draw.h"
#include "../platformio/arrival_feedback.h"
#include "../platformio/gray_layer.h"
#include "../platformio/instruction_layout.h"
#include "../platformio/map_motion.h"
#include "../platformio/side_road_ray.h"
#include "../platformio/speed_limit_sign.h"
#include "../platformio/text_cache.h"

#include "../platformio/runtime/hardware.inc"

// BEGIN PACKET AUTH - also compiled by the host authentication tests.
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

#include "../platformio/runtime/mailbox_state.inc"

#include "../platformio/runtime/runtime_support.inc"

#include "../platformio/runtime/ble_callbacks.inc"

#include "../platformio/runtime/render_primitives.inc"

#include "../platformio/runtime/render_geometry.inc"

#include "../platformio/runtime/render_instructions.inc"

#include "../platformio/runtime/display_lifecycle.inc"

void setup() {
  pinMode(BOOT_BUTTON_PIN, INPUT_PULLUP);
  const uint64_t chipId = ESP.getEfuseMac();
  snprintf(deviceIdentity, sizeof(deviceIdentity), "%04X%08lX",
           static_cast<unsigned int>((chipId >> 32) & 0xffff),
           static_cast<unsigned long>(chipId & 0xffffffff));
  snprintf(DEVICE_NAME, sizeof(DEVICE_NAME), "NAVIO-%s", deviceIdentity);
  Serial.begin(115200);
  delay(100);
  Serial.println();
  Serial.println("[BOOT] ESP32 navigation display");
  Serial.print("[BOOT] reset reason: ");
  Serial.println(resetReasonName(esp_reset_reason()));

  displayAvailable = initDisplay();
  if (!displayAvailable) {
    Serial.println("[TFT] init failed");
    Serial.println("[TFT] continuing without display so BLE still works");
  } else {
    refreshUiState();
    renderDisplay(uiState, true);
  }
  wakeDisplay();

  loadAuthKey();
  setupBle();
  Serial.println("[BOOT] Ready");
}

#include "../platformio/runtime/runtime_events.inc"

void loop() {
  updatePairing();
  applyBleMailbox();
  updateLiveTimeout();
  updateDisplayPower();
  refreshUiState();
  if (mapMotion.tick(millis())) displayDirty = true;
  static time_t lastClockMinute = -1;
  const time_t clockMinute = time(nullptr) / 60;
  if (clockMinute != lastClockMinute) {
    lastClockMinute = clockMinute;
    if (uiState.screen == UiScreen::Clock) displayDirty = true;
  }
  static bool blinkState = true;
  static uint32_t lastBlinkMs = 0;
  static uint32_t lastRenderMs = 0;

  if (millis() - lastBlinkMs > 300) {
    blinkState = !blinkState;
    lastBlinkMs = millis();
    if (uiState.screen == UiScreen::Navigating &&
        uiState.navigation.distanceMeters <= 30) {
      displayDirty = true;
    }
  }

  if (displayDirty && millis() - lastRenderMs >= DISPLAY_REFRESH_MS) {
    lastRenderMs = millis();
    // Clear before drawing so a BLE callback arriving during the SPI transfer
    // schedules another frame instead of having its update erased here.
    displayDirty = false;
    const uint32_t renderStartUs = micros();
    renderDisplay(uiState, blinkState);
    if (uiState.screen != UiScreen::Off)
      reportRenderTiming(micros() - renderStartUs, lastFrameTransferUs);
  }

  delay(5);
}
