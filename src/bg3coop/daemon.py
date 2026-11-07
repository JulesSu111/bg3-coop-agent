"""Windows local supervisor, debugger owner and event-driven Codex controller."""
from __future__ import annotations

import argparse
import asyncio
import hmac
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .app_server import AppServer
from .local_transport import data_dir
from .task_queue import TaskQueue
from .resource_policy import ResourcePolicy
from .process_watch import game_running

LOG = logging.getLogger("bg3coop.local")
READ_ONLY = {"rules", "party", "status", "look", "combat", "spells", "inventory", "examine",
             "dialogue", "quests", "sight", "say", "ask", "wiki", "notes", "stop"}
WAKE_EVENTS = {"your_turn", "summon_turn", "dialogue_started", "combat_started", "combat_ended"}
LOCAL_RULES = """You are a BG3 companion controlled from the in-game panel.
Use only the supplied bg3_* tools. Never use shell, file changes, other MCP services or wait loops.
The local controller polls game events and starts a new turn when needed. Finish each bounded task
and return; do not keep calling wait. Read rules for game mechanics, but its continuous-wait advice
is superseded by these local instructions. First inspect party/status. Take over only the companion
the player explicitly names with set_agent; do not select one automatically.
In waiting mode answer and inspect only; never move, attack, start dialogue or change the game.
In free mode continue exploration in bounded turns.
In follow mode stay near the human; do not start unrelated exploration.
Always check current game state before acting, especially after load, timeout or interrupted work:
an earlier action may already have happened.
All replies and errors belong in the game panel. Ask the player there when information is missing.
"""


class BridgeServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False


def start_bridge(game, config):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            if self.path != "/rpc" or not hmac.compare_digest(
                    self.headers.get("Authorization", ""), "Bearer " + config["token"]):
                self.send_error(403)
                return
            try:
                length = int(self.headers.get("Content-Length", 0))
                if not 0 < length <= 1024 * 1024:
                    self.send_error(413)
                    return
                message = json.loads(self.rfile.read(length))
                if message["method"] == "game_call":
                    value = {"value": game.call(**message["params"]),
                             "identity": {"agent": game.agent_id, "human": game.human_id, "name": game.agent_name}}
                else:
                    with game.lock:
                        client = game._connect()
                        if message["method"] == "connect":
                            value = client.server_version
                        elif message["method"] == "evaluate":
                            value = client.evaluate(**message["params"])
                        else:
                            raise ValueError("unknown method")
                reply = {"result": value}
            except Exception as exc:
                reply = {"error": str(exc), "error_type": type(exc).__name__}
            body = json.dumps(reply, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    server = BridgeServer(("127.0.0.1", int(config["port"])), Handler)
    threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 2}, daemon=True).start()
    return server


