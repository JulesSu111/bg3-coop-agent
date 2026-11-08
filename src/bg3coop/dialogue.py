"""Conversations on screen and their skill checks. client.lua reads the dialogue widget and the dice
window; the server side says which dialogue the agent's character is in and whose it is."""

from __future__ import annotations

import re
import time
from typing import Any

from .game import Game, GameError
from .handles import bare


SAID_SHOWN = 40  # at most this many unread lines per read


def view(game: Game) -> dict:
    """The conversation on screen, with `yours` and, in the agent's own, a waiting skill check.
    `said` holds the lines spoken since the last read (also once the conversation is over),
    recorded in the game as they come, so lines the human clicked past are there too."""
    st = game.call("status")
    mine = st.get("dialog")
    protagonist = st.get("control_mode") == "protagonist"
    if mine:
        if protagonist:
            d = game.protagonist_ui("dialogue", ui_args(st))
            d["yours"] = bool(mine.get("yours") and d.pop("verified", False))
            d.pop("snapshot", None)
        else:
            d = game.call("dialogue", {"instance": mine["instance"]}, context="client")
            d["yours"] = bool(mine.get("yours"))
        if not d.get("open"):
            d["note"] = "your character is in a conversation but nothing is on screen (a short remark, or it is ending)"
    else:
        d = game.call("dialogue", context="client")
        d["yours"] = False
    d.pop("answerer", None)
    d.pop("instance", None)
    said = d.pop("said", None) or []
    if d.get("open") and said and d.get("line") and said[-1].endswith(d["line"]):
        said.pop()  # the line on screen, shown as `line`
    if said:
        d["said"] = said[-SAID_SHOWN:]
    if d.get("open") and not d["yours"]:
        d["note"] = "this is the human's conversation: do not answer it"
    elif d.get("open"):
        if protagonist:
            r = {}
            if d.get("dice_visible"):
                try:
                    r = game.protagonist_ui("roll_state", roll_args(game, st))
                except GameError as exc:
                    d["note"] = "dice ownership could not be verified; wait for the player: " + str(exc)
        else:
            r = game.call("roll_state", context="client")
        if r.get("state") in {"waiting", "rolling", "done"}:
            d["roll"] = {k: r[k] for k in ("skill", "dc", "need", "state") if r.get(k) is not None}
            me = st.get("id")
            mine_ = [b.get("name") or b.get("spell") for b in r.get("boosts") or [] if b.get("owner") and me
                     and b["owner"].lower() in me.lower()]
            if mine_:
                d["roll"]["your_boosts"] = mine_
            d["note"] = "a skill check is waiting for its dice (`need` = what the d20 must show): throw them with `roll`"
    if d.pop("dice_unknown", False):
        d["note"] = "dice window state is unclear; wait for the player"
    if d.pop("dice_visible", False) and "roll" not in d:
        d["note"] = "dice are visible but cannot be verified; wait for the player"
    return d


def ui_args(st: dict) -> dict:
    return {"owner": bare(st["id"]), "instance": st["dialog"]["instance"]}


def roll_args(game: Game, st: dict) -> dict:
    args = ui_args(st)
    result = game.call("dialogue_roll", {"instance": args["instance"]})
    if not result.get("roll_id"):
        raise GameError("no verified dice request for the protagonist's current dialogue")
    return {**args, "roll_id": result["roll_id"]}


# A conservative extra guard for explicit danger tags/wording. Story consequences are
# contextual; the controller's policy still requires confirmation whenever they are unclear.
def possibly_irreversible(text: str) -> bool:
    return bool(re.search(r"\b(attack|kill|execute|sacrifice|betray|swear|pledge|banish|abandon)\b"
                          r"|攻击|杀死|处决|献祭|背叛|效忠|驱逐|离队", text, re.IGNORECASE))


def choice_line(game: Game, chose: str, why: str) -> str:
    """What the chat panel shows after the agent answered: the answer, and why."""
    why = why.strip()[:200]
    if game.language() == "zh":
        return f"[选择] {chose}" + (f" —— {why}" if why else "")
    return f"[chose] {chose}" + (f" - {why}" if why else "")


def _until(call, state: str) -> dict | str:
    """Wait for the dice window to reach `state`; a string says why it did not."""
    deadline = time.monotonic() + 10
    while True:
        info = call("roll_state")
        if not info.get("state"):
            return "the roll closed before the result showed; read dialogue"
        if info["state"] == state:
            return info
        if time.monotonic() > deadline:
            return "the dice are still rolling; call roll again"
        time.sleep(0.5)


def _throw(call, reroll: bool = False) -> dict | str:
    if reroll:
        call("roll", step="reroll")
        got = _until(call, "waiting")
        if isinstance(got, str):
            return got
    call("roll", step="throw")
    return _until(call, "done")


def roll(game: Game, reroll_if_failed: bool = False, use_boosts: bool = False) -> Any:
    st = game.call("status")
    mine = st.get("dialog")
    if not mine or not mine.get("yours"):
        return {"error": "there is no check in your own conversation; the human rolls for theirs"}
    if st.get("control_mode") == "protagonist":
        args = roll_args(game, st)

        def call(op, **kwargs):
            return game.protagonist_ui(op, {**args, **kwargs})

        initial = call("roll_state")
        if initial.get("state") not in {"waiting", "done"}:
            return {"error": "the dice are not ready; read dialogue again"}
        if initial["state"] == "done":
            use_boosts = False
    else:
        def call(op, **kwargs):
            return game.call(op, kwargs, context="client")

    boosted: list = []
    if use_boosts and st.get("id"):
        boosted = call("roll_boost", owner=bare(st["id"])).get("added") or []
    info = _throw(call)
    if isinstance(info, str):
        return {"error": info}
    out: dict = {"boosted_with": boosted} if boosted else {}
    if reroll_if_failed and not info.get("success") and (info.get("inspiration") or 0) > 0:
        out["first_natural"] = info.get("natural")
        info = _throw(call, reroll=True)
        if isinstance(info, str):
            return {"error": info}
    call("roll", step="continue")
    for k in ("skill", "dc", "natural", "total", "success", "inspiration"):
        if info.get(k) is not None:
            out[k] = info[k]
    return out
