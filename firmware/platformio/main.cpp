// Keep one firmware source for PlatformIO and the existing host tests.
// A C++ entry point avoids .ino conversion's shared temporary .ino.cpp file,
// which can be removed by a concurrent PlatformIO metadata/monitor request.
#include <Arduino.h>
// Expose core-library dependencies directly to PlatformIO's dependency finder.
#include <BLEDevice.h>
#include <Preferences.h>
#include "../esp32_nav_display/esp32_nav_display.ino"
