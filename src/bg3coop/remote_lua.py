"""Talk to BG3 Script Extender's Lua debugger port and run Lua in the game.

The Script Extender (bg3se) opens this port when ScriptExtenderSettings.json has
"EnableLuaDebugger": true (port 9998 unless LuaDebuggerPort says otherwise). Its protocol is defined
in bg3se's LuaDebug.proto; this module speaks the small part of it the bridge needs: connect,
turn off break-on-error, evaluate a chunk in the server or client Lua state.

Packets: a little-endian uint32 with the size of the whole packet (these 4 bytes included), then one
protobuf message. The few messages used here are encoded and decoded by hand below.

What bg3se insists on (each one drops the connection or refuses the request otherwise):

* Every message we send carries seq_no, starting at 1 on each connection and growing by exactly 1.
* The connect request asks for protocol version 5.
* A statement evaluation names frame -1 (no stack frame).

The connect response is the only reply without reply_seq_no; every other reply names the seq_no of
the request it answers. Status replies (BkResult) report refusals such as EVAL_ENGINE_NOT_READY.

One request at a time: evaluate() sends, then reads packets until the answer arrives, handling
whatever else the game sends meanwhile (log lines, a paused context). Game wraps it in a lock.

Command line, for poking at the game while developing:

    python -m bg3coop.remote_lua [--port 9998] [--server] 'return Ext.Utils.Version()'
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import threading
import time
from typing import Union

BG3SE_PROTOCOL_VERSION = 5
DEFAULT_PORT = 9998
MAX_PACKET_BYTES = 16 * 1024 * 1024

# LuaDebug.proto field numbers.
# DebuggerToBackend (what we send)
SEQ_NO = 1
CONNECT_REQUEST = 3
UPDATE_SETTINGS = 4
CONTINUE = 6
EVALUATE = 7
# BackendToDebugger (what the game sends)
REPLY_SEQ_NO = 2
CONNECT_RESPONSE = 3
BREAKPOINT_TRIGGERED = 4
EVALUATE_RESPONSE = 5
RESULT = 9

# DbgEvaluate flags
FLAG_STATEMENT = 1  # compile the code as a chunk, not as one expression
FLAG_NO_VARIABLE_REFS = 2  # we only want the value, not handles to browse tables

CONTEXT_IDS = {"server": 0, "client": 1}

STATUS_NAMES = ["SUCCESS", "NOT_IN_PAUSE", "NO_DEBUGGEE", "INVALID_CONTINUE_ACTION", "IN_PAUSE",
                "EVAL_ENGINE_NOT_READY", "EVAL_FAILED", "NO_SUCH_FILE"]

# MsgValue.type_id -> what the value looks like when the message carries no value field
# (proto3 omits zero values, so false / 0 / "" arrive as the bare type).
EMPTY_VALUES = {0: "nil", 1: "false", 2: "0", 3: "0.0", 4: ""}
TYPE_NAMES = {5: "table", 6: "function", 7: "userdata", 8: "thread", 9: "unknown", 11: "none"}

Field = Union[int, bytes, str]
Message = dict  # field number -> list of raw values (int for varints, bytes otherwise)


class RemoteLuaError(Exception):
    """The game answered with an error: a Lua error message or a refusal status."""


# ---------------------------------------------------------------- protobuf subset


def encode(*fields: tuple[int, Field]) -> bytes:
    """Encode (number, value) pairs: ints as varints (negative ones as 64-bit two's complement),
    bytes and str as length-delimited."""
    out = bytearray()
    for number, value in fields:
        if isinstance(value, int):
            out += _varint(number << 3)
            out += _varint(value % (1 << 64))
        else:
            data = value.encode("utf-8") if isinstance(value, str) else value
            out += _varint(number << 3 | 2)
            out += _varint(len(data))
            out += data
    return bytes(out)


def _varint(n: int) -> bytes:
    out = bytearray()
    while n > 0x7F:
        out.append(0x80 | (n & 0x7F))
        n >>= 7
    out.append(n)
    return bytes(out)


def decode(data: bytes) -> Message:
    """Decode one message into {field number: [values]}."""
    msg: Message = {}
    pos, end = 0, len(data)

    def varint() -> int:
        nonlocal pos
        n = shift = 0
        while True:
            if pos >= end or shift > 63:
                raise ValueError("bad varint")
            b = data[pos]
            pos += 1
            n |= (b & 0x7F) << shift
            shift += 7
            if b < 0x80:
                return n

    while pos < end:
        key = varint()
        wire = key & 7
        if wire == 0:
            value: Field = varint()
        else:
            size = {1: 8, 5: 4}.get(wire)
            if size is None:
                if wire != 2:
                    raise ValueError(f"wire type {wire} not supported")
                size = varint()
            if pos + size > end:
                raise ValueError("truncated field")
            value = data[pos:pos + size]
            pos += size
        msg.setdefault(key >> 3, []).append(value)
    return msg


def get(msg: Message, number: int, default=None):
    """The last value of a field (protobuf: a repeated scalar field's last value wins)."""
    values = msg.get(number)
    return values[-1] if values else default


def get_message(msg: Message, number: int) -> Message:
    raw = get(msg, number)
    return decode(raw) if isinstance(raw, bytes) else {}


def get_text(msg: Message, number: int) -> str:
    raw = get(msg, number)
    return raw.decode("utf-8", "replace") if isinstance(raw, bytes) else ""


def value_text(value: Message) -> str:
    """MsgValue as text, the way Lua's tostring() would show it."""
    if 5 in value:
        return get_text(value, 5)
    if 2 in value:
        return "true" if get(value, 2) else "false"
    if 3 in value:
        n = get(value, 3)
        return str(n - (1 << 64) if n >= 1 << 63 else n)
    if 4 in value:
        return repr(struct.unpack("<d", get(value, 4))[0])
    type_id = get(value, 1, 0)
    if type_id in EMPTY_VALUES:
        return EMPTY_VALUES[type_id]
    return f"<{TYPE_NAMES.get(type_id, type_id)}>"


# ---------------------------------------------------------------- client


class RemoteLua:
    """One connection to the debugger port. Not for concurrent use from several threads without a
    lock around it (evaluate() takes one anyway)."""

    def __init__(self, host: str = "127.0.0.1", port: int = DEFAULT_PORT,
                 protocol_version: int = BG3SE_PROTOCOL_VERSION, connect_timeout: float = 5.0) -> None:
        self.host = host
        self.port = port
        self.protocol_version = protocol_version
        self.connect_timeout = connect_timeout
        self.server_version: int | None = None
        self._sock: socket.socket | None = None
        self._next_seq = 1
        # Bytes read but not yet a whole packet: kept across a timeout, so the stream stays in step.
        self._rbuf = bytearray()
        self._lock = threading.Lock()

    @property
    def connected(self) -> bool:
        return self._sock is not None or bool(getattr(self, "_proxy", None))

    def connect(self) -> int:
        """Open the connection and do the handshake; returns the game's protocol version."""
        from .local_transport import endpoint, request
        self._proxy = endpoint() if self.host == "127.0.0.1" and self.port == DEFAULT_PORT else None
        if self._proxy:
            self.server_version = request(self._proxy, "connect", {})
            return self.server_version
        self.close()
        self._sock = socket.create_connection((self.host, self.port), timeout=self.connect_timeout)
        self._sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self._next_seq = 1
        self._rbuf = bytearray()
        try:
            deadline = time.monotonic() + self.connect_timeout
            self._send((CONNECT_REQUEST, encode((1, self.protocol_version))))
            while True:
                msg = self._receive(deadline)
                if CONNECT_RESPONSE in msg:
                    break
                self._handle_unsolicited(msg)
            self.server_version = get(get_message(msg, CONNECT_RESPONSE), 1, 0)
            if self.server_version != self.protocol_version:
                raise ConnectionError(f"the game speaks debugger protocol {self.server_version}, "
                                      f"not {self.protocol_version}")
            # An empty settings message: break-on-error off, so a Lua error never pauses the game.
            self._send((UPDATE_SETTINGS, b""))
        except socket.timeout as e:
            self.close()
            raise TimeoutError(f"no connect response from {self.host}:{self.port}") from e
        except BaseException:
            self.close()
            raise
        return self.server_version

    def close(self) -> None:
        self._proxy = None
        sock, self._sock = self._sock, None
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass

    def __enter__(self) -> RemoteLua:
        self.connect()
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def evaluate(self, code: str, context: str = "client", timeout: float = 15.0,
                 statement: bool = True) -> str:
        """Run `code` in the "server" or "client" Lua state and return the result as text.

        statement=True runs it as a chunk (use `return` to get a value); False evaluates one expression.
        Raises RemoteLuaError for errors and refusals, TimeoutError when the game does not answer in
        time, ConnectionError when the connection is gone.

        A timeout keeps the connection: the game answers late (after a loading screen, say) and that
        answer is skipped by its sequence number. Closing instead would leak: SE v33 never closes
        its end of a connection the client hung up, and with enough of those the port stops
        serving.
        """
        if getattr(self, "_proxy", None):
            from .local_transport import request
            return request(self._proxy, "evaluate", {"code": code, "context": context,
                                                      "timeout": timeout, "statement": statement})
        if context not in CONTEXT_IDS:
            raise ValueError(f"unknown context {context!r}")
        flags = FLAG_NO_VARIABLE_REFS | (FLAG_STATEMENT if statement else 0)
        request = encode((1, CONTEXT_IDS[context]), (2, code), (3, -1), (4, flags))
        with self._lock:
            if self._sock is None:
                raise ConnectionError("not connected")
            try:
                deadline = time.monotonic() + timeout
                self._sock.settimeout(timeout)
                seq = self._send((EVALUATE, request))
                while True:
                    msg = self._receive(deadline)
                    if get(msg, REPLY_SEQ_NO, 0) != seq:
                        self._handle_unsolicited(msg)
                        continue
                    if EVALUATE_RESPONSE in msg:
                        answer = get_message(msg, EVALUATE_RESPONSE)
                        error = get_text(answer, 2)
                        if error:
                            raise RemoteLuaError(error)
                        return value_text(get_message(answer, 1))
                    if RESULT in msg:
                        status = get(get_message(msg, RESULT), 1, 0)
                        if status:
                            name = STATUS_NAMES[status] if status < len(STATUS_NAMES) else f"status {status}"
                            raise RemoteLuaError(name)
            except socket.timeout as e:
                raise TimeoutError(f"the game did not answer within {timeout} s") from e
            except (OSError, ValueError) as e:
                self.close()
                if isinstance(e, ConnectionError):
                    raise
                raise ConnectionError(f"debugger connection failed: {e}") from e

    # ---- plumbing ----

    def _send(self, *fields: tuple[int, Field]) -> int:
        seq = self._next_seq
        self._next_seq += 1
        body = encode((SEQ_NO, seq), *fields)
        assert self._sock is not None
        self._sock.sendall(struct.pack("<I", len(body) + 4) + body)
        return seq

    def _receive(self, deadline: float) -> Message:
        self._fill(4, deadline)
        size = struct.unpack("<I", bytes(self._rbuf[:4]))[0]
        if not 4 <= size <= MAX_PACKET_BYTES:
            raise ConnectionError(f"bad packet size {size}")
        self._fill(size, deadline)
        body = bytes(self._rbuf[4:size])
        del self._rbuf[:size]
        return decode(body)

    def _fill(self, n: int, deadline: float) -> None:
        """Read until the buffer holds n bytes. A timeout leaves what came so far in the buffer."""
        assert self._sock is not None
        while len(self._rbuf) < n:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise socket.timeout("debugger response deadline reached")
            self._sock.settimeout(remaining)
            chunk = self._sock.recv(n - len(self._rbuf))
            if not chunk:
                raise ConnectionError("the game closed the debugger connection")
            self._rbuf += chunk

    def _handle_unsolicited(self, msg: Message) -> None:
        """Log lines, late answers to timed-out requests and the like are dropped. A paused context
        is resumed at once: the bridge never debugs, and a paused game would hang everyone."""
        if BREAKPOINT_TRIGGERED in msg:
            context = get(get_message(msg, BREAKPOINT_TRIGGERED), 3, 0)
            self._send((CONTINUE, encode((1, context))))


# ---------------------------------------------------------------- command line


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m bg3coop.remote_lua", description="Run Lua in the game.")
    ap.add_argument("code", help='Lua code, e.g. "return 1 + 1"; "-" reads it from stdin')
    ap.add_argument("--server", action="store_true", help="server Lua state (needs a loaded save)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--timeout", type=float, default=15.0)
    args = ap.parse_args(argv)
    code = sys.stdin.read() if args.code == "-" else args.code
    # A bare expression ("Ext.Utils.Version()") is evaluated as one; anything else runs as a chunk.
    statement = args.code == "-" or code.lstrip().startswith("return") or "\n" in code.strip()
    try:
        with RemoteLua(args.host, args.port) as client:
            print(client.evaluate(code, "server" if args.server else "client", args.timeout, statement))
    except RemoteLuaError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"connection: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
