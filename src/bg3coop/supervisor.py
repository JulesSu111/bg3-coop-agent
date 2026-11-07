"""Small login-task process: sleep in wait(), restart crashes, own all descendants."""
import argparse
from collections import deque
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import subprocess
import sys
import time

if __package__:
    from .windows_lifecycle import LauncherLifetime
else:
    # Run with the native base interpreter, not Windows' venv redirector. Task Scheduler
    # must terminate the actual process holding the job handle, not a redirector parent.
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from bg3coop.windows_lifecycle import LauncherLifetime


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    config_path = root / "config.json"
    handler = RotatingFileHandler(root / "launcher.log", maxBytes=1_000_000, backupCount=2, encoding="utf-8")
    logger = logging.getLogger("bg3coop.supervisor")
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    try:
        lifetime = LauncherLifetime(root)
        if lifetime.duplicate:
            return 0
        config = json.loads(config_path.read_text(encoding="utf-8-sig"))
        python = config.get("python") or str(Path(sys.executable).with_name("python.exe"))
        env = dict(os.environ, BG3COOP_LOCAL_DIR=str(root))
        return supervise(root, config_path, python, env, logger)
    except Exception:
        logger.exception("supervisor stopped; manual check required")
        return 0  # no automatic launch loop after invalid configuration / lifetime setup failure
    finally:
        logger.removeHandler(handler)
        handler.close()


def supervise(root, config_path, python, env, logger):
    failures = deque()
    while (root / "enabled").exists():
        try:
            process = subprocess.Popen([python, "-m", "bg3coop.daemon", "--config", str(config_path)],
                                       env=env, creationflags=0x08000000,
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            (root / "daemon.pid").write_text(str(process.pid), encoding="ascii")
            code = process.wait()  # kernel wait, no polling while the daemon is healthy
        except OSError:
            logger.exception("could not start daemon")
            code = 1
        if code in {0, 2}:
            return 0
        logger.error("daemon exited: %s", code)
        now = time.monotonic()
        failures.append(now)
        while failures and failures[0] < now - 300:
            failures.popleft()
        if len(failures) >= 5:
            logger.error("five failures in five minutes; stopped, manual restart required")
            return 0  # prevents Task Scheduler restart-on-failure loop
        if (root / "enabled").exists():
            time.sleep(5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
