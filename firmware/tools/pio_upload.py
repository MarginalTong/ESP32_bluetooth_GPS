"""PlatformIO upload hooks: release the shared monitor before flashing.

Advisory locks are released even if a build/upload is interrupted. No stale
pause flag can strand the monitor after a failed upload.
"""

import atexit
import fcntl
from pathlib import Path
import subprocess
import sys
import time

Import("env")

root = Path(env.subst("$PROJECT_DIR"))
local = root / ".navo"
held_locks = []


def release():
    while held_locks:
        handle = held_locks.pop()
        fcntl.flock(handle, fcntl.LOCK_UN)
        handle.close()


def before_upload(source, target, env):
    local.mkdir(exist_ok=True)
    handle = (local / "upload.lock").open("a")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        raise RuntimeError("Another NAVIO upload is already running") from None
    held_locks.append(handle)
    handle = (local / "port.lock").open("a")
    deadline = time.monotonic() + 10
    while True:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                handle.close()
                release()
                raise RuntimeError("Shared monitor did not release USB within 10 seconds")
            time.sleep(0.1)
    held_locks.append(handle)
    print("NAVIO: shared serial monitor released; uploading via PlatformIO")


def after_upload(source, target, env):
    release()
    subprocess.run([sys.executable, str(root / "firmware/tools/navo_monitor.py"), "start"],
                   cwd=root, check=True)


atexit.register(release)
env.AddPreAction("upload", before_upload)
env.AddPostAction("upload", after_upload)