class Controller:
    def __init__(self, config, root, srv, running=game_running, app_factory=AppServer, clock=time.time):
        self.config, self.root, self.srv = config, root, srv
        self.game, self.running, self.app_factory = srv.game, running, app_factory
        self.queue = TaskQueue(root / "tasks.sqlite3")
        self.policy = ResourcePolicy(self.queue, config, clock)
        self.clock = clock
        self.sleep_interval = self.policy.config["game_absent_interval"]
        self.process_next_check = 0
        self.process_alive = False
        self.last_process_error = None
        self.last_model_activity = clock()
        self.error_halt = None
        self.mode = self.queue.get("mode", "waiting")
        if self.queue.db.execute("SELECT 1 FROM tasks WHERE state IN ('interrupted','failed') LIMIT 1").fetchone():
            self.mode = "paused"
            self.queue.set("mode", self.mode)
            if not self.queue.get("pause_reason"):
                self.queue.set("pause_reason", "上次任务失败或结果未知，请核对状态后继续")
        self.ready = False
        self.epoch, self.seq = self.queue.get("cursor", [None, 0])
        self.app = None
        self.thread = self.queue.get("thread")
        self.turn = None
        self.active = None
        self.token = uuid.uuid4().hex
        self.done = None
        self.failed = None
        self.worker = None
        self.lock = asyncio.Lock()
        self.last_free = 0
        self.status = None
        self.tools = {}
        self.tool_context = threading.local()
        self.game._local_guard = self.guard

    async def close_app(self):
        app, self.app = self.app, None
        if app:
            await app.close()

    async def halt(self, reason, state="interrupted"):
        self.mode = "paused"
        self.queue.set("mode", self.mode)
        self.queue.set("pause_reason", reason)
        await self.interrupt(reason, state=state, immediate=(state == "failed"))
        await self.post("已暂停自动模型任务: " + reason + "。不会自动重试；请处理后点击继续。")

    def guard(self):
        context = getattr(self.tool_context, "task", None)
        if context is not None and (context != (self.active, self.token) or not self.ready):
            from .game import GameError
            raise GameError("Local task was interrupted; stale tool execution rejected")

    async def post(self, text, kind="note"):
        LOG.info("panel: %s", text)
        try:
            await asyncio.to_thread(self.game.chat_post, text, kind)
        except Exception:
            LOG.exception("panel unavailable; message retained in log")

    async def notice(self, method, params):
        if method == "item/completed" and params.get("item", {}).get("type") == "agentMessage":
            await self.post(params["item"].get("text", ""), "agent")
        if method == "turn/completed" and (not self.turn or params.get("turn", {}).get("id") == self.turn):
            turn = params.get("turn", {})
            if turn.get("status") != "completed":
                self.failed = json.dumps(turn.get("error") or turn.get("status"), ensure_ascii=False)
            if self.done:
                self.done.set()
        if method == "error":
            reason = "Codex 额度/网络/认证或服务错误: " + json.dumps(params.get("error", params), ensure_ascii=False)
            # Even willRetry=true must not let App Server silently keep retrying.
            self.failed = reason
            if self.app and (not self.error_halt or self.error_halt.done()):
                self.error_halt = asyncio.create_task(self.halt(reason, state="failed"))
        if method == "local/toolError":
            await self.post("工具执行失败: " + params["error"])
        if method == "local/disconnected":
            if self.app is None:  # intentional close
                return
            self.failed = params["error"]
            if self.done:
                self.done.set()
            if not self.active and (not self.error_halt or self.error_halt.done()):
                self.error_halt = asyncio.create_task(self.halt("Codex 连接中断: " + params["error"], state="failed"))

    async def tool_request(self, method, params):
        if method != "item/tool/call":
            await self.post("已拒绝非游戏工具或系统权限请求: " + method)
            raise PermissionError("Only game dynamic tools are authorized")
        if self.turn and params.get("turnId") != self.turn:
            raise PermissionError("Stale turn tool request")
        name = params.get("tool", "").removeprefix("bg3_")
        args = params.get("arguments", {})
        if isinstance(args, str):
            args = json.loads(args)
        async with self.lock:
            if not self.ready or not self.active or name not in self.tools:
                raise PermissionError("Game unavailable or task cancelled")
            if self.mode in {"waiting", "paused"} and name not in READ_ONLY:
                raise PermissionError("Waiting/paused mode forbids game actions")
            # notes writes are local memory, never a save-file edit; wait is never advertised.
            fn = getattr(self.srv, name)
            ident = (self.active, self.token)
            def invoke():
                self.tool_context.task = ident
                try:
                    return fn(**args)
                finally:
                    self.tool_context.task = None
            try:
                value = await asyncio.wait_for(asyncio.to_thread(invoke), self.config["tool_timeout"])
            except TimeoutError:
                self.failed = "游戏工具超时，执行结果未知，需核对状态"
                self.active = None
                if self.done:
                    self.done.set()
                raise TimeoutError(self.failed)
        if isinstance(value, dict) and "error" in value:
            await self.post("游戏工具错误: " + str(value["error"]))
        # Preserve screenshots returned by the existing MCP wrappers.
        if hasattr(value, "content"):
            items = []
            for block in value.content:
                if block.type == "text":
                    items.append({"type": "inputText", "text": block.text})
                elif block.type == "image":
                    items.append({"type": "inputImage", "imageUrl": f"data:{block.mimeType};base64,{block.data}"})
        else:
            items = [{"type": "inputText", "text": json.dumps(value, ensure_ascii=False, default=str)}]
        return {"contentItems": items, "success": not (isinstance(value, dict) and "error" in value)}

    async def connect_app(self):
        if self.app:
            return
        self.app = self.app_factory(self.config["codex"], self.tool_request, self.notice)
        await self.app.start()
        tools = await self.srv.mcp.list_tools()
        self.tools = {t.name: t for t in tools if t.name not in {"wait", "job_status"}}
        params = {"cwd": str(self.root), "approvalPolicy": "untrusted", "sandbox": "read-only", "modelProvider": "openai",
                  "baseInstructions": LOCAL_RULES,
                  "config": {"mcp_servers": {}, "features.shell_tool": False,
                             "features.apply_patch_freeform": False, "web_search": "disabled",
                             "apps._default.enabled": False, "forced_login_method": "chatgpt"}}
        # Empty maps can merge with user config. Disable every inherited MCP server explicitly.
        effective = await self.app.call("config/read", {"includeLayers": False})
        inherited = effective.get("config", {}).get("mcp_servers", {})
        for name in inherited:
            params["config"][f"mcp_servers.{name}.enabled"] = False
        if self.config.get("model"):
            params["model"] = self.config["model"]
        if self.thread:
            params["threadId"] = self.thread
            result = await self.app.call("thread/resume", params)
        else:
            params["dynamicTools"] = [{"type": "function", "name": "bg3_" + t.name, "description": t.description or t.name,
                                        "inputSchema": t.input_schema} for t in self.tools.values()]
            result = await self.app.call("thread/start", params)
        self.thread = result["thread"]["id"]
        self.queue.set("thread", self.thread)

    async def interrupt(self, reason, state="interrupted", immediate=False):
        # Revoke tool permission before sending the interrupt; late requests are rejected.
        if self.active:
            self.queue.finish(self.active, state, reason)
            self.active = None
        if self.app and self.turn and not immediate:
            try:
                await self.app.call("turn/interrupt", {"threadId": self.thread, "turnId": self.turn}, timeout=5)
            except Exception:
                LOG.exception("interrupt failed")
        if self.worker and self.worker is not asyncio.current_task() and not self.worker.done():
            self.worker.cancel()
            await asyncio.gather(self.worker, return_exceptions=True)
        self.worker = None
        await self.close_app()
        self.turn = None
        # Existing game jobs are explicitly stopped too, not just model generation.
        if self.game.agent_id and self.ready:
            try:
                await asyncio.to_thread(self.game.call, "stop", {})
            except Exception:
                LOG.exception("could not stop game job")

    async def execute(self, task):
        ident, payload = task
        autonomous = not (isinstance(payload, dict) and "message" in payload)
        reason = self.policy.reason(autonomous, self.mode)
        if reason:
            self.queue.finish(ident, "pending", reason)
            await self.halt(reason)
            return
        self.active = ident
        self.token = uuid.uuid4().hex
        self.failed = None
        self.done = asyncio.Event()
        try:
            await self.connect_app()
            if not self.ready or self.mode == "paused" or self.failed:
                raise RuntimeError(self.failed or "游戏未就绪或任务已暂停")
            reason = self.policy.reason(autonomous, self.mode)
            if reason:
                raise RuntimeError(reason)
            text = LOCAL_RULES + "\nCurrent mode: " + self.mode + "\nTask: " + json.dumps(payload, ensure_ascii=False)
            self.policy.reserve(autonomous)
            self.last_model_activity = self.clock()
            reply = await self.app.call("turn/start", {"threadId": self.thread,
                                        "input": [{"type": "text", "text": text}]})
            self.turn = reply["turn"]["id"]
            await asyncio.wait_for(self.done.wait(), self.config["task_timeout"])
            if self.failed:
                raise RuntimeError(self.failed)
            if self.active == ident:
                self.queue.finish(ident, "completed")
            self.last_model_activity = self.clock()
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self.queue.finish(ident, "failed", str(exc))
            self.active = None
            self.mode = "paused"
            self.queue.set("mode", self.mode)
            self.queue.set("pause_reason", str(exc) or type(exc).__name__)
            await self.post("任务未完成，已暂停（额度/认证/网络或执行错误）: " + (str(exc) or type(exc).__name__) + "。不会自动重试，请处理后点击继续。")
            if self.game.agent_id and self.ready:
                try:
                    await asyncio.to_thread(self.game.call, "stop", {})
                except Exception:
                    LOG.exception("stop after failure failed")
            await self.close_app()
        finally:
            self.active = None
            self.turn = None

    async def command(self, text, key):
        self.policy.player_activity()
        normalized = text.strip().lower() if isinstance(text, str) else ""
        if normalized in {"/pause", "/stop", "pause", "stop", "暂停", "停下", "停止"} or normalized.startswith("[button] stop"):
            self.mode = "paused"
            self.queue.set("mode", self.mode)
            self.queue.set("pause_reason", "玩家暂停")
            self.queue.cancel_pending()
            await self.interrupt("玩家暂停")
            await self.post("已暂停；点击继续恢复。")
            return
        if normalized in {"/resume", "继续"}:
            self.mode = "waiting"
            self.queue.recover()
            self.queue.set("mode", self.mode)
            self.queue.set("pause_reason", None)
            await self.post("已继续；当前为等待模式。额度保护计数不会清零。")
            return
        elif normalized.startswith("[button] wait") or normalized in {"/wait", "wait", "wait for me", "等待", "等我"}:
            self.mode = "waiting"
            self.queue.cancel_pending()
            await self.interrupt("玩家要求等待")
            self.queue.set("mode", self.mode)
            await self.post("已停止当前动作并等待；游戏事件不再自动调用模型，发送新消息仍可回复。")
            return
        elif normalized.startswith("[button] explore") or normalized == "/free":
            self.mode = "free"
        elif normalized.startswith("[button] follow"):
            self.mode = "follow"
        elif normalized.startswith("/agent "):
            async with self.lock:
                value = await asyncio.to_thread(self.srv.set_agent, text.strip()[7:])
            await self.post(json.dumps(value, ensure_ascii=False, default=str))
            return
        self.queue.set("mode", self.mode)
        self.queue.put(key, {"message": text, "reconcile": True})

    async def poll(self):
        now = self.clock()
        if now >= self.process_next_check:
            try:
                self.process_alive = await asyncio.to_thread(self.running)
                self.last_process_error = None
            except Exception as exc:
                self.process_alive = False
                if self.last_process_error is None or now - self.last_process_error >= 300:
                    LOG.warning("process check unavailable; waiting locally without restart: %s", exc)
                    self.last_process_error = now
            interval = self.policy.config["process_check_interval"] if self.process_alive else self.policy.config["game_absent_interval"]
            self.process_next_check = now + interval
        if not self.process_alive:
            self.sleep_interval = self.policy.config["game_absent_interval"]
            if self.ready or self.app:
                self.ready = False
                await self.interrupt("游戏已关闭")
            self.game.close()
            return
        self.sleep_interval = self.policy.config["menu_poll_interval"]
        try:
            # Server Lua must exist AND a live host entity must be in the loaded world.
            ready = await asyncio.to_thread(self.game.eval,
                "local h = Osi and Osi.GetHostCharacter and Osi.GetHostCharacter(); "
                "return tostring(Ext.Utils.GetGameState()) == 'Running' "
                "and h ~= nil and h ~= '' and Ext.Entity.Get(h) ~= nil", "server", 3)
            if ready.strip() != "true":
                raise RuntimeError("存档尚未就绪")
            await asyncio.to_thread(self.game.call, "ping", {}, "client")
            events = await asyncio.to_thread(self.game.call, "events", {"epoch": self.epoch, "since": self.seq})
            changed = events["epoch"] != self.epoch
            if changed:
                await self.interrupt("存档已重新载入", state="cancelled")
                self.queue.cancel_pending()
                self.epoch, self.seq = events["epoch"], 0
                if self.mode in {"free", "follow"}:
                    self.queue.put("load:" + self.epoch, {"event": "save_loaded", "reconcile": True})
            elif not self.ready and self.mode in {"free", "follow"}:
                self.queue.put("reconnect:" + uuid.uuid4().hex,
                               {"event": "connection_restored", "reconcile": True})
            self.ready = True
            # Durable inbox is acknowledged only after SQLite commit.
            inbox = await asyncio.to_thread(self.game.call, "local_inbox", {}, "client")
            for msg in inbox["messages"]:
                await self.command(msg["text"], "chat:" + inbox["epoch"] + ":" + str(msg["id"]))
                await asyncio.to_thread(self.game.call, "local_ack", {"id": msg["id"]}, "client")
            for event in events["events"]:
                if event["kind"] in WAKE_EVENTS and self.mode in {"free", "follow"}:
                    self.queue.put(f"event:{self.epoch}:{event['seq']}", event)
            self.seq = events["latest"]
            self.queue.set("cursor", [self.epoch, self.seq])
            identity = {"agent": self.game.agent_id, "human": self.game.human_id,
                        "name": self.game.agent_name}
            self.queue.set("identity", identity)
            if not self.status or self.status != self.epoch:
                detail = self.queue.get("pause_reason") if self.mode == "paused" else None
                await self.post("本地桥接和面板已就绪。/agent 角色名 接管；当前模式: " + self.mode
                                + ("；暂停原因: " + detail if detail else ""))
                self.status = self.epoch
            self.sleep_interval = max(0.25, self.config["poll_interval"])
        except Exception as exc:
            if self.ready:
                self.ready = False
                self.status = None
                await self.interrupt("游戏断线或加载中")
            LOG.debug("waiting for loaded game: %s", exc)
            return
        if self.worker and self.worker.done():
            await asyncio.gather(self.worker, return_exceptions=True)
            self.worker = None
        if self.mode in {"free", "follow"} and now - self.policy.last_player >= self.policy.config["idle_timeout"]:
            await self.halt("玩家空闲超时")
            return
        if not self.worker and self.app and now - self.last_model_activity >= self.policy.config["codex_idle_timeout"]:
            await self.close_app()
        if self.ready and self.mode != "paused" and not self.worker:
            task = self.queue.next()
            if not task and self.mode in {"free", "follow"} and time.monotonic() - self.last_free >= self.config["free_interval"]:
                self.last_free = time.monotonic()
                self.queue.put("continue:" + uuid.uuid4().hex, {"event": "continue_" + self.mode})
                task = self.queue.next()
            if task:
                self.worker = asyncio.create_task(self.execute(task))

    async def run(self):
        identity = self.queue.get("identity", {})
        self.game.agent_id, self.game.human_id = identity.get("agent"), identity.get("human")
        self.game.agent_name = identity.get("name")
        try:
            while True:
                await self.poll()
                await asyncio.sleep(self.sleep_interval)
        finally:
            await self.interrupt("后台控制器退出")
            self.queue.close()


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args(argv)
    os.environ["BG3COOP_BRIDGE_OWNER"] = "1"
    os.environ.pop("BG3COOP_SSH_HOST", None)
    os.environ["BG3COOP_PORT"] = "9998"
    root = data_dir()
    root.mkdir(parents=True, exist_ok=True)
    handler = RotatingFileHandler(root / "daemon.log", maxBytes=2_000_000, backupCount=3, encoding="utf-8")
    logging.basicConfig(level=logging.INFO, handlers=[handler], format="%(asctime)s %(levelname)s %(message)s")
    config = json.loads(args.config.read_text(encoding="utf-8-sig"))
    from .tool_runtime import ToolRuntime
    srv = ToolRuntime()
    endpoint = json.loads((root / "bridge.json").read_text(encoding="utf-8-sig"))
    try:
        bridge = start_bridge(srv.game, endpoint)  # exclusive bind also prevents duplicate owners
    except OSError:
        LOG.error("Bridge port already occupied; refusing a second debugger owner")
        return 2
    controller = Controller(config, root, srv)
    try:
        asyncio.run(controller.run())
    except Exception:
        LOG.exception("daemon terminated unexpectedly")
        raise
    finally:
        bridge.shutdown()
        bridge.server_close()
        srv.game.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
