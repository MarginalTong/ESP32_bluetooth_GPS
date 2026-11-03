# NAVIO

Motorcycle navigation: an iPhone app plans the route and sends signed,
turn-by-turn guidance over Bluetooth LE to a round display on the handlebar.

```
 iPhone app (Flutter)  ── BLE, HMAC-signed packets ──▶  ESP32-S3 display
   │  route planning      direction, distance,            ST77916 360×360
   │  voice guidance      20-point route preview          anti-aliased UI
   │
   ├─▶ Valhalla routing server (VPS)        routes and reroutes
   └─▶ Supabase (accounts)                  profile, settings sync, rider map
```

## Repository

| Path | What it is | Details |
| --- | --- | --- |
| `moto_nav_bridge/` | Flutter app (iOS first; Android builds). Package and Bundle IDs keep their historical names. | [app README](moto_nav_bridge/README.md), [`docs/`](moto_nav_bridge/docs) |
| `firmware/` | Display firmware, host tests and tools. The source is `esp32_nav_display/`; `platformio/` holds the board config and UI modules. | [firmware README](firmware/README.md) |
| `supabase/` | Database migrations, their tests, and the `account-actions` edge function. | `supabase/tests/` |
| `platformio.ini` | Firmware build environments. `jc3636w518c` is the connected board. | |
| `tools/` | `check.sh` (all checks) and the maintainability rule guards. | [AGENTS.md](AGENTS.md) |

The Bluetooth contract (UUIDs, signed packet format, pairing) is specified in
[firmware/README.md](firmware/README.md) under "BLE contract" and mirrored in
`moto_nav_bridge/lib/config/ble_constants.dart`.

## Getting started

Tools: Flutter (stable), Xcode, PlatformIO (`~/.platformio/penv/bin/pio`),
Node.js for the database tests, and a C++ compiler for firmware host tests.

```sh
bash tools/check.sh                    # every check; run before each commit
bash tools/check.sh --firmware-build   # also compile all firmware boards
```

**App.** Account settings are passed at build time from a private file that is
not in Git (`.navo/accounts.test.json`). Always pass it: a plain
`flutter build`/`flutter run` regenerates the Xcode config without it, and the
app then says the account service is not configured.

```sh
cd moto_nav_bridge
flutter run --dart-define-from-file=../.navo/accounts.test.json
```

**Firmware.** Build and upload with PlatformIO only; read serial output from
the shared monitor log instead of opening the port again.

```sh
~/.platformio/penv/bin/pio run -e jc3636w518c -t upload
~/.platformio/penv/bin/python firmware/tools/navo_monitor.py view   # .navo/serial.log
```

**Database.** Migrations in `supabase/migrations/` are applied in order in the
Supabase SQL editor. Apply a new migration before installing an app build that
needs it.

## Working on the project

Read [AGENTS.md](AGENTS.md) first. It holds the workflow (commit per verified
step, experiment branches, no automatic push or merge) and the maintainability
rules every change follows, including the whole-file tidy-up recorded in
`tools/tidied_files.txt`.

Private material (credentials, the factory firmware backup, serial logs) lives
in `.navo/` and is never committed.
