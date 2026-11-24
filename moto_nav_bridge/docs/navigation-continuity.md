# Navigation continuity

## Confirmed reset paths (2026-11-24)

- ESP32 `ServerCallbacks::onDisconnect` increments the mailbox disconnect
  counter. `applyBleMailbox` previously cleared navigation, packet age and
  maneuver state, then invalidated `mapMotion`. `resolveUiState` prioritised
  disconnected -> `ConnectionLost`; `renderUiScreen` drew the NAVIO brand.
- Flutter does not call End or change tabs on BLE loss. `AppShell` keeps the
  map inside an IndexedStack. `NavigationController` keeps the route/session
  on GPS errors, but previously sent a geometry-free STOP packet, causing the
  display's fullscreen NoGuidance page.
- BLE already retries the bound display at 1/2/4/8 seconds, then ten seconds,
  later thirty seconds. Reconnection creates a fresh signed session nonce.
  The old pending-state flush accepted navigation up to ten seconds old;
  reconnection needs explicit GPS-quality-aware synchronisation instead.

## Module boundaries

BLE scanning, pairing/discovery and writes are private library parts of
`BleService`. Firmware runtime fragments preserve translation-unit order;
the sketch keeps entrypoints and the host-tested authentication block.
Hardware registers, pins, panel setup and visual parameters are unchanged by
this extraction. The user's pre-existing gray-layer edits remain uncommitted
(the rendering fragment now owns the moved code).
