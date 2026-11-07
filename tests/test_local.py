"""Offline acceptance for local scheduling, durable inbox and debugger arbitration."""
import asyncio
import json
from types import SimpleNamespace
import threading
import time

import pytest

from bg3coop.daemon import Controller, start_bridge
from bg3coop.local_transport import request
from bg3coop.task_queue import TaskQueue


CONFIG = {"codex": "fake", "task_timeout": 0.15, "tool_timeout": 0.1,
          "poll_interval": 0.01, "free_interval": 1000}


class Game:
    agent_id = human_id = agent_name = None

    def __init__(self):
        self.lock = threading.Lock()
        self.loaded = True
        self.epoch = "save1"
        self.messages = []
        self.events = []
        self.posts = []
        self.calls = []
        self.closed = False

    def eval(self, *args):
        return "true" if self.loaded else "false"

    def call(self, op, args=None, context="server"):
        self.calls.append(op)
        if op == "events":
            return {"epoch": self.epoch, "latest": len(self.events), "events": self.events}
        if op == "local_inbox":
            return {"epoch": self.epoch, "messages": list(self.messages)}
        if op == "local_ack":
            self.messages = [m for m in self.messages if m["id"] > args["id"]]
        return {}

    def chat_post(self, text, kind="note"):
        self.posts.append(text)

    def close(self):
        self.closed = True


class App:
    starts = 0
    turns = 0
    fail = False
    hang = False

    def __init__(self, executable, request, notice):
        self.notice = notice

    async def start(self):
        type(self).starts += 1
        if self.fail:
            raise RuntimeError("OAuth expired / quota exhausted / network unavailable")

    async def call(self, method, params, **kw):
        if method == "config/read":
            return {"config": {}}
        if method.startswith("thread/"):
            return {"thread": {"id": "thread-1"}}
        if method == "turn/start":
            type(self).turns += 1
            ident = str(self.turns)
            if not self.hang:
                asyncio.get_running_loop().call_soon(asyncio.create_task,
                    self.notice("turn/completed", {"turn": {"id": ident, "status": "completed"}}))
            return {"turn": {"id": ident}}
        return {}

    async def close(self):
        pass


def controller(tmp_path):
    game = Game()
    async def tools():
        return [SimpleNamespace(name="move", description="move", input_schema={}),
                SimpleNamespace(name="status", description="status", input_schema={})]
    srv = SimpleNamespace(game=game, mcp=SimpleNamespace(list_tools=tools),
                          status=lambda: {"ok": True}, move=lambda: {"moved": True},
                          set_agent=lambda name: {"name": name})
    App.starts = App.turns = 0
    App.fail = App.hang = False
    c = Controller(CONFIG, tmp_path, srv, running=lambda: True, app_factory=App)
    return c


def test_queue_order_dedup_and_crash_recovery(tmp_path):
    path = tmp_path / "q.sqlite"
    q = TaskQueue(path)
    q.put("a", "first")
    q.put("a", "duplicate")
    q.put("b", "second")
    ident, payload = q.next()
    assert payload == "first"
    q.db.close()
    q = TaskQueue(path)
    assert q.db.execute("SELECT state FROM tasks WHERE id=?", (ident,)).fetchone()[0] == "interrupted"
    q.recover()
    assert q.next() == (ident, "first")
    q.finish(ident, "completed")
    assert q.next()[1] == "second"


def test_no_model_at_menu_or_when_game_closed(tmp_path):
    async def run():
        c = controller(tmp_path)
        c.game.loaded = False
        await c.poll()
        assert not c.ready and not c.worker and not App.starts
        c.running = lambda: False
        c.process_next_check = 0
        c.queue.put("msg", "hello")
        await c.poll()
        assert not c.worker and not App.starts
    asyncio.run(run())


def test_load_chat_and_turn_completion_rewake(tmp_path):
    async def run():
        c = controller(tmp_path)
        await c.poll()
        assert c.ready and App.turns == 0 and c.worker is None
        c.game.messages = [{"id": 1, "text": "hello"}]
        await c.poll()
        await c.worker
        assert App.turns == 1 and c.game.messages == []
        await c.poll()
        assert c.worker is None and App.turns == 1  # idle costs no turns
        c.game.messages = [{"id": 2, "text": "another message after the turn completed"}]
        await c.poll()
        await c.worker
        assert App.turns == 2
        c.game.messages = [{"id": 1, "text": "duplicate delivery"}]
        await c.poll()
        assert c.worker is None and App.turns == 2
        c.game.epoch = "save2"
        await c.poll()
        assert c.worker is None and App.turns == 2  # waiting mode load is local-only
    asyncio.run(run())


def test_waiting_gate_and_pause_resume(tmp_path):
    async def run():
        c = controller(tmp_path)
        c.ready = True
        c.active = 1
        c.tools = {"move": True, "status": True}
        with pytest.raises(PermissionError, match="Waiting"):
            await c.tool_request("item/tool/call", {"tool": "bg3_move"})
        result = await c.tool_request("item/tool/call", {"tool": "bg3_status"})
        assert result["success"]
        await c.command("/pause", "pause")
        assert c.mode == "paused" and c.active is None
        await c.command("/resume", "resume")
        assert c.mode == "waiting"
        await c.command("[button] Explore on your own", "free")
        assert c.mode == "free"
        with pytest.raises(PermissionError):
            await c.tool_request("item/commandExecution/requestApproval", {})
    asyncio.run(run())


