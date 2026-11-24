// ======================================================
// Hardware
// ======================================================

// Keep the old panel's layout; give the round panel a square map/instruction
// layout instead of letterboxing the 240x135 strip in the middle of the LCD.
constexpr int16_t SCREEN_WIDTH = 240;
#if NAV_ROUND_DISPLAY
constexpr int16_t SCREEN_HEIGHT = 240;
#else
constexpr int16_t SCREEN_HEIGHT = 135;
#endif

// Route-preview points use the old 128x64 coordinate system, scaled into the
// large TFT map. Current apps send them in tenths ("P"/"R"); older ones send
// whole units ("p"/"r").
constexpr int16_t ROUTE_SOURCE_WIDTH = 128;
constexpr int16_t ROUTE_SOURCE_HEIGHT = 64;

#if NAV_ROUND_DISPLAY
// Output always fills the physical panel; rendering resolution is independent.
constexpr int16_t PANEL_VIEW_WIDTH = PANEL_SIZE;
constexpr int16_t PANEL_VIEW_HEIGHT = PANEL_SIZE;
constexpr int16_t PANEL_VIEW_X = (PANEL_SIZE - PANEL_VIEW_WIDTH) / 2;
constexpr int16_t PANEL_VIEW_Y = (PANEL_SIZE - PANEL_VIEW_HEIGHT) / 2;
constexpr int16_t PANEL_VISIBLE_RADIUS = PANEL_SIZE / 2 - 3;
constexpr int16_t NATIVE_LAYER_SIZE = NAVIO_RENDER_SIZE;
static_assert(NAVIO_RENDER_SIZE >= SCREEN_WIDTH && NAVIO_RENDER_SIZE <= PANEL_SIZE,
              "Render size must be between the logical canvas and physical panel");
static_assert(PANEL_VIEW_WIDTH * SCREEN_HEIGHT == PANEL_VIEW_HEIGHT * SCREEN_WIDTH,
              "Preserve the logical canvas aspect ratio");
Arduino_ESP32QSPI lcdBus(TFT_CS_PIN, TFT_SCLK_PIN, TFT_DATA0_PIN,
                        TFT_DATA1_PIN, TFT_DATA2_PIN, TFT_DATA3_PIN);
#if NAV_JC3636W518C
// Apply inversion explicitly below; Arduino_GFX XORs it with the IPS flag.
Arduino_ST77916 tft(&lcdBus, TFT_RESET_PIN, TFT_PANEL_ROTATION, false,
                    PANEL_SIZE, PANEL_SIZE,
                    0, 0, 0, 0, jc3636_qspi_init, sizeof(jc3636_qspi_init));
#else
Arduino_SPD2010 tft(&lcdBus, GFX_NOT_DEFINED);
#endif
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
#if NAV_JC3636W518C
// Full backlight lifts this IPS panel's black to a bluish grey around white
// UI; a lower level keeps black darker. Raise it if sunlight demands.
constexpr uint8_t BACKLIGHT_NORMAL = 160;
#else
constexpr uint8_t BACKLIGHT_NORMAL = 255;
#endif
constexpr uint8_t BACKLIGHT_DIM = 24;

GFXcanvas16 display(SCREEN_WIDTH, SCREEN_HEIGHT);

constexpr uint16_t COLOR_BG = 0x0000;
constexpr uint16_t COLOR_WHITE = 0xFFFF;
constexpr uint16_t COLOR_ROUTE = COLOR_WHITE;
// Primary indications are white; side-road edges fade through grayscale.
constexpr uint16_t COLOR_ACCENT = COLOR_WHITE;
bool displayAvailable = false;
volatile bool displayDirty = true;

// ======================================================
// Product behavior
// ======================================================

// If the phone stops sending navigation packets, stop showing a stale turn.
constexpr uint32_t LIVE_PACKET_TIMEOUT_MS = 8000;

// TFT power policy. BLE keeps running while the display is dim/off.
constexpr uint32_t DISPLAY_DIM_AFTER_IDLE_MS = 15000;
constexpr uint32_t DISPLAY_OFF_AFTER_IDLE_MS = 60000;
// At most 40 route-animation frames per second (25 ms between frame starts).
// The loop still draws only when displayDirty; static navigation does not
// continuously redraw. Actual panel FPS also depends on render/SPI time.
constexpr uint32_t DISPLAY_REFRESH_MS = 25;

constexpr int MAX_DISTANCE_M = 9999;
constexpr uint8_t MAX_ROUTE_PREVIEW_POINTS = 20;
// Every junction arm in view is drawn; the phone sends the nearest first and
// keeps the packet within the size limit in NavWriteCallbacks.
constexpr uint8_t MAX_SIDE_ROAD_SEGMENTS = MapMotion::kRoadSegments;

// ======================================================
// BLE contract - must match the Flutter app.
// ======================================================

char DEVICE_NAME[20] = "NAVIO";
char deviceIdentity[13] = "";
// Waveshare's BOOT button pulls GPIO0 low. Never hold it while resetting,
// because GPIO0 is also the ESP32-S3 download-mode strap.
constexpr int8_t BOOT_BUTTON_PIN = 0;
volatile bool pairingActive = false;
volatile bool pairingVerified = false;
volatile bool pairingButtonReleased = false;
volatile uint32_t pairingStartedMs = 0;
uint32_t bootLowSinceMs = 0;
// Power-up pairing: one pairing per power-on, only within PAIR_WINDOW_MS.
volatile bool pairWindowUsed = false;
// A pairing request arrived after the window closed; told to the phone.
volatile bool pairingRefused = false;
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

NavState nav = {Direction::Stop, 0, 0};
bool rerouting = false;
bool clockSynced = false;
UiState uiState;
ArrivalFeedback arrivalFeedback;

// Placed after the enum declarations: the Arduino preprocessor inserts its
// generated prototypes before the first function definition.
