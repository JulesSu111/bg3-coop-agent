import asyncio
from pathlib import Path
import subprocess
import sys

import pytest

from bg3coop.resource_policy import ResourcePolicy
from bg3coop.task_queue import TaskQueue
from test_local import App, controller


def test_hourly_budget_persists_and_resume_cannot_reset_it(tmp_path):
    q = TaskQueue(tmp_path / "queue.db")
    now = [10000.0]
    p = ResourcePolicy(q, {"max_turns_per_hour": 2}, lambda: now[0])
    p.reserve(False)
    now[0] += 60
    p.reserve(False)
    p.player_activity()
    assert "每小时" in p.reason(False, "waiting")
    p = ResourcePolicy(q, {"max_turns_per_hour": 2}, lambda: now[0])
    assert "每小时" in p.reason(False, "waiting")
    now[0] += 3601
    assert p.reason(False, "waiting") is None
    q.close()


def test_autonomy_burst_idle_and_backward_clock(tmp_path):
    q = TaskQueue(tmp_path / "queue.db")
    now = [10000.0]
    p = ResourcePolicy(q, {"max_autonomous_turns": 2, "max_turns_per_window": 3}, lambda: now[0])
    p.reserve(True)
    p.reserve(True)
    assert "自主" in p.reason(True, "free")
    p.player_activity()
    assert p.reason(True, "free") is None
    p.reserve(False)
    assert "高频" in p.reason(False, "waiting")
    now[0] += 301
    assert "空闲" in p.reason(True, "free")
    now[0] = 9000
    assert "时间回退" in p.reason(False, "waiting")
    q.close()


@pytest.mark.parametrize("config", [{"max_turns_per_hour": 0}, {"max_autonomous_turns": 1.5},
                                     {"game_absent_interval": -1}, {"idle_timeout": float("inf")}])
def test_invalid_protection_config_rejected(tmp_path, config):
    q = TaskQueue(tmp_path / "queue.db")
    with pytest.raises(ValueError):
        ResourcePolicy(q, config)
    q.close()


def test_absent_uses_slow_cached_process_check_no_model_or_game_rpc(tmp_path):
    async def run():
        c = controller(tmp_path)
        now = [10000.0]
        c.clock = c.policy.clock = lambda: now[0]
        calls = []
        c.running = lambda: calls.append(now[0]) or False
        for _ in range(100):
            await c.poll()
        assert calls == [10000.0]
        assert c.sleep_interval == 30 and App.starts == 0 and not c.game.calls
        now[0] += 30
        await c.poll()
        assert len(calls) == 2
    asyncio.run(run())


def test_process_probe_failure_is_not_a_daemon_crash(tmp_path, caplog):
    async def run():
        c = controller(tmp_path)
        now = [10000.0]
        c.clock = lambda: now[0]
        def fail():
            raise OSError("snapshot unavailable")
        c.running = fail
        for _ in range(3):
            await c.poll()
            now[0] += 30
        assert App.starts == 0 and c.sleep_interval == 30
        assert sum("process check unavailable" in r.message for r in caplog.records) == 1
    asyncio.run(run())


def test_stop_and_wait_do_not_call_model_or_wake_for_combat(tmp_path):
    async def run():
        c = controller(tmp_path)
        await c.poll()
        for command in ("[button] Wait for me here", "[button] Stop what you are doing"):
            c.mode = "free"
            await c.command(command, command)
            c.game.events = [{"seq": 1, "kind": "your_turn"}, {"seq": 2, "kind": "dialogue_started"}]
            await c.poll()
            assert c.worker is None and c.app is None and App.turns == 0
        await c.command("/resume", "resume")
        assert c.worker is None and c.mode == "waiting"
        await c.command("hello", "hello")
        await c.poll()
        await c.worker
        assert App.turns == 1
    asyncio.run(run())


def test_autonomous_limit_pauses_without_self_cancel_or_extra_turn(tmp_path):
    async def run():
        c = controller(tmp_path)
        c.mode = "free"
        c.policy.config["max_autonomous_turns"] = 1
        await c.poll()
        await c.worker
        c.game.events = [{"seq": 1, "kind": "your_turn"}]
        await c.poll()
        task = c.worker
        await task
        assert c.mode == "paused" and App.turns == 1 and c.app is None
        assert any("自主" in line for line in c.game.posts)
        for _ in range(5):
            await c.poll()
        assert App.turns == 1
    asyncio.run(run())


def test_error_notice_disallows_internal_retry(tmp_path):
    async def run():
        c = controller(tmp_path)
        await c.poll()
        App.hang = True
        await c.command("hello", "hello")
        await c.poll()
        await asyncio.sleep(0.01)
        await c.notice("error", {"error": {"message": "Plus usage limit", "codexErrorInfo": "usageLimitExceeded"}, "willRetry": True})
        await c.error_halt
        assert c.mode == "paused" and c.app is None and c.worker is None
        assert any("usageLimitExceeded" in line and "不会自动重试" in line for line in c.game.posts)
        before = App.turns
        for _ in range(5):
            await c.poll()
        assert App.turns == before
    asyncio.run(run())


def test_idle_closes_app_server_and_pauses_autonomy(tmp_path):
    async def run():
        c = controller(tmp_path)
        now = [10000.0]
        c.clock = c.policy.clock = lambda: now[0]
        c.policy.player_activity()
        await c.poll()
        await c.command("hello", "hello")
        await c.poll()
        await c.worker
        now[0] += 61
        await c.poll()
        assert c.app is None and c.mode == "waiting" and App.turns == 1
        c.mode = "free"
        now[0] += 301
        await c.poll()
        assert c.mode == "paused" and App.turns == 1
    asyncio.run(run())


def test_standby_does_not_import_model_or_mcp_stack():
    script = "from bg3coop.tool_runtime import ToolRuntime; import sys; r=ToolRuntime(); assert r.game; assert 'bg3coop.server' not in sys.modules; assert 'mcp' not in sys.modules"
    subprocess.run([sys.executable, "-c", script], check=True, timeout=15)


def test_unchanged_settings_do_not_write_database(tmp_path):
    q = TaskQueue(tmp_path / "queue.db")
    q.set("cursor", ["epoch", 0])
    changes = q.db.total_changes
    for _ in range(100):
        q.set("cursor", ["epoch", 0])
    assert q.db.total_changes == changes
    q.close()
