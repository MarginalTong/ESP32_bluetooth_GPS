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
- The current environment is `waveshare_146` in the root `platformio.ini`.
- VS Code and the assistant share the monitor managed by
  `firmware/tools/navo_monitor.py`; read `.navo/serial.log` instead of opening a
  competing serial connection. PlatformIO upload hooks release/resume it.
- Keep build outputs, serial logs and credentials out of Git.
