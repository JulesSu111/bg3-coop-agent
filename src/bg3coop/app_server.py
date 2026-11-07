"""Small official Codex App Server stdio client; OAuth stays in Codex's credential store."""
from __future__ import annotations

import asyncio
import json
import os


class AppServer:
    def __init__(self, executable, on_request, on_notice):
        self.executable, self.on_request, self.on_notice = executable, on_request, on_notice
        self.pending = {}
        self.serial = 0
        self.proc = None
        self.reader = None
        self.requests = set()

    async def start(self):
        env = {k: v for k, v in os.environ.items() if k not in ("OPENAI_API_KEY", "CODEX_API_KEY")}
        self.proc = await asyncio.create_subprocess_exec(
            self.executable, "app-server", stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, env=env,
            creationflags=0x08000000 if os.name == "nt" else 0, limit=16 * 1024 * 1024)
        self.reader = asyncio.create_task(self._read())
        await self.call("initialize", {"clientInfo": {"name": "bg3coop_local", "version": "0.1"},
                                       "capabilities": {"experimentalApi": True}})
        await self.send({"method": "initialized"})
        account = (await self.call("account/read", {"refreshToken": True})).get("account")
        if not account or account.get("type") != "chatgpt":
            raise RuntimeError("需要当前 Windows 用户已有的 Codex ChatGPT OAuth 登录；拒绝使用 API Key")

    async def send(self, value):
        self.proc.stdin.write((json.dumps(value, ensure_ascii=False) + "\n").encode())
        await self.proc.stdin.drain()

    async def call(self, method, params, timeout=45):
        self.serial += 1
        ident = self.serial
        future = asyncio.get_running_loop().create_future()
        self.pending[ident] = future
        try:
            await self.send({"id": ident, "method": method, "params": params})
            return await asyncio.wait_for(future, timeout)
        finally:
            self.pending.pop(ident, None)

    async def _request(self, message):
        try:
            result = await self.on_request(message["method"], message.get("params", {}))
            await self.send({"id": message["id"], "result": result})
        except Exception as exc:
            await self.on_notice("local/toolError", {"error": str(exc) or type(exc).__name__})
            await self.send({"id": message["id"], "error": {"code": -32000, "message": str(exc)}})

    async def _read(self):
        try:
            while line := await self.proc.stdout.readline():
                message = json.loads(line)
                if "method" in message:
                    if "id" in message:
                        task = asyncio.create_task(self._request(message))
                        self.requests.add(task)
                        task.add_done_callback(self.requests.discard)
                    else:
                        await self.on_notice(message["method"], message.get("params", {}))
                elif message.get("id") in self.pending:
                    future = self.pending[message["id"]]
                    if not future.done():
                        if "error" in message:
                            future.set_exception(RuntimeError(json.dumps(message["error"], ensure_ascii=False)))
                        else:
                            future.set_result(message.get("result", {}))
        except Exception as exc:
            failure = exc
        else:
            failure = ConnectionError("Codex App Server exited")
        finally:
            for future in self.pending.values():
                if not future.done():
                    future.set_exception(failure)
            await self.on_notice("local/disconnected", {"error": str(failure)})

    async def close(self):
        if self.proc and self.proc.returncode is None:
            self.proc.kill()
            await self.proc.wait()
        if self.reader:
            await asyncio.gather(self.reader, return_exceptions=True)
        requests = list(self.requests)
        for task in requests:
            task.cancel()
        await asyncio.gather(*requests, return_exceptions=True)
