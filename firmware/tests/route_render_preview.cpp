// Renders the round panel's map view the old way and the new way, side by
// side, so drawing changes can be judged without hardware.
// Run with: bash firmware/tests/run_route_render_preview.sh [out.ppm]
// The runner prepends the sketch's ROUTE RENDER block.
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vector>

// Waveshare 1.46 geometry, as in the sketch.
static const int kCanvas = 240, kView = 380, kViewOffset = 16, kPanel = 412;
static const float kScale = float(kView) / kCanvas;
static const float kMapLeft = 0, kMapRight = kCanvas - 1, kMapTop = 0, kMapBottom = 166;
static const int kMapClipBottom = 166 - 4;
static const float kZoom = 1.90f;
static const int kRouteStroke = 7;

static float mapX(float x) {
  const float center = (kMapLeft + kMapRight) / 2.0f;
  const float projected = kMapLeft + 6 + (x - 18) * (kMapRight - kMapLeft - 12) / 92.0f;
  return center + (projected - center) * kZoom;
}
static float mapY(float y) {
  const float anchor = kMapBottom - 12;
  const float projected = kMapTop + 25 + (y - 2) * (kMapBottom - kMapTop - 47) / 32.0f;
  return anchor + (projected - anchor) * 1.90f;
}

// The route ahead, in metres: straight for 30 m, then curving right.
struct Point { float x, y; };
static Point routeAt(float forward) {
  const float lateral = forward > 30 ? 0.0012f * (forward - 30) * (forward - 30) : 0.0f;
  // Phone projection: 32 source units per 200 m, rider at (64, 34).
  return {64 + lateral * 0.16f, 34 - forward * 0.16f};
}

// ---- Old pipeline ---------------------------------------------------------
static void putCanvas(std::vector<uint16_t>& c, int x, int y, uint16_t color) {
  if (x >= 0 && x < kCanvas && y >= 0 && y < kCanvas) c[y * kCanvas + x] = color;
}
static void line(std::vector<uint16_t>& c, int x0, int y0, int x1, int y1, uint16_t color) {
  int dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1, dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
  int err = dx + dy;
  for (;;) {
    putCanvas(c, x0, y0, color);
    if (x0 == x1 && y0 == y1) break;
    int e2 = 2 * err;
    if (e2 >= dy) { err += dy; x0 += sx; }
    if (e2 <= dx) { err += dx; y0 += sy; }
  }
}
static void thickLine(std::vector<uint16_t>& c, int x0, int y0, int x1, int y1, int thickness) {
  const int r = thickness / 2;
  for (int dx = -r; dx <= r; dx++)
    for (int dy = -r; dy <= r; dy++) line(c, x0 + dx, y0 + dy, x1 + dx, y1 + dy, 0xFFFF);
}
static void fillTri(std::vector<uint16_t>& c, int ax, int ay, int bx, int by, int cx, int cy,
                    uint16_t color) {
  for (int y = 0; y < kCanvas; ++y)
    for (int x = 0; x < kCanvas; ++x) {
      const float px = x, py = y;
      const float d1 = (px - bx) * (ay - by) - (ax - bx) * (py - by);
      const float d2 = (px - cx) * (by - cy) - (bx - cx) * (py - cy);
      const float d3 = (px - ax) * (cy - ay) - (cx - ax) * (py - ay);
      const bool neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0;
      if (!(neg && pos)) putCanvas(c, x, y, color);
    }
}
static void oldSideRoad(std::vector<uint16_t>& c, int x0, int y0, int x1, int y1) {
  const float dx = x1 - x0, dy = y1 - y0, length = sqrtf(dx * dx + dy * dy);
  const float ux = dx / length, uy = dy / length, visible = 48.0f;
  for (int y = 0; y < kMapClipBottom; ++y)
    for (int x = 0; x < kCanvas; ++x) {
      const float px = x - x0, py = y - y0, along = px * ux + py * uy;
      if (along < 0 || along >= visible) continue;
      const float edge = fabsf(fabsf(px * uy - py * ux) - 3.0f);
      if (edge >= 1.9f) continue;
      const float t = fmaxf(0, (along / visible - 0.45f) / 0.55f);
      const float fade = 1 - t * t * (3 - 2 * t);
      const uint8_t g = uint8_t(lroundf(245 * fade * (1 - edge / 1.9f)));
      const uint16_t color = ((g >> 3) << 11) | ((g >> 2) << 5) | (g >> 3);
      if (color > c[y * kCanvas + x]) c[y * kCanvas + x] = color;
    }
}

