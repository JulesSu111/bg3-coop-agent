"""Persistent, local-only turn budget. A turn is an attempted turn/start, not a token estimate."""
import math
import time


DEFAULTS = {
    "game_absent_interval": 30,
    "menu_poll_interval": 5,
    "process_check_interval": 2,
    "max_turns_per_hour": 30,
    "max_autonomous_turns": 6,
    "idle_timeout": 300,
    "codex_idle_timeout": 60,
    "burst_window_seconds": 30,
    "max_turns_per_window": 4,
}


class ResourcePolicy:
    def __init__(self, queue, config, clock=time.time):
        self.queue, self.clock = queue, clock
        self.config = {**DEFAULTS, **config}
        for key in DEFAULTS:
            value = self.config[key]
            if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or value <= 0:
                raise ValueError(f"{key} must be positive and finite")
        for key in ("max_turns_per_hour", "max_autonomous_turns", "max_turns_per_window"):
            if int(self.config[key]) != self.config[key]:
                raise ValueError(f"{key} must be an integer")
        self.history = queue.get("turn_attempts", [])
        self.autonomous = queue.get("autonomous_count", 0)
        self.last_player = queue.get("last_player_activity", self.clock())

    def player_activity(self):
        self.last_player = self.clock()
        self.autonomous = 0
        self.queue.set("last_player_activity", self.last_player)
        self.queue.set("autonomous_count", 0)

    def reason(self, autonomous, mode):
        now = self.clock()
        if any(at > now + 1 for at in self.history):
            return "系统时间回退，额度计数无法安全计算"
        self.history = [at for at in self.history if at > now - 3600]
        if len(self.history) >= self.config["max_turns_per_hour"]:
            return "已达到每小时模型回合上限"
        if sum(at > now - self.config["burst_window_seconds"] for at in self.history) >= self.config["max_turns_per_window"]:
            return "模型调用异常高频，已触发频率保护"
        if autonomous and self.autonomous >= self.config["max_autonomous_turns"]:
            return "已达到连续自主行动回合上限"
        if mode in {"free", "follow"} and now - self.last_player >= self.config["idle_timeout"]:
            return "玩家空闲超时"

    def reserve(self, autonomous):
        # Persist BEFORE sending: even a lost response must count against the local budget.
        self.history.append(self.clock())
        self.autonomous = self.autonomous + 1 if autonomous else 0
        self.queue.set("turn_attempts", self.history)
        self.queue.set("autonomous_count", self.autonomous)
