# Persistent project workflow

These are explicit user preferences for this repository:

- Make a Git commit after each completed, meaningfully verified step so the
  user can roll back individual changes. Report the commit IDs at handoff.
- Before trying an experimental implementation or alternative approach,
  create and switch to a clearly named experiment branch. Preserve a
  committed baseline before changing the behavior being compared.
- Preserve pre-existing edits and staged changes. Commit explicit paths for
  the current task; do not absorb unrelated work into a checkpoint.
- Do not automatically push, merge, reset, or discard changes.
- For App changes, default to local tests and static analysis. Do not routinely
  build for or install/launch on the user's phone. Request fresh confirmation
  when device validation is needed; earlier installation approval is not a
  standing authorization for later changes.

## Firmware development

- The public product name is **NAVIO**, not NAVO or Moto Nav. Keep App UI,
  platform display names, firmware screens and documentation consistent.
  Preserve historical package/Bundle IDs, BLE UUIDs, storage keys and the
  internal `.navo` monitor directory unless an explicit migration is requested.

- Use PlatformIO for builds and uploads; do not use Arduino CLI or Arduino IDE.
- The connected replacement board is JC3636W518C (ESP32-S3R8, ST77916,
  360×360, 16MB Flash). The current environment is `jc3636w518c` in the root
  `platformio.ini`. `waveshare_146` is retained only for the old board; do not
  power or flash the damaged old screen.
- VS Code and the assistant share the monitor managed by
  `firmware/tools/navo_monitor.py`; read `.navo/serial.log` instead of opening a
  competing serial connection. PlatformIO upload hooks release/resume it.
- Keep build outputs, serial logs and credentials out of Git.

## Maintainability rules

These apply to all code in this repository. Existing code that breaks a rule
is not rewritten wholesale; it is brought into line when that code is changed.

Standing instruction from the user: every change tidies up **each whole file
it touches**, not just the edited lines, without being asked. For every file a
change edits, bring the entire file in line with these rules: UI text and
colors moved to their homes, missing tests added, oversized functions and
files split by responsibility into their own modules with tests (the large
files `esp32_nav_display.ino`, `AppDelegate.swift` and
`navigation_controller.dart` included). Do the tidy-up as its own commit(s)
before the behavior change, so either can be reverted alone, and say in the
handoff what was reorganized. Files the change does not edit are left alone.

### Verification

- `bash tools/check.sh` runs every local check: App analysis and tests,
  firmware host tests, monitor tests and database migration tests. It must
  pass before each commit. Add `--firmware-build` when firmware changed.
- A behavior change ships with a test in the same commit. A bug fix includes a
  test that fails without the fix. Do not weaken or delete a test to make a
  change pass; change it only when the specified behavior changed.
- Logic that can run off the device is written so it can be tested on the
  host: firmware logic in `firmware/platformio/*.h|.cpp` with a test under
  `firmware/tests/`, App logic in services/controllers rather than widgets.

### Size and structure

- Do not add new features to the largest files:
  `esp32_nav_display.ino`, `AppDelegate.swift`,
  `navigation_controller.dart`. Put new firmware behavior in a module under
  `firmware/platformio/`, new iOS native code in its own Swift file, and new
  App logic in a new service or controller.
- Guide limits for new or touched code: a Dart file about 400 lines, a
  function about 60 lines. Beyond that, split by responsibility first.
- App layers point one way: `ui` → `controllers` → `services` → `models`.
  Services and models never import widgets or take a `BuildContext`.
  `AppText.current` is only for code that has no context.

### Contracts between App, firmware and backend

- The BLE contract is defined in `firmware/README.md` ("BLE contract") and
  `lib/config/ble_constants.dart`. Change both sides, their tests and the
  README in one commit. New packet or pairing fields are optional, so older
  App or firmware builds keep working.
- Database migrations are append-only: never edit a migration that may have
  been applied; add a new one. Each migration gets a test in
  `supabase/tests/` and is listed in its `package.json`. RPCs take identity
  from `auth.uid()`, never from client input. When the App depends on a new
  migration, say that it must be applied before the App is installed.

### App code

- All user-visible text lives in `lib/l10n/app_text.dart` (spoken guidance in
  `services/guidance/guidance_phrases.dart`). No new inline
  `en ? '…' : '…'` strings in widgets.
- Colors, type and spacing come from `ui/navio_theme.dart` or Cupertino
  dynamic colors. No new `Color(0x…)` literals in widgets.
- When the user asks to remove a feature, remove its code, assets, settings
  and tests in the same change; do not leave it behind a flag.

### Firmware code

- Board differences live in `firmware/platformio/board_config.h`. Elsewhere
  use the named constants or `NAV_*` flags it defines; never repeat a pin
  number or panel size.
- Every hardware value (pins, register tables, timings) names its source in a
  comment: schematic, vendor file or factory image. Values copied from a
  source are extracted by script, not retyped.
- Visual tuning (backlight, rendering, panel registers) is changed in one
  place and recorded in `firmware/README.md` with the reason.

### Comments and documentation

- Comments explain why, not what the next line does. Unexplained constants
  get a comment with their unit and origin.
- Keep `firmware/README.md` and the relevant `moto_nav_bridge/docs/` page
  current in the same commit as the behavior they describe; delete notes about
  removed code instead of keeping history in docs (Git keeps it).
