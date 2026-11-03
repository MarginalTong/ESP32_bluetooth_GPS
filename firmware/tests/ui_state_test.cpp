#include "ui_state.h"
#include "ui_screens.h"
#include "ui_draw.h"
#include "arrival_feedback.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

static void check(bool condition, const char* name) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", name);
    std::exit(1);
  }
}

static UiInputs boot() {
  UiInputs inputs;
  inputs.displayAvailable = true;
  return inputs;
}

static UiInputs guiding() {
  UiInputs inputs = boot();
  inputs.connected = inputs.hadConnection = inputs.paired = true;
  inputs.hasNavigation = true;
  inputs.routePointCount = 20;
  inputs.navigation = {Direction::Right, 117};
  return inputs;
}

static void expectPage(const UiInputs& inputs, UiScreen expected, const char* name) {
  const UiState state = resolveUiState(inputs);
  check(state.screen == expected, name);
  check(state.connected == inputs.connected &&
        state.navigation.direction == inputs.navigation.direction &&
        state.navigation.distanceMeters == inputs.navigation.distanceMeters,
        "a page decision must preserve frame-local navigation data");
}

static void transitions() {
  UiInputs inputs = boot();
  expectPage(inputs, UiScreen::Brand, "cold boot has no placeholder clock");
  inputs.clockSynced = true;
  expectPage(inputs, UiScreen::Brand, "a synced clock must not hide the disconnected brand");
  inputs.connected = true;
  expectPage(inputs, UiScreen::NotPaired, "connection alone does not mean ready");
  inputs.pairing = true;
  expectPage(inputs, UiScreen::Pairing, "BOOT prompt overrides unpaired state");
  inputs.pairing = false;
  inputs.paired = true;
  expectPage(inputs, UiScreen::Clock, "paired display waits for navigation");

  inputs = guiding();
  expectPage(inputs, UiScreen::Navigating, "new guidance starts navigation");
  inputs.packetTimedOut = true;
  expectPage(inputs, UiScreen::StaleGuidance, "expired guidance is not live");
  inputs.packetTimedOut = false;
  expectPage(inputs, UiScreen::Navigating, "a fresh packet restores live guidance");
  inputs.rerouting = true;
  expectPage(inputs, UiScreen::CachedRoute, "reroute retains geometry as context");
  inputs.packetTimedOut = true;
  expectPage(inputs, UiScreen::WaitingPhone, "reroute timeout keeps its own waiting page");
  inputs.routePointCount = 1;
  expectPage(inputs, UiScreen::Updating, "one point cannot form a cached route");
  inputs.routePointCount = 2;
  expectPage(inputs, UiScreen::WaitingPhone, "two points are enough for cached geometry");
  inputs.rerouting = false;
  inputs.navigation.direction = Direction::Stop;
  expectPage(inputs, UiScreen::NoGuidance, "explicit STOP takes priority over stale guidance");
  inputs.navigation.direction = Direction::Arrived;
  expectPage(inputs, UiScreen::Arrived, "arrival does not expire when the app stops sending");
  inputs.arrivalElapsedMs = 800;
  check(resolveUiState(inputs).arrivalProgress == 100, "check finishes after 800 ms");
  inputs.arrivalElapsedMs = 4000;
  expectPage(inputs, UiScreen::Brand, "arrival returns to standby without another packet");
  ArrivalFeedback feedback;
  feedback.update(true, UINT32_MAX - 100);
  feedback.update(true, 200);
  check(feedback.elapsed(200) == 301, "duplicate packets and millis wrap preserve timer");
  feedback.update(false, 300);
  feedback.update(true, 400);
  check(feedback.elapsed(500) == 100, "new trip gets a new celebration");

  inputs = guiding();
  inputs.tripEnded = true;
  inputs.hasNavigation = false;
  expectPage(inputs, UiScreen::Brand, "ending returns to NAVIO while still connected");
  inputs.connected = false;
  expectPage(inputs, UiScreen::Brand, "intentional disconnect after end stays on NAVIO");
  inputs.clockSynced = true;
  for (int attempt = 0; attempt < 5; ++attempt) {
    inputs.connected = true;
    expectPage(inputs, UiScreen::Brand, "connected end screen uses compact brand layout");
    inputs.connected = false;
    expectPage(inputs, UiScreen::Brand, "disconnect restores the large brand despite synced time");
  }

  inputs = guiding();
  inputs.connected = false;
  inputs.rerouting = inputs.packetTimedOut = true;
  expectPage(inputs, UiScreen::ConnectionLost, "unexpected disconnect overrides old route flags");
  inputs.connected = true;
  inputs.hasNavigation = false;
  expectPage(inputs, UiScreen::Brand, "reconnect does not resurrect old guidance");
  inputs = guiding();
  inputs.pairing = inputs.packetTimedOut = true;
  expectPage(inputs, UiScreen::Pairing, "pairing takes priority over a navigation warning");
  inputs.displayOn = false;
  expectPage(inputs, UiScreen::Off, "an off panel cannot show a pairing prompt");
  inputs.displayOn = true;
  inputs.displayAvailable = false;
  expectPage(inputs, UiScreen::Off, "an unavailable panel cannot render");
}

