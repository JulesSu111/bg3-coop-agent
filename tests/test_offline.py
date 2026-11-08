"""End-to-end against the fake game: MCP tool functions -> Game -> LuaDebug -> server.lua -> mocks."""

from __future__ import annotations

import socket
import time

import pytest

from fakegame import FakeGame


@pytest.fixture()
def env(monkeypatch, tmp_path):
    fake = FakeGame()
    monkeypatch.delenv("BG3COOP_SSH_HOST", raising=False)
    monkeypatch.setenv("BG3COOP_DATA_DIR", str(tmp_path))  # persona notes
    monkeypatch.setenv("BG3COOP_PORT", str(fake.port))
    import importlib

    import bg3coop.server as srv
    srv = importlib.reload(srv)
    yield fake, srv
    srv.game.close()


def test_needs_agent_first(env):
    _, s = env
    assert "set_agent" in s.status()["error"]


def test_set_agent_detaches_and_status(env):
    fake, s = env
    assert s.set_agent("shadow")["name"] == "Shadowheart"
    assert fake.world.detached["3ed74f06-3c60-42dc-83f6-f034cb47c679"]
    st = s.status()
    assert st["name"] == "Shadowheart" and st["hp"] == 20
    assert st["human"]["name"] == "Tav"
    assert st["resources"]["ActionPoint"] == [1, 1]
    assert st["statuses"] == ["Blessed"]


def test_cannot_take_the_humans_character(env):
    _, s = env
    assert "human" in s.set_agent("Tav")["error"]


def test_look_filters_unseen_and_uses_handles(env):
    _, s = env
    s.set_agent("Shadowheart")
    seen = s._look_rows()
    names = [c["name"] for c in seen["characters"]]
    assert "Sneaky Goblin" not in names
    assert {"Tav", "Goblin", "Arron"} <= set(names)
    gob = next(c for c in seen["characters"] if c["name"] == "Goblin")
    assert gob["rel"] == "enemy" and gob["id"].startswith("e") and "hp" not in gob
    arron = next(c for c in seen["characters"] if c["name"] == "Arron")
    assert arron["talk"] and arron["trader"]
    assert seen["items"][0]["name"] == "Chest"


def test_look_sees_doors_its_sight_ray_misses(env):
    # A door's pivot sits in its frame: HasLineOfSight says no even right in front of it.
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute(
        'local near, far = "aaaaaaaa-0000-0000-0000-00000000d001", "aaaaaaaa-0000-0000-0000-00000000d002"\n'
        'MOCK.doors = { [near] = true, [far] = true }\n'
        'MOCK.pos[near] = { 2, 0, 5 }; MOCK.pos[far] = { 2, 0, 45 }\n'
        'MOCK.names[near] = "Front Door"; MOCK.names[far] = "Back Door"\n'
        'table.insert(MOCK.items, near); table.insert(MOCK.items, far)')
    items = {i["name"]: i for i in s._look_rows()["items"]}
    assert items["Front Door"]["kind"] == "door"
    assert "Back Door" not in items  # past how far the agent notices things


def test_look_sees_through_walls_but_not_into_shut_rooms(env):
    # The human's screen shows things behind walls, but not inside a room whose doors and windows
    # are all shut, nor someone sneaking.
    fake, s = env
    s.set_agent("Shadowheart")
    names = lambda: [c["name"] for c in s._look_rows()["characters"]]  # noqa: E731
    assert "Sneaky Goblin" not in names()  # behind a wall and sneaking
    fake.server.execute("MOCK.active[MOCK.wall_gob:sub(-36)] = nil")  # stops sneaking
    fake.server.execute("MOCK.pos[MOCK.wall_gob:sub(-36)] = { 2, 0, 30 }")  # 30 m off, still behind the wall
    assert "Sneaky Goblin" in names()
    fake.server.execute(  # a 6 x 6 m room round him, its door on the south wall
        'local door = "aaaaaaaa-0000-0000-0000-00000000d003"\n'
        'MOCK.doors = { [door] = true }; MOCK.pos[door] = { 2, 0, 27 }; MOCK.names[door] = "Door"\n'
        'table.insert(MOCK.items, door)\n'
        'MOCK.rooms = { { Transform = { Transform = { Translate = { 2, 1.5, 30 }, RotationQuat = { 0, 0, 0, 1 } } },'
        ' TriggerArea = { Physics = { Extents = { 3, 2.5, 3 } } } } }\n'
        'BG3COOP.roomCtx, BG3COOP.roomOpenings = nil, nil')
    assert "Sneaky Goblin" not in names()  # the door is shut
    assert "Door" in [i["name"] for i in s._look_rows()["items"]]  # the door itself is on the wall: seen
    fake.server.execute('MOCK.opened = { ["aaaaaaaa-0000-0000-0000-00000000d003"] = true }; BG3COOP.roomCtx = nil')
    assert "Sneaky Goblin" in names()  # open door
    fake.server.execute('MOCK.opened = {}; BG3COOP.roomCtx = nil; MOCK.pos[MOCK.host:sub(-36)] = { 2, 0, 31 }')
    assert "Sneaky Goblin" in names()  # the human is in the room


def test_look_lists_lines_then_only_changes(env):
    fake, s = env
    s.set_agent("Shadowheart")
    first = s.look()
    assert any(line.startswith("e") and "Goblin (enemy" in line for line in first["characters"])
    assert any("Chest (container" in line for line in first["items"])
    assert "unchanged" not in first and isinstance(first["explore"], dict)
    again = s.look()
    assert again["characters"] == [c for c in first["characters"] if "the human" in c]
    assert again["items"] == [] and "more as in your last look" in again["unchanged"]
    assert again["explore"] == "as in your last look"
    fake.server.execute("MOCK.dead[MOCK.gob:sub(-36)] = true; MOCK.pos[MOCK.npc:sub(-36)] = { 900, 0, 900 }")
    third = s.look()
    assert any("Goblin" in c and "dead" in c for c in third["characters"])
    assert any("Arron" in g for g in third["gone"])
    fake.server.execute("MOCK.pos[MOCK.sh:sub(-36)] = { 2, 0, 30 }")  # walked 30 m north
    assert isinstance(s.look()["explore"], dict)
    fake.server.execute("MOCK.pos[MOCK.sh:sub(-36)] = { 2, 0, 0 }")
    full = s.look(full=True)
    assert "unchanged" not in full and any("Goblin" in c for c in full["characters"])
    fake.server.execute("MOCK.owners[MOCK.chest:sub(-36)] = MOCK.npc; MOCK.owners[MOCK.potion:sub(-36)] = MOCK.host")
    assert any("Chest (container, owned by Arron," in i for i in s.look(full=True)["items"])
    s.set_agent("Shadowheart")  # taking over again starts afresh
    assert "unchanged" not in s.look()


