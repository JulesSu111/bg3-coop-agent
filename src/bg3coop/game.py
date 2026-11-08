"""Connection to the running game: debugger socket, Lua injection, RPC.

The game and the agent normally run on the same Windows PC, so this talks to 127.0.0.1:9998.
For development, BG3COOP_SSH_HOST=<ssh host> reaches a game on another machine through ssh -L.
"""

from __future__ import annotations

import atexit
import contextlib
import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time
import uuid
from importlib import resources
from collections.abc import Iterator
from typing import Any

from .remote_lua import BG3SE_PROTOCOL_VERSION, RemoteLua, RemoteLuaError

GAME_PORT = 9998
DEBUGGER_RETRY_SECONDS = 30
CHAT_LINES = 100


def _clock() -> int:
    """Seconds since local midnight: the panel's clock for the human's own lines."""
    t = time.localtime()
    return t.tm_hour * 3600 + t.tm_min * 60 + t.tm_sec
# The debugger drops the connection on a message over 64 KiB, so longer scripts go in pieces.
CHUNK_BYTES = 32 * 1024
# The table each injected script lives in, per Lua state.
GLOBALS = {"server": "BG3COOP", "client": "BG3COOP_C"}


class GameError(Exception):
    """The game refused an action; the message is meant for the agent."""


class NotReady(GameError):
    """The debugger answered, but the Lua state is not there yet: main menu or loading."""


class DebuggerBusy(GameError):
    """The debugger port took the connection but never answered: it serves one client at a time."""


def _lua(name: str) -> str:
    return resources.files("bg3coop").joinpath("lua", name).read_text(encoding="utf-8")


def lua_version(src: str) -> int:
    """The C.VERSION a Lua side declares; a live state with another version gets the file again."""
    m = re.search(r"^C\.VERSION = (\d+)", src, re.M)
    if not m:
        raise ValueError("Lua source has no C.VERSION")
    return int(m.group(1))


def _chunks(text: str, limit: int) -> list[str]:
    """Split text at line ends into pieces of at most `limit` UTF-8 bytes (a longer line stands alone)."""
    pieces, cur, size = [], [], 0
    for line in text.splitlines(keepends=True):
        n = len(line.encode())
        if cur and size + n > limit:
            pieces.append("".join(cur))
            cur, size = [], 0
        cur.append(line)
        size += n
    if cur:
        pieces.append("".join(cur))
    return pieces


def _long_string(text: str) -> str:
    """Lua long-bracket literal that cannot be closed early by the text."""
    level = 1
    while "]" + "=" * level + "]" in text:
        level += 1
    eq = "=" * level
    return f"[{eq}[{text}]{eq}]"