static void combinations() {
  // Adversarial combinations include old route flags left over during a
  // disconnect/reconnect; the transport normally clears them together.
  for (unsigned bits = 0; bits < (1u << 11); ++bits) {
    for (int direction = 0; direction <= int(Direction::Unknown); ++direction) {
      for (uint8_t points = 0; points <= 2; ++points) {
        UiInputs inputs;
        inputs.displayAvailable = bits & (1u << 0);
        inputs.displayOn = bits & (1u << 1);
        inputs.pairing = bits & (1u << 2);
        inputs.paired = bits & (1u << 3);
        inputs.connected = bits & (1u << 4);
        inputs.hadConnection = bits & (1u << 5);
        inputs.hasNavigation = bits & (1u << 6);
        inputs.tripEnded = bits & (1u << 7);
        inputs.clockSynced = bits & (1u << 8);
        inputs.rerouting = bits & (1u << 9);
        inputs.packetTimedOut = bits & (1u << 10);
        inputs.routePointCount = points;
        inputs.navigation = {Direction(direction), 25};
        const auto page = resolveUiState(inputs).screen;
        check((page == UiScreen::Off) == (!inputs.displayAvailable || !inputs.displayOn),
              "panel availability wins every flag combination");
        if (page == UiScreen::Navigating || page == UiScreen::Arrived) {
          check(inputs.connected && inputs.hasNavigation && !inputs.rerouting &&
                !inputs.pairing && inputs.navigation.direction != Direction::Stop,
                "live pages require a connected navigation session");
          check(!inputs.packetTimedOut || page == UiScreen::Arrived,
                "only arrival may remain live-looking after timeout");
        }
        if (page == UiScreen::CachedRoute || page == UiScreen::WaitingPhone) {
          check(inputs.connected && inputs.hasNavigation && inputs.rerouting && points >= 2,
                "cached pages require a route and a reroute session");
        }
        if (!inputs.connected) {
          check(page == UiScreen::Off || page == UiScreen::Pairing ||
                page == UiScreen::Brand ||
                page == UiScreen::ConnectionLost,
                "disconnected facts can never expose old guidance");
        }
        if (page == UiScreen::Clock)
          check(inputs.connected && inputs.clockSynced,
                "the clock is a connected-only standby page");
      }
    }
  }
}

// Board-free drawing spy: verifies that pages never expose a live rider or
// countdown on cached/stale guidance, and present exactly one complete frame.
static std::vector<std::string> calls;
static bool native = true;
static bool rider = false;
static NavState drawnNavigation = {Direction::Stop, 0};
struct BrandDraw {
  uint8_t size;
  float left, top;
  bool centered;
};
static std::vector<BrandDraw> brandDraws;

void beginFrame() { calls.push_back("begin"); }
void presentDisplay() { calls.push_back("present"); }
void drawUiText(const char* text, uint8_t size, float left, float top) {
  calls.push_back(text);
  if (std::string(text) == "NAVIO") brandDraws.push_back({size, left, top, false});
}
float uiTextWidth(const char*, uint8_t) { return 20; }
bool useNativeLayer() { return native; }
uint16_t roundTextHeight(const char*, uint8_t size) { return 7 * size; }
void drawRoundCenteredText(const char* text, uint8_t, int16_t) { calls.push_back(text); }
void drawRoundCenteredStatus(const char* text, uint8_t size, const char* subtitle, uint8_t) {
  calls.push_back(text);
  if (std::string(text) == "NAVIO") brandDraws.push_back({size, 120, 0, true});
  if (subtitle) calls.push_back(subtitle);
}
void drawStandbyBrandText(const char* text, bool primary) {
  calls.push_back(text);
  if (std::string(text) == "NAVIO" && primary) brandDraws.push_back({5, 120, 0, true});
}
void drawMiniRouteMap(bool showRider, Direction) {
  calls.push_back("route");
  rider = showRider;
}
void drawDirection(Direction direction) {
  calls.push_back("direction");
  drawnNavigation.direction = direction;
}
void drawDistance(const NavState& navigation, bool) {
  calls.push_back("distance");
  drawnNavigation = navigation;
}
void drawBottomError() { calls.push_back("diagnostic"); }
void drawArrivalCheck(uint8_t) { calls.push_back("check"); }

static bool drew(const char* call) {
  return std::find(calls.begin(), calls.end(), call) != calls.end();
}