def test_quests_reads_the_journal(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute("MOCK.flags['FLAG_Met@NULL_00000000-0000-0000-0000-000000000000'] = true;"
                        "MOCK.flags['FLAG_Found@' .. MOCK.sh] = true")
    q = s.quests()["open"]
    assert [x["title"] for x in q] == ["Find the Relic", "Ask the Priest"]  # closed and hidden left out
    assert q[0]["latest"] == "We found the relic in the crypt."
    assert q[1]["part_of"] == "Find the Relic" and "latest" not in q[1]


def test_move_and_loot(env):
    fake, s = env
    s.set_agent("Shadowheart")
    chest = next(i for i in s._look_rows()["items"] if i["name"] == "Chest")
    r = s.move(target=chest["id"])
    assert r["status"] == "done", r
    assert r["result"]["left_m"] <= 2.0
    inside = s.container(chest["id"])["items"]
    assert inside[0]["name"] == "Potion of Healing"
    r = s.take([inside[0]["id"]])
    assert r["status"] == "done" and r["result"]["taken"] == ["Potion of Healing"], r


def test_a_new_action_replaces_a_running_one(env):
    fake, s = env
    s.set_agent("Shadowheart")
    first = s.game.call("move", {"dir": "N", "meters": 30})["job"]  # started, not yet looked at
    assert s.move(direction="E", meters=2)["status"] == "done"
    old = s.job_status(first, wait_s=0)
    assert old["status"] == "replaced" and "newer action" in old["error"]


def test_move_direction(env):
    _, s = env
    s.set_agent("Shadowheart")
    r = s.move(direction="N", meters=5)
    assert r["status"] == "done", r
    assert s.status()["pos"][2] == pytest.approx(5, abs=0.2)


def test_talk_reports_dialogue(env):
    fake, s = env
    s.set_agent("Shadowheart")
    arron = next(c for c in s._look_rows()["characters"] if c["name"] == "Arron")
    r = s.talk(arron["id"])
    assert r["status"] == "done" and r["result"]["dialogue"], r
    assert [e["kind"] for e in r["events"]] == ["dialogue_started"]  # with the result, not the next wait
    assert fake.world.selectedDialog  # the game picks the dialogue, as when the human clicks
    d = s.dialogue()
    assert d["yours"] is True and d["open"] is False  # mock has no UI
    assert s.status()["dialog"]["yours"] is True
    assert s.wait(1)["events"] == []  # handed over once


def test_dialogue_check_tags_are_translated(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.client.execute("""
        local d = { ShowAnswers = true, BodyText = "Arron: Hello", History = { Items = {} }, Answers = {
            { BodyText = "Look closer.", Enabled = true,
              AnswerTags = { { Text = "hfd00683fg1522g4f04g91c4g9bef52cda3d0" } } },
            { BodyText = "Leave.", Enabled = true, AnswerTags = {} } } }
        local dc = { Data = { Dialogues = { d } } }
        MOCK_C.root = { Find = function() return { Children = { { Name = "Dialogue", DataContext = dc } } } end }
        MOCK_C.loca = { hfd00683fg1522g4f04g91c4g9bef52cda3d0 = "Investigation" }
    """)
    d = s.game.call("dialogue", {}, context="client")
    assert [a["text"] for a in d["answers"]] == ["[INVESTIGATION] Look closer.", "Leave."]
    assert d["speaker"] == "Arron" and d["line"] == "Hello"


def _dialogue_on_screen(fake, instance=9):
    """Shadowheart talks to Arron: dialogue `instance` on screen, its lines set with MOCK_C.dlg."""
    fake.server.execute(f"MOCK.dialog[MOCK.sh:sub(-36)] = {instance}")
    fake.client.execute("""
        MOCK_C.dlg = { DialogInstanceID = %d, ShowAnswers = false, BodyText = "", History = { Items = {} },
            Answers = {} }
        local dc = { Data = { Dialogues = { MOCK_C.dlg } } }
        dc.SelectAnswerCommand = { Execute = function(_, vm) MOCK_C.answered = vm.BodyText end }
        MOCK_C.dlgDC = dc
        MOCK_C.root = { Find = function() return { Children = { { Name = "Dialogue", DataContext = dc } } } end }
    """ % instance)


def _speak(fake, line, ms=100):
    """The next line, on screen and in the history as the game has it; the game ticks `ms` later."""
    fake.client.execute(f"""
        local d = MOCK_C.dlg
        d.History.Items[#d.History.Items + 1] = {{ BodyText = {line!r} }}
        d.BodyText = {line!r}
        MOCK_C.now = (MOCK_C.now or 0) + {ms}
        MOCK_C.fire("Tick")
    """)


def test_dialogue_keeps_lines_the_human_clicked_past(env):
    fake, s = env
    s.set_agent("Shadowheart")
    _dialogue_on_screen(fake)
    for line in ("Arron: Hello.", "Arron: Lovely day.", "Arron: Off with you."):
        _speak(fake, line)
    d = s.dialogue()
    assert d["line"] == "Off with you." and d["said"] == ["Arron: Hello.", "Arron: Lovely day."]
    assert "said" not in s.dialogue()  # read once
    _speak(fake, "Arron: One more thing.")
    _speak(fake, "Arron: Farewell.")
    fake.client.execute("MOCK_C.root = nil")  # the conversation closes
    fake.server.execute("MOCK.dialog[MOCK.sh:sub(-36)] = nil")
    d = s.dialogue()
    assert d["open"] is False and d["said"] == ["Arron: One more thing.", "Arron: Farewell."]


def test_dialogue_reads_a_one_liner_after_it_ended(env):
    fake, s = env
    s.set_agent("Shadowheart")
    _dialogue_on_screen(fake)
    _speak(fake, "Morand: Not now.")
    fake.client.execute('MOCK_C.dlg.BodyText = "Not now."; MOCK_C.now = MOCK_C.now + 100; MOCK_C.fire("Tick")')
    fake.client.execute("MOCK_C.root = nil")
    fake.server.execute("MOCK.dialog[MOCK.sh:sub(-36)] = nil")
    assert s.dialogue()["said"] == ["Morand: Not now."]


def test_choose_tells_the_human_what_and_why(env):
    fake, s = env
    s.set_agent("Shadowheart")
    s.say("hello")  # brings up the panel
    _dialogue_on_screen(fake)
    fake.client.execute("""
        MOCK_C.dlg.ShowAnswers = true
        MOCK_C.dlg.Answers = { { BodyText = "Let us pass.", Enabled = true, AnswerTags = {} } }
    """)
    r = s.choose(1, why="We came for my parents.")
    assert r.pop("events") == [{"kind": "dialogue_started", "yours": True}]
    assert r == {"chose": "Let us pass."}
    assert fake.client.eval("MOCK_C.answered") == "Let us pass."
    assert _lines(fake)[-1] == "[chose] Let us pass. - We came for my parents."


def test_said_keeps_one_copy_of_a_line_even_out_of_order(env):
    # The box shows "A" and "B" first; History adds "Mirya: A" and "Mirya: B" afterwards.
    fake, s = env
    s.set_agent("Shadowheart")
    _dialogue_on_screen(fake)
    for line in ("Welcome.", "Come in."):
        fake.client.execute(f'MOCK_C.dlg.BodyText = {line!r}; MOCK_C.now = (MOCK_C.now or 0) + 100; MOCK_C.fire("Tick")')
    _speak(fake, "Mirya: Welcome.")
    _speak(fake, "Mirya: Come in.")
    # a colon of its own in the line, on screen without the speaker
    fake.client.execute('MOCK_C.dlg.BodyText = "We lift burdens: grief, anger."; MOCK_C.now = MOCK_C.now + 100; '
                        'MOCK_C.fire("Tick")')
    _speak(fake, "Mirya: We lift burdens: grief, anger.")
    _speak(fake, "Mirya: “Sit down.”")
    _speak(fake, "Mirya: Sit down.")  # said again: History has it twice
    d = s.dialogue()
    assert d["said"] == ["Mirya: Welcome.", "Mirya: Come in.", "Mirya: We lift burdens: grief, anger.",
                         "Mirya: “Sit down.”"]
    assert d["line"] == "Sit down."


def test_said_shows_the_agents_answer_as_the_agents(env):
    # History names the human's character as the speaker of every answer.
    fake, s = env
    s.set_agent("Shadowheart")
    _dialogue_on_screen(fake)
    fake.client.execute("""
        MOCK_C.dlg.ShowAnswers = true
        MOCK_C.dlg.Answers = { { BodyText = "Let us pass.", Enabled = true, AnswerTags = {} } }
    """)
    s.choose(1, why="go on")
    _speak(fake, "Tav: Let us pass.")
    _speak(fake, "Mirya: As you wish.")
    assert s.dialogue()["said"] == ["Shadowheart: Let us pass."]


def _world_object(fake, name, pos, on_use=""):
    """An object to use near Shadowheart; `on_use` is Lua run when she uses it (`who` = the user)."""
    u = "aaaaaaaa-0000-0000-0000-0000000%05x" % (abs(hash(name)) % 0xFFFFF)
    fake.server.execute(
        f'local u = "{u}"\nMOCK.pos[u] = {{ {pos[0]}, {pos[1]}, {pos[2]} }}\nMOCK.names[u] = {name!r}\n'
        f'table.insert(MOCK.items, u)\nMOCK.onUse = MOCK.onUse or {{}}\n'
        f'MOCK.onUse[u] = function(who) {on_use} end')
    return u


def test_a_conversation_started_by_using_something_is_yours(env):
    # Sitting on a bench starts a vision; the human is in it too, but the agent sat down.
    fake, s = env
    s.set_agent("Shadowheart")
    _world_object(fake, "Bench", (1, 0, 1),
                  "MOCK.dialog[MOCK.sh:sub(-36)] = 300; MOCK.dialog[MOCK.host:sub(-36)] = 300")
    bench = next(i["id"] for i in s._look_rows()["items"] if i["name"] == "Bench")
    r = s.use(bench)
    assert r["status"] == "done", r
    assert r["result"]["dialogue"] and "conversation started" in r["result"]["effect"]
    assert "no visible change" not in r["result"]["effect"]
    assert s.status()["dialog"]["yours"] is True


def test_use_tells_what_appeared_or_where_it_took_you(env):
    fake, s = env
    s.set_agent("Shadowheart")
    stairs = _world_object(fake, "Secret Stairs", (3, 0, 3))
    fake.server.execute(f'MOCK.offstage = {{ ["{stairs}"] = true }}')
    _world_object(fake, "Lever", (1, 0, 0), f'MOCK.offstage["{stairs}"] = nil')
    _world_object(fake, "Portal", (-1, 0, 0), "MOCK.pos[who:sub(-36)] = { 200, 0, 200 }")
    rows = {i["name"]: i["id"] for i in s._look_rows()["items"]}
    assert "Secret Stairs" not in rows
    r = s.use(rows["Lever"])["result"]
    assert [a["name"] for a in r["appeared"]] == ["Secret Stairs"], r
    r = s.use(rows["Portal"])["result"]
    assert r["moved_m"] > 100 and "taken somewhere else" in r["effect"], r


def _check_on_screen(fake, s, throws, setup_companion=True):
    """Shadowheart's dialogue with an Investigation check (DC 11, +5) waiting for its dice."""
    if setup_companion:
        s.set_agent("Shadowheart")
    fake.server.execute("MOCK.dialog[MOCK.sh:sub(-36)] = 9")
    fake.client.execute("MOCK_C.throws = { " + ", ".join(map(str, throws)) + " }")
    fake.client.execute("""
        local d = { DialogInstanceID = 9, ShowAnswers = false, BodyText = "Shadowheart: Look closer.",
            History = { Items = {} }, Answers = {} }
        local roll = { RollState = "WaitForStart", TargetNumber = 6, Roll = { DifficultyCheck = 11 },
            RollContext = "DialogCheck",
            SkillOrAbility = "hfd00683fg1522g4f04g91c4g9bef52cda3d0", RolledNumber1 = 0, FinalResult = 0,
            Success = false, InspirationPoints = 2 }
        local guidance = { IsSelected = false, BoostModifier = { Name = "Guidance", PrototypeID = "Target_Guidance" } }
        local tavs = { IsSelected = false, BoostModifier = { Name = "Bardic Inspiration", PrototypeID = "BI" } }
        roll.NearbyPartyCharacters = {
            { Owner = { EntityUUID = "3ed74f06-3c60-42dc-83f6-f034cb47c679" }, BoostModifierList = { guidance } },
            { Owner = { EntityUUID = "11111111-1111-1111-1111-111111111111" }, BoostModifierList = { tavs } } }
        roll.AddModifierCommand = { Execute = function(_, m) m.IsSelected = true end }
        roll.UserTriggeredNextPhaseCommand = { Execute = function()
            local n = table.remove(MOCK_C.throws, 1)
            local total = n + 5 + (guidance.IsSelected and 2 or 0)
            roll.RollState, roll.RolledNumber1, roll.FinalResult, roll.ResultNumber, roll.Success =
                "ResultReady", n, n, total, total >= 11
        end }
        roll.RollAgainCommand = { Execute = function()
            roll.RollState, roll.InspirationPoints = "WaitForReRoll", roll.InspirationPoints - 1 end }
        MOCK_C.rollWidget = { Name = "ActiveRoll", Visibility = "Visible", DataContext = roll }
        roll.ContinueCommand = { Execute = function() MOCK_C.rollWidget.Visibility = "Hidden" end }
        local dc = { Data = { Dialogues = { d } } }
        MOCK_C.root = { Find = function()
            return { Children = { { Name = "Dialogue", DataContext = dc }, MOCK_C.rollWidget } } end }
        MOCK_C.loca = { hfd00683fg1522g4f04g91c4g9bef52cda3d0 = "Investigation" }
    """)


def test_a_skill_check_in_your_dialogue(env):
    fake, s = env
    _check_on_screen(fake, s, [9])
    d = s.dialogue()
    assert d["yours"] and d["roll"] == {"skill": "Investigation", "dc": 11, "need": 6, "state": "waiting",
                                        "your_boosts": ["Guidance"]}  # not the human's Bardic Inspiration
    assert "`roll`" in d["note"]
    assert s.roll(reroll_if_failed=True) == {"skill": "Investigation", "dc": 11, "natural": 9, "total": 14,
                                             "success": True, "inspiration": 2}  # passed: no reroll
    assert fake.client.eval("MOCK_C.rollWidget.Visibility") == "Hidden"  # the dialogue goes on
    assert "roll" not in s.dialogue()


def test_a_failed_check_is_rerolled_only_when_asked(env):
    fake, s = env
    _check_on_screen(fake, s, [2, 15])
    r = s.roll(reroll_if_failed=True)
    r.pop("events", None)
    assert r == {"first_natural": 2, "skill": "Investigation", "dc": 11,
                 "natural": 15, "total": 20, "success": True, "inspiration": 1}
    _check_on_screen(fake, s, [2, 15])
    assert s.roll()["success"] is False


def test_a_check_with_your_boosts(env):
    fake, s = env
    _check_on_screen(fake, s, [4])
    r = s.roll(use_boosts=True)
    assert r["boosted_with"] == ["Guidance"] and r["total"] == 11 and r["success"] is True
    assert fake.client.eval("MOCK_C.rollWidget.DataContext.NearbyPartyCharacters[2].BoostModifierList[1].IsSelected") is False


def test_no_rolling_for_the_human(env):
    fake, s = env
    s.set_agent("Shadowheart")
    assert "human rolls" in s.roll()["error"]
    fake.server.execute("MOCK.dialog[MOCK.host:sub(-36)] = 7; MOCK.dialog[MOCK.sh:sub(-36)] = 7")
    assert "human rolls" in s.roll()["error"]


def test_a_bark_is_not_a_conversation(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute("MOCK.dialog[MOCK.sh:sub(-36)] = 9; MOCK.barks[9] = true")  # a shout in combat
    assert "dialog" not in s.status()
    assert s.move(direction="N", meters=5)["status"] == "done"
    fake.server.execute("MOCK.barks[9] = nil")
    assert s.status()["dialog"]["instance"] == 9


def test_humans_dialogue_is_not_yours(env):
    fake, s = env
    s.set_agent("Shadowheart")
    # the human talks to Arron and Shadowheart gets pulled in as a listener
    fake.server.execute("MOCK.dialog[MOCK.host:sub(-36)] = 7; MOCK.dialog[MOCK.sh:sub(-36)] = 7")
    assert s.status()["dialog"] == {"instance": 7, "yours": False}
    assert s.dialogue()["yours"] is False
    assert "human" in s.choose(1)["error"]


def test_choose_refuses_humans_dialogue(env):
    _, s = env
    s.set_agent("Shadowheart")
    assert "not in a conversation" in s.choose(1)["error"]


def test_combat_turn_guard(env):
    fake, s = env
    s.set_agent("Shadowheart")
    gob = next(c for c in s._look_rows()["characters"] if c["name"] == "Goblin")
    fake.server.execute("MOCK.combat = true; MOCK.turn = nil")
    assert "not your turn" in s.cast("Target_MainHandAttack", target=gob["id"])["error"]
    fake.server.execute("MOCK.turn = '3ed74f06-3c60-42dc-83f6-f034cb47c679'")
    assert s.status()["my_turn"] is True
    assert s.cast("Target_MainHandAttack", target=gob["id"])["status"] == "done"
    assert s.status()["resources"]["ActionPoint"] == [0, 1]
    assert "action left" in s.cast("Projectile_GuidingBolt", target=gob["id"])["error"]
    assert "unknown" not in str(s.end_turn())
    assert "not your turn" in s.cast("Target_MainHandAttack", target=gob["id"])["error"]


def test_end_turn_in_shared_turn(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute("MOCK.combat = true; MOCK.shared_turn = true; MOCK.turn = '3ed74f06-3c60-42dc-83f6-f034cb47c679'")
    r = s.end_turn()
    assert r["ended"] and r["note"].startswith("you share this turn with Tav")
    st = s.status()
    assert st["my_turn"] is False and st["turn_ended"] and st["waiting_for_party"]
    assert "already ended" in s.move(direction="E", meters=2)["error"]
    fake.server.execute("MOCK.turn = nil")  # the group finished
    assert "turn_ended" not in s.status()


def test_cast_spends_slots_and_checks_preparation(env):
    fake, s = env
    s.set_agent("Shadowheart")
    tav = next(c for c in s._look_rows()["characters"] if c["name"] == "Tav")
    assert s.cast("Projectile_GuidingBolt", target=tav["id"])["status"] == "done"
    opts = dict(list(fake.world.castOptions.values())[-1])
    assert "IgnoreSpellRolls" not in opts and "IgnoreCastChecks" not in opts  # the game rolls and checks
    assert "IgnoreHasSpell" in opts
    assert s.status()["resources"]["SpellSlot1"] == [1, 2]
    assert s.status()["resources"]["ActionPoint"] == [1, 1]  # out of combat the action refills anyway
    s.cast("Projectile_GuidingBolt", target=tav["id"])
    assert "spell slot" in s.cast("Projectile_GuidingBolt", target=tav["id"])["error"]
    assert "not prepared" in s.cast("Target_CureWounds", target=tav["id"])["error"]


def test_spells_list(env):
    _, s = env
    s.set_agent("Shadowheart")
    rows = {r["spell"]: r for r in s._spell_rows()}
    assert set(rows) == {"Target_MainHandAttack", "Projectile_GuidingBolt", "Projectile_Fireball",
                         "Zone_BurningHands", "Shout_SpiritGuardians", "Shout_TurnUndead",
                         "Shout_HealingWord_Mass", "Shout_RadianceOfTheDawn", "Target_FlamingSphere",
                         "Teleportation_Revivify", "Projectile_Jump"}  # Cure Wounds not prepared
    assert rows["Target_MainHandAttack"]["range_m"] == 1.5
    assert rows["Projectile_GuidingBolt"]["cost"] == "action, slot1" and rows["Projectile_GuidingBolt"]["usable"]
    assert s.spells(kind="heal")[0] == ("Shout_HealingWord_Mass Mass Healing Word "
                                        "(healing; bonus action; no target: around you within 9 m)")
    # the kind shown on a row works as a filter too
    kind = rows["Projectile_GuidingBolt"]["kind"]
    lines = s.spells(kind=kind)
    assert any(line.startswith("Projectile_GuidingBolt Guiding Bolt (") for line in lines), lines
    assert "Target_MainHandAttack Attack (damage; action; 1.5 m)" in s.spells()


def test_prepare_spells(env):
    fake, s = env
    s.set_agent("Shadowheart")
    book = s.prepare()["classes"]
    assert book == [{"class": "Cleric", "prepared_count": 1, "max": 1,
                     "prepared": ["Projectile_GuidingBolt Guiding Bolt (level 1)"],
                     "not_prepared": ["Target_CureWounds Cure Wounds (level 1)"]}]
    # the class is full: adding alone goes over the game's limit
    assert "can prepare 1" in s.prepare(add=["Target_CureWounds"])["error"]
    assert "already prepared" in s.prepare(add=["Projectile_GuidingBolt"])["error"]
    assert "not prepared" in s.prepare(remove=["Target_CureWounds"])["error"]
    assert "not a spell" in s.prepare(add=["Projectile_Fireball"])["error"]  # always prepared
    r = s.prepare(add=["Target_CureWounds"], remove=["Projectile_GuidingBolt"])
    assert r == {"done": True, "prepared": ["Target_CureWounds"], "unprepared": ["Projectile_GuidingBolt"],
                 "classes": ["Cleric 1/1"]}, r
    rows = {r["spell"] for r in s._spell_rows()}
    assert "Target_CureWounds" in rows and "Projectile_GuidingBolt" not in rows
    fake.server.execute("MOCK.combat = true")
    assert "after the fight" in s.prepare(add=["Projectile_GuidingBolt"], remove=["Target_CureWounds"])["error"]


def test_area_spells_spare_the_party(env):
    fake, s = env
    s.set_agent("Shadowheart")  # Shadowheart at (2,0,0), Tav at (0,0,0), Goblin at (12,0,0)
    goblin = next(c for c in s._look_rows()["characters"] if c["name"] == "Goblin")
    assert s.cast("Projectile_Fireball", target=goblin["id"])["status"] == "done"
    r = s.cast("Projectile_Fireball", x=1, y=0, z=0)
    assert "would also hit Tav" in r["error"], r
    n = len(fake.world.casts)
    assert s.cast("Projectile_Fireball", x=1, y=0, z=0, even_if_allies=True)["status"] == "done"
    assert len(fake.world.casts) == n + 1
    # a cone towards the goblin leaves Tav behind; towards Tav it catches him
    assert s.cast("Zone_BurningHands", x=12, y=0, z=0)["status"] == "done"
    assert "Tav" in s.cast("Zone_BurningHands", x=-5, y=0, z=0)["error"]
    # an aura on the caster and Sculpt Spells spare allies by themselves
    assert s.cast("Shout_SpiritGuardians")["status"] == "done"
    # Turn Undead only troubles undead allies
    assert s.cast("Shout_TurnUndead")["status"] == "done"
    fake.server.execute("MOCK.undead = { ['11111111-1111-1111-1111-111111111111'] = true }")
    assert "Tav" in s.cast("Shout_TurnUndead")["error"]
    fake.server.execute("MOCK.sculpt = true")
    assert s.cast("Projectile_Fireball", x=1, y=0, z=0)["status"] == "done"


def test_reactions_default_and_change(env):
    _, s = env
    modes = {r["reaction"]: r["mode"] for r in s.set_agent("Shadowheart")["reactions"]}
    assert modes == {"Interrupt_WardingFlare": "auto", "Interrupt_Shield": "never",
                     "Interrupt_AttackOfOpportunity": "auto"}
    rows = s.reactions(mode="auto", reaction="shield")
    assert {r["reaction"]: r["mode"] for r in rows}["Interrupt_Shield"] == "auto"
    s.regroup()
    assert {r["reaction"]: r["mode"] for r in s.reactions()}["Interrupt_Shield"] == "ask"


def test_human_stays_fixed_when_selection_changes(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute("MOCK.selected = MOCK.sh")  # the human clicks on Shadowheart
    rows = {r["name"]: r for r in s.party()}
    assert rows["Tav"]["human"] and not rows["Shadowheart"].get("human")
    assert rows["Shadowheart"]["selected_by_human"]
    st = s.status()
    assert st["human"]["name"] == "Tav" and "selected your character" in st["note"]


def test_events_not_repeated(env):
    fake, s = env
    s.set_agent("Shadowheart")
    assert s.wait(1)["events"] == []
    fake.server.execute("BG3COOP = nil")
    assert [e["kind"] for e in s.wait(1)["events"]] == ["agent_set"]
    assert s.wait(1)["events"] == []


def test_wait_carries_a_short_status(env):
    _, s = env
    s.set_agent("Shadowheart")
    st = s.wait(1)["status"]
    assert st["hp"] == 20 and st["human"]["name"] == "Tav"
    assert "resources" not in st and "pos" not in st


def test_a_new_bridge_skips_old_events(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute(f"MOCK.fire('LeveledUp', '{SH}')")
    # hours later a new bridge process starts: the game still holds the old events
    fake.server.execute("for _, e in ipairs(BG3COOP.events) do e.t = e.t - 3600000 end")
    s._events.update(epoch=None, seq=0)
    fake.server.execute(f"MOCK.fire('LeveledUp', '{SH}')")
    assert [e["kind"] for e in s.wait(1)["events"]] == ["level_up"]
    assert s.wait(1)["events"] == []


def test_combat_movement_budget(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute("MOCK.combat = true; MOCK.turn = '3ed74f06-3c60-42dc-83f6-f034cb47c679'")
    assert "not enough movement" in s.move(direction="E", meters=20)["error"]
    # the game's own figure for the way counts, not its length (a ladder climb costs nothing)
    fake.server.execute("MOCK.pathCostScale = 0.1")
    assert "not enough movement" not in str(s.move(direction="E", meters=20))


def test_turn_based_mode_outside_combat(env):
    fake, s = env
    s.set_agent("Shadowheart")
    assert "turn_based" not in s.status() and "not in combat" in s.end_turn()["error"]
    fake.server.execute("MOCK.ftb = true")
    assert s.status()["turn_based"] is True and s.wait(1)["status"]["turn_based"] is True
    err = s.move(direction="E", meters=20)["error"]
    assert "turn-based mode" in err and "end_turn" in err
    assert s.move(direction="E", meters=3)["status"] == "done"
    assert s.end_turn()["ended"] is True


def test_reinjects_after_reload(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute("BG3COOP = nil")  # what a save load does to the Lua state
    assert s.status()["name"] == "Shadowheart"


def test_reinjects_over_an_older_script(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute("BG3COOP.VERSION = 1; BG3COOP.ops.status = nil")  # left by an older bg3coop
    assert s.status()["name"] == "Shadowheart"
    assert fake.server.eval("BG3COOP.VERSION") == s.game.versions["server"]


def test_say_writes_to_panel_and_urgent_pops_up(env):
    fake, s = env
    s.set_agent("Shadowheart")
    assert s.say("I found a chest") == {"shown": "panel"}
    assert fake.world.message is None
    assert _lines(fake)[-1] == "I found a chest"
    assert _texts(list(_panel(fake)[3].Children.values())[-1])[0] == "Shadowheart"  # the speaker line
    assert s.say("Goblins!", urgent=True)["shown"] == "panel and pop-up"
    assert fake.world.message == "Shadowheart: Goblins!"
    assert "without urgent" in s.say("more goblins", urgent=True)["error"]
    assert s.say("still fine")["shown"] == "panel"


class _Panel:
    """The chat panel as the human sees it (see buildPanel in client.lua)."""

    def __init__(self, fake):
        wins = fake.client.eval("MOCK_C.windows")
        self.win = wins[len(wins)]
        kids = list(self.win.Children.values())
        self.state, self.turn = kids[:2]
        chat, actions = list(kids[3].Children.values())[:2]
        self.log, table, self.input, self.send = list(chat.Children.values())
        cells = table.Children[1].Children.values()
        self.buttons = [c.Children[1] for c in cells]
        self.recent = actions.Children[1]


def _panel(fake):
    """window, header, quick buttons, log, input, send button"""
    p = _Panel(fake)
    return p.win, p, p.buttons, p.log, p.input, p.send


def _texts(el):
    """Every text under an element, in order."""
    out = []
    for k in el.Children.values():
        if k.kind == "text":
            out.append(k.Label)
        out += _texts(k)
    return out


def _activity(fake):
    """the activity line's text, and the recent actions (newest first, one string each)"""
    # the panel lists them oldest first, newest at the bottom
    fake.client.execute('MOCK_C.fire("Tick")')
    p = _Panel(fake)
    return p.state.Label, [" ".join(_texts(g)) for g in p.recent.Children.values() if g.kind == "group"][::-1]


def _lines(fake):
    """The message texts in the log, without speaker lines and times."""
    out = []
    for g in _panel(fake)[3].Children.values():
        texts = [k for k in g.Children.values() if k.kind == "text"]
        if texts:
            out.append(texts[-1].Label)
    return out


def _type(fake, text, enter=True):
    *_, inp, button = _panel(fake)
    inp.Text = text
    (inp.OnChange if enter else button.OnClick)(inp)


def test_human_messages_reach_the_agent(env):
    fake, s = env
    s.set_agent("Shadowheart")
    _type(fake, "  follow me  ")
    _type(fake, "and open that chest", enter=False)
    st = s.status()
    assert st["human_says"] == ["follow me", "and open that chest"]
    assert "human_says" not in s.status()
    _type(fake, "   ")
    assert "human_says" not in s.status()


def test_wait_returns_when_the_human_writes(env):
    fake, s = env
    s.set_agent("Shadowheart")
    _type(fake, "wait for me")
    t = time.monotonic()
    r = s.wait(10)
    assert r["human_says"] == ["wait for me"] and time.monotonic() - t < 3


def test_events_ride_along_with_any_tool(env):
    fake, s = env
    s.set_agent("Shadowheart")
    s.wait(0.5)  # the backlog
    fake.server.execute("MOCK.combat = true; MOCK.fire('CombatStarted', 'combat-1')")
    r = s.look()  # busy exploring, not waiting
    assert [e["kind"] for e in r["events"]] == ["combat_started"]
    assert s.wait(0.5)["events"] == []  # not twice
    assert "events" not in s.status()  # nothing new: no key


def test_every_fight_starts_with_the_combat_basics(env):
    fake, s = env
    s.set_agent("Shadowheart")
    s.wait(0.5)  # the backlog
    fake.server.execute("MOCK.combat = true; MOCK.fire('CombatStarted', 'combat-1')")
    r = s.look()  # whatever the tool
    assert any("Opportunity attack" in line for line in r["combat_basics"])
    assert "combat_basics" not in s.status()  # once per fight
    fake.server.execute(f"MOCK.turn = '{SH}'; MOCK.fire('TurnStarted', '{SH}')")
    assert "combat_basics" not in s.inventory()  # not again on the first turn
    fake.server.execute("MOCK.combat = false; MOCK.fire('CombatEnded', 'combat-1')")
    assert "combat_basics" not in s.wait(0.5)
    fake.server.execute("MOCK.combat = true; MOCK.fire('CombatStarted', 'combat-2')")
    assert "combat_basics" in s.wait(0.5)  # the next fight: again


def test_combat_basics_come_with_the_first_turn_when_the_start_was_missed(env):
    fake, s = env
    _fight(fake, s)
    s.status()  # the start of the fight, handed over
    s._basics["given"] = False  # as if the bridge started mid-fight
    fake.server.execute(f"MOCK.turn = '{SH}'; MOCK.fire('TurnStarted', '{SH}')")
    r = s.inventory()
    assert "your_turn" in r and r["combat_basics"]
    assert "combat_basics" not in s.status()


def test_a_long_action_gives_way_to_the_human(env, monkeypatch):
    fake, s = env
    s.set_agent("Shadowheart")
    real = s.game.call
    monkeypatch.setattr(s.game, "call", lambda op, args=None, context="server":
                        {"status": "running"} if op == "job" else real(op, args, context))
    _type(fake, "stop, come back")
    t = time.monotonic()
    r = s._run_job({"job": 99}, 30)
    assert r["status"] == "running" and "came up" in r["hint"] and time.monotonic() - t < 3
    assert s.status()["human_says"] == ["stop, come back"]
    # an urgent event cuts it short too, a minor one does not
    fake.server.execute("MOCK.combat = true; MOCK.fire('CombatStarted', 'combat-1')")
    t = time.monotonic()
    assert "came up" in s._run_job({"job": 99}, 30)["hint"] and time.monotonic() - t < 3
    s.status()  # hands the event over
    fake.server.execute("BG3COOP.push('noticed', {})")
    assert "came up" not in s._run_job({"job": 99}, 1.5)["hint"]


def test_events_lost_to_the_buffer_are_owned_up_to(env):
    fake, s = env
    s.set_agent("Shadowheart")
    s.wait(0.5)
    fake.server.execute("for i = 1, 250 do BG3COOP.push('attacked', { n = i }) end")
    ev = s.wait(0.5)["events"]
    assert ev[0]["kind"] == "missed" and ev[0]["count"] == 50 and len(ev) == 201


def test_errors_still_carry_messages(env):
    fake, s = env
    s.party()  # injects the client side, which opens the panel
    _type(fake, "hello")
    r = s.status()
    assert "set_agent" in r["error"] and r["human_says"] == ["hello"]


def test_hotkey_toggles_panel(env):
    fake, s = env
    s.party()
    w = _panel(fake)[0]
    assert w.Open
    fake.client.execute('MOCK_C.fire("KeyInput", { Event = "KeyDown", Key = "F10", Repeat = false })')
    assert not w.Open
    fake.client.execute('MOCK_C.fire("KeyInput", { Event = "KeyUp", Key = "F10", Repeat = false })')
    fake.client.execute('MOCK_C.fire("KeyInput", { Event = "KeyDown", Key = "F9", Repeat = false })')
    assert not w.Open
    fake.client.execute('MOCK_C.fire("KeyInput", { Event = "KeyDown", Key = "F10", Repeat = false })')
    assert w.Open


def test_log_keeps_scrolling_to_the_newest_line(env):
    fake, s = env
    s.set_agent("Shadowheart")
    c = fake.client.execute
    log = _panel(fake)[3]

    def tick(now):
        log.scrolled = None
        c(f"MOCK_C.now = {now}; MOCK_C.fire('Tick', {{}})")
        return log.scrolled is not None

    c("MOCK_C.now = 1000")
    s.say("first")
    # asked again on later ticks: ImGui clamps one request to the height before the new line
    assert tick(1000) and tick(1200) and tick(1400)
    tick(1500)
    assert not tick(1600)  # then the human can scroll up again
    _type(fake, "hello")
    assert tick(1700) and tick(2100)
    tick(2200)
    c("MOCK_C.now = 5000")
    c('MOCK_C.fire("KeyInput", { Event = "KeyDown", Key = "F10", Repeat = false })')  # hide
    assert not tick(5500)
    c('MOCK_C.fire("KeyInput", { Event = "KeyDown", Key = "F10", Repeat = false })')  # show again
    assert tick(5500)


def test_chat_history_survives_a_save_load(env):
    fake, s = env
    s.set_agent("Shadowheart")
    s.say("first")
    _type(fake, "second")
    s.status()
    fake.client.execute("BG3COOP_C = nil")  # a save load gives the client a fresh Lua state
    s.status()
    assert _lines(fake) == ["first", "second"]
    assert [c.get("who") for c in s.game.chat] == ["Shadowheart", None]
    assert len(fake.client.eval("MOCK_C.windows")) >= 2


def test_messages_taken_during_a_failed_wait_are_kept(env):
    fake, s = env
    s.party()
    assert "F10" in _lines(fake)[0]  # first-time hint
    _type(fake, "are you there?")
    r = s.wait(2)  # fails: no agent yet
    assert "set_agent" in r["error"] and r["human_says"] == ["are you there?"]


def test_agent_messages_bring_up_the_panel(env):
    fake, s = env
    s.set_agent("Shadowheart")
    w = _panel(fake)[0]
    w.Open, w.collapsed = False, True  # hidden with F10, or collapsed to its title bar
    s.say("Over here")
    assert w.Open and w.collapsed is False and _lines(fake)[-1] == "Over here"
    w.Open, w.collapsed = False, True
    _answer_when_asked(fake, click="Yes")
    assert s.ask("Open the chest?") == {"answer": "yes"}
    assert w.Open and w.collapsed is False


def test_new_agent_messages_blink_until_the_human_looks(env):
    fake, s = env
    s.set_agent("Shadowheart")
    c = fake.client.execute
    w = _panel(fake)[0]
    assert w.Label == "BG3 Co-op  ·  Shadowheart  ·  F10###bg3coop"
    c("MOCK_C.now = 1000")
    s.say("Over here")
    s.say("And here")
    assert w.Label == "BG3 Co-op  ·  Shadowheart  ·  2 new###bg3coop"
    lit = set()
    for t in range(1000, 4500, 100):  # it blinks for a few seconds
        c(f"MOCK_C.now = {t}")
        _activity(fake)
        lit.add(tuple(w.colors.TitleBg.values()))
    assert len(lit) == 2
    c("MOCK_C.now = 9000")
    _activity(fake)
    steady = tuple(w.colors.TitleBg.values())
    assert w.Label.endswith("2 new###bg3coop")  # still marked after the blinking
    _panel(fake)[3].OnHoverEnter(_panel(fake)[3])  # the human looks at the messages
    assert w.Label.endswith("Shadowheart  ·  F10###bg3coop") and tuple(w.colors.TitleBg.values()) != steady
    _type(fake, "ok")
    s.status()
    assert w.Label.endswith("F10###bg3coop")  # the human's own lines never count


def test_quick_buttons_and_status_line(env):
    fake, s = env
    s.set_agent("Shadowheart")
    s.status()
    _, head, buttons, *_ = _panel(fake)
    assert _panel(fake)[0].Label == "BG3 Co-op  ·  Shadowheart  ·  F10###bg3coop"
    assert [b.Label for b in buttons] == ["Follow me", "Stop", "Wait for me", "Free roam"]
    buttons[0].OnClick(buttons[0])
    assert s.party()["human_says"][0].startswith("[button] Follow me")


def _asks(fake):
    """The Yes/No question groups in the log."""
    return [g for g in _panel(fake)[3].Children.values() if g.kind == "group" and str(g.Label).startswith("ask")]


def _answer_when_asked(fake, click=None, text=None, seen=None):
    import threading
    before = len(_asks(fake))

    def run():
        for _ in range(100):
            groups = _asks(fake)
            if len(groups) > before:
                g = groups[-1]
                if seen is not None:
                    seen.append(_activity(fake)[0])
                if click:
                    btn = next(b for b in g.Children.values() if b.Label.startswith(click))
                    btn.OnClick(btn)
                else:
                    _type(fake, text)
                return
            time.sleep(0.05)
    threading.Thread(target=run, daemon=True).start()


def test_ask_yes_no_and_reply(env):
    fake, s = env
    s.set_agent("Shadowheart")
    seen = []
    _answer_when_asked(fake, click="Yes", seen=seen)
    assert s.ask("Open the chest?") == {"answer": "yes"}
    g = _asks(fake)[-1]
    assert [c.Label for c in g.Children.values() if not c.destroyed] == ["Yes"]
    assert _lines(fake)[-2] == "Open the chest?"
    assert seen[0].startswith("asking you · ")  # while asking
    assert _panel(fake)[1].state.Label.startswith("Thinking")
    _answer_when_asked(fake, text="only if it is not trapped")
    assert s.ask("Now?") == {"reply": "only if it is not trapped"}


def test_ask_times_out(env):
    fake, s = env
    s.set_agent("Shadowheart")
    t = time.monotonic()
    r = s.ask("Anyone?", timeout=1)
    assert r["timed_out"] and time.monotonic() - t < 8
    g = _asks(fake)[-1]
    assert [c.Label for c in g.Children.values() if not c.destroyed] == ["(no answer in time)"]
    assert _lines(fake)[-2] == "Anyone?"


def test_set_agent_by_english_name_in_another_language(env):
    fake, s = env
    fake.server.execute("MOCK.names[MOCK.sh:sub(-36)] = '影心'")
    assert s.set_agent("Shadowheart")["name"] == "影心"
    assert "error" in s.set_agent("Pl")  # too short to match ids


def test_inventory_lists_consumables_and_gear(env):
    _, s = env
    s.set_agent("Shadowheart")
    inv = s._inventory_rows()
    assert [(e["slot"], e["name"]) for e in inv["equipped"]] == [("Helmet", "Circlet")]
    rows = {r["name"]: r for r in inv["items"]}
    assert set(rows) == {"Potion of Healing", "Scroll of Bless", "Bottle of Grease", "Scroll of Revivify"}
    assert rows["Bottle of Grease"]["kind"] == "throwable"
    assert rows["Potion of Healing"]["count"] == 2 and rows["Potion of Healing"]["heals"]
    assert inv["not_shown"] == {"gear": 1} and inv["gold"] == 120
    gear = s._inventory_rows("gear")["items"]
    assert gear == [{"id": gear[0]["id"], "name": "Iron Helmet", "kind": "gear", "slot": "Helmet"}]
    assert "kind must be" in s.inventory("junk")["error"]
    shown = s.inventory()
    assert f"{rows['Potion of Healing']['id']} Potion of Healing x2 (potion, heals)" in shown["items"]
    assert shown["equipped"] == [f"Helmet: {inv['equipped'][0]['id']} Circlet"]
    assert s.inventory("gear")["items"] == [f"{gear[0]['id']} Iron Helmet (gear, Helmet)"]


def test_drink_potion(env):
    fake, s = env
    s.set_agent("Shadowheart")
    pot = next(r for r in s._inventory_rows()["items"] if r["name"] == "Potion of Healing")
    r = s.use_item(pot["id"])
    assert r["status"] == "done", r
    assert r["result"]["gained"] == ["Healing"] and r["result"]["left"] == 1
    tav = next(c for c in s._look_rows()["characters"] if c["name"] == "Tav")
    assert "give it to them" in s.use_item(pot["id"], target=tav["id"])["error"]


def test_potion_in_combat_costs_the_bonus_action(env):
    fake, s = env
    s.set_agent("Shadowheart")
    pot = next(r for r in s._inventory_rows()["items"] if r["name"] == "Potion of Healing")
    fake.server.execute("MOCK.combat = true; MOCK.turn = nil")
    assert "not your turn" in s.use_item(pot["id"])["error"]
    fake.server.execute("MOCK.turn = '3ed74f06-3c60-42dc-83f6-f034cb47c679'")
    assert s.use_item(pot["id"])["status"] == "done"
    assert s.status()["resources"]["BonusActionPoint"] == [0, 1]
    assert "bonus action" in s.use_item(pot["id"])["error"]


def test_read_scroll_casts_and_uses_it_up(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute("MOCK.item['77777777-7777-7777-7777-777777777773'].total = 2")
    scroll = next(r for r in s._inventory_rows("scroll")["items"] if r["name"] == "Scroll of Bless")
    r = s.use_item(scroll["id"])
    assert r["status"] == "done" and r["result"]["cast"] == "Target_Bless", r
    assert list(fake.world.casts.values())[-1].startswith("Target_Bless@")
    assert "DestroySource" in dict(list(fake.world.castOptions.values())[-1])  # the game uses it up
    assert s.status()["resources"]["SpellSlot1"] == [2, 2]  # a scroll needs no spell slot
    left = [r for r in s._inventory_rows("scroll")["items"] if r["name"] == "Scroll of Bless"]
    assert len(left) == 1 and left[0].get("count", 1) == 1, left  # one used, not two


def test_scroll_falls_back_when_request_is_gone(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute("Ext.Timer = nil")  # the request cannot be edited: remove the scroll ourselves
    scroll = next(r for r in s._inventory_rows("scroll")["items"] if r["name"] == "Scroll of Bless")
    assert s.use_item(scroll["id"])["status"] == "done"
    assert [r["name"] for r in s._inventory_rows("scroll")["items"]] == ["Scroll of Revivify"]


def _grease(s):
    return next(r for r in s._inventory_rows("throwable")["items"])


def test_throw_at_a_character(env):
    fake, s = env
    s.set_agent("Shadowheart")
    goblin = next(c for c in s._look_rows()["characters"] if c["name"] == "Goblin")
    r = s.throw(_grease(s)["id"], target=goblin["id"])
    assert r["status"] == "done" and r["result"]["thrown"] == "Bottle of Grease", r
    assert r["result"]["at"] == "Goblin" and r["result"]["left"] == 1
    assert list(fake.world.casts.values())[-1].startswith("Throw_Throw@22222222")
    opts = dict(list(fake.world.castOptions.values())[-1])
    # the game rolls to hit and checks what can be thrown (found a tick later than other requests)
    assert not {"IgnoreSpellRolls", "IgnoreCastChecks", "IgnoreTargetChecks"} & set(opts), opts
    assert "IgnoreHasSpell" in opts


def test_throw_at_a_position_names_the_item(env):
    fake, s = env
    s.set_agent("Shadowheart")
    r = s.throw(_grease(s)["id"], x=4, y=0, z=1)
    assert r["status"] == "done" and r["result"]["left"] == 1, r
    assert list(fake.world.thrown.values())[-1] == "77777777-7777-7777-7777-777777777776"


def test_throw_refusals(env):
    fake, s = env
    s.set_agent("Shadowheart")
    worn = s._inventory_rows("gear")["equipped"][0]
    r = s.throw(worn["id"], x=4, y=0, z=1)  # the game will not throw worn armour
    assert r["status"] == "failed" and "would not throw" in r["error"], r
    assert "target" in s.throw(_grease(s)["id"])["error"]
    assert "throw" in s.use_item(_grease(s)["id"])["error"]
    fake.server.execute("MOCK.combat = true; MOCK.turn = nil")
    assert "not your turn" in s.throw(_grease(s)["id"], x=4, y=0, z=1)["error"]


def test_revive_scroll_raises_the_fallen(env):
    fake, s = env
    s.set_agent("Shadowheart")
    scroll = next(r for r in s._inventory_rows("scroll")["items"] if r["name"] == "Scroll of Revivify")
    tav = next(c for c in s._look_rows()["characters"] if c["name"] == "Tav")
    assert "whom" in s.use_item(scroll["id"])["error"]
    assert "not dead or downed" in s.use_item(scroll["id"], target=tav["id"])["error"]  # alive
    assert any(i["name"] == "Scroll of Revivify" for i in s._inventory_rows("scroll")["items"])
    fake.server.execute("MOCK.dead['11111111-1111-1111-1111-111111111111'] = true")
    assert "within 9 m" in s.use_item(scroll["id"], target=tav["id"], x=30, y=0, z=0)["error"]
    r = s.use_item(scroll["id"], target=tav["id"], x=1, y=0, z=1)
    assert r["status"] == "done" and r["result"]["revived"] == "Tav", r
    assert list(fake.world.casts.values())[-1].startswith("Teleportation_Revivify_Scroll@11111111")
    assert list(list(fake.world.landed.values())[-1].values()) == [1, 0, 1]
    assert "IgnoreSpellRolls" not in dict(list(fake.world.castOptions.values())[-1])
    assert not any(i["name"] == "Scroll of Revivify" for i in s._inventory_rows("scroll")["items"])


def test_equip_and_remove(env):
    fake, s = env
    s.set_agent("Shadowheart")
    helm = s._inventory_rows("gear")["items"][0]
    r = s.equip(helm["id"])
    assert r["status"] == "done" and r["result"]["equipped"] is True, r
    assert [e["name"] for e in s._inventory_rows()["equipped"]] == ["Iron Helmet"]
    assert s.equip(helm["id"], remove=True)["result"]["equipped"] is False
    assert "not wearing" in s.equip(helm["id"], remove=True)["error"]
    pot = s._inventory_rows()["items"][0]
    assert "cannot be worn" in s.equip(pot["id"])["error"]


def test_give_to_the_human(env):
    fake, s = env
    s.set_agent("Shadowheart")
    inv = s._inventory_rows()
    pot = next(r for r in inv["items"] if r["name"] == "Potion of Healing")
    worn = inv["equipped"][0]
    assert "unequip" in s.give([worn["id"]])["error"]
    r = s.give([pot["id"]])
    assert r == {"given": ["Potion of Healing x2"], "to": "Tav"}
    assert fake.server.eval("MOCK.item[MOCK.heal:sub(-36)].given") == 2
    assert "not in your bag" in s.give([pot["id"]])["error"]
    fake.server.execute("MOCK.combat = true")
    scroll = next(r for r in inv["items"] if r["name"] == "Scroll of Bless")
    assert "fight" in s.give([scroll["id"]])["error"]


def test_flee_like_the_combat_button(env):
    fake, s = env
    s.set_agent("Shadowheart")
    assert "not in combat" in s.travel("flee")["error"]
    fake.server.execute("MOCK.combat = true; MOCK.turn = nil")
    assert "your turn" in s.travel("flee")["error"]
    fake.server.execute("MOCK.turn = MOCK.sh:sub(-36); MOCK.fleeFlags = { 'EnemyTooClose' }")
    err = s.travel("flee")["error"]
    assert "more than 27 m" in err and "4.2 m" in err
    fake.server.execute("MOCK.fleeFlags = nil; MOCK.fleeBlocked = true")
    assert "not allow" in s.travel("flee")["error"]
    fake.server.execute("MOCK.fleeBlocked = nil")
    r = s.travel("flee")
    assert r["status"] == "done" and r["result"]["fled"] and r["result"]["in_camp"], r
    assert fake.server.eval("MOCK.fled[2]") == "combat-1"
    assert fake.server.eval("MOCK.fighters[MOCK.host:sub(-36)]")  # the others fight on


def test_travel_to_camp_and_back(env):
    fake, s = env
    s.set_agent("Shadowheart")
    start = s.status()["pos"]
    r = s.travel("camp")
    assert r["status"] == "done" and r["result"]["in_camp"] is True, r
    fake.server.execute("MOCK.camp[MOCK.host:sub(-36)] = {0, 0, 0}")  # the human is in camp too
    r = s.travel("camp")  # in camp: the same button leaves it
    assert r["result"]["in_camp"] is False and s.status()["pos"] == start
    assert fake.server.eval("MOCK.camp[MOCK.host:sub(-36)] ~= nil")  # only the agent left
    fake.server.execute("MOCK.camp = {}")
    s.regroup()  # chained to the human: going to camp must not bring them along
    r = s.travel("camp")
    assert r["result"]["unchained"] is True
    assert not fake.server.eval("MOCK.camp[MOCK.host:sub(-36)] ~= nil")
    s.travel("camp")
    fake.server.execute("MOCK.campNight = true")
    s.travel("camp")
    assert "night" in s.travel("camp")["error"]
    fake.server.execute("MOCK.campNight = false")
    s.travel("camp")
    fake.server.execute("MOCK.campBlocked = true")
    assert "not allow" in s.travel("camp")["error"]
    fake.server.execute("MOCK.campBlocked = false; MOCK.combat = true")
    assert "combat" in s.travel("camp")["error"]
    assert "unknown destination" in s.travel("moon")["error"]


def test_travel_waypoint(env):
    fake, s = env
    s.set_agent("Shadowheart")
    s.regroup()
    listed = s.travel("waypoint")["waypoints"]
    assert [w["waypoint"] for w in listed] == ["Village"]  # locked and other-map ones are left out
    assert "no unlocked waypoint" in s.travel("waypoint", "Grove")["error"]
    r = s.travel("waypoint", "village")
    assert r["status"] == "done" and r["result"]["unchained"] is True and "effect" not in r["result"], r
    assert s.status()["pos"] == [100, 0, 0]
    assert fake.server.eval("MOCK.pos[MOCK.host:sub(-36)][1]") == 0  # the human stayed
    fake.server.execute("MOCK.wpBlocked = true")
    assert "not allow" in s.travel("waypoint", "Village")["error"]


SH = "3ed74f06-3c60-42dc-83f6-f034cb47c679"
TAV = "11111111-1111-1111-1111-111111111111"
GOB = "22222222-2222-2222-2222-222222222222"
CHEST = "44444444-4444-4444-4444-444444444444"


def test_combat_overview(env):
    fake, s = env
    s.set_agent("Shadowheart")
    assert "not in combat" in s.combat()["error"]
    fake.server.execute(
        f"MOCK.combat = true; MOCK.turn = '{GOB}'; MOCK.fighters = {{ ['{SH}'] = true, ['{TAV}'] = true, ['{GOB}'] = true }};"
        f"MOCK.init = {{ ['{SH}'] = 12, ['{TAV}'] = 8, ['{GOB}'] = 15 }}; MOCK.conc['{GOB}'] = 'Target_Bless'"
    )
    c = s._combat_rows()
    assert [r["name"] for r in c["order"]] == ["Goblin", "Shadowheart", "Tav"]  # Arron is not fighting
    gob, me, tav = c["order"]
    assert gob["current"] and gob["concentrating"] == "Bless" and gob["hp_pct"] == 80 and "hp" not in gob
    assert me["rel"] == "you" and me["hp"] == 20 and "dist" not in me
    assert tav["human"] and tav["dist"] == 2
    assert c["my_turn"] is False and c["movement_m"] == 9 and c["actions"] == 1
    lines = s.combat()["order"]
    assert lines[0].startswith(f">> {gob['id']} Goblin (enemy; level 3; AC 15; 80% HP; init 15;")
    assert "concentrating on Bless" in lines[0]
    assert lines[1].startswith(f"{me['id']} Shadowheart (you; HP 20/")
    assert lines[2].startswith(f"{tav['id']} Tav (the human; HP")


def test_combat_log_between_turns(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute(f"MOCK.combat = true; MOCK.fire('CombatStarted', 'combat-1'); MOCK.fire('TurnEnded', '{SH}')")
    fake.server.execute(
        f"MOCK.fire('UsingSpellOnTarget', '{GOB}', '{TAV}', 'Projectile_GuidingBolt', '', '', 1);"
        f"MOCK.fire('UsingSpellOnTarget', '{GOB}', '{SH}', 'Projectile_GuidingBolt', '', '', 1);"
        f"MOCK.fire('AttackedBy', '{TAV}', '{GOB}', '{GOB}', 'Fire', 7, '', 1);"
        f"MOCK.fire('AttackedBy', '{SH}', '{GOB}', '{GOB}', 'Fire', 0, '', 1);"
        f"MOCK.fire('StatusApplied', '{TAV}', 'DOWNED', '{GOB}', 1);"
        f"MOCK.fire('StatusApplied', '{SH}', 'SLEEPING', '{GOB}', 1);"
        f"MOCK.fire('StatusApplied', '{SH}', 'BURNING', '{GOB}', 1);"
        f"MOCK.fire('StatusRemoved', '{SH}', 'SLEEPING', '{GOB}', 1);"
        f"MOCK.turn = '{SH}'; MOCK.fire('TurnStarted', '{SH}')"
    )
    log = [
        {"by": "Goblin", "cast": "Guiding Bolt", "on": ["Tav", "you"]},
        {"by": "Goblin", "hit": "Tav", "damage": 7},
        {"by": "Goblin", "no_damage": "you"},  # a miss or a passed save
        {"downed": "Tav"},
        {"status": "Asleep", "on": "you"},
    ]
    events = s.wait(1)["events"]
    assert [e["kind"] for e in events] == ["combat_started", "attacked", "downed", "controlled", "control_ended", "your_turn"]
    assert events[1] == {"kind": "attacked", "by": "Goblin", "damage": 0}
    assert events[2] == {"kind": "downed", "name": "Tav", "human": True}
    assert events[3] == {"kind": "controlled", "status": "Asleep", "by": "Goblin"}
    assert events[5]["movement_m"] == 9
    assert s.combat()["since_your_last_turn"] == log
    fake.server.execute(f"MOCK.fire('TurnEnded', '{SH}')")
    assert "since_your_last_turn" not in s.combat()  # empty lists are dropped


def test_a_downed_party_member_did_not_die(env):
    fake, s = env
    s.set_agent("Shadowheart")
    run = "local t = MOCK.timers; MOCK.timers = {}; for _, fn in ipairs(t) do fn() end"
    fake.server.execute(f"MOCK.fire('Died', '{TAV}'); {run}")  # Osiris says so on 0 HP, downed or not
    assert s.wait(0.5)["events"] == []
    fake.server.execute(f"MOCK.dead['{TAV[-36:]}'] = true; MOCK.fire('Died', '{TAV}'); {run}")
    assert s.wait(0.5)["events"] == [{"kind": "died", "name": "Tav", "human": True}]
    assert s.wait(0.5)["events"] == []  # once
    fake.server.execute(f"MOCK.fire('Died', '{GOB}')")  # not in the party: at once
    assert s.wait(0.5)["events"] == [{"kind": "died", "name": "Goblin"}]


def test_examine_and_enemy_defenses(env):
    fake, s = env
    s.set_agent("Shadowheart")
    seen = {c["name"]: c["id"] for c in s._look_rows()["characters"]}
    x = s.examine(seen["Goblin"])
    assert x["ac"] == 15 and x["level"] == 3 and x["abilities"]["dex"] == 14
    assert x["resist"] == ["Fire"] and x["immune"] == ["Poison"] and x["vulnerable"] == ["Radiant"]
    assert x["immune_to"] == ["Charmed", "Asleep"]
    assert x["traits"] == [{"name": "Darkvision", "what": "Can see in the dark up to 12."},
                           {"name": "Nimble Escape", "what": "Disengage or hide as a bonus action."}]
    assert "hp" not in x and x["hp_pct"] == 80
    assert s.examine(seen["Tav"])["hp"] == 20
    assert "cannot see" in s.examine("Hidden_66666666-6666-6666-6666-666666666666")["error"]
    assert "characters" in s.examine(s._look_rows()["items"][0]["id"])["error"]
    fake.server.execute("MOCK.combat = true")
    c = s.combat()
    assert any("resists Fire" in line and "cannot be Charmed, Asleep" in line for line in c["order"])
    # the first listing in a fight brings the enemy's traits, later ones do not
    assert c["enemy_traits"] == [f"{seen['Goblin']} Goblin: Darkvision: Can see in the dark up to 12.; "
                                 "Nimble Escape: Disengage or hide as a bonus action."]
    gob = next(r for r in s._combat_rows()["order"] if r["name"] == "Goblin")
    assert gob["resist"] == ["Fire"] and gob["immune_to"] == ["Charmed", "Asleep"] and "traits" not in gob


def test_grenade_blast_spares_the_party(env):
    fake, s = env
    s.set_agent("Shadowheart")
    grease = _grease(s)["id"]
    r = s.throw(grease, x=1, y=0, z=1)  # Tav stands 1.4 m away, inside the 3 m puddle
    assert "Tav" in r["error"] and "even_if_allies" in r["error"], r
    assert _grease(s)["count"] == 2
    assert s.throw(grease, x=1, y=0, z=1, even_if_allies=True)["status"] == "done"
    # without a surface in the template the blast counts as 4 m
    fake.server.execute("MOCK_TPL = Ext.Template.GetTemplate; Ext.Template.GetTemplate = function() end")
    assert "Tav" in s.throw(_grease(s)["id"], x=3.5, y=0, z=1)["error"]


def test_human_points_with_a_middle_click(env):
    fake, s = env
    s.set_agent("Shadowheart")
    s.say("hi")  # brings up the panel
    c = fake.client.execute

    def click(ms=100, moved=0):
        c("MOCK_C.now = 1000; MOCK_C.fire('MouseButtonInput', { Button = 2, Pressed = true })")
        if moved:
            c(f"MOCK_C.pick.WindowCursorPos = {{ 500 + {moved}, 300 }}")
        c(f"MOCK_C.now = 1000 + {ms}; MOCK_C.fire('MouseButtonInput', {{ Button = 2, Pressed = false }})")

    c("MOCK_C.pick = { WindowCursorPos = { 500, 300 }, Inner = { Position = { 5, 0, 1 }, Inner = { { GameObject = {} },"
      f" {{ GameObject = {{ Uuid = {{ EntityUuid = '{GOB}' }}, ClientCharacter = {{}} }} }} }} }} }}")
    click()
    # an item, as the game hands it over: an id, but no ClientItem component
    c("MOCK_C.pick = { WindowCursorPos = { 500, 300 }, Inner = { Position = { -5, 0, 0 }, Inner = {"
      f" {{ GameObject = {{ Uuid = {{ EntityUuid = '{CHEST}' }} }} }} }} }} }}")
    click()
    c("MOCK_C.pick = { WindowCursorPos = { 500, 300 }, Inner = { Position = { 5.04, 0, 1 }, Inner = {} } }")
    click()
    click(ms=800)  # held: turning the camera
    click(moved=40)  # dragged
    c("MOCK_C.fire('MouseButtonInput', { Button = 1, Pressed = true }); MOCK_C.fire('MouseButtonInput', { Button = 1, Pressed = false })")
    c('MOCK_C.fire("KeyInput", { Event = "KeyDown", Key = "F9", Repeat = false })')  # F9 is the game's photo mode
    said = s.status()["human_says"]
    gob_id = next(x["id"] for x in s._look_rows()["characters"] if x["name"] == "Goblin")
    chest_id = next(x["id"] for x in s._look_rows()["items"] if x["name"] == "Chest")
    assert said == [f"[pointing at] Goblin ({gob_id}, enemy, 10.0 m E of you)",
                    f"[pointing at] Chest ({chest_id}, object, 7.0 m W of you)",
                    "[pointing at] the ground at x=5.0 y=0.0 z=1.0 (3.2 m E of you)"]



def _walk(fake, who, pos, note="local t = MOCK.timers; MOCK.timers = {}; for _, fn in ipairs(t) do fn() end"):
    """Put a party member at `pos`, let the 2 s sampling see it, and bring them back."""
    key = f"MOCK.pos[MOCK.{who}:sub(-36)]"
    fake.server.execute(f"local old = {key}; {key} = {{ {pos[0]}, 0, {pos[1]} }}; {note}; {key} = old")


def _spots(ex):
    """The frontier coordinates (x, y, z) in explore.unexplored."""
    import re

    return [tuple(float(v) for v in re.match(r"x=(\S+) y=(\S+) z=(\S+) ", line).groups()) for line in ex["unexplored"]]


def _west(ex):
    return [p for p in _spots(ex) if p[0] < -9 and abs(p[2]) < 8]


def test_look_explores_without_the_mod(env):
    # Frontiers: the nearest places she can walk to where ground nobody in the party has been begins.
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute("MOCK.edgeX = 12")  # no ground east of x = 12
    ex = s._look_rows()["explore"]
    assert ex["region"] == "the wilderness (act 1)"
    assert ex["nearest_waypoint"] == "Grove (50.0 m N, not unlocked)"
    assert len(ex["unexplored"]) == 3 and all("m on foot" in line for line in ex["unexplored"]), ex
    assert all(x <= 12 for x, _, _ in _spots(ex)) and "memory mod" in ex["memory"]
    assert _west(ex), ex  # the ground just west of the party's cells is new
    _walk(fake, "host", (-25, 0))  # the human went west while the agent did nothing
    assert not _west(s._look_rows()["explore"])
    fake.server.execute("BG3COOP = nil")  # a save load: without the mod the memory is gone
    assert _west(s._look_rows()["explore"])


def test_frontiers_tell_the_door_on_the_way_and_are_kept(env):
    fake, s = env
    s.set_agent("Shadowheart")
    door = _world_object(fake, "Cellar Door", (2, 0, -6))
    fake.server.execute(f'MOCK.doors = {{ ["{door}"] = true }}')
    # walls all round but for the way south through the door and the far diagonals
    fake.server.execute("MOCK.blocks = { { 2, 15, 9 }, { -8, 0, 4 }, { 12, 0, 4 }, { 8, -8, 4 }, { -4, -8, 4 } }")
    lines = s._look_rows()["explore"]["unexplored"]
    south = [line for line in lines if "through Cellar Door" in line]
    assert south and " S;" in south[0], lines
    asked = fake.server.eval("MOCK.pathAsked")
    s._look_rows()  # same spot: the ways are kept, no new questions
    assert fake.server.eval("MOCK.pathAsked") == asked


def test_a_locked_door_she_stands_by_is_not_on_the_way(env):
    # Every way starts next to it, yet the pathfinder never goes through a locked door.
    fake, s = env
    s.set_agent("Shadowheart")
    gate = _world_object(fake, "Iron Gate", (2.5, 0, 0.5))
    fake.server.execute(f'MOCK.doors = {{ ["{gate}"] = true }}; MOCK.locked = {{ ["{gate}"] = true }}')
    lines = s._look_rows()["explore"]["unexplored"]
    assert lines and not any("Iron Gate" in line for line in lines), lines


MOD = "addfead0-7a1a-46c3-942a-77c0348aeee3"


def load_memory_mod(fake):
    """What the Script Extender does at startup with the installed mod."""
    from bg3coop.modpak import mod_files

    src = mod_files()["Mods/BG3CoopMemory/ScriptExtender/Lua/BootstrapServer.lua"].decode()
    fake.server.globals().MOD_SRC = src
    fake.server.execute(f"""
        Mods = Mods or {{}}
        local env = setmetatable({{ ModuleUUID = "{MOD}" }}, {{ __index = _G }})
        Mods.BG3CoopMemory = env
        MOCK.mods["{MOD}"] = true
        assert(load(MOD_SRC, "BootstrapServer", "t", env))()
    """)


def test_memory_mod_keeps_the_trail_in_the_save(env):
    fake, s = env
    load_memory_mod(fake)
    fake.server.execute("for _, fn in ipairs(MOCK.subs.Tick) do fn() end")  # first sample on the game's tick
    assert fake.server.eval(f"MOCK.modvars['{MOD}'].Trail.WLD_Main_A['0,0']") == 1
    s.set_agent("Shadowheart")
    _walk(fake, "host", (-25, 0), note="Mods.BG3CoopMemory.Note()")
    ex = s._look_rows()["explore"]
    assert "memory" not in ex
    assert not _west(ex), ex
    fake.server.execute("BG3COOP = nil")  # the injected script goes; the save's record stays
    assert not _west(s._look_rows()["explore"])
    fake.server.execute(f"MOCK.modvars['{MOD}'] = {{}}")  # another save, from before the walk
    assert _west(s._look_rows()["explore"])


def test_quest_markers_from_the_map(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.client.execute("""
        local function marker(props, x, z, quests)
            local m = { WorldPos = { x, z }, QuestViews = quests }
            function m:GetAllProperties() return props end
            return m
        end
        MOCK_C.loca = { h1g1g1g1g1 = "Tombstone Shop", h2g2g2g2g2 = "Find the Killer", h3g3g3g3g3 = "Murder in Baldur's Gate", h4g4g4g4g4 = "Inn" }
        local markers = {
            marker({ Type = "LocationMarker", Name = "h4g4g4g4g4", Height = 5 }, 3, 3, {}),
            marker({ Type = "QuestMarker", Name = "h1g1g1g1g1", Height = 4 }, 2, 120,
                { { Quest = { Title = "h2g2g2g2g2" }, MainItem = { Title = "h3g3g3g3g3" } } }),
        }
        local dc = { CurrentPlayer = { WorldMap = { Markers = markers } } }
        MOCK_C.root = { Find = function() return { Children = { { Name = "Minimap", DataContext = dc } } } end }
    """)
    ex = s._look_rows()["explore"]
    assert ex["quest_marker"] == "Tombstone Shop (120 m N, x=2 y=4 z=120) for Find the Killer (part of Murder in Baldur's Gate)"
    assert s.quests()["markers"] == [ex["quest_marker"]]
    fake.client.execute("MOCK_C.root = nil")
    assert "quest_marker" not in s._look_rows()["explore"]


def test_memory_mod_pak_reads_back():
    from bg3coop import modpak

    pak = modpak.build_pak(modpak.mod_files())
    assert modpak.read_pak(pak) == modpak.mod_files()
    big = bytes(range(256)) * 40
    assert modpak.lz4_unblock(modpak.lz4_block(big)) == big
    assert modpak.lz4_unblock(modpak.lz4_block(b"short")) == b"short"
    assert modpak.mod_version() >= 1


def _tick(fake):
    fake.server.execute("for _, fn in ipairs(MOCK.subs.Tick) do fn() end")


def test_notes_without_the_mod(env, tmp_path):
    fake, s = env
    s.set_agent("Shadowheart")
    assert s.notes()["empty"] and "not installed" in s.notes()["warning"]
    assert s.notes("add", "Find a cure for the tadpole", "goal") == {"added": "s1"}
    assert s.notes("add", "Dry wit; protective of Tav", "persona") == {"added": "p1"}
    got = s.notes()
    assert got["goal"] == ["s1: Find a cure for the tadpole"] and got["persona"] == ["p1: Dry wit; protective of Tav"]
    assert (tmp_path / "notes" / f"avatar-{TAV}.json").exists()
    fake.server.execute("BG3COOP = nil")  # a save load: the story note was only in the Lua state
    got = s.notes()
    assert "goal" not in got and got["persona"] == ["p1: Dry wit; protective of Tav"]
    assert s.set_agent("Shadowheart")["notes"]["persona"]  # set_agent brings them back too


def test_notes_follow_the_save_with_the_mod(env):
    fake, s = env
    load_memory_mod(fake)
    _tick(fake)
    assert fake.server.eval(f"MOCK.modvars['{MOD}'].Campaign") == f"avatar-{TAV}"  # a save from before v2
    s.set_agent("Shadowheart")
    s.notes("add", "Promised Arron to come back", "story")
    s.notes("add", "Likes short messages", "preference")
    assert "warning" not in s.notes()
    assert fake.server.eval(f"MOCK.modvars['{MOD}'].Notes[1].text") == "Promised Arron to come back"
    fake.server.execute("BG3COOP = nil")
    assert s.notes()["story"] == ["s1: Promised Arron to come back"]
    # an older save of the same playthrough: no story note, same persona file
    fake.server.execute(f"MOCK.modvars['{MOD}'] = {{}}")
    _tick(fake)
    got = s.notes()
    assert "story" not in got and got["preference"] == ["p1: Likes short messages"]


def test_new_game_gets_its_own_campaign(env):
    fake, s = env
    load_memory_mod(fake)
    fake.server.execute("local real = Osi.GetRegion; Osi.GetRegion = function() return 'TUT_Avernus_C' end")
    _tick(fake)
    assert fake.server.eval(f"MOCK.modvars['{MOD}'].Campaign") == "aaaaaaaa-0000-0000-0000-000000000001"


def test_notes_edit_delete_and_limits(env, monkeypatch):
    _, s = env
    s.set_agent("Shadowheart")
    assert "kind must be" in s.notes("add", "x", "mood")["error"]
    assert "text required" in s.notes("add", "  ", "goal")["error"]
    s.notes("add", "Old plan", "goal")
    assert s.notes("edit", "New   plan", id="s1") == {"edited": "s1"}
    assert s.notes()["goal"] == ["s1: New plan"]
    assert "no note" in s.notes("delete", id="s9")["error"]
    assert s.notes("delete", id="s1") == {"deleted": "s1"}
    assert s.notes("add", "y" * 400, "place")["cut_to"] == 300
    import bg3coop.notes as n
    monkeypatch.setattr(n, "MAX_LOCAL", 1)
    s.notes("add", "a", "persona")
    assert "already" in s.notes("add", "b", "persona")["error"]


def test_origin_companions_get_a_role_play_sketch(env):
    _, s = env
    r = s.set_agent("Shadowheart")
    assert r["role_play"].startswith("Shadowheart: Guarded")
    from bg3coop.persona import role_play
    assert role_play("S_Player_Karlach_2c76687d-93a2-477b-8b18-8a14b549304c").startswith("Karlach:")
    assert role_play("HalfElves_Male_Wood_Player_Strong_98ba4a14-58cf-7ea2-10a5-dcec34aa78db") is None


def test_panel_speaks_the_games_language(env):
    fake, s = env
    fake.client.execute("MOCK_C.language = 'Chinese'")
    s.set_agent("Shadowheart")
    s.status()
    w, head, buttons, *_ = _panel(fake)
    assert w.Label.startswith("BG3 合作") and w.Label.endswith("###bg3coop")
    assert _activity(fake)[0].startswith("思考中 · ") and "上一步：看自己状态" in head.state.Label
    assert head.turn.Visible is False
    assert [b.Label for b in buttons] == ["跟上我", "停下", "等我", "自由行动"]
    assert "中键" in _lines(fake)[0]
    buttons[0].OnClick(buttons[0])
    assert s.party()["human_says"][0].startswith("[button] Follow me")  # the agent still reads English
    assert _lines(fake)[-1] == "[跟上我]" and s.game.chat[-1]["text"] == "[跟上我]"
    assert _texts(list(_panel(fake)[3].Children.values())[-1])[0] == "你"
    _answer_when_asked(fake, click="是")
    assert s.ask("开箱子吗？") == {"answer": "yes"}
    g = _asks(fake)[-1]
    assert [c.Label for c in g.Children.values() if not c.destroyed][-1] == "是"


def test_spell_lines(env):
    _, s = env
    line = s.views.spell_line({"spell": "Projectile_Fireball", "name": "Fireball", "kind": "damage", "level": 3,
                          "cost": "action, slot3", "range_m": 18, "upcast": [4, 5, 6], "usable": True})
    assert line == "Projectile_Fireball Fireball (damage; action, slot3; 18 m; upcast 4-6)"
    line = s.views.spell_line({"spell": "Target_Daylight_Container", "name": "Daylight", "kind": "utility",
                          "cost": "action, slot3", "range_m": 18, "upcast": [4, 6],
                          "variants": ["Target_Daylight", "Target_Daylight_Enchantment"],
                          "usable": False, "why_not": "no slot3 left"})
    assert line == ("Target_Daylight_Container Daylight (utility; action, slot3; 18 m; upcast 4,6; "
                    "variants Target_Daylight, Target_Daylight_Enchantment) NOT NOW: no slot3 left")
    assert s.views.spell_line({"spell": "Shout_Dash", "name": "Dash", "kind": "utility", "cost": "action",
                          "range_m": "self", "usable": True}) == "Shout_Dash Dash (utility; action; self)"


def test_a_lost_game_gives_plain_errors(env):
    _, s = env
    s.set_agent("Shadowheart")
    free = socket.socket()
    free.bind(("127.0.0.1", 0))
    port = free.getsockname()[1]
    free.close()  # nothing listens here: as if the game had closed
    good = s.game.port
    s.game.close()
    s.game.port = port
    for r in (s.status(), s.wait(1), s.look(), s.say("hi")):
        assert "cannot reach the game" in r["error"], r
    s.game.port = good  # the game is back
    assert s.status()["name"] == "Shadowheart"


def test_noticing_something_hidden(env):
    fake, s = env
    s.set_agent("Shadowheart")
    chest = next(i for i in s._look_rows()["items"] if i["name"] == "Chest")
    guid = s.ids.resolve(chest["id"])
    fake.server.execute(
        f"MOCK.fire('RollResult', 'GLO_CONST_HiddenItemCheck', '{TAV}', '{guid}', 1, 0, 0);"  # not mine
        f"MOCK.fire('RollResult', 'GLO_CONST_HiddenItemCheck', '{SH}', '{guid}', 0, 0, 0);"  # failed
        f"MOCK.fire('RollResult', 'Persuasion', '{SH}', '{guid}', 1, 1, 0);"  # an active roll
        f"MOCK.fire('RollResult', 'GAMEPLAY_SpellSavingThrowSave', '{SH}', '{guid}', 1, 0, 0);"  # a save vs her spell
        f"MOCK.fire('RollResult', 'GLO_CONST_HiddenItemCheck', '{SH}', '{guid}', 1, 0, 0)"
    )
    events = [e for e in s.wait(1)["events"] if e["kind"] == "noticed"]
    assert len(events) == 1
    e = events[0]
    assert e["name"] == "Chest" and e["id"] == chest["id"] and e["check"] == "HiddenItemCheck" and e["dist"] > 0


# ---- stealth: Arron stands at (0, 0, 8) and, unturned, faces south, so he watches Shadowheart at (2, 0, 0)

NPC = "33333333-3333-3333-3333-333333333333"
FACE_NORTH = "{ 0, 1, 0, 0 }"  # turned half way round: looks along +Z


def test_sight_shows_cones_and_safe_spots(env):
    fake, s = env
    s.set_agent("Shadowheart")
    r = s.sight()
    arron = next(w for w in r["watchers"] if "Arron" in w)
    assert "faces S" in arron and "16.0 m in a 90 deg cone" in arron and "SEES YOU" in arron
    gob = next(w for w in r["watchers"] if "Goblin" in w)
    assert "SEES YOU" not in gob  # he looks south too, and she stands west of him
    assert r["seen_by"] == "Arron" and r["sneaking"] is False
    assert not any("Sneaky Goblin" in w or "Tav" in w for w in r["watchers"])  # unseen ones and the party
    assert r["safe_spots"]
    for line in r["safe_spots"]:
        x, z = (float(part.split("=")[1]) for part in line.split()[0:3:2])
        assert s.sight(x, 0, z)["seen_there"] is False
    assert s.sight(0, 0, 2)["seen_there"] is True
    fake.server.execute("MOCK.walls = { { 1, 4, 1 } }")  # a pillar between them
    assert "seen_by" not in s.sight()
    assert any("behind cover" in w for w in s.sight()["watchers"])


def test_sneak_refused_in_view_then_hides(env):
    fake, s = env
    s.set_agent("Shadowheart")
    assert "Arron would spot you" in s.sneak()["error"]
    fake.server.execute(f"MOCK.rot['{NPC}'] = {FACE_NORTH}")
    r = s.sneak()
    assert r["status"] == "done" and r["result"]["sneaking"] is True, r
    assert s.status()["sneaking"] is True and s.wait(1)["status"]["sneaking"] is True
    assert s.sneak()["note"] == "already sneaking"
    assert s.sneak(on=False) == {"sneaking": False}
    assert not [e for e in s.wait(1)["events"] if e["kind"] == "stealth_lost"]  # asked for, not spotted


def test_spotted_while_sneaking(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute(f"MOCK.rot['{NPC}'] = {FACE_NORTH}")
    s.sneak()
    fake.server.execute(f"MOCK.rot['{NPC}'] = nil; Osi.RemoveStatus('{SH}', 'SNEAKING')")  # he turns round
    lost = [e for e in s.wait(1)["events"] if e["kind"] == "stealth_lost"]
    assert lost and lost[0]["seen_by"] == "Arron"


def test_sneaking_walk_checks_the_way(env):
    fake, s = env
    s.set_agent("Shadowheart")
    assert "not sneaking" in s.move(x=6, y=0, z=0, sneak=True)["error"]
    fake.server.execute(f"MOCK.rot['{NPC}'] = {FACE_NORTH}")
    s.sneak()
    r = s.move(x=0, y=0, z=14, sneak=True)  # straight past him into his view
    assert r["status"] == "failed" and "crosses Arron's view" in r["error"], r
    assert r["result"]["would_see_you"] == "Arron" and r["result"]["seen_at"][2] > 8
    assert s.status()["pos"] == [2, 0, 0]  # did not set off
    r = s.move(x=6, y=0, z=0, sneak=True)
    assert r["status"] == "done", r
    assert fake.server.eval("MOCK.walked_how") == "Walk"
    r = s.move(x=0, y=0, z=14, sneak=True, even_if_seen=True)  # he sees her get there, but she goes
    assert r["status"] == "done", r
    fake.server.execute("MOCK.noPath = true")
    assert "no way there" in s.move(x=6, y=0, z=0, sneak=True)["error"]


def test_sneaking_walk_stops_when_spotted(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute(f"MOCK.rot['{NPC}'] = {FACE_NORTH}; MOCK.slow = true")
    s.sneak()
    job = s.game.call("move", {"pos": [6, 0, 0], "sneak": True})["job"]
    assert s.game.call("job", {"id": job})["status"] == "running"  # on the way
    fake.server.execute(f"MOCK.rot['{NPC}'] = nil")  # he turns towards her
    r = s.job_status(job, 2)
    assert r["status"] == "interrupted" and r["result"]["would_see_you"] == "Arron", r
    fake.server.execute(f"MOCK.rot['{NPC}'] = {FACE_NORTH}")
    job = s.game.call("move", {"pos": [6, 0, 0], "sneak": True})["job"]
    s.game.call("job", {"id": job})
    fake.server.execute(f"Osi.RemoveStatus('{SH}', 'SNEAKING')")
    r = s.job_status(job, 2)
    assert r["status"] == "failed" and "no longer sneaking" in r["error"], r


def test_stealing_needs_permission_and_sneaking(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute(f"MOCK.owners[MOCK.chest:sub(-36)] = MOCK.npc; MOCK.rot['{NPC}'] = {FACE_NORTH}")
    chest = next(i for i in s._look_rows()["items"] if i["name"] == "Chest")
    assert s.move(target=chest["id"])["status"] == "done"
    potion = s.container(chest["id"])["items"][0]["id"]
    r = s.take([potion])
    assert "belongs to Arron" in r["error"] and "ask the human first" in r["error"]
    assert "only while sneaking" in s.take([potion], steal=True)["error"]
    assert not fake.server.eval(f"MOCK.picked[MOCK.potion:sub(-36)]")
    s.sneak()
    r = s.take([potion], steal=True)
    assert r["status"] == "done" and r["result"]["taken"] == ["Potion of Healing"], r


def test_no_looting_the_living(env):
    fake, s = env
    s.set_agent("Shadowheart")
    arron = next(c for c in s._look_rows()["characters"] if c["name"] == "Arron")
    fake.server.execute("MOCK.pos[MOCK.sh:sub(-36)] = { 0, 0, 7 }")  # next to him
    assert "pockets" in s.container(arron["id"])["error"]


# ---- trading: a fake trade window on the client; the server's PROC_StartTrade opens it ----

_TRADE_UI = """
MOCK_C.autoTick = true
local T = { open = false, gold = 100, tgold = 40, log = {} }
MOCK_C.tradeUI = T
local function obj(id, name, count, price, kind)
    return { EntityUUID = id, Name = name, Count = count, TradePrice = price, ItemType = kind or "Consumable",
        Equipped = "NotEquipped" }
end
T.goods = { obj("aaaaaaaa-0000-0000-0000-000000000001", "Arrows", 10, 20),
    obj("aaaaaaaa-0000-0000-0000-000000000002", "Cheese", 1, 6), obj("aaaaaaaa-0000-0000-0000-00000000000f", "Gold", 40, 40, "Gold") }
T.mine = { obj("77777777-7777-7777-7777-777777777776", "Bottle of Grease", 2, 8) }
T.humans = { obj("bbbbbbbb-0000-0000-0000-000000000001", "Tav's Sword", 1, 50) }
local function slots(list) local s = {} for i, o in ipairs(list) do s[i] = { Object = o } end return s end
local function remove(list, o) for i, x in ipairs(list) do if x == o then table.remove(list, i) return end end end
local function move(o, n, from, to, paid)
    local unit = o.TradePrice / o.Count
    if n >= o.Count then remove(from, o); to[#to + 1] = o
    else o.Count = o.Count - n; o.TradePrice = unit * o.Count; to[#to + 1] = obj(o.EntityUUID .. "x", o.Name, n, unit * n) end
    T.gold = T.gold + (paid and -unit * n or unit * n)
    T.tgold = T.tgold + (paid and unit * n or -unit * n)
end
local function deal(o, n)
    local buying = false
    for _, x in ipairs(T.goods) do if x == o then buying = true end end
    T.log[#T.log + 1] = (buying and "buy " or "sell ") .. o.Name .. " x" .. n .. " " .. T.widget.Visibility
        .. " hud " .. T.hotbar.Visibility
    if buying then move(o, n, T.goods, T.mine, true) else move(o, n, T.mine, T.goods, false) end
end
local dc = {}
setmetatable(dc, { __index = function(_, k)
    if k == "TraderInventory" then return { Slots = slots(T.goods) } end
    if k == "PartyCharacterInventories" then return {
        { OwnerObject = { EntityUUID = "11111111-1111-1111-1111-111111111111" }, TradeInventories = { { Slots = slots(T.humans) } } },
        { OwnerObject = { EntityUUID = "3ed74f06-3c60-42dc-83f6-f034cb47c679" }, TradeInventories = { { Slots = slots(T.mine) } } } } end
    if k == "TradePartyGold" then return T.gold end
    if k == "TraderInventoryGold" then return T.tgold end
end })
dc.CurrentTradingCharacter = { EntityUUID = T.who or "3ed74f06-3c60-42dc-83f6-f034cb47c679" }
dc.Trader = { EntityUUID = "33333333-3333-3333-3333-333333333333" }
dc.Mode = "Trade"
dc.TradeItemCommand = { Execute = function(_, o)
    if o.Count > 1 then T.split = { o = o, data = { ItemCount = o.Count, TargetCount = 1 } }
    else deal(o, 1) end
end }
T.widget = { Name = "Trade", Visibility = "Visible", DataContext = dc }
local split = { CurrentPlayer = { UIData = {} },
    ApplySplitCommand = { Execute = function() deal(T.split.o, T.split.data.TargetCount); T.split = nil end } }
T.splitWidget = { Name = "SplitItem", Visibility = "Visible", DataContext = split }
Ext.Input = { InjectKeyPress = function(k) if k == "ESCAPE" then T.open = false end end }
-- like the game: trading hides the HUD until the window closes
T.hotbar = { Name = "HotBar", Visibility = "Visible" }
T.combatOverlay = { Name = "CombatantsOverlay", Visibility = "Hidden" }  -- hidden before: stays hidden
function MOCK_C.openTrade() T.open = true; T.widget.Visibility = "Visible"; T.hotbar.Visibility = "Hidden" end
local root = { Find = function()
    if not T.open then T.hotbar.Visibility = "Visible" end
    local kids = { T.hotbar, T.combatOverlay }
    if T.open then kids[#kids + 1] = T.widget end
    if T.split then split.CurrentPlayer.UIData.SplitItemData = T.split.data; kids[#kids + 1] = T.splitWidget end
    return { Children = kids }
end }
local plain = Ext.UI.GetRoot
Ext.UI.GetRoot = function()
    if MOCK_C.autoTick and not MOCK_C.inTick then  -- the game ticks between our reads
        MOCK_C.inTick = true; pcall(MOCK_C.fire, "Tick", {}); MOCK_C.inTick = false
    end
    return root
end
"""


def _trade_env(fake, s):
    s.set_agent("Shadowheart")
    s.party()  # injects the client side
    fake.client.execute(_TRADE_UI)
    fake.server.globals().PY_open_trade = lambda: fake.client.execute("MOCK_C.openTrade()")
    fake.server.execute("Osi.PROC_StartTrade = function(me, npc, mode) MOCK.trade_mode = mode; PY_open_trade() end")
    return next(c for c in s._look_rows()["characters"] if c["name"] == "Arron")["id"]


def _answer_asks(fake, clicks):
    import threading

    def run():
        done = len([g for g in _panel(fake)[3].Children.values() if g.kind == "group"])
        for click in clicks:
            for _ in range(200):
                groups = [g for g in _panel(fake)[3].Children.values() if g.kind == "group"]
                if len(groups) > done:
                    done = len(groups)
                    btn = next(b for b in groups[-1].Children.values() if b.Label.startswith(click))
                    btn.OnClick(btn)
                    break
                time.sleep(0.05)
    threading.Thread(target=run, daemon=True).start()


def test_trade_on_your_own_is_hidden_and_closed(env):
    fake, s = env
    arron = _trade_env(fake, s)
    assert "why" in s.trade(arron)["error"]  # the human is asked first, with a reason
    _answer_asks(fake, ["Yes", "No"])  # may trade; not together
    r = s.trade(arron, why="arrows for my bow")
    assert r["together"] is False and r["merchant"] == "Arron", r
    assert [g.split(" ", 1)[1] for g in r["goods"]] == ["Arrows x10 (20 gold for all, about 2 each)", "Cheese (6 gold)"]
    assert fake.server.eval("MOCK.trade_mode") == 1  # Trade mode, not Barter
    assert fake.client.eval("MOCK_C.tradeUI.open") is False  # closed again after browsing
    arrows = next(g.split(" ")[0] for g in r["goods"] if "Arrows" in g)
    grease = s._inventory_rows()["items"]
    grease = next(i["id"] for i in grease if i["name"] == "Bottle of Grease")
    r = s.trade(arron, buy=[f"{arrows}:4"], sell=[f"{grease}:all"])  # no new question within 10 minutes
    assert r["done"] == ["sold Bottle of Grease x2 (got 8 gold)", "bought Arrows x4 (paid 8 gold)"], r
    assert r["your_gold"] == 100
    log = list(fake.client.eval("MOCK_C.tradeUI.log").values())
    # the human never saw the window, and kept their HUD
    assert log == ["sell Bottle of Grease x2 Collapsed hud Visible", "buy Arrows x4 Collapsed hud Visible"]
    assert fake.client.eval("MOCK_C.tradeUI.combatOverlay.Visibility") == "Hidden"
    assert fake.client.eval("MOCK_C.tradeUI.open") is False
    assert any("Traded with Arron" in line for line in _lines(fake))  # the human hears what was traded


def test_trade_together_stays_open_and_sells_only_yours(env):
    fake, s = env
    arron = _trade_env(fake, s)
    _answer_asks(fake, ["Yes", "Yes"])
    r = s.trade(arron, why="selling junk", show_yours=True)
    assert r["together"] is True and [y.split(" ", 1)[1] for y in r["yours"]] == ["Bottle of Grease x2 (8 gold for all, about 4 each)"]
    assert fake.client.eval("MOCK_C.tradeUI.open") is True
    assert fake.client.eval("MOCK_C.tradeUI.widget.Visibility") == "Visible"
    r = s.trade(arron, buy=[next(g.split(" ")[0] for g in r["goods"] if "Cheese" in g)])
    assert r["done"] == ["bought Cheese (paid 6 gold)"]
    assert s.trade(arron, done=True) == {"closed": True}
    assert fake.client.eval("MOCK_C.tradeUI.open") is False


def test_trade_needs_the_humans_yes(env):
    fake, s = env
    arron = _trade_env(fake, s)
    _answer_asks(fake, ["No"])
    r = s.trade(arron, why="potions")
    assert r["declined"] and fake.client.eval("MOCK_C.tradeUI.open") is False
    assert fake.server.eval("MOCK.trade_mode") is None


def test_no_trading_while_the_human_trades(env):
    fake, s = env
    arron = _trade_env(fake, s)
    fake.client.execute("MOCK_C.tradeUI.widget.DataContext.CurrentTradingCharacter = { EntityUUID = '11111111-1111-1111-1111-111111111111' }; MOCK_C.openTrade()")
    assert "human is trading" in s.trade(arron, why="potions")["error"]


def test_walks_are_planned_before_setting_off(env):
    # The game's pathfinder is asked first: with no way there the walk fails at once, saying why
    # and where the closest reachable spot is, instead of standing still and timing out.
    fake, s = env
    s.set_agent("Shadowheart")
    door = _world_object(fake, "Cell Door", (2, 0, 6))
    fake.server.execute(f'MOCK.doors = {{ ["{door}"] = true }}; MOCK.locked = {{ ["{door}"] = true }}\n'
                        'MOCK.blocks = { { 2, 6, 1, door = true } }')
    r = s.move(x=2, y=0, z=12)
    assert r["status"] == "failed" and "locked door" in r["error"] and "Cell Door" in r["error"], r
    assert r["result"]["blocked_by"]["name"] == "Cell Door" and r["result"]["blocked_by"]["id"].startswith("e")
    near = r["result"]["nearest"]
    assert 4 < near["pos"][2] < 5 and near["short_m"] > 7, near
    assert s.status()["pos"] == [2, 0, 0]  # did not set off
    fake.server.execute("MOCK.blocks = { { 2, 6, 1, ladder = true } }")
    assert s.move(x=2, y=0, z=12)["status"] == "done"  # the walk climbs ladders itself
    fake.server.execute('MOCK.pos["3ed74f06-3c60-42dc-83f6-f034cb47c679"] = { 2, 0, 0 }')
    fake.server.execute("MOCK.blocks = { { 2, 6, 1 } }")
    assert "no way there on foot" in s.move(x=2, y=0, z=12)["error"]
    fake.server.execute("MOCK.blocks = {}")
    assert s.move(x=2, y=0, z=12)["status"] == "done"


def test_move_in_a_direction_goes_as_far_as_it_can_walk(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute("MOCK.blocks = { { 2, 6, 3 } }")  # a wall 3-9 m north
    r = s.move(direction="N", meters=10)
    assert r["status"] == "done", r
    assert 1 < s.status()["pos"][2] < 3
    fake.server.execute("MOCK.edgeX = 3")  # a drop just east
    assert "nowhere to walk to the E" in s.move(direction="E", meters=10)["error"]


def test_use_walks_to_where_it_can_reach_it(env):
    # A sign's centre is in the wall: the way ends 2.4 m short, close enough to use it from there.
    fake, s = env
    s.set_agent("Shadowheart")
    _world_object(fake, "Sign", (2, 0, 10), "MOCK.signRead = true")
    fake.server.execute("MOCK.pathShort = 2.4")
    sign = next(i["id"] for i in s._look_rows()["items"] if i["name"] == "Sign")
    r = s.use(sign)
    assert r["status"] == "done", r
    assert fake.server.eval("MOCK.signRead") is True
    assert s.status()["pos"][2] == pytest.approx(7.6, abs=0.2)
    assert not fake.server.eval("MOCK.movedToObject")  # walked to the planned spot, not "to the object"


def test_look_lists_only_places_you_can_walk_to(env):
    fake, s = env
    s.set_agent("Shadowheart")
    fake.server.execute("MOCK.blocks = { { 2, 30, 18 } }")  # a wall across the north
    ex = s._look_rows()["explore"]
    assert ex["unexplored"] and not any(z > 12 and abs(x - 2) < 10 for x, _, z in _spots(ex)), ex
    fake.server.execute("MOCK.noPath = true; BG3COOP.frontCache = {}")  # walled in
    ex = s._look_rows()["explore"]
    assert ex["unexplored"] == [] and "everywhere you can walk to" in ex["hint"]


def test_explore_lines():
    from bg3coop import explore

    out = explore.summary({}, {"spots": [{"pos": [1, 2.5, 3], "dist": 20, "dir": "N", "walk_m": 41,
                                          "via": [{"id": "x", "name": "Door"}], "dy": -4}], "more": True})
    assert out["unexplored"] == ["x=1 y=2.5 z=3 (20 m N; 41 m on foot; through Door; down 4 m)"]
    assert "next look" in out["more"]
    assert "look again" in explore.summary({}, {"spots": {}, "more": True})["hint"]


def test_look_marks_exits(env):
    # Doors, ladders, stairs: whether she can get there and whether what lies past is new.
    fake, s = env
    s.set_agent("Shadowheart")
    near = _world_object(fake, "Kitchen Door", (2, 0, 5))
    far = _world_object(fake, "Vault Door", (2, 0, -9))
    stairs = _world_object(fake, "Secret Stairs", (6, 0, 0))
    fake.server.execute(f'MOCK.doors = {{ ["{near}"] = true, ["{far}"] = true }}\n'
                        f'MOCK.usable = MOCK.usable or {{}}; MOCK.usable["{stairs}"] = true\n'
                        'MOCK.blocks = { { 2, -5, 1, door = true } }')
    items = {i["name"]: i for i in s._look_rows()["items"]}
    assert "can't get there" not in str(items.get("Kitchen Door")), items
    vault = items["Vault Door"]
    assert "locked door is in the way" in vault["unreachable"], vault
    assert "unexplored beyond" in s.views.item_line(vault)  # 6 m past it is outside the party's cells
    assert items["Secret Stairs"]["kind"] == "stairs"



def test_a_walk_after_regroup_leaves_the_humans_group(env):
    # Chained to the human, the game walks the agent back to them as soon as it stops.
    fake, s = env
    s.set_agent("Shadowheart")
    s.regroup()
    r = s.move(x=2, y=0, z=6)
    assert r["status"] == "done" and "regroup" in r["result"]["unchained"], r
    assert fake.world.detached["3ed74f06-3c60-42dc-83f6-f034cb47c679"]
    assert "unchained" not in s.move(x=2, y=0, z=3)["result"]  # already on her own


def _crowd_rows():
    chars = [{"id": "e1", "name": "Tav", "rel": "party", "human": True, "dist": 38.0, "dir": "S"},
             {"id": "e2", "name": "Rat", "rel": "neutral", "dist": 2.0, "dir": "N"},
             {"id": "e3", "name": "Imp", "rel": "enemy", "combat": True, "dist": 39.0, "dir": "E"}]
    items = [{"id": f"e{10 + n}", "name": "Candle", "kind": "usable", "dist": 3.0 + n, "dir": "NE"} for n in range(8)]
    items += [{"id": f"e{30 + n}", "name": f"Crate {n}", "kind": "container", "dist": 5.0 + n, "dir": "W"}
              for n in range(35)]
    items += [{"id": "e90", "name": "Lever", "kind": "usable", "dist": 1.0, "dir": "N"}]
    return chars, items


def test_look_keeps_about_30_rows_and_sums_up_the_rest():
    from bg3coop.views import crowd, group_line
    chars, items = _crowd_rows()
    c, i, g, more = crowd(chars, items)
    names = [x["name"] for x in c]
    assert "Tav" in names and "Imp" in names  # the human and enemies in the fight always
    assert len(c) + len(i) + len(g) <= 32
    assert [x["name"] for x in i][0] == "Lever"  # close and usable beats far containers
    assert len(g) == 1 and g[0]["count"] == 8 and g[0]["id"] == "e10"
    assert group_line(g[0]) == "e10 Candle x8 (usable, 3.0-10.0 m, nearest NE)"
    assert more and all(" m: " in line for line in more)
    assert sum(int(w) for line in more for w in line.split(": ")[1].split() if w.isdigit()) \
        == len(chars) + len(items) - len(c) - len(i) - g[0]["count"]


def test_look_with_many_rows_lists_the_rest_once():
    from bg3coop.views import LookMemory
    chars, items = _crowd_rows()
    mem = LookMemory()
    r = {"me": [0, 0, 0], "characters": chars, "items": items, "explore": {"region": "X"}}
    first = mem.show(r, "Shadowheart", 40)
    assert first["farther"] and any("Candle x8" in line for line in first["items"])
    again = mem.show(r, "Shadowheart", 40)
    assert "farther" not in again and "gone" not in again


# ---------------------------------------------------------------- combat as tested on Orin (2026-11-04)

DEVA = "99999999-9999-9999-9999-999999999999"


def _fight(fake, s):
    s.set_agent("Shadowheart")
    s.wait(0.5)  # the backlog
    fake.server.execute(f"MOCK.combat = true; MOCK.init = {{ ['{SH}'] = 12, ['{TAV}'] = 8, ['{GOB}'] = 15 }};"
                        f"MOCK.fighters = {{ ['{SH}'] = true, ['{TAV}'] = true, ['{GOB}'] = true, ['{DEVA}'] = true }};"
                        f"MOCK.fire('CombatStarted', 'combat-1')")


def test_the_fight_says_where_everyone_is_and_how_far_to_walk(env):
    fake, s = env
    _fight(fake, s)
    fake.server.execute(f"MOCK.turn = '{SH}'; MOCK.fire('TurnStarted', '{SH}')")
    rows = {r["name"]: r for r in s._combat_rows()["order"]}
    gob = rows["Goblin"]
    assert len(gob["pos"]) == 3 and gob["walk_m"] > 0 and "walk_m" not in rows["Shadowheart"]
    line = next(x for x in s.combat()["order"] if "Goblin" in x)
    x, y, z = gob["pos"]
    assert f"x={x} y={y} z={z}" in line
    assert f"walk {gob['walk_m']} m (" in line and "your movement" in line
    x = s.examine(next(r for r in s._combat_rows()["order"] if r["name"] == "Goblin")["id"])
    assert x["pos"] == gob["pos"] and x["walk_m"] == gob["walk_m"]
    fake.server.execute("MOCK.noPath = true")
    assert "no way there on foot" in next(x for x in s.combat()["order"] if "Goblin" in x)


def test_the_first_result_of_a_turn_brings_the_fight(env):
    fake, s = env
    _fight(fake, s)
    fake.server.execute(f"MOCK.turn = '{GOB}'")
    assert "your_turn" not in s.status()  # not yours
    fake.server.execute(f"MOCK.turn = '{SH}'; MOCK.fire('TurnStarted', '{SH}')")
    r = s.inventory()  # whatever the agent calls first
    assert r["your_turn"]["my_turn"] and any("Goblin" in line for line in r["your_turn"]["order"])
    assert r["your_turn"]["enemy_traits"]  # the enemies' traits, the first time
    assert "your_turn" not in s.status()  # once per turn
    assert "enemy_traits" not in s.combat()
    fake.server.execute(f"MOCK.fire('TurnEnded', '{SH}'); MOCK.turn = '{SH}'; MOCK.fire('TurnStarted', '{SH}')")
    c = s.combat()  # the next turn: combat itself is the picture
    assert c["my_turn"] and "your_turn" not in c
    assert "your_turn" not in s.status()


def test_activity_line_shows_what_the_agent_does_and_whether_it_got_its_turn(env):
    fake, s = env
    _fight(fake, s)
    gob = next(c for c in s._look_rows()["characters"] if c["name"] == "Goblin")
    c = fake.client.execute
    c("MOCK_C.now = 1000")
    s.status()
    line, recent = _activity(fake)
    assert line == "Thinking · 0s  ·  after: checking myself"
    assert recent[0].endswith(" checking myself")
    c("MOCK_C.now = 13000")
    assert _activity(fake)[0].startswith("Thinking · 12s")
    c("MOCK_C.now = 200000")
    assert _activity(fake)[0] == "No action for 3m 19s · thinking hard, or the agent stopped"
    # a tool running: what it is, by name, and for how long
    s.chat.begin("cast", {"spell": "Fire Bolt", "target": gob["id"]})
    c("MOCK_C.now = 203000")
    assert _activity(fake)[0] == "casting Fire Bolt → Goblin · 3s"
    s.cast("Fire Bolt", target=gob["id"])  # not the agent's turn: refused
    assert _activity(fake)[1][0].endswith("casting Fire Bolt → Goblin failed")
    # the turn comes: the client sees it before the agent is told, then once the agent got it
    fake.server.execute(f"MOCK.turn = '{SH}'; MOCK.fire('TurnStarted', '{SH}')")
    c(f"MOCK_C.turns = {{ ['{SH}'] = {{ IsActiveCombatTurn = true }} }}")
    c("MOCK_C.now = 210000")
    _activity(fake)
    c("MOCK_C.now = 218000")
    _activity(fake)
    assert _Panel(fake).turn.Label == "Shadowheart's turn · not received yet (8s)"
    assert "your_turn" in s.inventory()
    assert _activity(fake)[0].startswith("Thinking · 0s")
    assert _Panel(fake).turn.Label == "Shadowheart's turn · received" and _Panel(fake).turn.Visible
    c(f"MOCK_C.turns['{SH}'].RequestedEndTurn = true; MOCK_C.now = 219000")
    assert _activity(fake)[0].startswith("Thinking · 1s") and _Panel(fake).turn.Visible is False
    s.status()
    s.status()
    recent = _activity(fake)[1]
    assert len(recent) == 7 and recent[-1].endswith("taking over")


def test_wait_wakes_for_a_shared_turn_that_started_with_someone_else(env):
    fake, s = env
    _fight(fake, s)
    fake.server.execute(f"MOCK.turn = '{GOB}'")
    s.status()
    # the human and the agent share one turn: the game names only the human in TurnStarted
    fake.server.execute(f"MOCK.turn = '{SH}'; MOCK.fire('TurnStarted', '{TAV}')")
    t = time.monotonic()
    r = s.wait(20)
    assert time.monotonic() - t < 5
    assert "your_turn" in r and [e for e in r["events"] if e["kind"] == "your_turn"]
    assert "your_turn" not in s.status()  # once per turn
    r = s.wait(1)
    assert not [e for e in r["events"] if e["kind"] == "your_turn"]
    # the next round: someone else's turn in between, then the shared turn again
    fake.server.execute(f"MOCK.turn = '{GOB}'; MOCK.fire('TurnStarted', '{GOB}')")
    s.status()
    fake.server.execute(f"MOCK.turn = '{SH}'")  # no TurnStarted at all this time
    r = s.wait(20)
    assert "your_turn" in r


def test_what_changed_between_turns_and_the_dead_human(env):
    fake, s = env
    _fight(fake, s)
    fake.server.execute(f"MOCK.turn = '{SH}'; MOCK.fire('TurnStarted', '{SH}'); MOCK.fire('TurnEnded', '{SH}')")
    s.wait(0.5)
    # on others' turns: the goblin is hurt and burns, Shadowheart is slowed, Tav drops, then dies
    # without a Died event (the death saves failed) and falls out of the fight's lists
    fake.server.execute(
        f"MOCK.hp = {{ ['{GOB}'] = {{ Hp = 5, MaxHp = 25 }} }}; MOCK.st = {{ ['{GOB}'] = {{ 'BURNING' }} }};"
        f"MOCK.statuses[#MOCK.statuses + 1] = 'SLEEPING';"
        f"MOCK.active['{TAV}'] = {{ DOWNED = true }}; MOCK.fire('StatusApplied', '{TAV}', 'DOWNED', '{GOB}', 1)")
    assert [e["kind"] for e in s.wait(0.5)["events"]] == ["downed"]
    fake.server.execute(f"MOCK.active['{TAV}'] = nil; MOCK.dead['{TAV}'] = true;"
                        f"MOCK.fighters = {{ ['{SH}'] = true, ['{GOB}'] = true }}")
    assert s.wait(0.5)["events"] == [{"kind": "died", "name": "Tav", "human": True}]
    assert s.status()["human"]["dead"]
    fake.server.execute(f"MOCK.turn = '{SH}'; MOCK.fire('TurnStarted', '{SH}')")
    c = s.combat()
    tav = next(line for line in c["order"] if " Tav " in line)
    assert "the human" in tav and "DEAD" in tav  # still listed, though out of the fight
    assert {"died": "Tav"} in c["since_your_last_turn"]
    assert c["changes_since_your_last_turn"] == [
        "Goblin: HP 80% -> 20%; now Burning",
        "Tav: DEAD",
        "you: now Asleep",
    ]


def test_spells_on_the_dead_are_the_games_call(env):
    fake, s = env
    _fight(fake, s)
    tav = s._look_rows()["characters"][0]["id"]
    fake.server.execute(f"MOCK.dead['{TAV}'] = true; MOCK.turn = '{SH}'")
    revive = next(i["id"] for i in s._inventory_rows("scroll")["items"] if "Revivify" in i["name"])
    assert "error" not in s.use_item(revive, target=tav)  # a revival is fine


def test_a_spell_on_the_dead_is_not_refused_up_front(env):
    fake, s = env
    _fight(fake, s)
    tav = s._look_rows()["characters"][0]["id"]
    fake.server.execute(f"MOCK.dead['{TAV}'] = true; MOCK.turn = '{SH}'")
    assert s.cast("Projectile_GuidingBolt", target=tav)["status"] == "done"  # the game decides


def test_a_revive_spell_brings_back_the_dead(env):
    fake, s = env
    _fight(fake, s)
    tav = s._look_rows()["characters"][0]["id"]
    fake.server.execute(f"MOCK.dead['{TAV}'] = true; MOCK.turn = '{SH}'")
    r = s.cast("Teleportation_Revivify", target=tav)
    assert r["status"] == "done" and r["result"]["revived"] == "Tav", r
    assert not fake.server.eval(f"MOCK.dead['{TAV}']")
    assert "not dead or downed" in s.cast("Teleportation_Revivify", target=tav)["error"]


def test_shouts_take_effect_around_you(env):
    fake, s = env
    _fight(fake, s)
    fake.server.execute(f"MOCK.turn = '{SH}'")
    gob = next(c["id"] for c in s._look_rows()["characters"] if c["name"] == "Goblin")
    r = s.cast("Shout_HealingWord_Mass", target=gob)
    assert r["status"] == "done" and "target you gave was not used" in r["result"]["note"]
    assert "Tav (party)" in r["result"]["around_you"] and fake.server.eval("MOCK.casts[#MOCK.casts]") == "Shout_HealingWord_Mass@pos"
    # Tav far off and Shadowheart unhurt: nobody it could heal
    fake.server.execute(f"MOCK.pos['{TAV}'] = {{ 30, 0, 0 }}; MOCK.hp = {{ ['{SH}'] = {{ Hp = 25, MaxHp = 25 }} }};"
                        f"MOCK.res = {{}}")
    err = s.cast("Shout_HealingWord_Mass")["error"]
    assert "no hurt party member is within 9 m" in err and "Tav 28.0 m away" in err
    assert s.cast("Shout_RadianceOfTheDawn")["status"] == "done"  # burns enemies: no heal check


def test_summons_act_on_their_turn(env):
    fake, s = env
    fake.server.execute(f"MOCK.chars[#MOCK.chars + 1] = '{DEVA}'; MOCK.pos['{DEVA}'] = {{ 4, 0, 0 }};"
                        f"MOCK.names['{DEVA}'] = 'Deva'; MOCK.summoner = {{ ['{DEVA}'] = '{SH}' }}")
    _fight(fake, s)
    fake.server.execute(f"MOCK.turns = {{ ['{SH}'] = true, ['{DEVA}'] = true }}; MOCK.fire('TurnStarted', '{DEVA}')")
    ev = [e for e in s.wait(0.5)["events"] if e["kind"] == "summon_turn"]
    assert ev[0]["name"] == "Deva"
    assert s.status()["summon_turn"] == ["Deva"]
    c = s.combat()
    assert any("Deva (your summon; HP 20/25" in line for line in c["order"])
    assert c["your_summons"] == [f"{ev[0]['id']} Deva (ITS TURN NOW: 9 m movement, 1 action(s), 1 bonus action(s))"]
    gob = next(x["id"] for x in s._look_rows()["characters"] if x["name"] == "Goblin")
    assert s.cast("Target_MainHandAttack", target=gob, summon="deva")["status"] == "done"
    assert fake.server.eval("MOCK.casts[#MOCK.casts]") == f"Target_MainHandAttack@{GOB}"
    assert fake.server.eval(f"MOCK.res['{DEVA}']['ap-guid'][1].Amount") == 0  # the summon paid
    assert fake.server.eval(f"MOCK.res['{SH}']['ap-guid'][1].Amount") == 1
    # the log names the summon, not its summoner
    fake.server.execute(f"MOCK.fire('AttackedBy', '{GOB}', '{SH}', '{DEVA}', 'Radiant', 6, '', 1)")
    assert {"by": "Deva (your summon)", "hit": "Goblin", "damage": 6} in s.combat()["since_your_last_turn"]
    # the game walks the summon first: the result says it moved, not "you"
    fake.server.execute(f"MOCK.walkOnCast = 3; MOCK.res['{DEVA}']['ap-guid'][1].Amount = 1")
    r = s.cast("Target_MainHandAttack", target=gob, summon="deva")["result"]
    fake.server.execute("MOCK.walkOnCast = nil")
    assert r["moved_m"] == 3 and r["why_moved"] == "the game walked Deva into range or sight first"
    assert s.end_turn(summon="Deva")["ended"]
    assert s.status()["my_turn"]  # Shadowheart's own turn goes on
    assert "no summon" in s.cast("Target_MainHandAttack", target=gob, summon="Imp")["error"]


def test_summons_found_in_the_summon_container_too(env):
    fake, s = env
    fake.server.execute(f"MOCK.chars[#MOCK.chars + 1] = '{DEVA}'; MOCK.pos['{DEVA}'] = {{ 4, 0, 0 }};"
                        f"MOCK.names['{DEVA}'] = 'Deva'; MOCK.summons = {{ ['{SH}'] = {{ '{DEVA}' }} }}")
    _fight(fake, s)
    assert any("Deva (your summon" in line for line in s.combat()["order"])


def test_a_shout_is_logged_when_it_goes_off(env):
    fake, s = env
    _fight(fake, s)
    fake.server.execute(f"MOCK.turn = '{SH}'")
    assert s.cast("Shout_HealingWord_Mass")["status"] == "done"
    # cast at the caster's feet: no UsingSpellOnTarget, the log has it from CastedSpell
    assert {"by": "you", "cast": "Mass Healing Word", "on": ["you", "Tav"]} in s.combat()["since_your_last_turn"]
    # a per-target event that does come joins the line instead of making another
    fake.server.execute(f"MOCK.fire('UsingSpellOnTarget', '{SH}', '{TAV}', 'Shout_HealingWord_Mass', '', '', 1)")
    rows = [r for r in s.combat()["since_your_last_turn"] if r.get("cast") == "Mass Healing Word"]
    assert rows == [{"by": "you", "cast": "Mass Healing Word", "on": ["you", "Tav"]}]


def test_a_summon_goes_on_the_ground_by_the_target(env):
    fake, s = env
    _fight(fake, s)
    fake.server.execute(f"MOCK.turn = '{SH}'")
    gob = next(c["id"] for c in s._look_rows()["characters"] if c["name"] == "Goblin")
    r = s.cast("Target_FlamingSphere", target=gob)
    assert r["status"] == "done" and "next to Goblin" in r["result"]["note"], r
    assert fake.server.eval("MOCK.casts[#MOCK.casts]") == "Target_FlamingSphere@pos"
    # the goblin stands at x 12, Shadowheart at x 2: the spot is 1.5 m short of the goblin
    assert fake.server.eval("MOCK.castAt[1]") == 10.5 and r["result"]["at"] == [10.5, 0, 0]
    assert {"by": "you", "cast": "Flaming Sphere"} in s.combat()["since_your_last_turn"]


def test_one_blow_is_one_line(env):
    fake, s = env
    _fight(fake, s)
    # a slash and its fire raise AttackedBy twice; a miss then a hit on another target stays apart
    fake.server.execute(
        f"MOCK.fire('AttackedBy', '{GOB}', '{TAV}', '{TAV}', 'Slashing', 9, '', 1);"
        f"MOCK.fire('AttackedBy', '{GOB}', '{TAV}', '{TAV}', 'Fire', 1, '', 1);"
        f"MOCK.fire('AttackedBy', '{SH}', '{GOB}', '{GOB}', 'Piercing', 0, '', 1);"
        f"MOCK.fire('AttackedBy', '{SH}', '{GOB}', '{GOB}', 'Poison', 2, '', 1)")
    assert s.combat()["since_your_last_turn"] == [
        {"by": "Tav", "hit": "Goblin", "damage": 10},
        {"by": "Goblin", "hit": "you", "damage": 2},
    ]


def test_enemy_statuses_say_what_they_do_once(env):
    fake, s = env
    _fight(fake, s)
    fake.server.execute(f"MOCK.st = {{ ['{GOB}'] = {{ 'BURNING', 'DIFFICULTY', 'DIFFICULTY' }} }}")
    c = s.combat()
    gob = next(line for line in c["order"] if "Goblin" in line)
    assert "Burning" in gob and "Hardcore" not in gob  # kept off the portraits
    assert c["status_effects"] == ["Burning: Takes 1d4 Fire at the start of each turn."]
    assert "status_effects" not in s.combat()  # once a fight
    fake.server.execute("MOCK.combat = false; MOCK.fire('CombatEnded', 'combat-1');"
                        "MOCK.combat = true; MOCK.fire('CombatStarted', 'combat-2')")
    assert s.combat()["status_effects"]  # a new fight tells again


def test_changes_leave_out_statuses_that_come_and_go(env):
    fake, s = env
    _fight(fake, s)
    fake.server.execute(f"MOCK.turn = '{SH}'; MOCK.fire('TurnStarted', '{SH}'); MOCK.fire('TurnEnded', '{SH}')")
    fake.server.execute(f"MOCK.st = {{ ['{TAV}'] = {{ 'GWM_BONUS_ATTACK', 'MARTIAL_ARTS', 'BURNING' }} }}")
    fake.server.execute(f"MOCK.turn = '{SH}'; MOCK.fire('TurnStarted', '{SH}')")
    assert s.combat()["changes_since_your_last_turn"] == ["Tav: now Burning"]


def test_enemies_of_a_kind_share_one_traits_line():
    from bg3coop import views
    t = [{"name": "Darkvision", "what": "Sees in the dark."}]
    order = [{"id": "e3", "name": "Reaper", "traits": t}, {"id": "e4", "name": "Reaper", "traits": t},
             {"id": "e5", "name": "Orin", "traits": [{"name": "Unstoppable"}]}, {"id": "e6", "name": "Imp", "traits": t}]
    assert views.traits_lines(order[:2]) == ["Reaper x2 (e3, e4): Darkvision: Sees in the dark."]
    assert views.traits_lines(order) == ["e3 Reaper, e4 Reaper, e6 Imp: Darkvision: Sees in the dark.",
                                         "e5 Orin: Unstoppable"]


def test_drawn_into_a_fight_late_still_hears_of_it(env):
    fake, s = env
    s.set_agent("Shadowheart")
    s.wait(0.5)  # the backlog
    # the fight starts without her (she stood too far off), and draws her in a moment later
    fake.server.execute(f"MOCK.combat = true; MOCK.fighters = {{ ['{TAV}'] = true, ['{GOB}'] = true }};"
                        f"MOCK.fire('CombatStarted', 'combat-1')")
    assert s.wait(0.5)["events"] == []
    fake.server.execute(f"MOCK.fighters = {{ ['{SH}'] = true, ['{TAV}'] = true, ['{GOB}'] = true }}")
    assert [e["kind"] for e in s.wait(0.5)["events"]] == ["combat_started"]
    assert s.wait(0.5)["events"] == []  # once
    fake.server.execute("MOCK.fire('CombatStarted', 'combat-1')")  # the same fight: no second one
    assert s.wait(0.5)["events"] == []
    fake.server.execute("MOCK.combat = false; MOCK.fire('CombatEnded', 'combat-1')")
    assert [e["kind"] for e in s.wait(0.5)["events"]] == ["combat_ended"]
    fake.server.execute("MOCK.combat = true; MOCK.fire('CombatStarted', 'combat-1')")  # the next fight
    assert [e["kind"] for e in s.wait(0.5)["events"]] == ["combat_started"]


def test_the_end_of_its_fight_always_wakes_wait(env):
    fake, s = env
    s.set_agent("Shadowheart")
    s.wait(0.5)  # the backlog
    fake.server.execute("MOCK.combat = true; MOCK.fire('CombatStarted', 'combat-1')")
    assert [e["kind"] for e in s.wait(0.5)["events"]] == ["combat_started"]
    # CombatEnded comes while IsInCombat is still set: the poll after it tells
    fake.server.execute("MOCK.fire('CombatEnded', 'combat-other')")
    assert s.wait(0.5)["events"] == []  # another fight: hers goes on
    fake.server.execute("MOCK.fire('CombatEnded', 'combat-1'); MOCK.combat = false")
    assert [e["kind"] for e in s.wait(0.5)["events"]] == ["combat_ended"]
    assert s.wait(0.5)["events"] == []  # once
    # she leaves a fight that goes on without her, with no CombatEnded at all
    fake.server.execute("MOCK.combat = true; MOCK.fire('CombatStarted', 'combat-1')")
    assert [e["kind"] for e in s.wait(0.5)["events"]] == ["combat_started"]
    fake.server.execute(f"MOCK.fighters = {{ ['{TAV}'] = true, ['{GOB}'] = true }}")
    assert [e["kind"] for e in s.wait(0.5)["events"]] == ["combat_ended"]
    assert s.wait(0.5)["events"] == []


def test_an_enemy_that_hides_is_still_in_the_fight(env):
    fake, s = env
    _fight(fake, s)
    fake.server.execute(f"MOCK.turn = '{SH}'; MOCK.fire('TurnStarted', '{SH}'); MOCK.fire('TurnEnded', '{SH}')")
    fake.server.execute(f"MOCK.invisible = {{ ['{GOB}'] = true }}")
    fake.server.execute(f"MOCK.turn = '{SH}'; MOCK.fire('TurnStarted', '{SH}')")
    c = s.combat()
    assert not any("Goblin" in line for line in c["order"])  # what one cannot see is not listed
    assert "Goblin: hidden (still in the fight)" in c["changes_since_your_last_turn"]


def test_a_healing_shout_lists_only_the_party_around(env):
    fake, s = env
    _fight(fake, s)
    fake.server.execute(f"MOCK.turn = '{SH}'; MOCK.pos['{GOB}'] = {{ 5, 0, 0 }}")
    around = s.cast("Shout_HealingWord_Mass")["result"]["around_you"]
    assert around == ["Tav (party)"]
    fake.server.execute("MOCK.res = {}")
    assert "Goblin (enemy)" in s.cast("Shout_RadianceOfTheDawn")["result"]["around_you"]  # it burns them


THIEVES_TOOLS = "TOOL_GEN_ThievesTools_A_Open_A_e32a200c-5b63-414d-ae57-00e7b38f125b"


def test_locks_are_left_to_the_human(env):
    # The game starts lockpicking only from the human's screen: the agent is told to ask them.
    fake, s = env
    s.set_agent("Shadowheart")
    chest = _world_object(fake, "Old Chest", (1, 0, 1))
    fake.server.execute(f'MOCK.locked = {{ ["{chest}"] = true }}')
    rows = {i["name"]: i["id"] for i in s._look_rows()["items"]}
    err = s.use(rows["Old Chest"])["error"]
    assert "Old Chest is locked" in err and "Lockpick" in err
    assert "nobody in the party has thieves' tools" in err and "crime" not in err
    fake.server.execute(
        f'local was = Osi.TemplateIsInInventory\n'
        f'Osi.TemplateIsInInventory = function(t, ch) if t == "{THIEVES_TOOLS}" then return 2 end '
        f'return was(t, ch) end\n'
        f'MOCK.owners["{chest}"] = MOCK.npc')
    err = s.container(rows["Old Chest"])["error"]
    assert "has 4 thieves' tools" in err  # two each for Shadowheart and Tav
    assert "belongs to Arron" in err and "crime" in err


def test_armed_traps_are_left_to_the_human(env):
    fake, s = env
    s.set_agent("Shadowheart")
    trap = _world_object(fake, "Spike Trap", (1, 0, 0))
    fake.server.execute(f'MOCK.traps = {{ ["{trap}"] = {{ discovered = true, armed = true }} }}')
    rows = {i["name"]: i["id"] for i in s._look_rows()["items"]}
    err = s.use(rows["Spike Trap"])["error"]
    assert "armed trap" in err and "Disarm" in err and "3 m away" in err
    assert "nobody in the party has trap disarm toolkits" in err
    fake.server.execute(f'MOCK.traps["{trap}"].armed = false')  # disarmed: an object like any other
    assert s.use(rows["Spike Trap"])["status"] == "done"



def test_a_summon_is_cast_without_stepping_about(env):
    fake, s = env
    _fight(fake, s)
    fake.server.execute(f"MOCK.turn = '{SH}'")
    gob = next(c["id"] for c in s._look_rows()["characters"] if c["name"] == "Goblin")
    assert s.cast("Target_FlamingSphere", target=gob)["status"] == "done"
    assert fake.server.eval("MOCK.castOptions[#MOCK.castOptions].NoMovement") is True


def test_a_cast_cut_off_by_a_blow_says_so_and_can_be_tried_again(env):
    fake, s = env
    _fight(fake, s)
    fake.server.execute(f"MOCK.turn = '{SH}'; MOCK.opportunist = '{GOB}'")
    r = s.cast("Projectile_Jump", x=5, y=0, z=0)
    assert r["status"] == "failed" and "struck you" in r["error"] and "try again" in r["error"], r
    r = s.cast("Projectile_Jump", x=5, y=0, z=0)
    assert r["status"] == "done", r
    # a jump is movement: not cast with NoMovement as summons are
    assert fake.server.eval("MOCK.castOptions[#MOCK.castOptions].NoMovement") is None


def test_leaving_an_enemys_reach_is_refused_first(env):
    fake, s = env
    _fight(fake, s)
    fake.server.execute(f"MOCK.turn = '{SH}'; MOCK.pos['{GOB}'] = {{ 3, 0, 0 }}")
    r = s.move(direction="W", meters=6)
    assert "opportunity attack" in str(r) and "Goblin" in str(r), r
    r = s.cast("Projectile_Jump", x=-2, y=0, z=0)
    assert "opportunity attack" in str(r), r
    n = fake.server.eval("#MOCK.casts")
    # refused once: the same call again takes the blow and goes
    assert s.cast("Projectile_Jump", x=-2, y=0, z=0)["status"] == "done"
    assert fake.server.eval("#MOCK.casts") == n + 1
    # a target out of range: the game would walk her up, out of the goblin's reach
    fake.server.execute(f"MOCK.pos['{SH}'] = {{ 2, 0, 0 }}")
    r = s.cast("Projectile_GuidingBolt", x=-30, y=0, z=0)
    assert "opportunity attack" in str(r) and "walk you up" in str(r) and "same call again" in str(r), r
    # even_if_provoking goes at once
    assert "opportunity" not in str(s.move(direction="S", meters=6, even_if_provoking=True))
    # out of the fight nothing is checked
    fake.server.execute(f"MOCK.combat = false; MOCK.pos['{SH}'] = {{ 2, 0, 0 }}")
    assert "opportunity" not in str(s.move(direction="W", meters=6))


def test_a_jump_goes_straight_there_within_reach(env):
    fake, s = env
    _fight(fake, s)
    fake.server.execute(f"MOCK.turn = '{SH}'")
    # Strength 8: the plain 4.5 m
    r = s.cast("Projectile_Jump", x=12, y=0, z=0)
    assert "you can jump 4.5 m" in str(r), r
    r = s.cast("Projectile_Jump", x=5, y=0, z=0)
    assert r["status"] == "done", r
    # the cast checks stay off, or the game walks her about before jumping
    assert fake.server.eval("MOCK.castOptions[#MOCK.castOptions].IgnoreCastChecks") is True
    assert "moved_m" not in r["result"] and "why_moved" not in r["result"], r


# ---- Local protagonist takeover -------------------------------------------------------------

def _grant_protagonist(fake, s):
    s.game.refresh_control(6000)
    s.game.call("local_inbox", context="client")
    _type(fake, "/protagonist on")
    return s.game.refresh_control(6000)


def _task_authority(monkeypatch, game, state):
    authority = {k: state[k] for k in ("epoch", "revision", "ticket")}
    monkeypatch.setattr(game, "_local_guard", lambda: authority, raising=False)
    return authority


def test_protagonist_consent_and_multiplayer_reservations(env, monkeypatch):
    from bg3coop.game import GameError

    fake, s = env
    g = s.game
    assert "error" in s.set_agent("Tav", human="Shadowheart")
    assert "error" in s.set_agent("Tav")
    assert s.set_agent("Shadowheart")["name"] == "Shadowheart"
    g.refresh_control(6000)
    fake._client_net("BG3COOP_LocalControl", g.connection_id + ":on", peer=0x10000)
    fake._client_net("BG3COOP_LocalControl", g.connection_id + ":on", peer=0)
    assert "ticket" not in g.refresh_control(6000)
    with pytest.raises(GameError, match="unknown op"):
        g.call("controlHeartbeat", {"ticket": "forged"})
    fake.server.execute("MOCK.selected = MOCK.sh")  # stable host avatar, even with a companion selected
    g.call("local_inbox", context="client")
    fake.client.execute("local w = MOCK_C.panel(); w.Children[4].Children[3].Children[4].OnClick()")
    state = g.refresh_control(6000)
    assert state["ticket"] and state["id"] == fake.world.host
    assert not fake.world.detached[SH]
    assert g.call("local_inbox", context="client")["messages"] == []
    assert g.call("status")["control_mode"] == "protagonist"
    assert "error" in s.set_agent("Tav", human="Shadowheart")
    with pytest.raises(GameError, match="Free Explore"):
        g.call("move", {"dir": "E"})
    _task_authority(monkeypatch, g, state)
    with pytest.raises(GameError, match="regroup"):
        g.call("regroup")
    with pytest.raises(GameError, match="follow"):
        g.call("move", {"to_human": True})
    assert not fake.world.detached[fake.world.host[-36:]]
    monkeypatch.setattr(g, "_local_guard", None)
    _type(fake, "/protagonist off")
    fake.server.execute(f"MOCK.reserved = {{ ['{SH}'] = 65537 }}; MOCK.selected = MOCK.host")
    assert "error" in s.set_agent("Shadowheart")
    fake.server.execute(f"MOCK.reserved['{SH}'] = 1; MOCK.avatars = {{ {{ MOCK.host }}, {{ MOCK.sh }} }}")
    assert "error" in s.set_agent("Shadowheart")
    fake.server.execute("MOCK.avatars = nil")
    assert s.set_agent("Shadowheart")["name"] == "Shadowheart"


@pytest.mark.parametrize("interrupt", ["off", "pause", "lease", "connection", "load", "client_load"])
def test_protagonist_jobs_and_old_tickets_are_cancelled(env, monkeypatch, interrupt):
    from bg3coop.game import GameError

    fake, s = env
    g = s.game
    state = _grant_protagonist(fake, s)
    _task_authority(monkeypatch, g, state)
    started = g.call("move", {"pos": [12, 0, 2]})
    if interrupt in {"off", "pause"}:
        _type(fake, "/protagonist off" if interrupt == "off" else "/pause")
    elif interrupt == "lease":
        fake.server.execute("BG3COOP.controlUntil = 0")
        fake.server.execute("for _, fn in ipairs(MOCK.subs.Tick) do fn() end")
    elif interrupt == "connection":
        g.close()
    elif interrupt == "load":
        fake.server.execute("for _, fn in ipairs(MOCK.subs.SessionLoading) do fn() end")
    else:
        fake.client.execute("BG3COOP_C = nil")

    # Player actions above take effect before the daemon polls, except that a
    # disconnected debugger is discovered at the next handshake or lease expiry.
    if interrupt in {"off", "pause", "lease", "load"}:
        with pytest.raises(GameError, match="changed"):
            g.call("job", {"id": started["job"]})
    monkeypatch.setattr(g, "_local_guard", None)
    state = g.refresh_control(6000)
    assert bool(state.get("ticket")) == (interrupt == "pause")
    if interrupt == "pause":
        _task_authority(monkeypatch, g, state)
    assert g.call("job", {"id": started["job"]})["status"] == "cancelled"
    assert fake.world.purged == fake.world.host[-36:]


def _protagonist_dialogue(fake, owner):
    _dialogue_on_screen(fake)
    fake.server.execute("MOCK.dialog[MOCK.sh:sub(-36)] = nil; MOCK.dialog[MOCK.host:sub(-36)] = 9")
    fake.client.execute(f'''
        local d, dc = MOCK_C.dlg, MOCK_C.dlgDC
        d.ShowAnswers = true
        d.AvailableSpeakers = {{{{ EntityUUID = "{owner}" }}}}
        d.Answers = {{{{ BodyText = "Where are we?", Enabled = true }}, {{ BodyText = "[Attack] Charge.", Enabled = true }}}}
        dc.CurrentPlayer = {{ SelectedCharacter = {{ PlayerCharacterProperties = {{ ActiveDialogue = d }} }} }}
        dc.SelectAnswerCommand.CanExecute = function() return true end
    ''')


def test_protagonist_choice_confirms_risk_and_rechecks_visible_answer(env, monkeypatch):
    fake, s = env
    state = _grant_protagonist(fake, s)
    _task_authority(monkeypatch, s.game, state)
    _protagonist_dialogue(fake, SH)
    assert not s.dialogue()["yours"]
    assert "error" in s.choose(1, expect="Where are we?", routine=True)
    assert fake.client.eval("MOCK_C.answered") is None
    _protagonist_dialogue(fake, fake.world.host[-36:])
    assert s.dialogue()["yours"]
    assert s.choose(1, expect="Where are we?", routine=True)["chose"] == "Where are we?"
    asked = []
    monkeypatch.setattr(s.chat, "ask", lambda q, _: asked.append(q) or {"answer": "no"})
    assert s.choose(2, expect="[Attack] Charge.", routine=True)["declined"]
    assert "[Attack] Charge." in asked[0]
    assert fake.client.eval("MOCK_C.answered") == "Where are we?"

    def reply_after_change(question, timeout):
        fake.client.execute('MOCK_C.dlg.Answers[2].BodyText = "Leave."')
        return {"answer": "yes"}

    monkeypatch.setattr(s.chat, "ask", reply_after_change)
    assert "error" in s.choose(2, expect="[Attack] Charge.")
    assert fake.client.eval("MOCK_C.answered") == "Where are we?"
    monkeypatch.setattr(s.chat, "ask", lambda *_: {"answer": "yes"})
    assert s.choose(2, expect="Leave.")["chose"] == "Leave."


def test_protagonist_roll_matches_native_window_actor_and_instance(env, monkeypatch):
    fake, s = env
    state = _grant_protagonist(fake, s)
    _task_authority(monkeypatch, s.game, state)
    _check_on_screen(fake, s, [9], setup_companion=False)
    fake.server.execute('''
        local me = Ext.Entity.Get(MOCK.host)
        MOCK.dialog[MOCK.host:sub(-36)] = 9
        Ext.Entity.Get = (function(old)
            return function(id) if id == MOCK.host:sub(-36) then return me end return old(id) end
        end)(Ext.Entity.Get)
        MOCK.requestedRoll = { DialogId = 10, Roller = me, RollUuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" }
        Ext.System.ServerRoll = { EntityToRollEntity = { [me] = { RequestedRoll = MOCK.requestedRoll } } }
    ''')
    fake.client.execute(f'''
        local dc, roll = MOCK_C.root:Find().Children[1].DataContext, MOCK_C.rollWidget.DataContext
        local d = dc.Data.Dialogues[1]
        d.AvailableSpeakers = {{{{ EntityUUID = "{fake.world.host[-36:]}" }}}}
        dc.CurrentPlayer = {{ SelectedCharacter = {{ PlayerCharacterProperties = {{ ActiveDialogue = d }} }} }}
        roll.Roll.RollUuid = "aaaaaaaa-bbbb-cccc-dddd-ffffffffffff"
        roll.UserTriggeredNextPhaseCommand.CanExecute = function() return true end
        roll.ContinueCommand.CanExecute = function() return true end
    ''')
    assert "error" in s.roll()
    fake.server.execute("MOCK.requestedRoll.DialogId = 9")
    assert "error" in s.roll()
    assert fake.client.eval("#MOCK_C.throws") == 1
    fake.client.execute('MOCK_C.rollWidget.DataContext.Roll.RollUuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"')
    assert s.dialogue()["roll"]["state"] == "waiting"
    assert s.roll()["success"] is True
    assert fake.client.eval("MOCK_C.rollWidget.Visibility") == "Hidden"


def test_player_off_blocks_already_deferred_choice(env, monkeypatch):
    fake, s = env
    state = _grant_protagonist(fake, s)
    _task_authority(monkeypatch, s.game, state)
    _protagonist_dialogue(fake, fake.world.host[-36:])
    fake.client.execute('''
        local d = MOCK_C.dlg
        local args = { owner = d.AvailableSpeakers[1].EntityUUID, instance = 9, n = 1,
            expect = "Where are we?", snapshot = BG3COOP_C.dialogueSnapshot(d) }
        MOCK_C.holdUI = true
        BG3COOP_C.queueControlUI("pending", BG3COOP_C.controlTicket, "choose", args)
    ''')
    _type(fake, "/protagonist off")
    fake.client.execute("MOCK_C.deferred()")
    assert fake.client.eval("MOCK_C.answered") is None


def test_panel_grants_solo_avatar_without_network_delivery(env):
    fake, s = env
    g = s.game
    # SE's local network sender can differ from the host character's reserved user.
    # The game may also lack a party row for a lone host avatar.
    fake.server.execute("""
        MOCK.reserved = { [MOCK.host:sub(-36)] = 131073 }
        Osi.DB_PartyMembers.Get = function() return {} end
        Ext.RegisterNetListener = nil
    """)
    fake.client.execute('Ext.ClientNet.PostMessageToServer = function() error("network unavailable") end')
    before = g.refresh_control(6000)
    assert not before.get("id") and not before.get("ticket")
    g.call("local_inbox", context="client")
    fake.client.execute("local w = MOCK_C.panel(); w.Children[4].Children[3].Children[4].OnClick(); MOCK_C.fire('Tick')")
    assert "等待授权确认" in fake.client.eval("BG3COOP_C.panel.mode.Text")
    assert g.call("local_inbox", context="client")["messages"] == []
    state = g.refresh_control(6000)
    assert state["ticket"] and state["id"] == fake.world.host
    assert g.call("status")["id"] == fake.world.host
    assert fake.server.eval("#MOCK.subs.Tick") > 0
    fake.client.execute("MOCK_C.fire('Tick')")
    assert "主角接管已授权" in fake.client.eval("BG3COOP_C.panel.mode.Text")
    _type(fake, "/protagonist off")
    assert not g.refresh_control(6000).get("ticket")


def test_consent_failure_reports_avatar_lookup_reason(env):
    fake, s = env
    g = s.game
    fake.server.execute("MOCK.avatars = {}")
    state = _grant_protagonist(fake, s)
    assert not state.get("id") and not state.get("ticket")
    assert "没有可核实归属" in state["consent"]["error"]
    fake.client.execute("MOCK_C.fire('Tick')")
    assert "授权失败" in fake.client.eval("BG3COOP_C.panel.mode.Text")
    assert fake.client.eval("BG3COOP_C.panel.modeDetail.Text") == state["consent"]["error"]
    assert "consent" not in g.refresh_control(6000)


def test_unanswered_consent_does_not_replay_on_reconnect(env):
    fake, s = env
    g = s.game
    g.refresh_control(6000)
    _type(fake, "/protagonist on")
    g.close()
    state = g.refresh_control(6000)
    assert not state.get("ticket")
    assert "连接已变更" in state["consent"]["error"]
    assert not g.refresh_control(6000).get("ticket")
