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

int main() {
  std::vector<Command> sent;
  bool writing = false, sleeping = true, timingEnabled = false;
  unsigned elapsed = 0, sleepOutAt = 0;
  int gammaTables = 0, fullRowWindows = 0, timingWaits = 0;
  const auto& ops = jc3636_qspi_init;
  for (size_t i = 0; i < sizeof(ops);) {
    const uint8_t op = ops[i++];
    if (op == BEGIN_WRITE) {
      assert(!writing);
      writing = true;
    } else if (op == END_WRITE) {
      assert(writing);
      writing = false;
    } else if (op == DELAY) {
      assert(!writing && i < sizeof(ops));
      const unsigned ms = ops[i++];
      elapsed += ms;
      if (timingEnabled && ms >= 10) ++timingWaits;
    } else {
      assert(op == WRITE_C8_BYTES && writing && i + 2 <= sizeof(ops));
      Command cmd{ops[i++], {}};
      const size_t length = ops[i++];
      assert(length > 0 && i + length <= sizeof(ops));
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
  // Factory table (184) plus pixel format and orientation.
  assert(!writing && sent.size() == 186);
  assert(sent[0].address == 0x36 && sent[0].data[0] == 0);
  assert(sent[1].address == 0x3A && sent[1].data[0] == 0x55);
  assert(sent.back().address == 0x29);
  assert(gammaTables == 2 && fullRowWindows == 0 && timingWaits == 0);
  // Factory values, not Espressif's generic defaults (B0 0x54, B1 0x3F).
  assert(sent[12].address == 0xB0 && sent[12].data[0] == 0x56);
  assert(sent[13].address == 0xB1 && sent[13].data[0] == 0x4D);
  std::puts("JC3636 init: 186 combined QSPI commands, gamma/windows/timing/sleep-out passed");
}
