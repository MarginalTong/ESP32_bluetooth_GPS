#include <cstdio>
#include <cstdlib>
#include <vector>
#include "instrument_clock.h"

static void check(bool value, const char* message) {
  if (!value) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}

static void geometry() {
  int hour, minute;
  check(!InstrumentClock::parse(nullptr, hour, minute), "null rejected");
  for (const char* invalid : {"", "1:23", "24:00", "12:60", "12:3x", "12-30", "12:30x"})
    check(!InstrumentClock::parse(invalid, hour, minute), "bad time rejected");
  for (int h = 0; h < 24; ++h) {
    for (int m = 0; m < 60; ++m) {
      char time[6];
      snprintf(time, sizeof(time), "%02d:%02d", h, m);
      check(InstrumentClock::parse(time, hour, minute) && hour == h && minute == m,
            "all 1440 valid minutes preserve 24-hour value");
    }
  }
  check(fabsf(InstrumentClock::hourAngle(3, 0) - 1.5707963f) < 0.0001f, "three points right");
  check(fabsf(InstrumentClock::minuteAngle(30) - 3.1415927f) < 0.0001f, "30 points down");
  check(InstrumentClock::hourAngle(3, 30) > InstrumentClock::hourAngle(3, 0),
        "hour hand advances with minutes");
  check(InstrumentClock::hourAngle(0, 0) == InstrumentClock::hourAngle(12, 0),
        "12-hour hand wraps at noon");
}

static void preview(const ColorSprite& sprite, const char* path) {
  FILE* out = fopen(path, "wb");
  check(out != nullptr, "preview opened");
  fprintf(out, "P6\n%d %d\n255\n", sprite.width, sprite.height);
  for (int i = 0; i < sprite.width * sprite.height; ++i) {
    const uint16_t p = sprite.pixels[i];
    const uint8_t rgb[] = {uint8_t((p >> 11) * 255 / 31),
                          uint8_t(((p >> 5) & 63) * 255 / 63), uint8_t((p & 31) * 255 / 31)};
    fwrite(rgb, 1, 3, out);
  }
  fclose(out);
}

int main(int argc, char** argv) {
  geometry();
  InstrumentClock clock;
  for (int size : {240, 360, 412}) {
    check(clock.prepare("10:08", size), "supported canvas renders");
    const auto count = clock.renders;
    check(clock.prepare("10:08", size) && clock.renders == count, "same minute uses cache");
    std::vector<uint16_t> previous(clock.sprite.pixels, clock.sprite.pixels + size * size);
    check(clock.prepare("10:09", size) && clock.renders == count + 1, "new minute redraws");
    int changed = 0, red = 0, warm = 0, shades = 0;
    for (int i = 0; i < size * size; ++i) {
      const uint16_t p = clock.sprite.pixels[i];
      check(p != 0, "opaque clock prevents old page leaking through");
      changed += p != previous[i];
      const int r = (p >> 11) * 255 / 31, g = ((p >> 5) & 63) * 255 / 63;
      red += r > 150 && g < 90;
      warm += r > 150 && g > 120;
      shades += r > 20 && r < 150;
    }
    check(changed > 50 && red > 20 && warm > 200 && shades > 200,
          "hands move, face is ivory, minute hand red, edges have coverage shades");
  }
  const auto count = clock.renders;
  check(!clock.prepare("bad", 360) && !clock.prepare("10:00", 10) && clock.renders == count,
        "invalid input does not replace cached frame");
  check(clock.prepare("10:30", 360), "downward minute hand renders");
  for (int y = 220; y < 252; ++y) {
    for (int x = 126; x < 234; ++x) {
      const uint16_t p = clock.sprite.pixels[y * 360 + x];
      const int r = (p >> 11) * 255 / 31, g = ((p >> 5) & 63) * 255 / 63;
      check(!(r > 150 && g < 90), "minute hand cannot obscure digital time window");
    }
  }
  if (argc > 1) { check(clock.prepare("10:08", 360), "preview rendered"); preview(clock.sprite, argv[1]); }
  puts("Instrument clock: time geometry, rendering, colour and cache passed");
}
