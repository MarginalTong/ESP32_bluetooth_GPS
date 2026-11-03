"""Board selection must also reach the one shared PlatformIO monitor."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "navio_monitor", ROOT / "firmware/tools/navo_monitor.py")
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


class MonitorConfigTest(unittest.TestCase):
    def test_default_follows_project(self):
        self.assertEqual(monitor.default_environment(), "jc3636w518c")

    def test_matching_running_monitor_is_reused(self):
        with patch.object(monitor, "busy", return_value=True), \
             patch.object(monitor, "STATE") as state, \
             patch.object(monitor, "STOP") as stop:
            state.exists.return_value = True
            state.read_text.return_value = '{"environment":"jc3636w518c"}'
            monitor.start(environment="jc3636w518c")
            stop.touch.assert_not_called()

    def test_old_environment_is_stopped_before_switch(self):
        with patch.object(monitor, "busy", side_effect=[True, False, False]), \
             patch.object(monitor, "STATE") as state, \
             patch.object(monitor, "STOP") as stop, \
             patch.object(monitor, "pio", side_effect=RuntimeError("stop test")):
            state.exists.return_value = True
            state.read_text.return_value = '{"environment":"waveshare_146"}'
            with self.assertRaisesRegex(RuntimeError, "stop test"):
                monitor.start(environment="jc3636w518c")
            stop.touch.assert_called_once()


if __name__ == "__main__":
    unittest.main()
