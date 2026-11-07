"""Authenticated loopback transport. No direct debugger fallback when installed."""
from __future__ import annotations

import json
import os
from pathlib import Path
from urllib.request import Request, ProxyHandler, build_opener


def data_dir() -> Path:
    return Path(os.environ.get("BG3COOP_LOCAL_DIR", str(Path(os.environ.get("LOCALAPPDATA", Path.home())) / "BG3Coop")))


def endpoint():
    if os.environ.get("BG3COOP_BRIDGE_OWNER") == "1":
        return None
    path = data_dir() / "bridge.json"
    return json.loads(path.read_text(encoding="utf-8-sig")) if path.exists() else None


def request(config, method, params):
    port = int(config["port"])
    req = Request(f"http://127.0.0.1:{port}/rpc", json.dumps({"method": method, "params": params}).encode(),
                  {"Authorization": "Bearer " + config["token"], "Content-Type": "application/json"})
    # Never send the loopback bearer token through a configured HTTP proxy.
    with build_opener(ProxyHandler({})).open(req, timeout=90) as response:
        result = json.load(response)
    if "error" in result:
        if result.get("error_type") == "RemoteLuaError":
            from .remote_lua import RemoteLuaError
            raise RemoteLuaError(result["error"])
        if result.get("error_type") in {"GameError", "NotReady", "DebuggerBusy"}:
            from .game import GameError, NotReady, DebuggerBusy
            errors = {"GameError": GameError, "NotReady": NotReady, "DebuggerBusy": DebuggerBusy}
            raise errors[result["error_type"]](result["error"])
        if result.get("error_type") == "TimeoutError":
            raise TimeoutError(result["error"])
        raise ConnectionError(result["error"])
    return result["result"]
