"""A fake game for offline tests: speaks bg3se's LuaDebug protocol and runs the Lua in lupa
against mock_env.lua. Checks the same eval preconditions bg3se does (frame == -1 for statements)."""

from __future__ import annotations

import json
import socket
import struct
import threading
import time
from pathlib import Path

import lupa.lua54 as lupa

from bg3coop import remote_lua as ld

HERE = Path(__file__).parent


def _to_py(v):
    if lupa.lua_type(v) == "table":
        keys = list(v.keys())
        if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [_to_py(v[k]) for k in sorted(keys)]
        if not keys:
            return []
        return {str(k): _to_py(v[k]) for k in keys}
    return v


def _recv_exact(conn: socket.socket, n: int) -> bytes | None:
    buf = b""
    while len(buf) < n:
        try:
            chunk = conn.recv(n - len(buf))
        except OSError:
            return None
        if not chunk:
            return None
        buf += chunk
    return buf


class FakeGame:
    def __init__(self) -> None:
        self.server = self._runtime(with_world=True)
        self.client = self._runtime(with_world=False)
        self.client.globals().PY_client_net = self._client_net
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen()
        self.port = self.sock.getsockname()[1]
        self.evals = 0
        threading.Thread(target=self._serve, daemon=True).start()

    def _runtime(self, with_world: bool) -> lupa.LuaRuntime:
        L = lupa.LuaRuntime(unpack_returned_tuples=True)
        g = L.globals()
        g.PY_now = lambda: time.monotonic() * 1000
        g.PY_stringify = lambda v: json.dumps(_to_py(v))

        def parse(s):
            def conv(x):
                if isinstance(x, dict):
                    return L.table_from({k: conv(v) for k, v in x.items()})
                if isinstance(x, list):
                    return L.table_from([conv(v) for v in x])
                return x
            return conv(json.loads(s))
        g.PY_parse = parse
        if with_world:
            L.execute((HERE / "mock_env.lua").read_text())
        else:
            L.execute((HERE / "mock_client.lua").read_text())
        return L

    @property
    def world(self):
        return self.server.globals().MOCK

    def _client_net(self, channel, payload, peer=0):
        listener = self.world.net[channel]
        listener(channel, payload, peer)

    # ---- protocol ----

    def _serve(self) -> None:
        while True:
            conn, _ = self.sock.accept()
            threading.Thread(target=self._conn, args=(conn,), daemon=True).start()

    def _send(self, conn, reply_seq: int, field: int, body: bytes) -> None:
        msg = ld.encode((2, reply_seq), (field, body))
        conn.sendall(struct.pack("<I", len(msg) + 4) + msg)

    def _conn(self, conn: socket.socket) -> None:
        expected = 1
        while True:
            head = _recv_exact(conn, 4)
            if head is None:
                return
            size = struct.unpack("<I", head)[0] - 4
            data = _recv_exact(conn, size)
            if data is None:
                return
            msg = ld.decode(data)
            seq = ld.get(msg, 1, 0)
            if seq != expected:  # like bg3se: a wrong sequence number drops the client
                conn.close()
                return
            expected += 1
            if 3 in msg:
                # like bg3se: the connect response has seq_no but no reply_seq_no
                body = ld.encode((1, 1), (3, ld.encode((1, 5))))
                conn.sendall(struct.pack("<I", len(body) + 4) + body)
            elif 7 in msg:
                self._evaluate(conn, seq, ld.get_message(msg, 7))

    def _evaluate(self, conn, seq: int, req: dict) -> None:
        self.evals += 1
        context = ld.get(req, 1, 0)
        code = ld.get_text(req, 2)
        if len(code.encode()) > 65536:  # like bg3se: a message this big drops the connection
            conn.close()
            return
        frame = ld.get(req, 3, 0)
        if frame >= 1 << 63:
            frame -= 1 << 64
        statement = bool(ld.get(req, 4, 0) & ld.FLAG_STATEMENT)
        L = self.client if context else self.server
        if statement and frame != -1:
            body = ld.encode((2, "Statement evaluation within a specific stack frame is not supported"))
            return self._send(conn, seq, 5, body)
        try:
            result = L.execute(code if statement else "return " + code)
        except lupa.LuaError as e:
            return self._send(conn, seq, 5, ld.encode((2, str(e))))
        if isinstance(result, tuple):
            result = result[0] if result else None
        if isinstance(result, bool):
            value = ld.encode((1, 1), (2, int(result)))
        elif result is None:
            value = ld.encode((1, 0))
        else:
            value = ld.encode((1, 4), (5, str(result)))
        self._send(conn, seq, 5, ld.encode((1, value)))
