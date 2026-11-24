// ======================================================
// BLE
// ======================================================

// The stack keeps the last read response as the attribute value. Wipe it
// between connections so a later client (e.g. a Read Blob at an offset)
// cannot see a response that carried the pairing key.
void clearPairingValue() {
  if (pairingCharacteristic != nullptr) pairingCharacteristic->setValue("{}");
}

// Why the chip last started, reported to the phone on every pairing read so
// a dropped connection can be told apart from a crash or brownout reset.
const char* resetReasonName(esp_reset_reason_t reason) {
  switch (reason) {
    case ESP_RST_POWERON: return "poweron";
    case ESP_RST_EXT: return "ext";
    case ESP_RST_SW: return "sw";
    case ESP_RST_PANIC: return "panic";
    case ESP_RST_INT_WDT: return "int_wdt";
    case ESP_RST_TASK_WDT: return "task_wdt";
    case ESP_RST_WDT: return "wdt";
    case ESP_RST_DEEPSLEEP: return "deepsleep";
    case ESP_RST_BROWNOUT: return "brownout";
    case ESP_RST_SDIO: return "sdio";
    default: return "unknown";
  }
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
    pairingRefused = false;
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
    pairingRefused = false;
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

// Reads up to `maxItems` groups of `stride` route-source coordinates (x, y,
// ...) into `out`, preferring the tenths key over the legacy whole-unit one.
// Stops at the first malformed group; returns the number of groups read.
uint8_t readMapValues(JsonDocument& doc, const char* fineKey, const char* coarseKey,
                      float* out, uint8_t maxItems, uint8_t stride) {
  JsonArray values = doc[fineKey].as<JsonArray>();
  float scale = 0.1f;
  if (values.isNull()) {
    values = doc[coarseKey].as<JsonArray>();
    scale = 1.0f;
  }
  if (values.isNull()) return 0;
  uint8_t count = 0;
  while (count < maxItems && size_t(count + 1) * stride <= values.size()) {
    const size_t base = size_t(count) * stride;
    bool wellFormed = true;
    for (uint8_t i = 0; i < stride; ++i)
      wellFormed = wellFormed && values[base + i].is<int>();
    if (!wellFormed) break;
    for (uint8_t i = 0; i < stride; ++i) {
      const float limit = (i % 2 == 0 ? ROUTE_SOURCE_WIDTH : ROUTE_SOURCE_HEIGHT) - 1;
      const float value = values[base + i].as<int>() * scale;
      out[base + i] = value < 0.0f ? 0.0f : (value > limit ? limit : value);
    }
    ++count;
  }
  return count;
}

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
    // Optional; a missing or impossible limit shows no sign.
    const uint8_t speedLimit = SpeedLimitSign::valid(doc["L"] | 0L);

    const bool reroutingPacket = doc["rerouting"] | false;
    const bool endTripPacket = doc["end"] | false;
    if (endTripPacket && (direction != Direction::Stop || reroutingPacket)) {
      rejectedPacketCount++;
      publishError("bad end packet");
      return;
    }
    float mapValues[MAP_VALUE_COUNT] = {};
    const uint8_t routePreviewPointCount = readMapValues(
        doc, "P", "p", mapValues, MAX_ROUTE_PREVIEW_POINTS, 2);
    const uint8_t sideRoadSegmentCount =
        readMapValues(doc, "R", "r", mapValues + MapMotion::kRouteValues,
                      MAX_SIDE_ROAD_SEGMENTS, 4);

    // Publish the whole packet at once so loop() never sees a new direction
    // with the previous distance, flags or geometry.
    portENTER_CRITICAL(&stateMux);
    memcpy(mailbox.map, mapValues, sizeof(mailbox.map));
    mailbox.nav = {direction, distance, speedLimit};
    mailbox.rerouting = reroutingPacket;
    mailbox.tripEnded = endTripPacket;
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
    const bool refused = pairingRefused;
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

    const char* boot = resetReasonName(esp_reset_reason());
    const unsigned long uptime = millis() / 1000;
    // How this display confirms a pairing, so the app can say what to do.
    const char* confirm = NAV_PAIR_ON_POWER_UP ? "power" : "boot";
    char response[256];
    if (verified) {
      snprintf(response, sizeof(response),
               "{\"id\":\"%s\",\"verified\":true,\"s\":\"%s\",\"k\":\"%s\","
               "\"boot\":\"%s\",\"up\":%lu,\"confirm\":\"%s\"}",
               deviceIdentity, nonceHex, keyHex, boot, uptime, confirm);
    } else {
      snprintf(response, sizeof(response),
               "{\"id\":\"%s\",\"verified\":false,\"s\":\"%s\","
               "\"boot\":\"%s\",\"up\":%lu,\"confirm\":\"%s\"%s}",
               deviceIdentity, nonceHex, boot, uptime, confirm,
               refused ? ",\"replug\":true" : "");
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
#if NAV_PAIR_ON_POWER_UP
      if (pairWindowUsed || millis() >= PAIR_WINDOW_MS) {
        portENTER_CRITICAL(&stateMux);
        pairingRefused = true;
        portEXIT_CRITICAL(&stateMux);
        Serial.println("[BLE] Pairing refused: replug the display to pair");
        return;
      }
#endif
      portENTER_CRITICAL(&stateMux);
      pairingRefused = false;
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
