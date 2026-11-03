#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <vector>

// Deliberately accept only QSPI-safe, combined command/parameter operations.
enum : uint8_t { BEGIN_WRITE = 1, END_WRITE, WRITE_C8_BYTES, DELAY };
#include "jc3636_panel_init.h"

struct Command {
  uint8_t address;
  std::vector<uint8_t> data;
};

struct Expect {
  size_t commands;
  int fullRowWindows, timingWaits;
};

template <size_t N>
void check(const uint8_t (&ops)[N], const Expect& expect, const char* name) {
  std::vector<Command> sent;
  bool writing = false, sleeping = true, timingEnabled = false;
  unsigned elapsed = 0, sleepOutAt = 0;
  int gammaTables = 0, fullRowWindows = 0, timingWaits = 0;
  for (size_t i = 0; i < N;) {
    const uint8_t op = ops[i++];
    if (op == BEGIN_WRITE) {
      assert(!writing);
      writing = true;
    } else if (op == END_WRITE) {
      assert(writing);
      writing = false;
    } else if (op == DELAY) {
      assert(!writing && i < N);
      const unsigned ms = ops[i++];
      elapsed += ms;
      if (timingEnabled && ms >= 10) ++timingWaits;
    } else {
      assert(op == WRITE_C8_BYTES && writing && i + 2 <= N);
      Command cmd{ops[i++], {}};
      const size_t length = ops[i++];
      assert(length > 0 && i + length <= N);
      cmd.data.assign(ops + i, ops + i + length);
      i += length;
      if (length == 14) {
        assert(cmd.address == 0xE0 || cmd.address == 0xE1);
        ++gammaTables;
      }
      if (cmd.address == 0x2A || cmd.address == 0x2B) {
        assert(length == 4);  // Must not become a raw quad pixel transfer.
        if (cmd.address == 0x2B && cmd.data == std::vector<uint8_t>{0, 0, 1, 0x67})
          ++fullRowWindows;
      }
      if (cmd.address == 0x4C) timingEnabled = cmd.data[0] == 1;
      if (cmd.address == 0x11) {
        sleeping = false;
        sleepOutAt = elapsed;
      }
      if (cmd.address == 0x29) assert(!sleeping && elapsed - sleepOutAt >= 120);
      sent.push_back(cmd);
    }
  }
  assert(!writing && sent.size() == expect.commands);
  assert(sent[0].address == 0x36 && sent[0].data[0] == 0);
  assert(sent[1].address == 0x3A && sent[1].data[0] == 0x55);
  assert(sent.back().address == 0x29);
  assert(gammaTables == 2 && fullRowWindows == expect.fullRowWindows &&
         timingWaits == expect.timingWaits);
  std::printf("%s init: %zu combined QSPI commands, gamma/windows/timing/sleep-out passed\n",
              name, sent.size());
}

int main() {
  check(jc3636_qspi_init, {219, 1, 1}, "JC3636W518C");
  // Vendor table (184) plus pixel format and orientation.
  check(jc3636k518_qspi_init, {186, 0, 0}, "JC3636K518");
  // Spot-check values copied from the K518 vendor INI, not the W518 defaults.
  const auto& k = jc3636k518_qspi_init;
  bool found = false;
  for (size_t i = 0; i + 3 < sizeof(k); ++i)
    if (k[i] == WRITE_C8_BYTES && k[i + 1] == 0xB0 && k[i + 2] == 1) {
      assert(k[i + 3] == 0x56);  // first B0 in the vendor table
      found = true;
      break;
    }
  assert(found);
}
