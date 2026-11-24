void renderDisplay(const UiState& state, bool blinkState) {
  char clockText[6] = "";
  if (state.screen == UiScreen::Clock) {
    const time_t now = time(nullptr);
    struct tm localClock;
    // The phone has already applied its local UTC offset.
    gmtime_r(&now, &localClock);
    snprintf(clockText, sizeof(clockText), "%02d:%02d", localClock.tm_hour,
             localClock.tm_min);
  }
  const UiRenderContext context = {
      DEVICE_NAME, clockText, SCREEN_HEIGHT,
#if NAV_ROUND_DISPLAY
      DISTANCE_TOP,
#else
      100.0f,
#endif
      float(DISTANCE_X)};
  renderUiScreen(state, context, blinkState);
}

// ======================================================
// State updates
// ======================================================

void updateLiveTimeout() {
  if (lastLivePacketMs == 0) return;
  if (isLiveFresh()) return;

  if (!livePacketTimedOut) {
    livePacketTimedOut = true;
    displayDirty = true;
  }

  // Keep the last direction: only an explicit STOP packet replaces it.
  // The UI resolver marks it as stale instead. The app re-sends every ~2 s
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
#if NAV_ROUND_DISPLAY
#if NAV_JC3636W518C
  Serial.println("[TFT] init JC3636W518C ST77916 QSPI (vendor command transactions)...");
#else
  Serial.println("[TFT] init Waveshare 1.46 SPD2010 QSPI...");
#endif
  pinMode(TFT_BACKLIGHT_PIN, OUTPUT);
  analogWrite(TFT_BACKLIGHT_PIN, 0);
#if NAV_WAVESHARE_146
  if (!Wire.begin(BOARD_I2C_SDA_PIN, BOARD_I2C_SCL_PIN, 400000) ||
      !resetRoundPanel()) {
    Serial.println("[TFT] TCA9554 reset failed (address 0x20)");
    return false;
  }
#endif
  if (!tft.begin(40000000)) {
    Serial.println("[TFT] QSPI initialization failed");
    return false;
  }
#if NAV_JC3636W518C
  tft.invertDisplay(true);  // Same polarity as the manufacturer's LCD demo.
#endif
  tft.fillScreen(COLOR_BG);
  analogWrite(TFT_BACKLIGHT_PIN, BACKLIGHT_NORMAL);
  panelComposer.init(PANEL_VIEW_WIDTH, PANEL_VIEW_HEIGHT, SCREEN_WIDTH, SCREEN_HEIGHT,
                     PANEL_SIZE / 2.0f - PANEL_VIEW_X, PANEL_SIZE / 2.0f - PANEL_VIEW_Y,
                     PANEL_VISIBLE_RADIUS, NATIVE_LAYER_SIZE, NATIVE_LAYER_SIZE);
  nativeLayer.pixels = static_cast<uint8_t*>(heap_caps_malloc(
      size_t(NATIVE_LAYER_SIZE) * NATIVE_LAYER_SIZE, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  if (nativeLayer.pixels != nullptr) {
    nativeLayer.width = NATIVE_LAYER_SIZE;
    nativeLayer.height = NATIVE_LAYER_SIZE;
    nativeLayer.clipBottom = NATIVE_LAYER_SIZE;
    nativeLayer.clear();
    Serial.printf("[TFT] NAVIO UI: %dx%d anti-aliased rendering -> %dx%d panel\n",
                  NATIVE_LAYER_SIZE, NATIVE_LAYER_SIZE, PANEL_VIEW_WIDTH, PANEL_VIEW_HEIGHT);
  } else {
    Serial.println("[TFT] NAVIO UI: low-resolution fallback (check OPI PSRAM setting)");
  }
#if NAV_JC3636W518C
  Serial.println("[TFT] ST77916 360x360 ready");
#else
  Serial.println("[TFT] SPD2010 412x412 ready");
#endif
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