static void drawPage(UiScreen page, bool connected = true) {
  calls.clear();
  brandDraws.clear();
  rider = false;
  const UiState state{page, connected, {Direction::Right, 117}};
  const UiRenderContext context{"NAVIO-TEST", "12:34", 240, 171, 132};
  renderUiScreen(state, context, true);
  const auto frames = std::count(calls.begin(), calls.end(), "present");
  check(frames == (page == UiScreen::Off ? 0 : 1), "one presentation per visible frame");
  if (page != UiScreen::Off) {
    check(calls.front() == "begin" && calls.back() == "present", "frame boundaries stay ordered");
  }
}

static void expectCompactBrand() {
  check(brandDraws.size() == 1, "connected idle page draws the brand exactly once");
  const auto& brand = brandDraws.front();
#if NAV_ROUND_DISPLAY
  check(brand.size == 2 && !brand.centered && brand.left == 38 && brand.top == 38,
        "compact round-panel brand is inset at the upper left");
#else
  check(brand.size == 2 && brand.left == 12 && brand.top == 8,
        "compact legacy-panel brand stays above the clock");
#endif
}

static void expectLargeBrand() {
  check(brandDraws.size() == 1, "disconnected page draws the brand exactly once");
  const auto& brand = brandDraws.front();
#if NAV_ROUND_DISPLAY
  check(brand.centered && brand.size == 5, "disconnected round-panel brand restores its full size");
#else
  check(brand.size == 4 && brand.left == 60 && brand.top == 35,
        "disconnected legacy-panel brand restores its centered position");
#endif
}

static void pages() {
  for (int value = 0; value <= int(UiScreen::Arrived); ++value) {
    const auto page = UiScreen(value);
    drawPage(page);
    const bool live = page == UiScreen::Navigating;
    check(drew("distance") == live && rider == live,
          "only active navigation shows rider and distance");
    if (page == UiScreen::Navigating || page == UiScreen::Arrived ||
        page == UiScreen::CachedRoute || page == UiScreen::WaitingPhone ||
        page == UiScreen::StaleGuidance)
      check(brandDraws.empty(), "branding never obscures route or maneuver geometry");
  }
  drawPage(UiScreen::CachedRoute);
  check(drew("CACHED ROUTE") && drew("UPDATING...") && !drew("direction"),
        "reroute context does not show a turn cue");
  drawPage(UiScreen::WaitingPhone);
  check(drew("WAITING PHONE") && drew("route"), "waiting keeps cached geometry");
  drawPage(UiScreen::Updating);
  check(drew("UPDATING...") && !drew("route"), "no invented geometry while updating");
  drawPage(UiScreen::StaleGuidance);
  check(drew("CHECK PHONE") && drew("direction") && !drew("distance"),
        "stale guidance retains context but never a countdown");
  drawPage(UiScreen::Navigating);
  check(drawnNavigation.direction == Direction::Right && drawnNavigation.distanceMeters == 117,
        "renderer receives the selected frame's maneuver and distance");
  drawPage(UiScreen::Brand, false);
  expectLargeBrand();
  check(drew("NAVIO") && drew("CONNECT PHONE"), "disconnected brand asks for a phone");
  drawPage(UiScreen::Brand, true);
  expectCompactBrand();
#if NAV_ROUND_DISPLAY
  check(drew("READY TO GO"), "connected round-panel brand is ready");
  native = false;
  drawPage(UiScreen::Brand, true);
  expectCompactBrand();
  drawPage(UiScreen::Brand, false);
  expectLargeBrand();
  check(drew("NAVIO") && drew("CONNECT PHONE"), "fallback font keeps the same brand state");
  native = true;
#else
  check(drew("ready to go"), "connected legacy-panel brand is ready");
#endif
  drawPage(UiScreen::Clock, true);
  expectCompactBrand();
  check(drew("12:34") && drew("ready to go"), "clock gets the supplied time and connection subtitle");
  drawPage(UiScreen::Clock, false);
  expectLargeBrand();
  check(drew("NAVIO") && drew("CONNECT PHONE") && !drew("12:34") && !drew("ready to go"),
        "disconnected clock restores the brand instead of claiming ready");
  drawPage(UiScreen::ConnectionLost, false);
  expectLargeBrand();
  check(drew("CONNECTION LOST") && drew("RECONNECT PHONE") && !drew("route"),
        "unexpected disconnect restores branding without hiding the loss warning");
  drawPage(UiScreen::NotPaired, true);
  expectCompactBrand();
  check(drew("NOT PAIRED"), "compact branding never replaces the pairing warning");
}

int main() {
  transitions();
  combinations();
  pages();
  std::printf("UI state/render: 55,296 combinations + transitions/pages passed (round=%d)\n",
              NAV_ROUND_DISPLAY);
}
