"""The bridge's side of the in-game chat panel: what the human typed or clicked, Yes/No questions, and
the panel's header (who the agent plays) and its activity line (what it is doing now)."""

from __future__ import annotations

import time
from typing import Any

from .game import Game, GameError
from .handles import Handles, bare

# What the human reads in the panel, when the game runs in Simplified Chinese.
ZH = {"Yes": "是", "No": "否", "(no answer in time)": "（没有及时回答）"}

# The activity line ("doing: casting Fire Bolt -> goblin"), by the tool running now. Unlisted tools
# show their own name.
ACTS = {
    "move": "walking", "use": "using", "talk": "starting a conversation", "dialogue": "reading the dialogue",
    "choose": "picking a line", "roll": "rolling the check", "cast": "casting", "end_turn": "ending the turn",
    "wait": "waiting for news", "job_status": "waiting on an action", "look": "looking around",
    "status": "checking myself", "combat": "reading the fight", "spells": "checking spells",
    "prepare": "preparing spells", "reactions": "setting reactions", "container": "opening",
    "take": "picking up", "stop": "stopping", "regroup": "following you", "inventory": "checking the bag",
    "use_item": "using", "throw": "throwing", "equip": "equipping", "give": "handing over",
    "examine": "examining", "notes": "taking notes", "quests": "reading the journal",
    "wiki": "reading the wiki", "sneak": "sneaking", "sight": "checking who can see", "trade": "trading with",
    "travel": "travelling to", "say": "writing to you", "ask": "asking you", "party": "checking the party",
    "set_agent": "taking over", "rules": "reading the rules",
}
ZH.update({
    "using something": "使用物体", "looking around": "观察四周", "checking spells": "查看法术",
    "following you": "跟着你", "checking the bag": "查看背包", "taking notes": "记笔记",
    "reading the journal": "看任务日志", "reading the wiki": "查 wiki", "sneaking": "潜行", "asking you": "在问你",
    "walking": "走路", "using": "使用", "starting a conversation": "搭话", "reading the dialogue": "看对话",
    "picking a line": "选对白", "rolling the check": "掷检定", "casting": "施法", "ending the turn": "结束回合",
    "waiting for news": "等游戏里的动静", "waiting on an action": "等动作做完", "checking myself": "看自己状态",
    "reading the fight": "看战况", "preparing spells": "换准备法术", "setting reactions": "设反应",
    "opening": "打开", "picking up": "拿东西", "stopping": "停下", "throwing": "投掷", "equipping": "装备",
    "handing over": "递东西", "examining": "查看", "checking who can see": "看谁能看到", "trading with": "交易",
    "travelling to": "传送去", "writing to you": "给你写消息", "checking the party": "看队伍",
    "taking over": "接管角色", "getting my turn ready": "收到回合，看战况、截图", "reading the rules": "读守则", "to you": "到你身边",
})
LABEL_LEN = 60

POPUP_EVERY_S = 60  # `say urgent` pops up a message box at most this often


