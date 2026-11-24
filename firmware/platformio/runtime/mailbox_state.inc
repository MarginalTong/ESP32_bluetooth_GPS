// Native-resolution drawing: platformio/gray_layer.h.

// Explicit: the generated prototype would precede the KeyRing declaration.
bool persistKeyRing(const KeyRing& ring);

constexpr uint8_t MAP_VALUE_COUNT =
    MAX_ROUTE_PREVIEW_POINTS * 2 + MAX_SIDE_ROAD_SEGMENTS * 4;
static_assert(MAP_VALUE_COUNT == MapMotion::kValues &&
                  MAX_ROUTE_PREVIEW_POINTS * 2 == MapMotion::kRouteValues,
              "MapMotion's layout matches the packet limits");

// BLE callbacks run on the Bluetooth stack's FreeRTOS task. They only publish
// into this mailbox under stateMux; loop() takes a snapshot each iteration and
// owns every navigation, timeout, error and backlight variable.
struct BleMailbox {
  bool connected = false;
  uint32_t disconnects = 0;
  bool clockSynced = false;
  bool navReady = false;
  NavState nav = {Direction::Stop, 0, 0};
  bool rerouting = false;
  bool tripEnded = false;
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
#if NAV_ROUND_DISPLAY
// The whole UI at the panel's native resolution, in PSRAM. Drawing code keeps
// the 240x240 canvas coordinates and scales them. Without PSRAM everything is
// drawn into the canvas and upscaled, as before.
GrayLayer nativeLayer;
// Text is rasterized once and reused: platformio/text_cache.h.
TextCache textCache;
// The only colour on the panel: platformio/speed_limit_sign.h.
SpeedLimitSign speedLimitSign;
// The sprite to compose over the current frame; cleared once presented.
const ColorSprite* frameSprite = nullptr;
PanelComposer panelComposer;
// Set when the current frame drew into nativeLayer; cleared once presented.
bool nativeLayerDrawn = false;
#endif

uint32_t lastLivePacketMs = 0;
bool hasReceivedNavPacket = false;
bool tripEnded = false;
bool livePacketTimedOut = false;
uint32_t rejectedPacketCount = 0;
char lastError[48] = "";
uint32_t lastFrameTransferUs = 0;

// Arduino's .ino preprocessor sometimes generates function prototypes before
// custom enum classes are declared, which breaks types like Direction and
// DisplayPowerState. Keep explicit prototypes here so the generated sketch
// compiles reliably in Arduino IDE.
Direction parseDirection(const char* value);
const char* directionName(Direction direction);
void setDisplayPower(DisplayPowerState state);
void presentDisplay();
void drawDirection(Direction direction);
void drawMiniRouteMap(bool showRider, Direction direction);
#if NAV_ROUND_DISPLAY
void drawRoundCenteredText(const char* value, uint8_t size, int16_t top);
#endif