static std::vector<uint16_t> renderOld() {
  std::vector<uint16_t> canvas(kCanvas * kCanvas, 0);
  // Integer source grid, then 6 points picked by index (old phone code).
  std::vector<Point> screen;
  for (float f = 0; f <= 200; f += 1) {
    Point p = routeAt(f);
    Point q = {roundf(p.x), roundf(p.y)};
    if (screen.empty() || screen.back().x != q.x || screen.back().y != q.y) screen.push_back(q);
  }
  std::vector<Point> sampled;
  for (int i = 0; i < 6; ++i)
    sampled.push_back(screen[size_t(lroundf((screen.size() - 1) * i / 5.0f))]);
  // Side road crossing 80 m ahead, both arms.
  const Point j = {roundf(routeAt(80).x), roundf(routeAt(80).y)};
  oldSideRoad(canvas, lroundf(mapX(j.x)), lroundf(mapY(j.y)), lroundf(mapX(j.x - 10)),
              lroundf(mapY(j.y - 3)));
  oldSideRoad(canvas, lroundf(mapX(j.x)), lroundf(mapY(j.y)), lroundf(mapX(j.x + 10)),
              lroundf(mapY(j.y + 3)));
  for (size_t i = 0; i + 1 < sampled.size(); ++i)
    thickLine(canvas, lroundf(mapX(sampled[i].x)), lroundf(mapY(sampled[i].y)),
              lroundf(mapX(sampled[i + 1].x)), lroundf(mapY(sampled[i + 1].y)), kRouteStroke);
  const int mx = 119, my = 166 - 12;
  fillTri(canvas, mx, my - 21, mx - 18, my + 14, mx + 18, my + 14, 0);
  fillTri(canvas, mx, my - 12, mx - 10, my + 6, mx + 10, my + 6, 0xFFFF);
  for (int y = kMapClipBottom; y < kCanvas; ++y)
    for (int x = 0; x < kCanvas; ++x) canvas[y * kCanvas + x] = 0;
  // Old presentDisplay: nearest-neighbour upscale and circle test per pixel.
  std::vector<uint16_t> out(kView * kView, 0);
  const int r = kPanel / 2 - 3;
  for (int y = 0; y < kView; ++y)
    for (int x = 0; x < kView; ++x) {
      const int px = kViewOffset + x - kPanel / 2, py = kViewOffset + y - kPanel / 2;
      if (px * px + py * py <= r * r)
        out[y * kView + x] = canvas[(y * kCanvas / kView) * kCanvas + x * kCanvas / kView];
    }
  return out;
}

// ---- New pipeline -----------------------------------------------------------
// Canvas coordinate to the map layer, as the sketch's layerCoord().
static float layer(float canvasValue) { return (canvasValue + 0.5f) * kScale; }

static std::vector<uint16_t> renderNew() {
  // 20 points at equal arc length, 0.1-unit precision (new phone code).
  std::vector<Point> dense;
  for (float f = 0; f <= 200; f += 0.5f) dense.push_back(routeAt(f));
  std::vector<float> along(dense.size(), 0);
  for (size_t i = 1; i < dense.size(); ++i)
    along[i] = along[i - 1] + hypotf(dense[i].x - dense[i - 1].x, dense[i].y - dense[i - 1].y);
  float xy[40];
  for (int i = 0; i <= 19; ++i) {
    const float target = along.back() * i / 19.0f;
    size_t k = 1;
    while (k < dense.size() - 1 && along[k] < target) ++k;
    const float t = (target - along[k - 1]) / (along[k] - along[k - 1]);
    const float sx = dense[k - 1].x + (dense[k].x - dense[k - 1].x) * t;
    const float sy = dense[k - 1].y + (dense[k].y - dense[k - 1].y) * t;
    xy[i * 2] = layer(mapX(roundf(sx * 10) / 10));
    xy[i * 2 + 1] = layer(mapY(roundf(sy * 10) / 10));
  }
  std::vector<uint8_t> pixels(kView * kView, 0);
  GrayLayer map;
  map.pixels = pixels.data();
  map.width = kView;
  map.height = kView;
  map.clipBottom = int16_t(kMapClipBottom * kScale);
  const Point j = routeAt(80);
  for (int side = -1; side <= 1; side += 2) {
    const float x0 = layer(mapX(j.x)), y0 = layer(mapY(j.y));
    const float x1 = layer(mapX(j.x + side * 10)), y1 = layer(mapY(j.y + side * 3));
    const float dx = x1 - x0, dy = y1 - y0, length = hypotf(dx, dy);
    map.strokeFadingRails(x0, y0, dx / length, dy / length, 48 * kScale, 3 * kScale,
                            1.9f * kScale, 245);
  }
  map.strokePolyline(xy, 20, kRouteStroke * kScale / 2, 255);
  const float mx = layer(119), my = layer(166 - 12);
  map.fillTriangle(mx, my - 21 * kScale, mx - 18 * kScale, my + 14 * kScale,
                     mx + 18 * kScale, my + 14 * kScale, 0);
  map.fillTriangle(mx, my - 12 * kScale, mx - 10 * kScale, my + 6 * kScale,
                     mx + 10 * kScale, my + 6 * kScale, 255);
  static PanelComposer composer;
  const float center = kPanel / 2.0f - kViewOffset;
  composer.init(kView, kView, kCanvas, kCanvas, center, center, kPanel / 2.0f - 3);
  std::vector<uint16_t> canvas(kCanvas * kCanvas, 0), out(kView * kView, 0);
  composer.compose(canvas.data(), &map, out.data(), 0, kView);
  return out;
}

int main(int argc, char** argv) {
  const char* path = argc > 1 ? argv[1] : "route_preview.ppm";
  const std::vector<uint16_t> before = renderOld(), after = renderNew();
  FILE* f = fopen(path, "wb");
  if (!f) return 1;
  const int gap = 12;
  fprintf(f, "P6\n%d %d\n255\n", kView * 2 + gap, kView);
  for (int y = 0; y < kView; ++y)
    for (int x = 0; x < kView * 2 + gap; ++x) {
      uint16_t p = 0x2104;  // dark gray divider
      if (x < kView) p = before[y * kView + x];
      else if (x >= kView + gap) p = after[y * kView + x - kView - gap];
      const unsigned char rgb[3] = {uint8_t((p >> 11) << 3), uint8_t(((p >> 5) & 63) << 2),
                                    uint8_t((p & 31) << 3)};
      fwrite(rgb, 1, 3, f);
    }
  fclose(f);
  printf("wrote %s (left: old, right: new)\n", path);
  return 0;
}