class Tunnel:
    """ssh -L to the game's debugger port when the game runs on another machine."""

    def __init__(self, host: str, local_port: int, remote_port: int = GAME_PORT) -> None:
        self.host, self.local_port, self.remote_port = host, local_port, remote_port
        self.proc: subprocess.Popen | None = None

    def _port_open(self) -> bool:
        try:
            with socket.create_connection(("127.0.0.1", self.local_port), timeout=0.5):
                return True
        except OSError:
            return False

    def ensure(self) -> None:
        if self.proc and self.proc.poll() is None:
            return
        if self._port_open():  # a tunnel opened by hand (or another bridge) is already there
            return
        ssh = shutil.which("ssh") or "/usr/bin/ssh"
        self.proc = subprocess.Popen(
            [ssh, "-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15",
             "-L", f"127.0.0.1:{self.local_port}:127.0.0.1:{self.remote_port}", self.host],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        atexit.register(self.close)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise GameError(f"ssh tunnel to {self.host} exited (code {self.proc.returncode})")
            if self._port_open():
                return
            time.sleep(0.3)
        raise GameError(f"ssh tunnel to {self.host} did not come up")

    def close(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()


class Game:
    """One debugger connection; re-injects the Lua side whenever the game reloaded it."""

    def __init__(self) -> None:
        self.ssh_host = os.environ.get("BG3COOP_SSH_HOST", "").strip() or None
        self.port = int(os.environ.get("BG3COOP_PORT", "19998" if self.ssh_host else str(GAME_PORT)))
        self.tunnel = Tunnel(self.ssh_host, self.port) if self.ssh_host else None
        self.client: RemoteLua | None = None
        self._debugger_busy_until = 0.0
        self.lock = threading.Lock()
        self.connection_id: str | None = None
        self.protagonist_ticket: str | None = None
        self.agent_id: str | None = None  # survive save loads (the Lua state does not)
        self.human_id: str | None = None
        self.agent_name: str | None = None
        self.chat: list[dict] = []  # panel history: the client Lua state loses it on save load
        self.lang: str | None = None  # the game's language as the panel uses it: "zh" or "en"
        self._ask_id = 0
        self._src = {"server": _lua("server.lua"), "client": _lua("client.lua")}
        self.versions = {ctx: lua_version(src) for ctx, src in self._src.items()}

    # ---- connection ----

    @property
    def address(self) -> str:
        return f"127.0.0.1:{self.port}" + (f" (ssh {self.ssh_host})" if self.ssh_host else "")

    def _connect(self) -> RemoteLua:
        if self.client and self.client.connected:
            return self.client
        busy = (f"the game's debugger port ({self.address}) took the connection but did not answer: another "
                "program may hold it, such as an older BG3 MCP session. Close the other client and try again.")
        if time.monotonic() < self._debugger_busy_until:
            raise DebuggerBusy(busy)
        if self.tunnel:
            self.tunnel.ensure()
        client = RemoteLua("127.0.0.1", self.port, protocol_version=BG3SE_PROTOCOL_VERSION)
        try:
            client.connect()
        except TimeoutError as e:
            # SE v33 can leave timed-out secondary connections in CLOSE_WAIT.
            self._debugger_busy_until = time.monotonic() + DEBUGGER_RETRY_SECONDS
            raise DebuggerBusy(busy) from e
        except OSError as e:
            raise GameError(
                "cannot reach the game's debugger port. Is BG3 running with the Script Extender "
                f"and EnableLuaDebugger on? (tried {self.address}; `bg3coop doctor` checks the setup)"
            ) from e
        self.client = client
        self.connection_id = uuid.uuid4().hex
        return client

    def _eval(self, code: str, context: str, timeout: float = 15.0) -> str:
        client = self._connect()
        try:
            return client.evaluate(code, context=context, timeout=timeout, statement=True)
        except TimeoutError:
            # Invalidate the session without leaking a debugger socket on a slow load.
            self.connection_id = uuid.uuid4().hex
            raise
        except ConnectionError:
            # Never replay an action with an unknown result on a new connection.
            self.connection_id = None
            client.close()
            self.client = None
            raise
        except RemoteLuaError as e:
            msg = str(e)
            if "NOT_READY" in msg or "NO_DEBUGGEE" in msg:
                raise NotReady("no save is loaded yet (the game is at the main menu or loading)") from e
            raise

    def _ensure_injected(self, context: str) -> bool:
        glob = GLOBALS[context]
        want = self.versions[context]
        have = self._eval(f"return {glob} ~= nil and {glob}.rpc ~= nil and {glob}.VERSION == {want}", context)
        if have.strip() == "true":
            return False
        if self._authority():
            raise NotReady("Lua state changed during a local task; waiting for the controller")
        self._inject(self._src[context], context)
        if context == "client":
            self._call_raw("client", "chat_restore", {"lines": self.chat[-CHAT_LINES:]})
        if context == "server" and self.agent_id and not self.protagonist_ticket:
            args = {"id": self.agent_id}
            if self.human_id:
                args["human_id"] = self.human_id
            try:
                self._call_raw("server", "set_agent", args)
            except GameError:
                # The saved companion might be absent or now reserved to a different player.
                self.agent_id = self.human_id = self.agent_name = None
        return True

    def _inject(self, src: str, context: str) -> None:
        if len(src.encode()) <= CHUNK_BYTES:
            self._eval(src, context, timeout=20)
            return
        self._eval("BG3COOP_SRC = {}", context)
        for piece in _chunks(src, CHUNK_BYTES):
            # a long string drops a newline right after its opening bracket, so give it one to drop
            self._eval(f"BG3COOP_SRC[#BG3COOP_SRC + 1] = {_long_string(chr(10) + piece)}", context)
        self._eval("local src = table.concat(BG3COOP_SRC); BG3COOP_SRC = nil; "
                   "return assert(load(src))()", context, timeout=20)

    def _authority(self):
        guard = getattr(self, "_local_guard", None)
        return guard() if guard else None

    def _call_raw(self, context: str, op: str, args: dict, authority=None) -> Any:
        fields = {k: v for k, v in (authority or {}).items() if v is not None}
        payload = json.dumps({"op": op, "args": args, **fields}, ensure_ascii=False)
        return self._decode(self._eval(f"return {GLOBALS[context]}.rpc({_long_string(payload)})", context))

    @staticmethod
    def _decode(raw):
        try:
            reply = json.loads(raw)
        except json.JSONDecodeError as e:
            raise GameError(f"unexpected reply from the game: {raw[:200]}") from e
        if not reply.get("ok"):
            raise GameError(reply.get("error") or "the game refused")
        return reply.get("result")

    @contextlib.contextmanager
    def _request(self) -> Iterator[None]:
        """One request at a time; debugger errors and timeouts come out as GameError."""
        with self.lock:
            try:
                yield
            except (RemoteLuaError, ConnectionError) as e:
                raise GameError(str(e)) from e
            except TimeoutError as e:
                raise GameError("the game did not answer (paused, loading, or alt-tabbed with pause on?)") from e

    def call(self, op: str, args: dict | None = None, context: str = "server") -> Any:
        """Run `op` in the injected script of `context` (injecting it first when needed)."""
        self._authority()
        from .local_transport import endpoint, request
        proxy = endpoint() if not self.ssh_host and self.port == GAME_PORT else None
        if proxy:
            try:
                reply = request(proxy, "game_call", {"op": op, "args": args, "context": context})
            except (OSError, ConnectionError) as exc:
                raise GameError(f"local bridge unavailable: {exc}") from exc
            identity = reply["identity"]
            self.agent_id, self.human_id, self.agent_name = identity["agent"], identity["human"], identity["name"]
            return reply["value"]
        with self._request():
            self._connect()
            authority = self._authority()
            self._ensure_injected(context)
            if context == "client" and op in {"choose", "roll", "roll_boost", "trade_item", "trade_hide", "trade_close"}:
                self._ensure_injected("server")
                # Even a separate MCP process sharing this bridge cannot use the avatar's UI.
                self._check_ui_authority(op, authority)
            authority = self._authority()
            result = self._call_raw(context, op, args or {}, authority if context == "server" else None)
            if op == "set_agent" and isinstance(result, dict):
                self.agent_id = result.get("id")
                self.human_id = result.get("human_id")
                self.agent_name = result.get("name")
            return result

    def refresh_control(self, lease_ms):
        """Private daemon heartbeat. The connection nonce is only sent to the local game."""
        with self._request():
            self._ensure_injected("server")
            client_reloaded = self._ensure_injected("client")
            session = _long_string(self.connection_id)
            local = json.loads(self._eval("return BG3COOP_C.readControl()", "client", 3))
            off = local.get("off") == self.connection_id
            if off or client_reloaded:
                self._eval("BG3COOP.controlReset()", "server", 3)
            # Only the local UI callback can put a request in this private slot.
            pending = local.get("request")
            request = pending if local.get("ready") and not off else None
            if request:
                request_expr = f"Ext.Json.Parse({_long_string(json.dumps(request))})"
            else:
                request_expr = "nil"
            state = json.loads(self._eval(
                f"return BG3COOP.controlHeartbeat({session}, {int(lease_ms)}, {request_expr})", "server", 3))
            self.protagonist_ticket = state.get("ticket")
            self.agent_id, self.human_id, self.agent_name = (state.get(k) for k in ("id", "human", "name"))
            ticket = _long_string(self.protagonist_ticket) if self.protagonist_ticket else "nil"
            epoch = _long_string(state["epoch"])
            consent = state.get("consent")
            if pending and not local.get("ready") and not off:
                consent = state["consent"] = {"id": pending["id"], "error": "授权请求已超时，请重新启用接管"}
            reply = f"Ext.Json.Parse({_long_string(json.dumps(consent, ensure_ascii=False))})" if consent else "nil"
            self._eval(f"BG3COOP_C.bindControl({session}, {ticket}, {int(lease_ms)}, {epoch}, {reply})", "client", 3)
            return state

    def suspend_control(self, revoke=False):
        with self._request():
            fn = "controlReset" if revoke else "controlStop"
            if revoke and self.connection_id:
                self.connection_id = uuid.uuid4().hex
            try:
                self._eval("if BG3COOP_C and BG3COOP_C.blockControl then BG3COOP_C.blockControl() end", "client", 3)
            finally:
                state = self._eval(f"if BG3COOP and BG3COOP.{fn} then return BG3COOP.{fn}() end", "server", 3)
            return json.loads(state) if state.startswith("{") else None

    def _check_ui_authority(self, op, authority, args=None):
        data = {"op": op, "authority": {k: v for k, v in (authority or {}).items() if v is not None}}
        if args is not None:
            data["args"] = args
        data = _long_string(json.dumps(data))
        raw = self._eval(f"return BG3COOP.authorizeUI({data})", "server", 3)
        return self._decode(raw)

    def protagonist_ui(self, op, args):
        """Read or act on the native UI, validating server ownership before queuing each step."""
        key = _long_string(uuid.uuid4().hex)
        with self._request():
            authority = self._authority()
            if not authority or not self.protagonist_ticket:
                raise GameError("the protagonist UI requires the local controller")
            ticket = _long_string(self.protagonist_ticket)
            self._check_ui_authority(op, authority, args)
            self._authority()
            payload = _long_string(json.dumps(args, ensure_ascii=False))
            self._eval(
                f"BG3COOP_C.queueControlUI({key}, {ticket}, {_long_string(op)}, Ext.Json.Parse({payload}))",
                "client", 3)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            with self._request():
                self._authority()
                result = self._eval(f"return BG3COOP_C.takeControlUI({key})", "client", 3)
                if result == "cancelled":
                    raise GameError("the protagonist UI action was cancelled")
                if result != "pending":
                    return self._decode(result)
            time.sleep(0.05)
        raise GameError("the protagonist UI did not respond")

    # ---- chat panel ----

    def _remember(self, kind: str, text: str, who: str | None = None) -> dict:
        """One line of panel history: {kind, text, who, at}."""
        line = {"kind": kind, "text": text, "at": time.strftime("%H:%M")}
        if who:
            line["who"] = who
        self.chat.append(line)
        del self.chat[:-CHAT_LINES]
        return line

    def chat_take(self, hud: dict | None = None, activity: dict | None = None) -> tuple[list, dict[int, str]]:
        """What the human sent since the last call: typed lines (and quick buttons), {"point": ...}
        marks (what they middle-clicked), and Yes/No answers by question id. `hud` ({name})
        refreshes the panel's header, `activity` its activity line."""
        args: dict[str, Any] = {"clock": _clock()}
        if hud:
            args["hud"] = hud
        if activity:
            args["activity"] = activity
        reply = self.call("chat_take", args, context="client") or {}
        self.lang = reply.get("lang") or self.lang
        got = reply.get("messages") or []
        texts = [m for m in got if isinstance(m, str) or (isinstance(m, dict) and "point" in m)]
        answers = {int(m["ask"]): m["answer"] for m in got if isinstance(m, dict) and "ask" in m}
        for line in reply.get("shown") or []:
            if isinstance(line, dict):
                self.chat.append({k: v for k, v in line.items() if k in ("kind", "text", "at")})
                del self.chat[:-CHAT_LINES]
        return texts, answers

    def _said(self, kind: str, text: str) -> dict:
        return self._remember(kind, text, self.agent_name if kind == "agent" else None)

    def language(self) -> str:
        """"zh" when the game runs in Simplified Chinese, else "en": what the human reads."""
        if self.lang is None:
            try:
                self.lang = self.call("lang", context="client")
            except GameError:
                return "en"
        return self.lang if self.lang in ("zh", "en") else "en"

    def chat_post(self, text: str, kind: str = "agent") -> None:
        self.call("chat_post", self._said(kind, text), context="client")

    def chat_ask(self, question: str) -> int:
        self._ask_id += 1
        self.call("chat_ask", {"id": self._ask_id, **self._said("agent", question)}, context="client")
        return self._ask_id

    def chat_ask_close(self, ask_id: int, text: str, kind: str = "human") -> None:
        self._remember(kind, text)
        self.call("chat_ask_close", {"id": ask_id, "text": text, "kind": kind}, context="client")

    def eval(self, code: str, context: str = "client", timeout: float = 15.0) -> str:
        """Raw evaluation, for diagnostics."""
        with self._request():
            return self._eval(code, context, timeout)

    def close(self) -> None:
        with self.lock:
            self.connection_id = None
            self._debugger_busy_until = 0.0
            if self.client:
                self.client.close()
            if self.tunnel:
                self.tunnel.close()
