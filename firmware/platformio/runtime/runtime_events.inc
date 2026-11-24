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
#if NAV_PAIR_ON_POWER_UP
  // The request already arrived inside the power-up window: confirm it, and
  // close the window so a second phone cannot pair before the next power-on.
  if (pairingActive) {
    pairingActive = false;
    pairWindowUsed = true;
    changed = confirmed = true;
  }
#else
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
#endif
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
  Serial.println(sameConnection ? (NAV_PAIR_ON_POWER_UP
                                     ? "[BLE] Pairing confirmed within power-up window"
                                     : "[BLE] Pairing confirmed with BOOT")
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
    // Counted, so a drop/reconnect between iterations also marks the old
    // snapshot stale until a new authenticated navigation packet arrives.
    seenDisconnects = snapshot.disconnects;
    navigationContinuity.linkLost();
    livePacketTimedOut = navigationContinuity.awaitingFresh;
    mapMotion.active = false;
    displayDirty = true;
  }
  if (snapshot.connected) hadBleConnection = true;
  bleConnected = snapshot.connected;
  clockSynced = snapshot.clockSynced;
  displayClockOffset = snapshot.utcOffset;
  displayUtcClockReady = snapshot.utcReady;
  if (snapshot.errorReady) setLastError(snapshot.error);
  if (snapshot.navReady) {
    navigationContinuity.accept(snapshot.nav, snapshot.tripEnded, snapshot.rerouting,
                                 snapshot.routes >= 2);
    nav = navigationContinuity.lastValid;
    rerouting = snapshot.rerouting || navigationContinuity.awaitingFresh;
    tripEnded = snapshot.tripEnded;
    if (tripEnded || !navigationContinuity.awaitingFresh) {
      lastLivePacketMs = tripEnded ? 0 : millis();
      liveExpiryUtc = snapshot.expiryUtc;
    }
    livePacketTimedOut = navigationContinuity.awaitingFresh;
    hasReceivedNavPacket = navigationContinuity.active;
    displayDirty = true;
  }
  if (snapshot.wake) wakeDisplay();

  if (!hasReceivedNavPacket || tripEnded) {
    mapMotion.valid = false;
    mapMotion.active = false;
  }
  if (!bleConnected || livePacketTimedOut) mapMotion.active = false;
  if (snapshot.navReady && !snapshot.tripEnded && snapshot.routes >= 2) {
    mapMotion.accept(snapshot.map, snapshot.routes, snapshot.roads, millis());
    if (livePacketTimedOut) mapMotion.active = false;
  }
}

// Aggregate actual frame work; idle gaps are deliberately not called low FPS.
// A 40 FPS target leaves 25 ms per frame, including panel transfer.
void reportRenderTiming(uint32_t frameUs, uint32_t transferUs) {
  static uint32_t frames = 0, peakUs = 0, lastReportMs = 0;
  static uint64_t totalUs = 0, totalTransferUs = 0;
  ++frames;
  totalUs += frameUs;
  totalTransferUs += transferUs;
  if (frameUs > peakUs) peakUs = frameUs;
  const uint32_t now = millis();
  if (lastReportMs != 0 && now - lastReportMs < 5000) return;
  Serial.printf("[RENDER] frames=%lu frame_ms=%.1f max_ms=%.1f cpu_ms=%.1f lcd_ms=%.1f budget_ms=%lu\n",
                static_cast<unsigned long>(frames), double(totalUs) / frames / 1000.0,
                peakUs / 1000.0, double(totalUs - totalTransferUs) / frames / 1000.0,
                double(totalTransferUs) / frames / 1000.0,
                static_cast<unsigned long>(DISPLAY_REFRESH_MS));
  frames = peakUs = 0;
  totalUs = totalTransferUs = 0;
  lastReportMs = now;
}
