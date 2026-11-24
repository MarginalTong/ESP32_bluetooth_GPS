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
  return bleConnected || hasReceivedNavPacket ||
         nav.direction == Direction::Arrived;
}

UiInputs captureUiInputs() {
  UiInputs inputs;
  // The BLE task owns pairing/auth changes; all other facts below belong to
  // loop(). Take this pair together instead of reading them during drawing.
  portENTER_CRITICAL(&stateMux);
  inputs.pairing = pairingActive;
  inputs.paired = keyRing.hasCurrent;
  portEXIT_CRITICAL(&stateMux);
  inputs.displayAvailable = displayAvailable;
  inputs.displayOn = displayPowerState != DisplayPowerState::Off;
  inputs.connected = bleConnected;
  inputs.hadConnection = hadBleConnection;
  inputs.hasNavigation = hasReceivedNavPacket;
  inputs.tripEnded = tripEnded;
  inputs.clockSynced = clockSynced;
  inputs.rerouting = rerouting;
  inputs.packetTimedOut = livePacketTimedOut;
  inputs.routePointCount = mapMotion.routes;
  inputs.navigation = nav;
  const uint32_t now = millis();
  arrivalFeedback.update(inputs.connected && inputs.hasNavigation &&
      !inputs.tripEnded && !inputs.rerouting && nav.direction == Direction::Arrived, now);
  inputs.arrivalElapsedMs = arrivalFeedback.elapsed(now);
  return inputs;
}

void refreshUiState() {
  const UiState next = resolveUiState(captureUiInputs());
  if (next.screen != uiState.screen) {
    Serial.printf("[UI] %s -> %s\n", uiScreenName(uiState.screen),
                  uiScreenName(next.screen));
  }
  if (next.screen != uiState.screen || next.connected != uiState.connected ||
      next.navigation.direction != uiState.navigation.direction ||
      next.navigation.distanceMeters != uiState.navigation.distanceMeters ||
      (next.screen == UiScreen::Arrived && next.arrivalProgress != uiState.arrivalProgress)) {
    displayDirty = true;
  }
  uiState = next;
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
