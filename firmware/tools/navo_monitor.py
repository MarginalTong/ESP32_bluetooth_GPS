#!/usr/bin/env python3
"""Share one native PlatformIO Device Monitor between VS Code and Codex.

Build/upload use pio directly. This supervisor only gives its interactive
monitor a persistent terminal, copies output to a shared file, and pauses it
while the PlatformIO upload hook owns upload.lock.
"""

import argparse
import contextlib
import configparser
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
LOCAL = ROOT / ".navo"
LOG = LOCAL / "serial.log"
STOP = LOCAL / "monitor.stop"
STATE = LOCAL / "monitor.json"


def default_environment():
    config = configparser.ConfigParser(interpolation=None)
    config.read(ROOT / "platformio.ini")
    return config["platformio"]["default_envs"].strip()


def pio():
    executable = (os.environ.get("NAVIO_PIO") or os.environ.get("NAVO_PIO")
                  or shutil.which("pio"))
    if not executable:
        executable = str(Path.home() / ".platformio/penv/bin/pio")
    if not Path(executable).is_file():
        raise RuntimeError("Install the PlatformIO IDE extension first, or set NAVIO_PIO.")
    return executable


@contextlib.contextmanager
def lock(name):
    LOCAL.mkdir(exist_ok=True)
    with (LOCAL / name).open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def busy(name):
    try:
        with lock(name):
            return False
    except BlockingIOError:
        return True


def port(explicit=None):
    # Use the same pyserial enumeration that PlatformIO uses. Never select a
    # random board when more than one USB serial device is attached.
    from serial.tools.list_ports import comports
    configured = explicit or os.environ.get("NAVIO_PORT") or os.environ.get("NAVO_PORT")
    if configured:
        if not Path(configured).exists():
            raise RuntimeError(f"USB port missing: {configured}")
        return configured
    devices = [device.device for device in comports() if device.vid is not None]
    if len(devices) != 1:
        raise RuntimeError(f"Expected one USB serial device, found {devices}; use --port to select NAVIO.")
    return devices[0]


def note(message):
    stamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
    with LOG.open("ab", buffering=0) as output:
        output.write(f"\n{stamp} [MONITOR] {message}\n".encode())


def status(state, device=None, environment=None):
    temporary = STATE.with_suffix(".tmp")
    temporary.write_text(json.dumps({"pid": os.getpid(), "state": state,
                                     "port": device, "environment": environment}))
    temporary.replace(STATE)


def stop_child(process, terminal):
    if process.poll() is None:
        with contextlib.suppress(OSError):
            os.write(terminal, b"\x03")  # Device Monitor's normal quit key.
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def daemon(explicit, environment):
    with lock("monitor.lock"):
        STOP.unlink(missing_ok=True)
        signal.signal(signal.SIGTERM, lambda *_: STOP.touch())
        last_error = None
        try:
            while not STOP.exists():
                if busy("upload.lock"):
                    status("paused for upload")
                    time.sleep(0.1)
                    continue
                try:
                    device = port(explicit)
                    with lock("port.lock"):
                        if busy("upload.lock"):
                            continue
                        master, slave = pty.openpty()
                        try:
                            command = [pio(), "device", "monitor", "-d", str(ROOT),
                                       "-e", environment, "--port", device, "--no-reconnect"]
                            process = subprocess.Popen(command, stdin=slave, stdout=slave,
                                                       stderr=slave, cwd=ROOT,
                                                       env={**os.environ, "TZ": "UTC"},
                                                       start_new_session=True)
                        finally:
                            os.close(slave)
                        try:
                            status("running PlatformIO monitor", device, environment)
                            note(f"PlatformIO monitor on {device} ({environment})")
                            with LOG.open("ab", buffering=0) as output:
                                while not STOP.exists() and not busy("upload.lock"):
                                    ready, _, _ = select.select([master], [], [], 0.1)
                                    if ready:
                                        data = os.read(master, 8192)
                                        if not data:
                                            break
                                        output.write(data)
                                    if process.poll() is not None:
                                        break
                        finally:
                            stop_child(process, master)
                            os.close(master)
                        note("Serial released")
                        last_error = None
                except (OSError, RuntimeError) as error:
                    if str(error) != last_error:
                        note(f"Waiting: {error}")
                        last_error = str(error)
                    status("waiting for USB", explicit)
                time.sleep(0.5)
        finally:
            status("stopped")
            STOP.unlink(missing_ok=True)
            note("Stopped")


def start(explicit=None, environment=None):
    environment = environment or default_environment()
    if busy("monitor.lock"):
        current = json.loads(STATE.read_text()) if STATE.exists() else {}
        if current.get("environment") == environment:
            return
        STOP.touch()
        deadline = time.monotonic() + 8
        while busy("monitor.lock") and time.monotonic() < deadline:
            time.sleep(0.1)
        if busy("monitor.lock"):
            raise RuntimeError("Cannot switch monitor environment: stop timed out")
    pio()
    port(explicit)
    command = [sys.executable, str(Path(__file__).resolve()), "_daemon",
               "--environment", environment]
    if explicit:
        command += ["--port", explicit]
    with (LOCAL / "monitor-driver.log").open("ab") as output:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=output,
                                 stderr=output, cwd=ROOT, start_new_session=True)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise RuntimeError(f"Monitor exited; see {LOCAL / 'monitor-driver.log'}")
        if busy("monitor.lock"):
            return
        time.sleep(0.05)
    raise RuntimeError("Monitor startup timed out")


def view():
    LOG.touch(exist_ok=True)
    print(f"Shared PlatformIO monitor: {LOG}\nCtrl+C closes only this viewer.", flush=True)
    with LOG.open(encoding="utf-8", errors="replace") as source:
        source.seek(max(0, LOG.stat().st_size - 12000))
        if source.tell():
            source.readline()
        while True:
            text = source.read()
            if text:
                print(text, end="", flush=True)
            else:
                time.sleep(0.1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["start", "view", "stop", "status", "_daemon"])
    parser.add_argument("--port")
    parser.add_argument("--environment", default=default_environment())
    args = parser.parse_args()
    LOCAL.mkdir(exist_ok=True)
    if args.command in ("start", "view"):
        start(args.port, args.environment)
        if args.command == "view":
            view()
        else:
            print(f"Shared PlatformIO monitor running: {LOG}")
    elif args.command == "stop":
        if busy("monitor.lock"):
            STOP.touch()
            deadline = time.monotonic() + 8
            while busy("monitor.lock") and time.monotonic() < deadline:
                time.sleep(0.1)
            if busy("monitor.lock"):
                raise RuntimeError("Monitor stop timed out")
        print("Shared PlatformIO monitor stopped.")
    elif args.command == "_daemon":
        daemon(args.port, args.environment)
    else:
        print(f"PlatformIO: {pio()}\nShared log: {LOG}\nReader running: {busy('monitor.lock')}")
        if STATE.exists():
            print(STATE.read_text())


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except (OSError, RuntimeError) as error:
        print(f"NAVIO monitor: {error}", file=sys.stderr)
        sys.exit(1)