class Chat:
    def __init__(self, game: Game, ids: Handles) -> None:
        self.game, self.ids = game, ids
        self.heard: list[str] = []  # typed by the human, not yet handed to the agent
        self.answers: dict[int, str] = {}  # Yes/No clicks on ask questions, by question id
        self._last_popup = 0.0

    def tr(self, text: str) -> str:
        return ZH.get(text, text) if self.game.language() == "zh" else text

    # ---- activity line ----

    def label(self, tool: str, kw: dict) -> str:
        """What a tool call does, as the human reads it: "casting Fire Bolt -> Goblin"."""
        def who(ref: Any) -> str:
            return self.ids.name(ref) or "" if isinstance(ref, str) and ref else ""
        what = ""
        if tool == "cast":
            what = " ".join(x for x in (str(kw.get("spell") or ""), who(kw.get("target")) and "→ " + who(kw.get("target"))) if x)
        elif tool == "move":
            what = self.tr("to you") if kw.get("to_human") else who(kw.get("target")) or str(kw.get("direction") or "")
        elif tool in ("use_item", "throw", "equip"):
            what = " ".join(x for x in (who(kw.get("item")) or str(kw.get("item") or ""), who(kw.get("target")) and "→ " + who(kw.get("target"))) if x)
        elif tool in ("use", "talk", "examine", "container"):
            what = who(kw.get("target"))
        elif tool == "trade":
            what = who(kw.get("merchant"))
        elif tool == "travel":
            what = str(kw.get("waypoint") or kw.get("to") or "")
        elif tool == "choose":
            what = f"#{kw.get('n')}"
        elif tool == "wiki":
            what = str(kw.get("query") or "")
        verb = self.tr(ACTS.get(tool, tool))
        return f"{verb} {what}".strip()[:LABEL_LEN]

    def begin(self, tool: str, kw: dict) -> dict:
        """Show the tool that starts now on the activity line; returns what `end` needs."""
        text = self.label(tool, kw)
        args: dict[str, Any] = {"busy": text}
        if self.game.agent_id:
            args["agent"] = bare(self.game.agent_id)
        try:
            self.game.call("chat_activity", args, context="client")
        except GameError:
            pass
        return {"done": text}

    def doing(self, what: str) -> None:
        """Change what the activity line says the running tool is doing (`what` is English)."""
        try:
            self.game.call("chat_activity", {"busy": self.tr(what)}, context="client")
        except GameError:
            pass

    def end(self, started: dict, result: Any) -> dict:
        """The activity update that rides on the next chat_take: the tool ended (failed when the
        result is an error), and whether it handed the agent its combat turn."""
        out = dict(started, at=time.strftime("%H:%M:%S"))
        if isinstance(result, dict):
            out["ok"] = "error" not in result
            events = result.get("events") if isinstance(result.get("events"), list) else []
            if "your_turn" in result or any(isinstance(e, dict) and e.get("kind") == "your_turn" for e in events):
                out["turn_ack"] = True
        return out

    # ---- header ----

    def header(self) -> dict | None:
        """The panel's header: who the agent plays."""
        return {"name": self.game.agent_name} if self.game.agent_name else None

    # ---- what the human sends ----

    def _pointing(self, point: dict) -> str:
        """A middle-click mark from the human, as a line the agent can act on."""
        args = {"id": point["id"]} if point.get("id") else {"pos": point.get("pos")}
        try:
            p = self.game.call("pointed", args)
        except GameError:
            return "[pointing at] something you cannot place"
        where = f"{p['dist']} m {p['dir']} of you" if p.get("dist") is not None else "somewhere"
        if point.get("id"):
            return f"[pointing at] {p.get('name', '?')} ({self.ids.handle(point['id'])}, {p.get('rel')}, {where})"
        x, y, z = point["pos"]
        return f"[pointing at] the ground at x={x} y={y} z={z} ({where})"

    def listen(self, hud: dict | None = None, activity: dict | None = None) -> bool:
        """Collect what the human sent; True when there are lines for the agent. `hud` refreshes
        the header, `activity` the activity line (from `end`)."""
        try:
            texts, answers = self.game.chat_take(hud, activity)
            self.heard.extend(t if isinstance(t, str) else self._pointing(t["point"]) for t in texts)
            self.answers.update(answers)
        except GameError:
            pass
        return bool(self.heard)

    def take_heard(self) -> list[str]:
        out, self.heard = self.heard, []
        return out

    # ---- questions ----

    def ask(self, question: str, seconds: float) -> dict:
        """Post a Yes/No question and wait up to `seconds` for a click or a typed reply."""
        ask_id = self.game.chat_ask(question)
        return self._wait_answer(ask_id, time.monotonic() + seconds)

    def _wait_answer(self, ask_id: int, deadline: float) -> dict:
        while True:
            self.game._authority()
            self.listen()
            if ask_id in self.answers:
                answer = self.answers.pop(ask_id)
                self.game.chat_ask_close(ask_id, self.tr(answer.capitalize()))
                return {"answer": answer}
            if self.heard:
                reply = self.heard.pop(0)
                self.game.chat_ask_close(ask_id, "")
                return {"reply": reply}
            if time.monotonic() >= deadline:
                self.game.chat_ask_close(ask_id, self.tr("(no answer in time)"), kind="note")
                return {"timed_out": True, "hint": "they may be busy; carry on and ask again later if it matters"}
            time.sleep(0.5)

    def popup_allowed(self) -> bool:
        """Whether an urgent pop-up may be shown now; counts it when it may."""
        if time.monotonic() - self._last_popup < POPUP_EVERY_S:
            return False
        self._last_popup = time.monotonic()
        return True
