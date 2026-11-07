"""Exercise JSON-RPC framing without contacting a model or reading credentials."""
import asyncio
import json

import pytest

from bg3coop.app_server import AppServer


class Process:
    def __init__(self, account="chatgpt"):
        self.stdout = asyncio.StreamReader()
        self.stdin = self
        self.returncode = None
        self.messages = []
        self.account = account

    def write(self, line):
        message = json.loads(line)
        self.messages.append(message)
        if "method" not in message or "id" not in message:
            return
        method = message["method"]
        if method == "timeout":
            return
        result = {"account": {"type": self.account}} if method == "account/read" else {}
        reply = {"id": message["id"], "result": result}
        if method == "fail":
            reply = {"id": message["id"], "error": {"code": -1, "message": "quota exhausted"}}
        self.feed(reply)

    def feed(self, message):
        self.stdout.feed_data((json.dumps(message) + "\n").encode())

    async def drain(self):
        pass

    def kill(self):
        self.returncode = -1
        self.stdout.feed_eof()

    async def wait(self):
        return self.returncode


def test_stdio_handshake_dispatch_error_timeout_and_disconnect(monkeypatch):
    async def run():
        process = Process()
        notices = []
        requests = []
        async def create(*args, **kwargs):
            assert args == ("codex.exe", "app-server")
            assert "OPENAI_API_KEY" not in kwargs["env"]
            assert "CODEX_API_KEY" not in kwargs["env"]
            return process
        async def request(method, params):
            requests.append((method, params))
            return {"success": True, "contentItems": []}
        async def notice(method, params):
            notices.append(method)
        monkeypatch.setattr(asyncio, "create_subprocess_exec", create)
        monkeypatch.setenv("OPENAI_API_KEY", "must-not-be-used")
        monkeypatch.setenv("CODEX_API_KEY", "must-not-be-used")
        app = AppServer("codex.exe", request, notice)
        await app.start()
        assert [m["method"] for m in process.messages] == ["initialize", "initialized", "account/read"]
        with pytest.raises(RuntimeError, match="quota exhausted"):
            await app.call("fail", {})
        with pytest.raises(TimeoutError):
            await app.call("timeout", {}, timeout=0.01)
        process.feed({"method": "turn/completed", "params": {"turn": {"id": "t", "status": "completed"}}})
        process.feed({"id": "request-1", "method": "item/tool/call", "params": {"tool": "bg3_status"}})
        await asyncio.sleep(0.01)
        assert "turn/completed" in notices
        assert requests == [("item/tool/call", {"tool": "bg3_status"})]
        assert any(m.get("id") == "request-1" and m.get("result", {}).get("success") for m in process.messages)
        await app.close()
        assert "local/disconnected" in notices and not app.pending
    asyncio.run(run())


@pytest.mark.parametrize("account", ["apiKey", "amazonBedrock", "unknown"])
def test_rejects_non_chatgpt_login(monkeypatch, account):
    async def run():
        process = Process(account)
        async def create(*args, **kwargs):
            return process
        async def noop(*args):
            pass
        monkeypatch.setattr(asyncio, "create_subprocess_exec", create)
        app = AppServer("codex.exe", noop, noop)
        try:
            with pytest.raises(RuntimeError, match="OAuth"):
                await app.start()
        finally:
            await app.close()
    asyncio.run(run())