def test_combat_and_dialogue_wake_once(tmp_path):
    async def run():
        c = controller(tmp_path)
        c.mode = "free"
        c.last_free = time.monotonic()
        await c.poll()
        await c.worker
        c.game.events = [{"seq": 1, "kind": "your_turn"}, {"seq": 2, "kind": "dialogue_started"}]
        await c.poll()
        await c.worker
        await c.poll()
        await c.worker
        await c.poll()
        assert App.turns == 3 and c.worker is None
    asyncio.run(run())


@pytest.mark.parametrize("failure", ["auth", "timeout"])
def test_failure_is_visible_and_recoverable(tmp_path, failure):
    async def run():
        c = controller(tmp_path)
        await c.poll()
        await c.command("hello", "hello")
        App.fail = failure == "auth"
        App.hang = failure == "timeout"
        await c.poll()
        await c.worker
        assert c.mode == "paused"
        assert any("任务未完成" in text for text in c.game.posts)
        assert c.queue.db.execute("SELECT state FROM tasks").fetchone()[0] == "failed"
        App.fail = App.hang = False
        await c.command("/resume", "resume")
        await c.poll()
        await c.worker
        assert c.queue.db.execute("SELECT state FROM tasks ORDER BY id").fetchone()[0] == "completed"
    asyncio.run(run())


def test_disconnect_stops_model_then_reconnects(tmp_path):
    async def run():
        c = controller(tmp_path)
        c.mode = "free"
        App.hang = True
        await c.poll()
        await asyncio.sleep(0.02)
        c.game.loaded = False
        await c.poll()
        assert not c.ready and not c.app and not c.worker
        before = App.turns
        await c.poll()
        assert App.turns == before
        c.game.loaded = True
        App.hang = False
        c.game.epoch = "save2"
        await c.poll()
        await c.worker
        assert c.ready and App.turns == before + 1
    asyncio.run(run())


def test_bridge_auth_exclusive_bind_and_shared_connection():
    g = Game()
    calls = []
    client = SimpleNamespace(server_version=5, evaluate=lambda **kw: calls.append(kw) or "true")
    g._connect = lambda: client
    cfg = {"port": 0, "token": "secret"}
    server = start_bridge(g, cfg)
    cfg = dict(cfg, port=server.server_port)
    try:
        assert request(cfg, "connect", {}) == 5
        assert request(cfg, "evaluate", {"code": "return true"}) == "true"
        assert request(cfg, "connect", {}) == 5 and len(calls) == 1
        with pytest.raises(Exception):
            request(dict(cfg, token="wrong"), "connect", {})
        with pytest.raises(OSError):
            start_bridge(g, cfg)
    finally:
        server.shutdown()
        server.server_close()


def test_lua_inbox_requires_ack_and_survives_other_tools(monkeypatch, tmp_path):
    from fakegame import FakeGame
    from bg3coop.game import Game as RealGame
    fake = FakeGame()
    monkeypatch.setenv("BG3COOP_PORT", str(fake.port))
    monkeypatch.setenv("BG3COOP_LOCAL_DIR", str(tmp_path))
    game = RealGame()
    try:
        first = game.call("local_inbox", context="client")
        fake.client.execute("local p = BG3COOP_C.panel; p.input.Text = 'hello'; p.input.OnChange()")
        got = game.call("local_inbox", context="client")
        assert got["messages"] == [{"id": 1, "text": "hello"}]
        assert game.chat_take()[0] == []
        assert game.call("local_inbox", context="client") == got
        game.call("local_ack", {"id": 1}, context="client")
        assert not game.call("local_inbox", context="client")["messages"]
        assert first["epoch"] == got["epoch"]
        ask_id = game.chat_ask("Ready?")
        fake.client.execute("local p = BG3COOP_C.panel; p.input.Text = 'yes, ready'; p.input.OnChange()")
        assert game.chat_take()[0] == ["yes, ready"]
        assert not game.call("local_inbox", context="client")["messages"]
        fake.client.execute("local p = BG3COOP_C.panel; p.input.Text = '/pause'; p.input.OnChange()")
        assert game.call("local_inbox", context="client")["messages"][0]["text"] == "/pause"
        game.chat_ask_close(ask_id, "yes")
    finally:
        game.close()


def test_mcp_and_doctor_share_real_debugger_and_agent_restore(monkeypatch, tmp_path):
    from fakegame import FakeGame
    from bg3coop.game import Game as RealGame
    from bg3coop import local_transport
    fake = FakeGame()
    monkeypatch.setenv("BG3COOP_LOCAL_DIR", str(tmp_path))
    monkeypatch.delenv("BG3COOP_SSH_HOST", raising=False)
    monkeypatch.setenv("BG3COOP_PORT", str(fake.port))
    owner = RealGame()
    cfg = {"port": 0, "token": "secret"}
    bridge = start_bridge(owner, cfg)
    cfg["port"] = bridge.server_port
    # Simulate separate client processes: only HTTP server threads are the debugger owner.
    monkeypatch.setattr(local_transport, "endpoint",
                        lambda: cfg if threading.current_thread() is threading.main_thread() else None)
    monkeypatch.setenv("BG3COOP_PORT", "9998")
    first, second = RealGame(), RealGame()
    try:
        result = first.call("set_agent", {"id": fake.world.sh})
        assert result["name"] == "Shadowheart"
        connection = owner.client
        assert second.call("ping")["agent"] == "Shadowheart"
        assert second.agent_id == first.agent_id == owner.agent_id
        assert first.eval("return 2+2") == "4"  # doctor-style raw evaluation
        assert second.eval("return 3+3") == "6"
        assert owner.client is connection
        fake.server.execute("BG3COOP = nil")
        assert second.call("ping")["agent"] == "Shadowheart"
        assert owner.client is connection  # reinjection did not reconnect
    finally:
        first.close()
        second.close()
        bridge.shutdown()
        bridge.server_close()
        owner.close()
