-- BG3COOP server side: injected into the game's server Lua state over the
-- Script Extender debugger. The bridge calls BG3COOP.rpc(json) and gets a JSON
-- string back. Everything here acts for ONE party member, the agent's
-- character; the human keeps the rest of the party and the UI.
--
-- The Lua state is wiped on every save load, so the bridge re-sends this file
-- whenever BG3COOP is missing. Keep state that must survive in the bridge.
-- Re-sending it into a live state is also safe (functions are replaced, state
-- tables kept, listeners dispatch through C.on).

BG3COOP = BG3COOP or {}
local C = BG3COOP
C.VERSION = 95

local function now() return Ext.Utils.MonotonicTime() end

C.events = C.events or {}
C.seq = C.seq or 0
-- Changes whenever the Lua state is fresh, so the bridge can tell that event
-- numbering restarted.
C.epoch = C.epoch or (tostring(math.floor(now())) .. "-" .. tostring(math.random(1, 1000000)))
C.jobs = C.jobs or {}
C.nextJob = C.nextJob or 0
C.ops = {}
C.on = {}
C.turn = C.turn or {}
C.dialogs = C.dialogs or {}        -- [instance] = { yours = bool } for dialogues the agent is in
C.origReactions = C.origReactions  -- reaction modes before set_agent changed them

local SIGHT = 40.0       -- metres: how far the agent's character "notices" things (about the camera's reach)
local TALK_RANGE = 3.0
local USE_RANGE = 2.5
local CLOSE_ENOUGH = USE_RANGE + 0.5 -- a walk that stalls this close to its goal counts as arrived

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function truthy(v) return v == 1 or v == true end

local function osi(fn, ...)
    if fn == nil then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
    return nil
end

-- "S_Player_ShadowHeart_3ed74f06-..." and "3ed74f06-..." name the same thing.
local function bare(id)
    if id == nil then return nil end
    id = tostring(id)
    local g = id:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$")
    return g or id
end
C.bare = bare

local function same(a, b) return a ~= nil and b ~= nil and bare(a) == bare(b) end

local function loca(handle)
    if handle == nil or handle == "" then return nil end
    local h = tostring(handle):gsub(";%d+$", "")
    local ok, s = pcall(Ext.Loca.GetTranslatedString, h)
    if ok and type(s) == "string" then
        s = s:gsub("^%s+", ""):gsub("%s+$", "")
        if s ~= "" and not s:find("^%%%%%% EMPTY") then return s end
    end
    return nil
end

-- A character without a display name (some spawned ones) goes by its
-- template's name; unnamed items stay "?" so look can leave them out.
function C.name(uuid)
    local n = loca(osi(Osi.GetDisplayName, uuid))
    if n then return n end
    if truthy(osi(Osi.IsCharacter, uuid)) then
        local t = osi(Osi.GetTemplate, uuid)
        t = t and tostring(t):gsub("_%x+%-%x+%-%x+%-%x+%-%x+$", "")
        if t and t ~= "" then return t end
    end
    return "?"
end

local function r1(x) return math.floor(x * 10 + 0.5) / 10 end

function C.pos(uuid)
    local x, y, z = osi(Osi.GetPosition, uuid)
    if x == nil then return nil end
    return { r1(x), r1(y), r1(z) }
end

local function dist(a, b)
    if not (a and b) then return nil end
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- 8-point compass, +X east, +Z north.
local DIRS = { "E", "NE", "N", "NW", "W", "SW", "S", "SE" }
local function dir(from, to)
    local a = math.atan(to[3] - from[3], to[1] - from[1])
    local i = math.floor((a / (math.pi / 4)) + 0.5) % 8
    return DIRS[i + 1]
end

local function entity(uuid)
    local ok, e = pcall(Ext.Entity.Get, bare(uuid))
    if ok then return e end
    return nil
end

local function comp(e, name)
    if not e then return nil end
    local ok, v = pcall(function() return e[name] end)
    if ok then return v end
    return nil
end

local function push(kind, data)
    C.seq = C.seq + 1
    C.events[#C.events + 1] = { seq = C.seq, t = now(), kind = kind, data = data }
    while #C.events > 200 do table.remove(C.events, 1) end
end
C.push = push

local function party()
    local out = {}
    local ok, rows = pcall(function() return Osi.DB_PartyMembers:Get(nil) end)
    if ok and rows then
        for _, row in ipairs(rows) do out[#out + 1] = row[1] end
    end
    return out
end

local function isParty(uuid)
    for _, p in ipairs(party()) do
        if same(p, uuid) then return true end
    end
    return false
end

-- Who acts: the agent's character, or for one call (args.as) one of its summons.
local function agent()
    if not C.agent then error("no agent character chosen yet: call set_agent first") end
    return C.actor or C.agent
end

-- The human's own character. Fixed at set_agent time: the character the human
-- has selected changes all the time (and follows the turn in combat).
local function human()
    if C.human then return C.human end
    local ok, rows = pcall(function() return Osi.DB_Avatars:Get(nil) end)
    if ok and rows then
        for _, row in ipairs(rows) do
            if not same(row[1], C.agent) and isParty(row[1]) then return row[1] end
        end
    end
    local host = osi(Osi.GetHostCharacter)
    if not same(host, C.agent) then return host end
    return nil
end

-- Avatar and reservation checks are independent of the optional set_agent human label.
function C.avatars()
    local ok, rows = pcall(function() return Osi.DB_Avatars:Get(nil) end)
    return ok and rows or nil
end

function C.hostAvatar()
    local host = osi(Osi.GetHostCharacter)
    if not host or not entity(host) then return nil, "游戏没有返回本机主持者角色" end
    local user = osi(Osi.GetReservedUserID, host)
    if type(user) ~= "number" or user < 0 then return nil, "无法核实本机主持者的角色归属" end
    local avatars = C.avatars()
    if not avatars then return nil, "游戏没有返回玩家化身列表（DB_Avatars）" end
    local avatar
    for _, row in ipairs(avatars) do
        local id = row[1]
        if (same(id, host) or isParty(id)) and entity(id) and osi(Osi.GetReservedUserID, id) == user then
            if avatar and not same(avatar, id) then return nil, "本机主持者有多个候选主角" end
            avatar = id
        end
    end
    if not avatar then return nil, "当前存档没有可核实归属本机主持者的主角" end
    return avatar
end

function C.companionAllowed(id)
    local avatars = C.avatars()
    if not avatars then return false end
    for _, row in ipairs(avatars) do
        if same(id, row[1]) then return false end
    end
    local host = osi(Osi.GetHostCharacter)
    local owner = osi(Osi.GetReservedUserID, id)
    local localUser = host and osi(Osi.GetReservedUserID, host)
    return type(owner) == "number" and type(localUser) == "number" and localUser >= 0
        and (owner == -65536 or owner == localUser)
end

local function hp(uuid)
    local h = comp(entity(uuid), "Health")
    if h then
        local ok, a, b = pcall(function() return h.Hp, h.MaxHp end)
        if ok then return a, b end
    end
    return osi(Osi.GetHitpoints, uuid), osi(Osi.GetMaxHitpoints, uuid)
end

local function isDead(uuid) return truthy(osi(Osi.IsDead, uuid)) end
local function isDowned(uuid) return truthy(osi(Osi.HasActiveStatus, uuid, "DOWNED")) end

local function inCombat(uuid) return truthy(osi(Osi.IsInCombat, uuid)) end
-- The human's turn-based toggle outside combat: movement comes per turn, as in a fight, and
-- a new turn starts when everyone in it has ended theirs.
local function turnBasedMode(uuid) return not inCombat(uuid) and truthy(osi(Osi.IsInForceTurnBasedMode, uuid)) end

-- Dialogue instance the character is in, or nil. (Osi.IsInDialog does not
-- exist in this game; DialogState.DialogId keeps its value after the end.)
-- Barks (a line shouted in combat, ambient chatter) are automated dialogues:
-- the game lists them in DB_AutomatedDialog. They are not conversations.
local function automated(inst)
    local ok, rows = pcall(function() return Osi.DB_AutomatedDialog:Get(inst) end)
    return ok and rows ~= nil and #rows > 0
end

local function dialogOf(uuid)
    for i = 1, 2 do
        local _, inst = osi(Osi.SpeakerGetDialog, uuid, i)
        inst = tonumber(inst)
        if inst and not automated(inst) then return inst end
    end
    return nil
end
local function inDialog(uuid) return dialogOf(uuid) ~= nil end

local function dialogHas(inst, uuid)
    local ok, rows = pcall(function() return Osi.DB_DialogPlayers:Get(inst, nil, nil) end)
    if ok and rows then
        for _, r in ipairs(rows) do if same(r[2], uuid) then return true end end
    end
    return dialogOf(uuid) == inst
end

-- Remember a dialogue the agent is in and whose it is. A dialogue counts as
-- the agent's when the agent started it, or when the human is not in it. One
-- that begins within AGENT_ACT_MS of the agent using an object or casting (a
-- bench that starts a vision, a lever that makes someone speak) is the agent's too.
local AGENT_ACT_MS = 5000
local function noteDialog(inst, startedByAgent)
    if not inst or automated(inst) then return nil end
    startedByAgent = startedByAgent or C.starting -- events fire inside the start call
    local d = C.dialogs[inst]
    if not d then
        local h = human()
        local justActed = C.actedAt and now() - C.actedAt < AGENT_ACT_MS
        if C.protagonist then
            -- The client must still prove the visible answerer is the granted avatar.
            d = { yours = C.agent ~= nil and dialogOf(C.agent) == inst }
        else
            d = { yours = startedByAgent or justActed or not (h and dialogHas(inst, h)) }
        end
        C.dialogs[inst] = d
        push("dialogue_started", { yours = d.yours })
    elseif startedByAgent and not C.protagonist then
        d.yours = true
    end
    return d
end

-- Is it this character's turn right now (turn-based combat)? Characters next to
-- each other in initiative share one turn, so IsActiveCombatTurn stays true for
-- the agent until the whole group is done; after end_turn we remember it.
local function turnState(uuid)
    local tb = comp(entity(uuid), "TurnBased")
    local active
    if tb then
        local ok, v = pcall(function() return tb.IsActiveCombatTurn end)
        if ok then active = v end
    end
    if active == nil then active = same(C.turn.current, uuid) end
    -- who ended their turn (the agent and each of its summons on their own)
    if type(C.turn.ended) ~= "table" then C.turn.ended = {} end
    if active ~= true then
        C.turn.ended[bare(uuid)] = nil
        return false, false
    end
    if C.turn.ended[bare(uuid)] then return false, true end
    return true, false
end
local function myTurn(uuid) return (turnState(uuid)) end

-- Action resources by name: ActionPoint, BonusActionPoint, Movement,
-- ReactionActionPoint, SpellSlot (per level), ...
local resNames = {}
local function resourceName(guid)
    if resNames[guid] then return resNames[guid] end
    local ok, d = pcall(Ext.StaticData.Get, guid, "ActionResource")
    local n = ok and d and d.Name or tostring(guid)
    resNames[guid] = n
    return n
end

-- Calls fn(name, entry) for every resource entry the character has.
local function eachResource(uuid, fn)
    local ar = comp(entity(uuid), "ActionResources")
    if not ar then return end
    pcall(function()
        for guid, list in pairs(ar.Resources) do
            local n = resourceName(guid)
            for _, entry in ipairs(list) do fn(n, entry) end
        end
    end)
end

local LEVELED = { SpellSlot = true, WarlockSpellSlot = true }

function C.resources(uuid)
    local out = {}
    eachResource(uuid, function(n, entry)
        if entry.MaxAmount and entry.MaxAmount > 0 then
            local key = LEVELED[n] and (n .. entry.Level) or n
            out[key] = { r1(entry.Amount), r1(entry.MaxAmount) }
        end
    end)
    return out
end

local function statusIds(uuid)
    local out = {}
    local sc = comp(entity(uuid), "StatusContainer")
    if not sc then return out end
    pcall(function()
        for _, name in pairs(sc.Statuses) do out[#out + 1] = name end
    end)
    return out
end

-- Whether a status stat carries one of the StatusPropertyFlags.
function C.statusFlag(st, flag)
    local ok, f = pcall(function() return st.StatusPropertyFlags end)
    if not ok or f == nil then return false end
    if type(f) == "table" then
        for _, x in ipairs(f) do if x == flag then return true end end
        return false
    end
    return tostring(f):find(flag, 1, true) ~= nil
end

-- Statuses that come and go as turns pass and say nothing about the fight: ones kept out of the
-- combat log (巨武器大师：附赠攻击) and ones that only unlock an action for a turn (武艺：徒手打击).
function C.fleeting(st)
    if C.statusFlag(st, "DisableCombatlog") then return true end
    local ok, b = pcall(function() return st.Boosts end)
    b = ok and tostring(b or "") or ""
    return b ~= "" and b:gsub("UnlockSpell%b()", ""):gsub("[;%s]", "") == ""
end

-- Display names of status ids, skipping technical ones: those without a name and those the game
-- keeps off the portraits (难度：硬核, 移位 from a tadpole power). `fleeting` ones too when asked.
-- Each name once: the same status from two sources (难度：硬核 twice on Orin) took two of the
-- few places and pushed 不可撼动 off the list.
local function statusNames(ids, max, noFleeting, with)
    local out, seen = {}, {}
    for _, name in ipairs(ids) do
        local ok, st = pcall(Ext.Stats.Get, name)
        local dn = ok and st and loca(st.DisplayName)
        if dn and not seen[dn] and #out < (max or 12) and not dn:find("^%%%%%%")
            and not C.statusFlag(st, "DisablePortraitIndicator") and not (noFleeting and C.fleeting(st)) then
            seen[dn] = true
            out[#out + 1] = dn
            if with then with(dn, st) end
        end
    end
    return out
end

local function statuses(uuid) return statusNames(statusIds(uuid)) end

------------------------------------------------------------------------
-- Costs: "ActionPoint:1;SpellSlotsGroup:1:1:2" -> list of { name, amount, level }
------------------------------------------------------------------------

local TURN_RESOURCES = { ActionPoint = true, BonusActionPoint = true, ReactionActionPoint = true, Movement = true }

local function parseCosts(str)
    local out = {}
    for part in tostring(str or ""):gmatch("[^;]+") do
        local fields = {}
        for f in part:gmatch("[^:]+") do fields[#fields + 1] = f:match("^%s*(.-)%s*$") end
        local name, amount = fields[1], tonumber(fields[2])
        if name == "SpellSlotsGroup" then
            out[#out + 1] = { name = "SpellSlot", amount = amount or 1, level = tonumber(fields[4]) or 1 }
        elseif name and amount then
            out[#out + 1] = { name = name, amount = amount }
        end
    end
    return out
end

-- The resource entry that pays a cost, or nil. Spell slots fall back to warlock slots.
local function payer(uuid, cost)
    local found
    local function want(n, entry)
        if found or not entry.MaxAmount or entry.MaxAmount <= 0 then return end
        if cost.level then
            if (n == "SpellSlot" or n == "WarlockSpellSlot") and entry.Level == cost.level and entry.Amount >= cost.amount then
                found = entry
            end
        elseif n == cost.name then
            found = entry
        end
    end
    eachResource(uuid, want)
    return found
end

local SHORT = { ActionPoint = "action", BonusActionPoint = "bonus action", ReactionActionPoint = "reaction",
    Movement = "movement" }

-- Why the costs cannot be paid now, or nil. Outside combat the per-turn
-- resources refill by themselves and are not checked.
local function cannotPay(uuid, costs, combat)
    for _, c in ipairs(costs) do
        if combat or not TURN_RESOURCES[c.name] then
            local e = payer(uuid, c)
            if c.level then
                if not e then return "no level " .. c.level .. " spell slot left" end
            elseif not e or e.Amount < c.amount - 0.001 then
                return "not enough " .. (SHORT[c.name] or c.name) .. (combat and TURN_RESOURCES[c.name] and " left this turn" or "")
            end
        end
    end
    return nil
end

-- Osi.UseSpell casts without spending anything, so the bridge pays the costs
-- itself once the game reports the cast.
local function pay(uuid, costs, combat)
    local e = entity(uuid)
    for _, c in ipairs(costs) do
        if combat or not TURN_RESOURCES[c.name] then
            local entry = payer(uuid, c)
            if entry then entry.Amount = math.max(0, entry.Amount - c.amount) end
        end
    end
    pcall(function() e:Replicate("ActionResources") end)
end

------------------------------------------------------------------------
-- Perception: only what the agent's own character could notice
------------------------------------------------------------------------

-- Rooms. The human's screen shows what is inside a room unless the room is shut: every door and
-- window on its walls closed, and neither the human nor the agent inside. Indoors or out, near or
-- far does not matter (tested by the user). The game marks rooms with room triggers (boxes or
-- prisms); which doors and windows belong to a room it keeps in a component the extender cannot
-- read, so doors and windows within Rm.TOUCH m of a room's walls count as its openings.
local Rm = { TOUCH = 1.5, INSIDE = 0.3, NEAR = 60, KEEP_MS = 1500, OPENINGS_MS = 60000,
    WINDOW_WORDS = { "window", "shutter", "窗", "百叶" } }

-- p in the room's own frame (its rotation undone).
function Rm.localPos(e, p)
    local t = e.Transform.Transform
    local c, q = t.Translate, t.RotationQuat
    local v = { p[1] - c[1], p[2] - c[2], p[3] - c[3] }
    local qx, qy, qz, qw = -q[1], -q[2], -q[3], q[4]
    local cx, cy, cz = qy * v[3] - qz * v[2], qz * v[1] - qx * v[3], qx * v[2] - qy * v[1]
    local dx, dy, dz = qy * cz - qz * cy, qz * cx - qx * cz, qx * cy - qy * cx
    return { v[1] + 2 * (qw * cx + dx), v[2] + 2 * (qw * cy + dy), v[3] + 2 * (qw * cz + dz) }
end

-- How far inside the room p is, in metres (negative: outside).
function Rm.depth(e, p)
    local l = Rm.localPos(e, p)
    local ph = e.TriggerArea.Physics
    local ok, ext = pcall(function() return ph.Extents end)
    if ok and ext then
        return math.min(ext[1] - math.abs(l[1]), ext[2] - math.abs(l[2]), ext[3] - math.abs(l[3]))
    end
    local okp, pts = pcall(function() return ph.Points end)
    if not okp or not pts or #pts < 3 then return -1e9 end
    local inside, edge, n = false, 1e9, #pts
    for i = 1, n do
        local a, b = pts[i], pts[i % n + 1]
        if (a[2] > l[3]) ~= (b[2] > l[3]) and l[1] < (b[1] - a[1]) * (l[3] - a[2]) / (b[2] - a[2]) + a[1] then
            inside = not inside
        end
        local ex, ez = b[1] - a[1], b[2] - a[2]
        local len = ex * ex + ez * ez
        local k = len > 0 and math.max(0, math.min(1, ((l[1] - a[1]) * ex + (l[3] - a[2]) * ez) / len)) or 0
        local px, pz = a[1] + ex * k - l[1], a[2] + ez * k - l[3]
        edge = math.min(edge, math.sqrt(px * px + pz * pz))
    end
    return math.min(inside and edge or -edge, l[2], (tonumber(ph.Height) or 0) - l[2])
end

-- Doors and windows around `at` (they do not move), kept a minute.
function Rm.openings(at)
    local key = ("%d,%d"):format(math.floor(at[1] / 20), math.floor(at[3] / 20))
    local c = C.roomOpenings
    if c and c.key == key and now() - c.at < Rm.OPENINGS_MS then return c.list end
    local list = {}
    local ok, all = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerItem")
    for _, e in ipairs(ok and all or {}) do
        local okp, t = pcall(function() return e.Transform.Transform.Translate end)
        if okp and t and math.abs(t[1] - at[1]) < Rm.NEAR + 20 and math.abs(t[3] - at[3]) < Rm.NEAR + 20
            and not comp(e, "InventoryMember") then
            local si = comp(e, "ServerItem")
            local oku, u = pcall(function() return e.Uuid.EntityUuid end)
            if not oku then u = nil end
            local _, door = pcall(function() return si and si.IsDoor end)
            local _, loose = pcall(function() return si and si.CanBePickedUp end)
            local win = false
            if u and not door and si and not loose then
                local n = C.name(u):lower()
                for _, w in ipairs(Rm.WINDOW_WORDS) do win = win or n:find(w, 1, true) ~= nil end
            end
            if u and (door or win) then list[#list + 1] = { id = u, pos = { t[1], t[2] + 1, t[3] } } end
        end
    end
    C.roomOpenings = { key = key, at = now(), list = list }
    return list
end

-- The rooms near the agent, each with whether the human's screen shows inside it now.
function Rm.near(me, mypos)
    local key = ("%d,%d,%d"):format(math.floor(mypos[1] / 4), math.floor(mypos[2] / 4), math.floor(mypos[3] / 4))
    local c = C.roomCtx
    if c and c.key == key and now() - c.at < Rm.KEEP_MS then return c.rooms end
    local rooms = {}
    local ok, all = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerRoomTrigger")
    for _, e in ipairs(ok and all or {}) do
        local okp, t = pcall(function() return e.Transform.Transform.Translate end)
        if okp and t and math.abs(t[1] - mypos[1]) < Rm.NEAR and math.abs(t[3] - mypos[3]) < Rm.NEAR then
            rooms[#rooms + 1] = { e = e }
        end
    end
    if #rooms > 0 then
        local viewers = { { mypos[1], mypos[2] + 1, mypos[3] } }
        local hp = human() and C.pos(human())
        if hp then viewers[2] = { hp[1], hp[2] + 1, hp[3] } end
        local openings = Rm.openings(mypos)
        for _, r in ipairs(rooms) do
            local okd, open = pcall(function()
                for _, v in ipairs(viewers) do
                    if Rm.depth(r.e, v) > 0 then return true end
                end
                local any = false
                for _, o in ipairs(openings) do
                    if Rm.depth(r.e, o.pos) > -Rm.TOUCH then
                        any = true
                        if truthy(osi(Osi.IsOpened, o.id)) then return true end
                    end
                end
                return not any -- a room with no door or window found: cannot tell, so not shut
            end)
            r.open = not okd or open
        end
    end
    C.roomCtx = { key = key, at = now(), rooms = rooms }
    return rooms
end

-- Is p inside a shut room (so the human's screen does not show it)?
function Rm.shut(me, mypos, p)
    local q = { p[1], p[2] + 1, p[3] }
    local inside = false
    for _, r in ipairs(Rm.near(me, mypos)) do
        local ok, d = pcall(Rm.depth, r.e, q)
        if ok and d > Rm.INSIDE then
            if r.open then return false end
            inside = true
        end
    end
    return inside
end
C.roomShut = Rm.shut

local function perceives(me, mypos, uuid, p)
    if same(me, uuid) then return true end
    if truthy(osi(Osi.CanSee, me, uuid)) then return true end
    if p == nil or dist(mypos, p) > SIGHT then return false end
    if truthy(osi(Osi.HasLineOfSight, me, uuid)) then return true end
    -- What the human's screen shows counts as seen, walls or not (and a door's pivot sits inside
    -- its own frame, so the sight ray misses doors right in front of you): everything but the
    -- inside of shut rooms. Not someone sneaking: the screen does not show them either, and CanSee
    -- above already said no.
    if truthy(osi(Osi.HasActiveStatus, uuid, "SNEAKING")) then return false end
    return not Rm.shut(me, mypos, p)
end

local function hidden(uuid)
    if not truthy(osi(Osi.IsOnStage, uuid)) then return true end
    if truthy(osi(Osi.IsInvisible, uuid)) or truthy(osi(Osi.IsInvisibleByScript, uuid)) then return true end
    return false
end

local function relation(me, uuid)
    if isParty(uuid) then return "party" end
    if truthy(osi(Osi.IsEnemy, me, uuid)) then return "enemy" end
    if truthy(osi(Osi.IsAlly, me, uuid)) then return "ally" end
    return "neutral"
end

-- Who an item belongs to when it is not the party's: taking it is theft.
local function ownedBy(item)
    local ow = osi(Osi.GetOwner, item)
    if ow == nil or tostring(ow):find("00000000-0000-0000-0000-000000000000", 1, true) or isParty(ow) then return nil end
    local n = C.name(ow)
    return n ~= "?" and n or "someone"
end

-- Lockpicking and disarming traps start only from the human's screen: the game's
-- lock and trap systems run on the client's network request, and writing their
-- request queues from Lua crashed the game (DEVLOG 2026-11-05). So the agent asks.
do
local TOOLS = {
    lock = { "TOOL_GEN_ThievesTools_A_Open_A_e32a200c-5b63-414d-ae57-00e7b38f125b", "thieves' tools" },
    trap = { "TOOL_GEN_Disam_Toolkit_A_22c74b5e-bef2-41b1-b9ed-f4acc766d4ee", "trap disarm toolkits" },
}
local function partyTools(kind)
    local n = 0
    for _, p in ipairs(party()) do n = n + (tonumber(osi(Osi.TemplateIsInInventory, TOOLS[kind][1], p)) or 0) end
    return n
end

function C.askHuman(item, kind)
    local n, what = partyTools(kind), TOOLS[kind][2]
    local msg
    if kind == "lock" then
        msg = C.name(item) .. " is locked. You cannot pick locks (the game starts lockpicking only from the "
            .. "human's screen): tell the human with `say` which one and where, and ask them to pick it "
            .. "(right-click it, Lockpick)"
    else
        msg = C.name(item) .. " is an armed trap. You cannot disarm traps (the game starts it only from the "
            .. "human's screen): tell the human with `say` which one and where, ask them to disarm it "
            .. "(right-click it, Disarm), and step at least 3 m away from it first. Never walk across it"
    end
    if n > 0 then
        msg = msg .. ("; the party has %d %s"):format(n, what)
    else
        msg = msg .. ("; nobody in the party has %s"):format(what)
            .. (kind == "lock" and " (a key opens it too; or find another way)" or " (go around it)")
    end
    local ow = ownedBy(item)
    if ow and kind == "lock" then
        msg = msg .. ("; it belongs to %s: picking it is a crime, so `ask` the human first"):format(ow)
    end
    return msg
end

function C.armedTrap(u)
    return truthy(osi(Osi.IsTrap, u)) and truthy(osi(Osi.IsTrapDiscovered, u)) and truthy(osi(Osi.IsTrapArmed, u))
end
end

-- ServerItem.IsContainer is false for many containers (cupboards, crates);
-- Osiris's IsContainer is what the game goes by.
local ITEM_FLAGS = { { "IsDoor", "door" }, { "IsLadder", "ladder" }, { "IsContainer", "container" },
                     { "CanBePickedUp", "item" }, { "CanUse", "usable" } }
local function itemKind(e, uuid)
    local si = comp(e, "ServerItem")
    if not si then return "item" end
    local flags = {}
    for _, f in ipairs(ITEM_FLAGS) do
        local ok, v = pcall(function() return si[f[1]] end)
        flags[f[1]] = ok and v or false
    end
    if not flags.IsDoor and not flags.IsLadder and uuid and truthy(osi(Osi.IsContainer, uuid)) then
        flags.IsContainer = true
    end
    for _, f in ipairs(ITEM_FLAGS) do
        if flags[f[1]] then return f[2] end
    end
    return "object"
end

local function entityPos(e)
    local ok, t = pcall(function() return e.Transform.Transform.Translate end)
    if ok and t then return { t[1], t[2], t[3] } end
    return nil
end

local function entityUuid(e)
    local ok, u = pcall(function() return e.Uuid.EntityUuid end)
    if ok then return u end
    return nil
end

-- The agent's living summons. SummonContainer is not reliable (a Flaming Sphere was listed under
-- Items, Characters empty), and IsSummon.Owner names the summon itself; Osi.CharacterGetOwner
-- gives the summoner (tested 2026-11-04). Both are looked at.
function C.mySummons()
    local out, seen = {}, {}
    if not C.agent then return out end
    local function add(u)
        if u and not seen[bare(u)] and not isDead(u) and comp(entity(u), "ServerCharacter") then
            seen[bare(u)] = true
            out[#out + 1] = u
        end
    end
    pcall(function()
        local sc = entity(C.agent).SummonContainer
        for _, list in ipairs({ sc.Characters, sc.Items }) do
            for _, x in pairs(list) do add(entityUuid(x)) end
        end
    end)
    pcall(function()
        for _, x in ipairs(Ext.Entity.GetAllEntitiesWithComponent("IsSummon")) do
            local u = entityUuid(x)
            if u and same(osi(Osi.CharacterGetOwner, u), C.agent) then add(u) end
        end
    end)
    return out
end

function C.isMySummon(u)
    for _, s in ipairs(C.mySummons()) do if same(s, u) then return true end end
    return false
end

function C.ops.look(args)
    local me = agent()
    local mypos = C.pos(me)
    local radius = math.min(tonumber(args.radius) or 40, 40)
    local chars, items = {}, {}
    local h = human()
    local sawHuman = false

    local ok, list = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerCharacter")
    if ok and list then
        for _, e in ipairs(list) do
            local p = entityPos(e)
            local d = p and dist(mypos, p)
            if d and d <= radius then
                local u = entityUuid(e)
                if u and not same(u, me) and not hidden(u) and perceives(me, mypos, u, p) then
                    local hpv, mh = hp(u)
                    local rel = relation(me, u)
                    local row = {
                        id = u, name = C.name(u), rel = rel, dist = r1(d), dir = dir(mypos, p),
                        dead = truthy(osi(Osi.IsDead, u)) or nil,
                        combat = inCombat(u) or nil,
                    }
                    if rel == "party" then
                        row.hp = hpv; row.max_hp = mh
                        if same(u, h) then row.human = true; sawHuman = true end
                    elseif hpv and mh and mh > 0 then
                        row.hp_pct = math.floor(hpv * 100 / mh)
                    end
                    if not row.dead and rel ~= "enemy" then
                        local talk = truthy(osi(Osi.GetHasDefaultDialog, u)) or truthy(osi(Osi.GetHasOsirisDialog, u))
                        row.talk = talk or nil
                        if truthy(osi(Osi.CanTrade, u)) then row.trader = true end
                    end
                    chars[#chars + 1] = row
                end
            end
        end
    end
    -- The human's character is always listed, wherever it is.
    if h and not same(h, me) and not sawHuman then
        local p = C.pos(h)
        if p then
            chars[#chars + 1] = { id = h, name = C.name(h), rel = "party", human = true, dist = r1(dist(mypos, p)),
                dir = dir(mypos, p), out_of_sight = true }
        end
    end

    local ok2, all = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerItem")
    if ok2 and all then
        for _, e in ipairs(all) do
            local p = entityPos(e)
            local d = p and dist(mypos, p)
            if d and d <= radius and not comp(e, "InventoryMember") then
                local u = entityUuid(e)
                if u and not hidden(u) then
                    local kind = itemKind(e, u)
                    local interact = truthy(osi(Osi.GetCanInteract, u))
                    local trap = truthy(osi(Osi.IsTrap, u))
                    local keep = interact or kind == "door" or kind == "container" or kind == "ladder"
                    if trap and not truthy(osi(Osi.IsTrapDiscovered, u)) and kind ~= "container" and kind ~= "door" then
                        keep = false
                    end
                    if keep and perceives(me, mypos, u, p) then
                        local n = C.name(u)
                        if n ~= "?" then
                            items[#items + 1] = {
                                id = u, name = n, kind = kind, dist = r1(d), dir = dir(mypos, p),
                                locked = truthy(osi(Osi.IsLocked, u)) or nil,
                                trap = (trap and truthy(osi(Osi.IsTrapDiscovered, u))) or nil,
                                owner = ownedBy(u),
                            }
                        end
                    end
                end
            end
        end
    end

    table.sort(chars, function(a, b) return a.dist < b.dist end)
    table.sort(items, function(a, b) return a.dist < b.dist end)
    -- Python keeps the ~30 that matter and sums up the rest; this only bounds the reply.
    while #items > 250 do table.remove(items) end
    local out = { me = mypos, sight_m = SIGHT, characters = chars, items = items }
    pcall(function()
        C.noteTrail()
        out.area, out.frontiers = C.area(me), C.frontiers(me)
        C.exits(me, mypos, items, out.frontiers)
    end)
    return out
end

------------------------------------------------------------------------
-- Stealth: who could spot the agent, and where. A character sees Sight.Sight
-- metres in a cone of Sight.FOV degrees around the way it faces, unless a wall
-- is in the way; a sneaking character is spotted the moment it crosses the
-- cone's edge (checked in game). It faces along -Z turned by its Transform
-- rotation. ServerViewshedParticipant.CanSee, the game's own "who sees whom",
-- is all-round, so it does not tell who spots a sneaker. Only characters the
-- agent itself perceives count: it cannot dodge what it has not seen.
------------------------------------------------------------------------

local WATCH_RANGE = 30.0 -- metres: watchers farther away are not checked
local EYE_H, BODY_H = 1.6, 1.0
local LOS_GROUPS, SEE_THROUGH = 0xC10, 0x820000 -- Terrain|Item|Scenery; CanSeeThrough|CanSeeThrough2
local LOOK_AHEAD = 1.5 -- metres: a sneaking walk stops this far short of a cone
local SNEAKING = "SNEAKING"

local function sneaking(me) return truthy(osi(Osi.HasActiveStatus, me, SNEAKING)) end
C.sneaking = sneaking

-- Way it faces on the ground, as a unit {x, z}.
local function facing(e)
    local ok, q = pcall(function() return e.Transform.Transform.RotationQuat end)
    if not (ok and q) then return nil end
    local x, y, z, w = q[1], q[2], q[3], q[4]
    local fx, fz = -2 * (x * z + w * y), -(1 - 2 * (x * x + y * y))
    local l = math.sqrt(fx * fx + fz * fz)
    if l < 1e-6 then return nil end
    return { fx / l, fz / l }
end

local function flat(a, b)
    local dx, dz = b[1] - a[1], b[3] - a[3]
    return math.sqrt(dx * dx + dz * dz)
end

-- Living characters outside the party within `range` of `centre` that the agent can see.
local function watchers(me, centre, range)
    range = range or WATCH_RANGE
    local out = {}
    local mypos = C.pos(me)
    local ok, list = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerCharacter")
    if not (ok and list and mypos) then return out end
    for _, e in ipairs(list) do
        local p = entityPos(e)
        if p and math.abs(p[1] - centre[1]) <= range and math.abs(p[3] - centre[3]) <= range
            and flat(p, centre) <= range then
            local u = entityUuid(e)
            local s = comp(e, "Sight")
            if u and s and not same(u, me) and not isParty(u) and not hidden(u)
                and not truthy(osi(Osi.IsDead, u)) and perceives(me, mypos, u, p) then
                out[#out + 1] = { id = u, e = e, pos = p, range = tonumber(s.Sight) or 0, fov = tonumber(s.FOV) or 90 }
            end
        end
    end
    return out
end

-- Where each one stands and faces now (they turn and walk about).
local function aim(ws)
    for _, w in ipairs(ws) do
        w.pos = entityPos(w.e) or w.pos
        w.fwd = facing(w.e)
    end
    return ws
end

-- No wall between an eye at `from` and a body at `to`. When the game cannot tell, it counts as seen.
local function clearLine(from, to)
    local ok, hit = pcall(Ext.Level.RaycastAny, { from[1], from[2] + EYE_H, from[3] },
        { to[1], to[2] + BODY_H, to[3] }, 5, LOS_GROUPS, SEE_THROUGH, -1)
    if not ok then return true end
    return not hit
end

local function inCone(w, p)
    local d = flat(w.pos, p)
    if d > w.range then return false end
    if d < 0.5 or not w.fwd then return true end
    return (w.fwd[1] * (p[1] - w.pos[1]) + w.fwd[2] * (p[3] - w.pos[3])) / d >= math.cos(math.rad(w.fov / 2))
end

local function seenAt(ws, p)
    local out = {}
    for _, w in ipairs(ws) do
        if inCone(w, p) and clearLine(w.pos, p) then out[#out + 1] = w end
    end
    return out
end

local function whoSees(ws)
    local n = {}
    for _, w in ipairs(ws) do n[#n + 1] = C.name(w.id) end
    return table.concat(n, ", ")
end

local function compass(v) return dir({ 0, 0, 0 }, { v[1], 0, v[2] }) end

-- Ground on the agent's floor at x/z, or nil.
local function groundAt(x, z, y0)
    local ok, hs = pcall(Ext.Level.GetHeightsAt, x, z)
    local best
    for _, h in ipairs(ok and hs or {}) do
        if math.abs(h - y0) < 1.5 and (not best or math.abs(h - y0) < math.abs(best - y0)) then best = h end
    end
    return best
end

-- Nearby spots on the agent's floor, in plain view from where it stands, that no watcher has in view.
local function safeSpots(mypos, ws, n)
    local out = {}
    for _, r in ipairs({ 3, 6, 9, 12 }) do
        for a = 0, 330, 30 do
            local x, z = mypos[1] + r * math.cos(math.rad(a)), mypos[3] + r * math.sin(math.rad(a))
            local y = groundAt(x, z, mypos[2])
            local p = y and { x, y, z }
            if p and #seenAt(ws, p) == 0 and clearLine({ mypos[1], mypos[2] - EYE_H + BODY_H, mypos[3] }, p) then
                out[#out + 1] = { pos = { r1(x), r1(y), r1(z) }, dist = r, dir = dir(mypos, p) }
                if #out >= n then return out end
            end
        end
    end
    return out
end

-- Who is around, which way they look, and whether they see the agent (or `pos`).
function C.ops.sight(args)
    local me = agent()
    local mypos = C.pos(me) or error("cannot tell where you are")
    local at = args.pos and { tonumber(args.pos[1]), tonumber(args.pos[2]), tonumber(args.pos[3]) } or mypos
    local ws = aim(watchers(me, at))
    local rows = {}
    for _, w in ipairs(ws) do
        local cone = inCone(w, at)
        local sees = cone and clearLine(w.pos, at)
        rows[#rows + 1] = { id = w.id, name = C.name(w.id), rel = relation(me, w.id), dist = r1(flat(mypos, w.pos)),
            dir = dir(mypos, w.pos), faces = w.fwd and compass(w.fwd) or nil, range_m = r1(w.range), fov = w.fov,
            sees = sees or nil, cover = (cone and not sees) or nil }
    end
    table.sort(rows, function(a, b) return a.dist < b.dist end)
    while #rows > 15 do table.remove(rows) end
    local out = { sneaking = sneaking(me), watchers = rows }
    if args.pos then
        out.at = at
        out.seen_there = #seenAt(ws, at) > 0
    else
        out.seen_by = whoSees(seenAt(ws, mypos))
        if out.seen_by == "" then out.seen_by = nil end
        out.safe_spots = safeSpots(mypos, ws, 6)
    end
    return out
end

------------------------------------------------------------------------
-- Status
------------------------------------------------------------------------

local function dialogView(uuid)
    local inst = dialogOf(uuid)
    if not inst then return nil end
    local d = noteDialog(inst, false)
    return { instance = inst, yours = d.yours }
end

local function sheet(uuid)
    local h, mh = hp(uuid)
    return {
        id = uuid, name = C.name(uuid), hp = h, max_hp = mh, pos = C.pos(uuid),
        dead = truthy(osi(Osi.IsDead, uuid)) or nil,
        combat = inCombat(uuid) or nil, dialog = dialogView(uuid),
        statuses = statuses(uuid),
    }
end

function C.ops.party()
    local out = {}
    local h = human()
    local host = osi(Osi.GetHostCharacter)
    local protagonist = C.hostAvatar()
    for _, p in ipairs(party()) do
        local hv, mh = hp(p)
        out[#out + 1] = { id = p, name = C.name(p), hp = hv, max_hp = mh,
            human = same(p, h) or nil, agent = same(p, C.agent) or nil,
            protagonist = same(p, protagonist) or nil,
            selected_by_human = same(p, host) or nil }
    end
    return out
end

function C.ops.status()
    local me = agent()
    local s = sheet(me)
    s.control_mode = C.protagonist and "protagonist" or nil
    local h = human()
    if h and not same(me, h) then
        local hp_ = C.pos(h)
        s.human = { name = C.name(h), dist = hp_ and s.pos and r1(dist(s.pos, hp_)),
            dir = hp_ and s.pos and dir(s.pos, hp_), combat = inCombat(h) or nil, dialog = inDialog(h) or nil,
            downed = isDowned(h) or nil, dead = isDead(h) or nil }
    end
    if C.protagonist then
        s.note = "Shared avatar: use Pause or disable takeover before entering manual gameplay input."
    elseif same(osi(Osi.GetHostCharacter), me) then
        s.note = "the human has selected your character and may be controlling it right now"
    end
    s.region = osi(Osi.GetRegion, me)
    s.resources = C.resources(me)
    if s.combat then
        local mine, ended = turnState(me)
        s.my_turn = mine
        if ended then s.turn_ended = true; s.waiting_for_party = true end
        -- a summon's turn: the agent commands it (summon=... on spells, move, cast, end_turn)
        local now_ = {}
        for _, u in ipairs(C.mySummons()) do
            if (turnState(u)) then now_[#now_ + 1] = C.name(u) end
        end
        if #now_ > 0 then s.summon_turn = now_ end
    elseif turnBasedMode(me) then
        s.turn_based = true
    end
    s.gold = osi(Osi.PartyGetGold, me)
    if sneaking(me) then s.sneaking = true end
    return s
end

------------------------------------------------------------------------
-- Reactions (interrupts): the human's screen would ask "use it?" for the
-- agent's character, which the agent cannot answer. Instead each reaction is
-- set to auto (always use), never, or ask (leave it to the human).
------------------------------------------------------------------------

local function reactionMode(flags)
    local f = tostring(flags)
    if not f:find("Enabled") then return "never" end
    if f:find("Ask") then return "ask" end
    return "auto"
end

local MODE_FLAGS = { auto = { "Enabled" }, ask = { "Ask", "Enabled" }, never = {} }

local function reactionRows(me)
    local out = {}
    local ip = comp(entity(me), "InterruptPreferences")
    if not ip then return out end
    pcall(function()
        for id, flags in pairs(ip.Preferences) do
            local st = Ext.Stats.Get(id)
            local cost = st and tostring(st.Cost or "") or ""
            out[#out + 1] = { reaction = id, name = st and loca(st.DisplayName) or id, mode = reactionMode(flags),
                uses_spell_slot = cost:find("SpellSlot") and true or nil }
        end
    end)
    table.sort(out, function(a, b) return a.reaction < b.reaction end)
    return out
end

local function setReactions(me, modes)
    local e = entity(me)
    local ip = comp(e, "InterruptPreferences")
    if not ip then error("this character has no reactions") end
    for id, mode in pairs(modes) do
        ip.Preferences[id] = MODE_FLAGS[mode]
    end
    pcall(function() e:Replicate("InterruptPreferences") end)
end

-- Default for the agent: no prompts. Free reactions are always used; ones that
-- burn a spell slot are off until the agent turns them on.
local function takeOverReactions(me)
    local modes, orig = {}, {}
    for _, r in ipairs(reactionRows(me)) do
        orig[r.reaction] = r.mode
        if r.mode == "ask" then modes[r.reaction] = r.uses_spell_slot and "never" or "auto" end
    end
    if not (C.origReactions and same(C.origReactions.owner, me)) then
        C.origReactions = { owner = me, modes = orig }
    end
    if next(modes) then setReactions(me, modes) end
end

function C.ops.reactions(args)
    local me = agent()
    if args.mode then
        local mode = tostring(args.mode)
        if not MODE_FLAGS[mode] then error("mode must be auto, never or ask") end
        local q = args.reaction and tostring(args.reaction):lower()
        local modes = {}
        for _, r in ipairs(reactionRows(me)) do
            if not q or r.reaction:lower():find(q, 1, true) or r.name:lower():find(q, 1, true) then
                modes[r.reaction] = mode
            end
        end
        if not next(modes) then error("no reaction matches " .. tostring(args.reaction)) end
        setReactions(me, modes)
    end
    return reactionRows(me)
end

------------------------------------------------------------------------
-- Choosing the agent's character
------------------------------------------------------------------------

local function findMember(q)
    if q == nil or q == "" then return nil end
    local want = bare(q)
    local low = tostring(q):lower()
    for _, p in ipairs(party()) do
        if same(p, want) or C.name(p):lower():find(low, 1, true) then return p end
    end
    -- Origin characters carry their English name in the id ("S_Player_ShadowHeart_3ed7..."),
    -- so "Shadowheart" works in a game running in another language.
    for _, p in ipairs(party()) do
        local tag = tostring(p):gsub("_?%x+%-%x+%-%x+%-%x+%-%x+$", ""):lower()
        if #low >= 3 and tag:find(low, 1, true) then return p end
    end
    return nil
end

function C.ops.set_agent(args)
    local p = findMember(args.id) or findMember(args.name)
    if not p then error("no party member matches " .. tostring(args.name or args.id)) end
    if C.protagonist then error("disable protagonist control in the local F10 panel first") end
    if not C.companionAllowed(p) then error("cannot take over a human avatar or another user's character") end
    local h = findMember(args.human_id) or findMember(args.human)
    if (args.human or args.human_id) and not h then error("no party member matches " .. tostring(args.human)) end
    if not h and C.human and not same(C.human, p) then h = C.human end
    if not h then
        local oldAgent, oldHuman = C.agent, C.human
        C.agent, C.human = p, nil
        h = human()
        C.agent, C.human = oldAgent, oldHuman
    end
    if not h then error("cannot tell which character is the human's: pass human") end
    if same(p, h) then error("that is the human's own character") end
    if C.agent and not same(C.agent, p) then C.releaseActor() end
    C.agent, C.human = p, h
    C.fallenInit = nil -- who is dead already is not news
    if args.detach ~= false then
        if truthy(osi(Osi.InSamePartyGroup, p, h)) then C.detachedForControl = true end
        osi(Osi.DetachFromPartyGroup, p)
    end
    takeOverReactions(p)
    local n = C.name(p)
    push("agent_set", { name = n })
    return { id = p, name = n, human = C.name(h), human_id = h, reactions = reactionRows(p) }
end

function C.ops.regroup()
    local me = agent()
    local h = human()
    if same(me, h) then error("protagonist mode has no separate character to regroup with") end
    osi(Osi.AttachToPartyGroup, me, h)
    C.detachedForControl = nil
    C.leftGroupAt = nil
    if C.origReactions and same(C.origReactions.owner, me) then
        pcall(setReactions, me, C.origReactions.modes)
        C.origReactions = nil
    end
    return { attached_to = C.name(h) }
end

------------------------------------------------------------------------
-- Jobs: anything that takes game time. The bridge polls job.poll.
------------------------------------------------------------------------

local function newJob(kind, data)
    -- the character does one thing at a time: a new action takes over from the last
    for id, old in pairs(C.jobs) do
        if old.status == "running" then
            old.status, old.error, old.ended = "replaced", "a newer action took over", now()
        elseif old.ended and now() - old.ended > 600000 then
            C.jobs[id] = nil -- finished long ago
        end
    end
    C.nextJob = C.nextJob + 1
    local j = { id = C.nextJob, kind = kind, status = "running", started = now(), data = data or {},
        me = C.actor or C.agent }
    C.jobs[j.id] = j
    return j
end

local function finish(j, status, result, err)
    if j.status ~= "running" then return end
    if j.data.unchained then
        result = result or {}
        result.unchained = "you left the human's group to walk on your own: regroup to follow them again"
    end
    if j.kind == "cast" and type(result) == "table" then
        -- where the caster stands says little; that the game walked it into range says a lot
        local from, at = j.data.from, result.pos
        local moved = from and at and dist(from, at)
        if moved and j.data.jump then
            result.jumped_m = r1(moved)
        elseif moved and moved > 0.5 then
            result.moved_m = r1(moved)
            local by = (j.me and not same(j.me, C.agent)) and C.name(j.me) or "you"
            result.why_moved = "the game walked " .. by .. " into range or sight first"
        end
        result.pos = nil
    end
    j.status, j.result, j.error = status, result, err
    j.ended = now()
end

local function arrived(j, p, left)
    local d = j.data
    if d.then_fn then
        local fn = d.then_fn
        d.then_fn, d.goal = nil, nil
        d.phase_started = now()
        local ok, err = pcall(fn, j)
        if not ok then return finish(j, "failed", nil, (tostring(err):gsub("^.-:%d+: ", ""))) end
        return
    end
    return finish(j, "done", { pos = p, left_m = left and r1(left) })
end

-- A sneaking walk: stop before stepping into someone's view, and fail when spotted.
-- Runs on every poll and on a short timer while the walk goes on.
local function stealthGuard(j, me)
    local d = j.data
    if j.status ~= "running" or not d.goal then return end
    local p = C.pos(me)
    if not p then return end
    if not sneaking(me) then
        osi(Osi.PurgeOsirisQueue, me)
        local by = whoSees(seenAt(aim(d.ws or {}), p))
        return finish(j, "failed", { pos = p, seen_by = by ~= "" and by or nil },
            "you are no longer sneaking (spotted, or something ended it)")
    end
    if not d.ws or now() - (d.ws_at or 0) > 1000 then d.ws, d.ws_at = watchers(me, p), now() end
    aim(d.ws)
    local ahead = p
    if d.prev and flat(p, d.prev) > 0.05 then
        local l = flat(p, d.prev)
        ahead = { p[1] + (p[1] - d.prev[1]) / l * LOOK_AHEAD, p[2], p[3] + (p[3] - d.prev[3]) / l * LOOK_AHEAD }
    end
    d.prev = p
    if d.even_if_seen then return end
    local seen = seenAt(d.ws, ahead)
    if #seen == 0 then seen = seenAt(d.ws, p) end
    if #seen > 0 then
        osi(Osi.PurgeOsirisQueue, me)
        return finish(j, "interrupted", { pos = p, would_see_you = whoSees(seen),
            reason = "stopped just short of their view: wait for them to look away, or find another way (sight)" })
    end
end

local function guardLoop(j, me)
    if j.status ~= "running" then return end
    pcall(stealthGuard, j, me)
    pcall(Ext.Timer.WaitFor, 100, function() guardLoop(j, me) end)
end

local replan -- route planning, below

-- Checked on every poll (no tick handler needed).
local function stepJob(j)
    if j.status ~= "running" then return end
    local me = j.me or C.agent
    local elapsed = now() - j.started
    local d = j.data
    local p = C.pos(me)

    if d.dialog_wait then
        local inst = dialogOf(me)
        if inst then
            noteDialog(inst, true)
            return finish(j, "done", { dialogue = true, pos = p })
        end
    end
    if d.used and (inDialog(me) or (inCombat(me) and not d.started_in_combat)) then
        -- what using it did (a bench that starts a vision, a trapped chest): the result, not an interruption
        local result = { pos = p }
        local ok, r = pcall(d.result_fn)
        if ok and r then for k, v in pairs(r) do result[k] = v end end
        return finish(j, "done", result)
    end
    if inCombat(me) and not d.started_in_combat then
        osi(Osi.PurgeOsirisQueue, me)
        return finish(j, "interrupted", { reason = "combat started", pos = p })
    end
    if inDialog(me) and not d.dialog_wait then
        return finish(j, "interrupted", { reason = "a dialogue started", pos = p })
    end
    if d.sneak_walk then
        stealthGuard(j, me)
        if j.status ~= "running" then return end
    end

    if d.goal then
        local gp = d.goal_id and C.pos(d.goal_id) or d.goal
        local left = p and gp and dist(p, gp)
        if left and left <= (d.within or 1.5) then return arrived(j, p, left) end
        -- where the planned way ends is close enough (the target's centre may be in a wall)
        local atStop = p and d.stop_at and flat(p, d.stop_at) <= 0.6 and math.abs(p[2] - d.stop_at[2]) < 1.5
        if atStop then return arrived(j, p, left) end
        if p then replan(j, me) end
        -- stall detection: stopped close by for 1 s counts as there; no progress for 3 s fails
        if p and d.last and dist(p, d.last) < 0.05 then
            d.still = d.still or now()
            local close = left and left <= math.max(d.within or 1.5, CLOSE_ENOUGH)
                or (d.stop_at and flat(p, d.stop_at) <= 1.5)
            if close and now() - d.still > 1000 then return arrived(j, p, left) end
            if now() - d.still > 3000 then
                return finish(j, "failed", { pos = p, left_m = left and r1(left) },
                    "stopped moving (blocked, needs a jump/ladder, or path not found)")
            end
        else
            d.still = nil
        end
        d.last = p
    elseif d.dialog_wait then
        if now() - (d.phase_started or j.started) > 4000 then
            return finish(j, "failed", { pos = p }, "they did not start a conversation")
        end
    elseif d.cast then
        -- the game walks into range first, so allow for a walk
        if now() - j.started > 20000 then
            if C.pending and C.pending.job == j.id then C.pending = nil end
            osi(Osi.PurgeOsirisQueue, me)
            return finish(j, "failed", { pos = p },
                "the spell did not go off (out of range, no line of sight, or the target is not valid)")
        end
    elseif d.ready_fn then
        -- waiting for a precondition before acting (e.g. an unchain to take effect)
        if d.ready_fn() then
            d.ready_fn = nil
            d.go()
        elseif elapsed > (d.ready_ms or 3000) then
            return finish(j, "failed", { pos = p }, d.not_ready or "gave up waiting")
        end
    elseif d.until_fn then
        -- done once until_fn holds, or after until_ms with whatever came of it
        if d.until_fn() or elapsed > (d.until_ms or 5000) then
            local result = { pos = p }
            local ok, r = pcall(d.result_fn)
            if ok and r then for k, v in pairs(r) do result[k] = v end end
            return finish(j, "done", result)
        end
    elseif d.wait_until then
        if now() >= d.wait_until and d.fail_fn then
            return finish(j, "failed", { pos = p }, d.fail_fn())
        elseif now() >= d.wait_until then
            local result = { pos = p }
            if d.result_fn then
                local ok, r = pcall(d.result_fn)
                if ok and r then for k, v in pairs(r) do result[k] = v end end
            end
            return finish(j, "done", result)
        end
    end

    if elapsed > (d.timeout or 60000) then
        osi(Osi.PurgeOsirisQueue, me)
        finish(j, "timeout", { pos = p })
    end
end

function C.ops.job(args)
    local j = C.jobs[tonumber(args.id)]
    if not j then error("no such job") end
    stepJob(j)
    return { id = j.id, kind = j.kind, status = j.status, result = j.result, error = j.error,
        ms = math.floor((j.ended or now()) - j.started) }
end

function C.ops.cancel(args)
    local j = C.jobs[tonumber(args.id)]
    if j and j.status == "running" then
        osi(Osi.PurgeOsirisQueue, j.me or C.agent)
        finish(j, "cancelled")
    end
    return true
end

------------------------------------------------------------------------
-- Combat guard: the agent may act in combat only on its own turn, and only
-- with the resources the game says it has left.
------------------------------------------------------------------------

local function combatGate(me)
    if not inCombat(me) then return false end
    local mine, ended = turnState(me)
    if ended then error("you already ended your turn; wait for your next one") end
    if not mine then error("in combat and it is not your turn: wait for your turn") end
    return true
end

------------------------------------------------------------------------
-- Route planning: ask the game's pathfinder (the one a click uses) before walking.
-- Found by trying it (2026-11-04): BeginPathfindingImmediate + FindPath answer at once
-- (1-70 ms). The goal must be a walkable tile at the right height: an object's own tile
-- is taken and a door's centre is in the wall, so a few spots by the target are tried.
-- CloseEnoughMax is how near (flat) the path must end, and with a large one the path
-- ends at the closest point it can reach. CheckLockedDoors = false walks through locked
-- doors. CanUseLadders is off on a fresh path, yet CharacterMoveToPosition climbs ladders
-- itself (a vine ladder in the Lower City: 8 m up it, 85 m round without it), so it is
-- always on. ErrorCause tells nothing useful.
------------------------------------------------------------------------

local function pathLen(pts)
    local m = 0
    for i = 2, #pts do m = m + dist(pts[i - 1], pts[i]) end
    return m
end

-- One question to the pathfinder: { found, pts, cost } (pts: the way, ending where it stops;
-- cost: the movement it takes, as the game reckons it: the last node's Distance, which is the
-- figure the turn-based cursor shows. A ladder climb costs nothing, so a 2.3 m walk to a ladder
-- 4 m down took 2.4 m of movement; a 6 m walk round a corner took 6.0), or nil when there is
-- no pathfinder to ask.
local function findPath(me, to, reach, opts)
    local L = Ext.Level
    if not (L and L.BeginPathfindingImmediate and L.FindPath) then return nil end
    local e = entity(me)
    if not e then return nil end
    local ok, res = pcall(function()
        local path = L.BeginPathfindingImmediate(e, { to[1], to[2], to[3] })
        local out = { found = false }
        local okf, err = pcall(function()
            path.CloseEnoughMax = math.max(reach, 0.6)
            path.CanUseLadders = true -- a walk climbs ladders by itself (off by default here only)
            for k, v in pairs(opts or {}) do path[k] = v end
            L.FindPath(path)
            if path.GoalFound then
                local pts, n = {}, path.Nodes
                for i = 1, #n do
                    local q = n[i].Position
                    pts[#pts + 1] = { q[1], q[2], q[3] }
                end
                out.found, out.pts = #pts > 0, pts
                if #n > 0 then pcall(function() out.cost = tonumber(n[#n].Distance) end) end
            end
        end)
        pcall(L.ReleasePath, path)
        if not okf then error(err) end
        return out
    end)
    if ok then return res end
    return nil
end

-- Where to aim for when going to tp: the spot itself, where the game would stand someone
-- by it, and the other floors at that place. Something hung up high (a sign over a door:
-- no floor within 3 m of it) is reached by standing under it: that floor comes back as
-- the second value.
local function goalSpots(me, tp)
    local spots = { tp }
    local x, y, z = osi(Osi.FindValidPosition, tp[1], tp[2], tp[3], 3.0, me, 1)
    if x and y and z then spots[#spots + 1] = { x, y, z } end
    local ok, hs = pcall(Ext.Level.GetHeightsAt, tp[1], tp[3])
    local near, under = false, nil
    for _, h in ipairs(ok and hs or {}) do
        local dy = math.abs(h - tp[2])
        if dy > 0.3 and dy < 4 then spots[#spots + 1] = { tp[1], h, tp[3] } end
        if dy <= 3 then near = true end
        if h < tp[2] and tp[2] - h < 8 and (not under or h > under) then under = h end
    end
    if near or not under then return spots end
    if tp[2] - under >= 4 then spots[#spots + 1] = { tp[1], under, tp[3] } end
    return spots, under
end

-- How far (flat) a point is from a path, counting only parts of it at about its height.
local function offPath(q, pts)
    local best = math.huge
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local dx, dz = b[1] - a[1], b[3] - a[3]
        local l2 = dx * dx + dz * dz
        local t = l2 > 0 and math.max(0, math.min(1, ((q[1] - a[1]) * dx + (q[3] - a[3]) * dz) / l2)) or 0
        local cx, cy, cz = a[1] + dx * t, a[2] + (b[2] - a[2]) * t, a[3] + dz * t
        if math.abs(q[2] - cy) < 3 then best = math.min(best, flat(q, { cx, cy, cz })) end
    end
    return best
end

-- The locked door a way goes through.
local function lockedDoorOn(pts)
    local ok, all = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerItem")
    if not (ok and all) then return nil end
    local lo, hi = { math.huge, math.huge }, { -math.huge, -math.huge }
    for _, q in ipairs(pts) do
        lo[1], lo[2] = math.min(lo[1], q[1]), math.min(lo[2], q[3])
        hi[1], hi[2] = math.max(hi[1], q[1]), math.max(hi[2], q[3])
    end
    local best, bestD
    for _, e in ipairs(all) do
        local p = entityPos(e)
        if p and p[1] > lo[1] - 3 and p[1] < hi[1] + 3 and p[3] > lo[2] - 3 and p[3] < hi[2] + 3 then
            local si = comp(e, "ServerItem")
            local door = false
            pcall(function() door = si.IsDoor == true end)
            if door then
                local u = entityUuid(e)
                local d = offPath(p, pts)
                if u and d < 2.5 and (not bestD or d < bestD) and truthy(osi(Osi.IsLocked, u)) then
                    best, bestD = u, d
                end
            end
        end
    end
    return best and { id = best, name = C.name(best) } or nil
end

-- The closest place to tp the agent can walk to: { pos, short_m (still that far, flat), walk_m }.
local function nearestSpot(me, from, tp, spots)
    local best
    local function consider(r)
        if not (r and r.found) then return end
        local last = r.pts[#r.pts]
        local off = flat(last, tp)
        if not best or off < best.off then best = { pos = last, off = off, walk = pathLen(r.pts) } end
    end
    local far = flat(from, tp)
    for _, s in ipairs(spots) do consider(findPath(me, s, far + 2)) end
    if not best then
        -- tp is off the walkable ground (in a wall, over a drop): come back along the line
        for k = 1, math.min(20, math.floor(far / 1.5)) do
            local t = k * 1.5 / far
            local q = { tp[1] + (from[1] - tp[1]) * t, tp[2] + (from[2] - tp[2]) * t, tp[3] + (from[3] - tp[3]) * t }
            local x, y, z = osi(Osi.FindValidPosition, q[1], q[2], q[3], 1.5, me, 1)
            local r = findPath(me, x and { x, y, z } or q, 1.0)
            if r and r.found then
                consider(r)
                break
            end
        end
    end
    if not best then return nil end
    local p = best.pos
    return { pos = { r1(p[1]), r1(p[2]), r1(p[3]) }, short_m = r1(best.off), walk_m = r1(best.walk) }
end

-- How to walk to tp and end within `reach` (flat) of it: { to = where the walk ends, walk_m, cost_m (movement), pts };
-- { why, door, nearest } when there is no way; nil when the pathfinder cannot help (walk blind).
function C.plan(me, tp, reach)
    local from = C.pos(me)
    if not (from and tp) then return nil end
    local spots, under = goalSpots(me, tp)
    local function try(opts)
        for _, s in ipairs(spots) do
            local r = findPath(me, s, reach - flat(s, tp), opts)
            if r == nil then return nil, true end
            if r.found then
                local last = r.pts[#r.pts]
                local level = math.abs(last[2] - tp[2]) <= 3 or (under and math.abs(last[2] - under) <= 1)
                if flat(last, tp) <= reach + 0.3 and level then return r end
            end
        end
        return nil
    end
    local r, blind = try()
    if blind then return nil end
    if r then return { to = r.pts[#r.pts], walk_m = pathLen(r.pts), cost_m = r.cost, pts = r.pts } end
    local near = nearestSpot(me, from, tp, spots)
    if not near then return nil end -- nowhere at all to go: this is not the pathfinder's ground
    local out = { nearest = near }
    local through = try({ CheckLockedDoors = false })
    if through then
        out.door = lockedDoorOn(through.pts)
        out.why = "a locked door is in the way" .. (out.door and (" (" .. out.door.name .. ")") or "")
            .. ": it needs a key or lockpicking (ask the human), or find another way"
    else
        out.why = "there is no way there on foot (it needs a jump or a climb, or that spot is inside a wall or over a drop)"
    end
    return out
end

-- The farthest spot up to m metres towards angle a that the agent can walk to without a long way
-- round (a door out of the room does not count as "north").
local function spotToward(me, a, m)
    local p = C.pos(me)
    local ux, uz = math.cos(a), math.sin(a)
    local step = math.max(1.5, m / 8)
    local k = m
    while k >= 1.5 do
        local q = { p[1] + ux * k, p[2], p[3] + uz * k }
        for _, s in ipairs(goalSpots(me, q)) do
            local r = findPath(me, s, 1.0) -- a larger reach would end the walk up to that far short
            if r == nil then return nil end
            if r.found then
                local last = r.pts[#r.pts]
                local ahead = (last[1] - p[1]) * ux + (last[3] - p[3]) * uz
                local straight = flat(p, last)
                if ahead >= math.min(1, k) and ahead >= straight * 0.7 and pathLen(r.pts) <= straight * 1.5 + 2 then
                    return last
                end
            end
        end
        k = k - step
    end
    return false
end

------------------------------------------------------------------------
-- Actions
------------------------------------------------------------------------

-- Set off for target (a uuid or a position) on the way the pathfinder planned (plan: one made
-- already). The walk is aimed at where the plan ends, not the target's centre, which can be in a
-- wall or past where the game itself would stop. With no way there the job fails right away,
-- saying why and where the closest reachable spot is; returns false then.
local function setOff(j, me, target, within, how, plan)
    local tp = type(target) == "table" and target or C.pos(target)
    local d = j.data
    d.goal, d.goal_id, d.within = tp, type(target) ~= "table" and target or nil, within
    if plan == nil then plan = C.plan(me, tp, within) end
    if plan and plan.why then
        finish(j, "failed", { pos = C.pos(me), blocked_by = plan.door, nearest = plan.nearest },
            "cannot get there: " .. plan.why .. (plan.nearest and "; `nearest` is the closest you can get" or ""))
        return false
    end
    d.how = how or "Run"
    -- chained to the human (after regroup), the game walks the agent back to them once it stops
    local h = human()
    if h and not same(me, h) and truthy(osi(Osi.InSamePartyGroup, me, h)) then
        osi(Osi.DetachFromPartyGroup, me)
        if same(me, C.agent) then C.detachedForControl = true end
        -- the group check lags a moment: a second walk right after is not news
        if not (C.leftGroupAt and now() - C.leftGroupAt < 5000) then d.unchained = true end
        C.leftGroupAt = now()
    end
    local to = plan and plan.to
    if to then
        d.stop_at, d.planned_for, d.planned_at = to, tp, now()
        Osi.CharacterMoveToPosition(me, to[1], to[2], to[3], d.how, "BG3COOP_move_" .. j.id)
    elseif type(target) == "table" then
        Osi.CharacterMoveToPosition(me, tp[1], tp[2], tp[3], d.how, "BG3COOP_move_" .. j.id)
    else
        Osi.CharacterMoveTo(me, target, d.how, "BG3COOP_move_" .. j.id)
    end
    return true
end

-- Someone walked to moves on: plan again towards where they are now (at most once a second).
replan = function(j, me)
    local d = j.data
    if not (d.goal_id and d.planned_for and d.stop_at) or now() - (d.planned_at or 0) < 1000 then return end
    local tp = C.pos(d.goal_id)
    if not tp or flat(tp, d.planned_for) < 2 then return end
    d.planned_at = now()
    local plan = C.plan(me, tp, d.within)
    if plan and plan.to then
        d.stop_at, d.planned_for = plan.to, tp
        Osi.CharacterMoveToPosition(me, plan.to[1], plan.to[2], plan.to[3], d.how or "Run", "BG3COOP_move_" .. j.id)
    end
end

local function startMove(j, me, target, within, how, plan)
    local tp = type(target) == "table" and target or C.pos(target)
    if not tp then error("cannot locate the target") end
    within = within or 1.5
    local combat = combatGate(me)
    local p = C.pos(me)
    j.data.started_in_combat = inCombat(me)
    local tbm = turnBasedMode(me)
    if plan == nil then plan = C.plan(me, tp, within) or false end
    if (combat or tbm) and not (plan and plan.why) then
        local r = C.resources(me)
        local have = r.Movement and r.Movement[1] or 0
        local need = plan and (plan.cost_m or plan.walk_m) or (dist(p, tp) - within)
        if need > have + 0.1 then
            if tbm then
                error(("the party is in turn-based mode outside combat: you have %.1f m of movement left this turn "
                    .. "(need ~%.1f m); end_turn to start a new one, or ask the human to switch turn-based mode off")
                    :format(have, need))
            end
            error(("not enough movement this turn: need ~%.1f m, have %.1f m"):format(need, have))
        end
    end
    return setOff(j, me, target, within, how, plan)
end

-- Sampled every half metre along a path: the first point someone has in view, and how far along.
local function firstSeen(ws, pts)
    local walked = 0
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local len = dist(a, b) or 0
        local steps = math.max(1, math.ceil(len / 0.5))
        for k = 1, steps do
            local t = k / steps
            local q = { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
            local seen = seenAt(ws, q)
            if #seen > 0 then return q, walked + len * t, seen end
        end
        walked = walked + len
    end
    return nil
end

-- Walk while sneaking: plan the way with the game's pathfinding, refuse a way
-- that crosses someone's view (unless even_if_seen), then walk and keep watch.
local function sneakMove(j, me, target, within, args)
    if not sneaking(me) then error("you are not sneaking: call sneak first") end
    combatGate(me)
    local from = C.pos(me)
    local tp = type(target) == "table" and target or C.pos(target)
    if not (from and tp) then error("cannot locate the target") end
    local d = j.data
    d.sneak_walk, d.even_if_seen = true, args.even_if_seen and true or nil
    local plan = C.plan(me, tp, within or 1.5) or false
    if plan and plan.why then return setOff(j, me, target, within or 1.5, "Walk", plan) end
    local pts = { from }
    for _, q in ipairs(plan and plan.pts or { tp }) do pts[#pts + 1] = q end
    if not args.even_if_seen then
        local mid = { (from[1] + tp[1]) / 2, from[2], (from[3] + tp[3]) / 2 }
        local ws = aim(watchers(me, mid, math.min(WATCH_RANGE + flat(from, tp) / 2, 60)))
        local q, m, seen = firstSeen(ws, pts)
        if q then
            return finish(j, "failed", { pos = from, seen_at = { r1(q[1]), r1(q[2]), r1(q[3]) }, m_ahead = r1(m),
                would_see_you = whoSees(seen) },
                ("the way there crosses %s's view %.0f m ahead: wait for them to look away, pick another spot "
                    .. "(sight), or move with even_if_seen"):format(whoSees(seen), m))
        end
    end
    if startMove(j, me, target, within, "Walk", plan) then guardLoop(j, me) end
end

function C.ops.move(args)
    local me = agent()
    if args.to_human and C.protagonist then error("the protagonist cannot follow themselves") end
    local j = newJob("move")
    local target = args.id
    local within = tonumber(args.within)
    if not target then
        if args.pos then
            target = { tonumber(args.pos[1]), tonumber(args.pos[2]), tonumber(args.pos[3]) }
        elseif args.dir then
            -- walk `meters` toward a compass direction
            local p = C.pos(me)
            local m = math.min(tonumber(args.meters) or 8, 30)
            local idx
            for i, d in ipairs(DIRS) do if d == tostring(args.dir):upper() then idx = i end end
            if not idx then error("dir must be one of N NE E SE S SW W NW") end
            local a = (idx - 1) * math.pi / 4
            local spot = spotToward(me, a, m)
            if spot == false then
                error(("there is nowhere to walk to the %s from here (a wall or a drop): try another direction")
                    :format(DIRS[idx]))
            end
            if spot then
                target = spot
            else -- no pathfinder: the point itself, on the ground there
                local x, z = p[1] + math.cos(a) * m, p[3] + math.sin(a) * m
                local _, y = osi(Osi.FindValidPosition, x, p[2], z, 4.0, me, 1)
                target = { x, y or p[2], z }
            end
        elseif args.to_human then
            target = human() or error("cannot tell where the human is")
            within = within or 3
        else
            error("give id, pos, dir or to_human")
        end
    end
    if type(target) == "string" then
        if not perceives(me, C.pos(me), target, C.pos(target)) and not isParty(target) then
            error("you cannot see that target from here")
        end
        within = within or 2.0 -- a character or object takes up room; nobody stands inside it
    end
    C.provokeCheck(me, type(target) == "string" and C.pos(target) or target, args)
    if args.sneak then
        sneakMove(j, me, target, within, args)
        return { job = j.id }
    end
    startMove(j, me, target, within)
    return { job = j.id }
end

-- What an object looks like before and after using it.
local function objectState(item)
    return {
        opened = truthy(osi(Osi.IsOpened, item)),
        locked = truthy(osi(Osi.IsLocked, item)),
        owner = osi(Osi.GetInventoryOwner, item),
        onstage = truthy(osi(Osi.IsOnStage, item)),
        pos = C.pos(item),
    }
end

local function useEffect(before, after, me)
    if not after.onstage and before.onstage then return "it disappeared (used up or picked up)" end
    if after.owner and not same(after.owner, before.owner) then
        return same(after.owner, me) and "picked up" or "moved into another inventory"
    end
    if after.opened ~= before.opened then return after.opened and "opened" or "closed" end
    if after.locked ~= before.locked then return after.locked and "locked" or "unlocked" end
    if before.pos and after.pos and dist(before.pos, after.pos) > 0.2 then return "it moved" end
    return "no visible change (it may need a key, a check, or something else first)"
end

-- Usable things near a spot ([uuid] = true), to tell what a lever or a button revealed.
local USE_NEW_M, TELEPORT_M = 15, 6
local function usableAround(pos, r)
    local out = {}
    if not pos then return out end
    local ok, all = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerItem")
    if not (ok and all) then return out end
    for _, e in ipairs(all) do
        local p = entityPos(e)
        if p and dist(pos, p) <= r and not comp(e, "InventoryMember") then
            local u = entityUuid(e)
            if u and not hidden(u) then
                local kind = itemKind(e, u)
                if truthy(osi(Osi.GetCanInteract, u)) or kind == "door" or kind == "ladder" or kind == "container" then
                    out[u] = true
                end
            end
        end
    end
    return out
end

-- What using an object did: to the object, and to the agent (moved somewhere else, in a
-- conversation or a fight) and around it (something new to use).
local function useResult(me, effect, from, around, startedInCombat, talking)
    local out, also = {}, {}
    local here = C.pos(me)
    local moved = from and here and dist(from, here)
    if moved and moved > TELEPORT_M then
        also[#also + 1] = ("you were taken somewhere else (%.0f m away): look around"):format(moved)
        out.moved_m = r1(moved)
    end
    local inst = dialogOf(me)
    if inst and inst ~= talking then
        noteDialog(inst, true)
        also[#also + 1] = "a conversation started: read dialogue"
        out.dialogue = true
    end
    if inCombat(me) and not startedInCombat then
        also[#also + 1] = "combat started"
        out.combat = true
    end
    if not out.moved_m then
        local new = {}
        for u in pairs(usableAround(from, USE_NEW_M)) do -- around the same spot as before
            if not around[u] then
                local n = C.name(u)
                if n ~= "?" then new[#new + 1] = { id = u, name = n, dist = r1(dist(here, C.pos(u))) } end
            end
        end
        table.sort(new, function(a, b) return a.dist < b.dist end)
        while #new > 6 do table.remove(new) end
        if #new > 0 then
            also[#also + 1] = "something new appeared nearby"
            out.appeared = new
        end
    end
    if #also > 0 and effect:find("^no visible change") then effect = nil end
    if effect then table.insert(also, 1, effect) end
    out.effect = table.concat(also, "; ")
    return out
end

function C.ops.use(args)
    local me = agent()
    local item = args.id or error("id required")
    local p, ip = C.pos(me), C.pos(item)
    if not ip then error("cannot locate that object") end
    if not perceives(me, p, item, ip) then error("you cannot see that object from here") end
    if truthy(osi(Osi.IsLocked, item)) then error(C.askHuman(item, "lock")) end
    if C.armedTrap(item) then error(C.askHuman(item, "trap")) end
    combatGate(me)
    local j = newJob("use")
    j.data.started_in_combat = inCombat(me)
    j.data.then_fn = function(job)
        local here, there = C.pos(me), C.pos(item)
        local left = here and there and flat(here, there)
        if left and (left > USE_RANGE + 0.6 or math.abs(here[2] - there[2]) > 3) then
            error(("could not get close enough (%.1f m away)"):format(dist(here, there)))
        end
        local before = objectState(item)
        -- wider than what is compared afterwards: things at the edge are not new
        local from, around, talking = C.pos(me), usableAround(C.pos(me), USE_NEW_M + 3), dialogOf(me)
        C.actedAt = now()
        Osi.Use(me, item, "BG3COOP_use_" .. job.id)
        job.data.used = true
        job.data.result_fn = function()
            return useResult(me, useEffect(before, objectState(item), me), from, around,
                job.data.started_in_combat, talking)
        end
        -- Done once the object changes or the agent is taken away; a conversation or a fight
        -- ends it at once (stepJob). Otherwise give a sitting animation or a vision time to start.
        job.data.until_ms = 60000 -- counted from the job's start; the wait below from the use
        job.data.until_fn = function()
            local since = now() - job.data.used_at
            if since < 800 then return false end
            if since > 3000 then return true end
            local here = C.pos(me)
            if from and here and dist(from, here) > TELEPORT_M then return true end
            return not useEffect(before, objectState(item), me):find("^no visible change")
        end
        job.data.used_at = now()
    end
    setOff(j, me, item, USE_RANGE)
    return { job = j.id }
end

-- How many items a stack holds. One stack in a slot can be made of several
-- entities (InventoryStack.Entries); GetStackAmount counts only one of them.
local function stackCount(u, e)
    local n
    pcall(function()
        for _, entry in ipairs((e or entity(u)).InventoryStack.Entries) do n = (n or 0) + entry.Quantity end
    end)
    return n or osi(Osi.GetStackAmount, u) or 1
end

-- Container contents, only when standing next to it and it is unlocked.
-- A living character outside the party: its bag is its pockets. Taking from them is
-- pickpocketing, which the game runs through its own window and Sleight of Hand roll
-- (only for the character the human has selected), so the agent cannot do it; reading
-- or emptying them here would skip the roll. Bodies can be looted.
local POCKETS = "that is in someone's pockets: you cannot pickpocket (the game only allows it from the human's own screen)"
local function inPockets(u)
    return comp(entity(u), "ServerCharacter") ~= nil and not isParty(u) and not truthy(osi(Osi.IsDead, u))
end

function C.ops.container(args)
    local me = agent()
    local box = args.id or error("id required")
    local d = dist(C.pos(me), C.pos(box))
    if not d or d > USE_RANGE + 0.5 then error("walk up to it first (use move with its id)") end
    if truthy(osi(Osi.IsLocked, box)) then error(C.askHuman(box, "lock")) end
    if inPockets(box) then error(POCKETS) end
    local e = entity(box)
    local inv = comp(e, "InventoryOwner")
    if not inv then error("cannot read what is inside (it may not be a container)") end
    local out = {}
    local ok, err = pcall(function()
        for _, i in ipairs(inv.Inventories) do
            for _, slot in pairs(i.InventoryContainer.Items) do
                local u = entityUuid(slot.Item)
                if u then
                    out[#out + 1] = { id = u, name = C.name(u), count = stackCount(u, slot.Item), owner = ownedBy(u) }
                end
            end
        end
    end)
    if not ok then error("cannot read what is inside: " .. tostring(err)) end
    return { items = out, empty = #out == 0 or nil }
end

-- Picks items up as a click does (Osi.Pickup): the game moves them, and for
-- owned ones raises CharacterStoleItem, so witnesses and the crime system
-- react (Osi.ToInventory moved them quietly and kept no record of a theft).
function C.ops.take(args)
    local me = agent()
    local ids = args.ids or { args.id }
    if inCombat(me) then error("taking items in combat costs actions; do it after the fight") end
    -- Theft: only when the human has agreed (steal), and only while sneaking.
    for _, it in ipairs(ids) do
        local holder = osi(Osi.GetInventoryOwner, it)
        if holder and inPockets(holder) then error(POCKETS) end
        local ow = ownedBy(it) or (holder and not isParty(holder) and ownedBy(holder)) or nil
        if ow and not args.steal then
            error(("%s belongs to %s: taking it is stealing. Do not steal on your own: ask the human first, and "
                .. "only if they agree, sneak and take it with steal"):format(C.name(it), ow))
        end
        if ow and not sneaking(me) then
            error(("%s belongs to %s: steal only while sneaking (sneak first, out of everyone's view)")
                :format(C.name(it), ow))
        end
    end
    local picking = {}
    for _, it in ipairs(ids) do
        local holder = osi(Osi.GetInventoryOwner, it)
        local where = holder and C.pos(holder) or C.pos(it)
        local d = dist(C.pos(me), where)
        if d and d <= USE_RANGE + 0.5 and not same(holder, me) then
            picking[#picking + 1] = { id = it, name = C.name(it) }
            osi(Osi.Pickup, me, it, "BG3COOP_take")
        end
    end
    if #picking == 0 then error("nothing taken: stand next to it first") end
    local j = newJob("take")
    local function mine_(it) return same(osi(Osi.GetInventoryOwner, it), me) end
    j.data.until_ms = 5000
    j.data.until_fn = function()
        for _, x in ipairs(picking) do if not mine_(x.id) then return false end end
        return true
    end
    j.data.result_fn = function()
        local taken, missed = {}, {}
        for _, x in ipairs(picking) do
            if mine_(x.id) then taken[#taken + 1] = x.name else missed[#missed + 1] = x.name end
        end
        return { taken = taken, not_taken = #missed > 0 and missed or nil }
    end
    return { job = j.id }
end

------------------------------------------------------------------------
-- Inventory: the agent's bag and what it wears
------------------------------------------------------------------------

local startCast -- defined with the spells below

local function statsOf(e)
    local ok, sid = pcall(function() return e.Data.StatsId end)
    if not ok or not sid then return nil, nil end
    local ok2, st = pcall(Ext.Stats.Get, sid)
    return sid, ok2 and st or nil
end

local USE_KIND = { Potion = "potion", Scroll = "scroll", Grenade = "throwable" }

-- weapon, gear (armour, clothes, jewellery), potion (also oils and poisons), scroll, throwable, other
local function itemKind2(e, st)
    local ml = st and tostring(st.ModifierList)
    if ml == "Weapon" then return "weapon" end
    if ml == "Armor" then return "gear" end
    local ok, t = pcall(function() return st.ItemUseType end)
    return ok and USE_KIND[tostring(t)] or "other"
end

local function equipSlot(e)
    local eq = comp(e, "Equipable")
    if not eq then return nil end
    local ok, s = pcall(function() return tostring(eq.Slot) end)
    return ok and s or nil
end

-- Items straight in the character's inventories of one type ("Main" bag or "Equipment").
-- Bags inside the bag (alchemy pouch, keychain) are listed as items, not opened.
local function eachItem(uuid, invType, fn)
    local inv = comp(entity(uuid), "InventoryOwner")
    if not inv then return end
    pcall(function()
        for _, i in ipairs(inv.Inventories) do
            local ok, t = pcall(function() return tostring(i.InventoryData.Type) end)
            if not ok or t == invType then
                for _, slot in pairs(i.InventoryContainer.Items) do
                    local u = entityUuid(slot.Item)
                    if u then fn(u, slot.Item) end
                end
            end
        end
    end)
end

local function equipped(uuid)
    local out = {}
    eachItem(uuid, "Equipment", function(u, e)
        out[#out + 1] = { slot = equipSlot(e), id = u, name = C.name(u) }
    end)
    table.sort(out, function(a, b) return tostring(a.slot) < tostring(b.slot) end)
    return out
end

local function inBag(me, item)
    return same(osi(Osi.GetInventoryOwner, item), me)
end

local DEFAULT_KINDS = { potion = true, scroll = true, throwable = true }
local ITEM_KINDS = { weapon = true, gear = true, potion = true, scroll = true, throwable = true, other = true }

function C.ops.inventory(args)
    local me = agent()
    local want
    local k = args.kind and tostring(args.kind):lower() or ""
    if k == "" then want = DEFAULT_KINDS
    elseif k == "all" then want = ITEM_KINDS
    elseif ITEM_KINDS[k] then want = { [k] = true }
    else error("kind must be weapon, gear, potion, scroll, throwable, other or all") end
    local rows, byKey, hiddenCount = {}, {}, {}
    eachItem(me, "Main", function(u, e)
        local sid, st = statsOf(e)
        local kind = itemKind2(e, st)
        if not want[kind] then
            hiddenCount[kind] = (hiddenCount[kind] or 0) + 1
            return
        end
        local n = C.name(u)
        local count = stackCount(u, e)
        local key = tostring(sid) .. "|" .. n
        local row = byKey[key]
        if row then
            row.count = row.count + count
        else
            row = { id = u, name = n, kind = kind, count = count, slot = equipSlot(e) }
            pcall(function()
                if kind == "potion" and tostring(st.ObjectCategory):find("Healing") then row.heals = true end
            end)
            byKey[key] = row
            rows[#rows + 1] = row
        end
    end)
    table.sort(rows, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        if a.slot ~= b.slot then return tostring(a.slot) < tostring(b.slot) end
        return a.name < b.name
    end)
    for _, r in ipairs(rows) do if r.count == 1 then r.count = nil end end
    return { equipped = equipped(me), items = rows, not_shown = next(hiddenCount) and hiddenCount or nil,
        gold = osi(Osi.PartyGetGold, me) }
end

-- Revivals (scrolls, Revivify, the Deva's) ask for Dead() in OriginTargetConditions: they take
-- the fallen as their second target. Other spells on the dead are the game's to allow or refuse.
local function raisesDead(spell)
    local ok, cond = pcall(function() return Ext.Stats.Get(spell).OriginTargetConditions end)
    return ok and tostring(cond or ""):find("Dead()", 1, true) ~= nil
end

-- The game refuses these requests once its target checks are back on (even
-- for a valid target), so the spell's own conditions are checked here and the
-- game's are skipped: a party member, dead, downed or petrified, not barred
-- from coming back, getting up within 9 m.
local function reviveProblem(me, who, landing)
    if not isParty(who) then return "only a party member can be brought back" end
    local fallen = truthy(osi(Osi.IsDead, who)) or truthy(osi(Osi.HasActiveStatus, who, "DOWNED"))
        or truthy(osi(Osi.HasActiveStatus, who, "PETRIFIED"))
    if not fallen then return "they are not dead or downed" end
    if C.tagged(who, "BLOCK_RESURRECTION") then return "the game does not let them be brought back" end
    local p = C.pos(me)
    if landing and p and math.sqrt((landing[1] - p[1]) ^ 2 + (landing[3] - p[3]) ^ 2) > 9 then
        return "where they get up (x/y/z) must be within 9 m of you"
    end
    return nil
end

-- Drink a potion or read a scroll from the agent's own bag.
function C.ops.use_item(args)
    local me = agent()
    local item = args.item or error("item required")
    if not inBag(me, item) then error("that is not in your bag (see inventory)") end
    local e = entity(item)
    local _, st = statsOf(e)
    local kind = itemKind2(e, st)
    local costs = parseCosts(st and st.UseCosts)
    if kind == "scroll" then
        local spell
        pcall(function() spell = e.SpellBook.Spells[1].Id.OriginatorPrototype end)
        if not spell then error("cannot tell which spell this scroll holds") end
        local template = osi(Osi.GetTemplate, item)
        local opt = { item = item, after = function()
            if template then Osi.TemplateRemoveFrom(template, me, 1) end
        end }
        if raisesDead(spell) then
            -- like the game's revive scrolls: target the fallen, land them where they lie or at x/y/z
            local who = args.id or error("say whom to bring back: target the dead or downed party member")
            local name = C.name(who)
            opt.second = who
            opt.landing = args.pos and { tonumber(args.pos[1]), tonumber(args.pos[2]), tonumber(args.pos[3]) } or nil
            local why = reviveProblem(me, who, opt.landing)
            if why then error(why) end
            opt.failed = "the game would not bring them back"
            opt.report = function() return { revived = name, hp = (hp(who)) } end
            return startCast(me, spell, costs, { id = who }, opt)
        end
        return startCast(me, spell, costs, args, opt)
    end
    if kind ~= "potion" then
        if kind == "throwable" then error("throw it with throw") end
        error("only potions and scrolls can be used from the bag; wear gear with equip")
    end
    if args.id and not same(args.id, me) then
        error("you can only drink a potion yourself; give it to them instead")
    end
    local combat = combatGate(me)
    local why = cannotPay(me, costs, combat)
    if why then error(why) end
    local before = { hp = (hp(me)), st = {}, res = C.resources(me), count = stackCount(item) }
    for _, s in ipairs(statusIds(me)) do before.st[s] = true end
    local j = newJob("use_item", { started_in_combat = true })
    Osi.Use(me, item, "BG3COOP_item_" .. j.id)
    j.data.wait_until = now() + 1500
    j.data.result_fn = function()
        local new = {}
        for _, s in ipairs(statusIds(me)) do if not before.st[s] then new[#new + 1] = s end end
        local h = hp(me)
        -- pay ourselves if the game did not (as with Osi.UseSpell)
        if combat then
            local r = C.resources(me)
            local paid = false
            for _, c in ipairs(costs) do
                local key = c.name
                if before.res[key] and r[key] and r[key][1] < before.res[key][1] then paid = true end
            end
            if not paid then pay(me, costs, combat) end
        end
        local left = inBag(me, item) and stackCount(item) or 0
        local r = { gained = statusNames(new), hp_change = h and before.hp and (h - before.hp) or nil, left = left }
        if left >= before.count and #new == 0 then r.effect = "nothing happened (it may not work on you now)" end
        return r
    end
    return { job = j.id }
end

function C.ops.equip(args)
    local me = agent()
    local item = args.item or error("item required")
    if not inBag(me, item) then error("that is not in your bag (see inventory)") end
    if inCombat(me) then error("change gear after the fight") end
    if args.remove then
        if not truthy(osi(Osi.IsEquipped, item)) then error("you are not wearing that") end
        Osi.Unequip(me, item)
    else
        if not equipSlot(entity(item)) then error("that cannot be worn or wielded") end
        Osi.Equip(me, item, 1, 1)
    end
    -- the swap shows up a moment later
    local j = newJob("equip")
    j.data.wait_until = now() + 800
    j.data.result_fn = function()
        local on = truthy(osi(Osi.IsEquipped, item))
        local r = { name = C.name(item), equipped = on }
        if on == (args.remove == true) then r.effect = "no change (it may need a proficiency or a free hand)" end
        return r
    end
    return { job = j.id }
end

-- Hand items to another party member (the human by default). Party members
-- share items at any distance outside combat, as in the game's own UI.
function C.ops.give(args)
    local me = agent()
    local to = args.to and findMember(args.to)
    if not args.to and not C.protagonist then to = human() end
    if args.to and not to then error("no party member matches " .. tostring(args.to)) end
    if not to then error("specify a different party member as recipient") end
    if same(to, me) then error("that is you") end
    if inCombat(me) then error("handing items over in combat is not supported; do it after the fight") end
    local given, skipped = {}, {}
    for _, it in ipairs(args.items or {}) do
        local n = C.name(it)
        if not inBag(me, it) then
            skipped[#skipped + 1] = n .. " (not in your bag)"
        elseif truthy(osi(Osi.IsEquipped, it)) then
            skipped[#skipped + 1] = n .. " (you are wearing it: unequip it first)"
        else
            local all = stackCount(it)
            local count = math.min(tonumber(args.count) or all, all)
            Osi.ToInventory(it, to, count, 1, 0)
            given[#given + 1] = count > 1 and (n .. " x" .. count) or n
        end
    end
    if #given == 0 then error("nothing given: " .. table.concat(skipped, "; ")) end
    return { given = given, to = C.name(to), skipped = #skipped > 0 and skipped or nil }
end

local function dialogFor(npc)
    local ok, rows = pcall(function() return Osi.DB_Dialogs:Get(npc, nil) end)
    if ok and rows and rows[1] then return rows[1][2] end
    ok, rows = pcall(function() return Osi.DB_Dialogs:Get(bare(npc), nil) end)
    if ok and rows and rows[1] then return rows[1][2] end
    return osi(Osi.GetDefaultDialog, npc)
end

function C.ops.talk(args)
    local me = agent()
    local npc = args.id or error("id required")
    if inCombat(me) then error("you cannot start a conversation in combat") end
    if inDialog(me) then error("you are already in a conversation: use dialogue") end
    local p, np = C.pos(me), C.pos(npc)
    if not np or not perceives(me, p, npc, np) then error("you cannot see them from here") end
    if truthy(osi(Osi.IsDead, npc)) then error("they are dead") end
    local dlg = dialogFor(npc)
    if not dlg then error("they have nothing to say") end
    if inDialog(npc) then error("they are already in a conversation") end
    local j = newJob("talk")
    j.data.then_fn = function(job)
        -- What the game does when a player clicks an NPC: it picks the dialogue that fits
        -- now, checks both are free and reveals a hidden speaker. The return value is
        -- unreliable; DialogState tells.
        C.starting = true
        if not pcall(Osi.QRY_SelectAndStartDialog, npc, me) then
            osi(Osi.QRY_StartDialog_Fixed, dlg, npc, me)
        end
        C.starting = nil
        job.data.dialog_wait = true
        local inst = dialogOf(me)
        if inst then
            noteDialog(inst, true)
            finish(job, "done", { dialogue = true, pos = C.pos(me) })
        end
    end
    setOff(j, me, npc, TALK_RANGE)
    return { job = j.id }
end

-- Trading: walk up to a merchant and open the game's trade window for the agent's
-- character, as the Trade button does (RequestTrade -> PROC_StartTrade: restocks the
-- merchant once per long rest, resets insults, ActivateTrade). The window opens on the
-- human's screen; client.lua reads and works it. Mode 1 = Trade (0 would be Barter).
local function tradeProblem(me, npc)
    if inCombat(me) then return "not in combat" end
    if inDialog(me) then return "you are in a conversation: finish it first" end
    local p, np = C.pos(me), C.pos(npc)
    if not np or not perceives(me, p, npc, np) then return "you cannot see them from here" end
    if truthy(osi(Osi.IsDead, npc)) then return "they are dead" end
    if not truthy(osi(Osi.CanTrade, npc)) then return "they do not trade (now)" end
    if truthy(osi(Osi.IsEnemy, me, npc)) then return "they are hostile" end
    if inDialog(npc) then return "they are in a conversation" end
    local h = human()
    if h and inDialog(h) then return "the human is in a conversation: the trade window would get in their way" end
    return nil
end

function C.ops.trade_check(args)
    local me = agent()
    local npc = args.id or error("id required")
    local why = tradeProblem(me, npc)
    if why then error(why) end
    return { name = C.name(npc), dist = r1(dist(C.pos(me), C.pos(npc))) }
end

-- The trade window lists a stack once, under the stack's own entity; an item that joined a
-- stack (InventoryStackMember.Stack) is found there.
function C.ops.trade_ids(args)
    local out = {}
    for _, u in ipairs(args.ids or {}) do
        local head = u
        pcall(function() head = entity(u).InventoryStackMember.Stack.Uuid.EntityUuid or u end)
        out[#out + 1] = head
    end
    return out
end

function C.ops.trade_open(args)
    local me = agent()
    local npc = args.id or error("id required")
    local why = tradeProblem(me, npc)
    if why then error(why) end
    local j = newJob("trade")
    j.data.goal, j.data.goal_id, j.data.within = C.pos(npc), npc, TALK_RANGE -- already there: stepJob goes on
    j.data.then_fn = function(job)
        if not pcall(Osi.PROC_StartTrade, me, npc, 1, "") then
            osi(Osi.PROC_GenTradeItems, me, npc)
            Osi.ActivateTrade(me, npc, 1, 1, "00000000-0000-0000-0000-000000000000", "")
        end
        finish(job, "done", { trading = C.name(npc), pos = C.pos(me) })
    end
    if dist(C.pos(me), C.pos(npc)) > TALK_RANGE then setOff(j, me, npc, TALK_RANGE) end
    return { job = j.id }
end

local function inCamp(uuid)
    local ok, rows = pcall(function() return Osi.DB_PlayerInCamp:Get(uuid) end)
    return ok and rows ~= nil and #rows > 0
end

-- Waypoints unlocked for the agent on this map. Ones on another map need a
-- region swap, which takes the whole party, so they are left out.
local function waypoints(me, locked_too)
    local out = {}
    local ok, lv = pcall(function() return Osi.DB_CurrentLevel:Get(nil) end)
    local level = ok and lv and lv[1] and lv[1][1]
    local ok2, rows = pcall(function() return Osi.DB_WaypointInfo:Get(nil, nil, nil, nil) end)
    if not (level and ok2 and rows) then return out end
    local p = C.pos(me)
    for _, r in ipairs(rows) do
        local id, trigger = r[2], r[4]
        local okU, got = pcall(function() return Osi.DB_WaypointUnlocked:Get(id, me) end)
        local unlocked = okU and got and #got > 0
        if (unlocked or locked_too) and osi(Osi.GetRegion, trigger) == level then
            local tp = C.pos(trigger)
            out[#out + 1] = { waypoint = tostring(id):gsub("^WAYP_", ""), id = id, trigger = trigger,
                locked = not unlocked or nil,
                dist = tp and p and r1(dist(p, tp)) or nil, dir = tp and p and dir(p, tp) or nil }
        end
    end
    table.sort(out, function(a, b) return (a.dist or 1e9) < (b.dist or 1e9) end)
    return out
end

-- Runs `go` as a travel job. The story's teleports bring the characters
-- chained to the traveller, so the agent unchains from the human first and
-- waits for that to land (it is not immediate).
local function travelJob(me, go, result_fn)
    local j = newJob("travel", { started_in_combat = inCombat(me) })
    local h = human()
    local unchained = h and not same(me, h) and truthy(osi(Osi.InSamePartyGroup, me, h)) or nil
    local function start()
        go()
        j.data.wait_until = now() + 3000
    end
    if unchained then
        osi(Osi.DetachFromPartyGroup, me)
        if same(me, C.agent) then C.detachedForControl = true end
        j.data.ready_fn = function() return not truthy(osi(Osi.InSamePartyGroup, me, h)) end
        j.data.go, j.data.not_ready = start, "could not unchain from the human's group"
    else
        start()
    end
    j.data.result_fn = function()
        local r = result_fn()
        r.region, r.unchained = osi(Osi.GetRegion, me), unchained
        return r
    end
    return { job = j.id }
end

-- Go to camp, or leave it, with the camp button's story procedures. The leave
-- button sends out everyone of the same user in camp, which here includes the
-- human's party, so the agent leaves through the per-character step
-- (PROC_Camp_Leave), which still picks the return spot.
local function travelCamp(me)
    local leaving = inCamp(me)
    if leaving then
        local ok, night = pcall(function() return Osi.DB_Camp_NightMode:Get(1) end)
        if ok and night and #night > 0 then error("it is night in camp; leave after the party wakes up") end
    elseif truthy(osi(Osi.QRY_Camp_IsPlayerBlockedFromTeleportToCamp, me)) then
        error("the game does not allow going to camp right now")
    end
    local from = C.pos(me)
    return travelJob(me, function()
        if leaving then Osi.PROC_Camp_Leave(me) else Osi.PROC_TeleportToFromCamp(me) end
    end, function()
        local here = inCamp(me)
        local r = { in_camp = here }
        if here == leaving and dist(from, C.pos(me)) < 5 then r.effect = "nothing happened" end
        return r
    end)
end

-- Fast travel as the waypoint map does: TeleportToWaypoint checks
-- QRY_GLO_BlockTeleportToWaypoint, then PROC_WaypointTeleportTo.
local function travelWaypoint(me, name)
    local list = waypoints(me)
    if not name or name == "" then
        local out = {}
        for _, w in ipairs(list) do out[#out + 1] = { waypoint = w.waypoint, dist = w.dist, dir = w.dir } end
        return { waypoints = out }
    end
    local want = tostring(name):gsub("^WAYP_", ""):lower()
    local wp
    for _, w in ipairs(list) do if w.waypoint:lower() == want then wp = w end end
    if not wp then error("no unlocked waypoint " .. tostring(name) .. " on this map (call travel waypoint without a name)") end
    if truthy(osi(Osi.QRY_WaypointTeleport_PlayerBlocked, me)) or
        truthy(osi(Osi.QRY_GLO_BlockTeleportToWaypoint, me, wp.trigger)) then
        error("the game does not allow fast travel right now")
    end
    return travelJob(me, function() Osi.PROC_WaypointTeleportTo(me, wp.trigger) end, function()
        local tp, p = C.pos(wp.trigger), C.pos(me)
        local r = { waypoint = wp.waypoint }
        if tp and p and dist(tp, p) > 10 then r.effect = "you did not arrive" end
        return r
    end)
end

-- Flee as the combat button does. The engine checks FleeCapability (Flags
-- name what stops it, e.g. EnemyTooClose within CurrentFleeDistance metres),
-- makes the character leave combat and raises FleeFromCombat; the story
-- (__Combat) then sends them to camp, else a waypoint, else the level start.
local function travelFlee(me)
    if not inCombat(me) then error("you are not in combat") end
    if not myTurn(me) then error("you can only flee on your turn") end
    local ok, rows = pcall(function() return Osi.DB_CombatFlee_BlockedFor:Get(me) end)
    if ok and rows and #rows > 0 then error("the game does not allow fleeing from this fight") end
    local fc = comp(entity(me), "FleeCapability")
    local flags = {}
    pcall(function()  -- a bitfield: its JSON form is the list of set flag names
        for _, f in ipairs(Ext.Json.Parse(Ext.Json.Stringify(fc.Flags))) do flags[#flags + 1] = tostring(f) end
    end)
    if #flags > 0 then
        if flags[1] == "EnemyTooClose" and fc.CurrentFleeDistance then
            error(string.format("an enemy is too close to flee: get more than %d m from every enemy (the nearest is %.1f m away)",
                math.floor(fc.CurrentFleeDistance + 0.5), fc.FleeDistance or 0))
        end
        error("the game does not allow fleeing now: " .. table.concat(flags, ", "))
    end
    local combat
    ok, rows = pcall(function() return Osi.DB_Is_InCombat:Get(nil, nil) end)
    for _, r in ipairs(ok and rows or {}) do if same(r[1], me) then combat = r[2] end end
    if not combat then error("could not tell which fight you are in") end
    return travelJob(me, function()
        Osi.FleeFromCombat(me, combat)
        Osi.LeaveCombat(me)
    end, function()
        return { fled = not inCombat(me), in_camp = inCamp(me) }
    end)
end

function C.ops.travel(args)
    local me = agent()
    local to = args.to or "camp"
    if to == "flee" then return travelFlee(me) end
    if to ~= "camp" and to ~= "waypoint" then error("unknown destination " .. tostring(to) .. " (camp, waypoint or flee)") end
    if to == "waypoint" and not args.waypoint then return travelWaypoint(me) end
    if inCombat(me) then error("you cannot travel in combat") end
    if inDialog(me) then error("finish the conversation first") end
    if to == "camp" then return travelCamp(me) end
    return travelWaypoint(me, args.waypoint)
end

------------------------------------------------------------------------
-- Exploration: the 10 m cells around where the party has been, per map. The
-- BG3 Co-op Memory mod keeps them in the save (mod/BootstrapServer.lua), so
-- they follow save loads and include play without the agent. Without the mod
-- this Lua state keeps its own record, lost on the next save load.
------------------------------------------------------------------------

local MEMORY_MOD = "addfead0-7a1a-46c3-942a-77c0348aeee3"
local CELL = 10
C.trail = C.trail or {}

local function memoryMod()
    local ok, loaded = pcall(Ext.Mod.IsModLoaded, MEMORY_MOD)
    return ok and loaded == true
end

local function visited(lv)
    if memoryMod() then
        local ok, t = pcall(function() return Ext.Vars.GetModVariables(MEMORY_MOD).Trail end)
        return ok and t and t[lv] or {}
    end
    return C.trail[lv] or {}
end

local function cellKey(x, z) return math.floor(x / CELL) .. "," .. math.floor(z / CELL) end

-- The mod's marking, for when it is not installed.
function C.noteTrail()
    if memoryMod() then return end
    for _, u in ipairs(party()) do
        local p, lv = C.pos(u), osi(Osi.GetRegion, u)
        if p and lv then
            local cells = C.trail[lv] or {}
            C.trail[lv] = cells
            local cx, cz = math.floor(p[1] / CELL), math.floor(p[3] / CELL)
            for dx = -1, 1 do
                for dz = -1, 1 do cells[(cx + dx) .. "," .. (cz + dz)] = 1 end
            end
        end
    end
end

-- Where the agent is: the map, the nearest waypoint (locked ones too, as landmarks) and
-- where the memory lives.
function C.area(me)
    local wp = waypoints(me, true)[1]
    return { region = osi(Osi.GetRegion, me), memory = memoryMod() and "save" or "session",
        waypoint = wp and { name = wp.waypoint, dist = wp.dist, dir = wp.dir, locked = wp.locked } or nil }
end

-- Frontiers: the nearest places the agent can walk to where ground nobody in the party has been
-- to begins. The pathfinder is asked for ways out in F.DIRS directions and two distances; a
-- way's first point in a cell the party has not been to is a frontier. Doors passed on the way and
-- floors climbed are told. Ways are kept a minute for the same spot (they do not change as the
-- party walks; which cells are new is worked out again each time), and each call spends at most
-- F.BUDGET_MS asking, so a first look somewhere new may give only part and finish next time.
-- SearchHorizon caps what one question costs: a way that cannot be found takes ~50 ms with the
-- game's default and ~13 ms with 8000, enough for walks of 60-80 m (measured 2026-11-04).
-- (one local for all of it: the main chunk is near Lua's limit of 200 locals)
local F = { DIRS = 16, RINGS = { 25, 50 }, BUDGET_MS = 120, KEEP = 3, APART = 12, SEARCH = { SearchHorizon = 8000 } }
C.frontCache = C.frontCache or {}

-- The floor at x, z nearest to height y (within 15 m), nil off the map or over a drop.
function F.floorNear(x, z, y)
    local ok, hs = pcall(Ext.Level.GetHeightsAt, x, z)
    local best
    for _, h in ipairs(ok and hs or {}) do
        if math.abs(h - y) < 15 and (not best or math.abs(h - y) < math.abs(best - y)) then best = h end
    end
    return best
end

function F.frontierAsks(p)
    local asks = {}
    for _, m in ipairs(F.RINGS) do
        for i = 0, F.DIRS - 1 do
            local a = i * 2 * math.pi / F.DIRS
            asks[#asks + 1] = { p[1] + math.cos(a) * m, p[3] + math.sin(a) * m, reach = m * 0.35 }
        end
    end
    return asks
end

-- Doors near a set of ways: { id, name, pos }.
function F.doorsNear(ways)
    local lo, hi = { math.huge, math.huge }, { -math.huge, -math.huge }
    for _, w in ipairs(ways) do
        for _, q in ipairs(w) do
            lo[1], lo[2] = math.min(lo[1], q[1]), math.min(lo[2], q[3])
            hi[1], hi[2] = math.max(hi[1], q[1]), math.max(hi[2], q[3])
        end
    end
    local out = {}
    local ok, all = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerItem")
    for _, e in ipairs(ok and all or {}) do
        local p = entityPos(e)
        if p and p[1] > lo[1] - 2 and p[1] < hi[1] + 2 and p[3] > lo[2] - 2 and p[3] < hi[2] + 2 then
            local si, door = comp(e, "ServerItem"), false
            pcall(function() door = si.IsDoor == true end)
            local u = door and entityUuid(e)
            if u then out[#out + 1] = { id = u, pos = p } end
        end
    end
    return out
end

-- Where a way first enters a cell the party has not been to: { pos, walk, upto = the way so far }.
function F.firstNew(pts, cells)
    local walked = 0
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local l = dist(a, b)
        local n = math.max(1, math.ceil(l / 2))
        for k = 1, n do
            local t = k / n
            local q = { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
            if walked + l * t >= 5 and not cells[cellKey(q[1], q[3])] then
                local upto = {}
                for j = 1, i - 1 do upto[j] = pts[j] end
                upto[#upto + 1] = q
                return { pos = q, walk = walked + l * t, upto = upto }
            end
        end
        walked = walked + l
    end
    return nil
end

function C.frontiers(me)
    local p, lv = C.pos(me), osi(Osi.GetRegion, me)
    if not (p and lv) then return { spots = {} } end
    local key = ("%s|%d,%d,%d"):format(lv, math.floor(p[1] / 2), math.floor(p[2] / 2), math.floor(p[3] / 2))
    local cache = C.frontCache
    if not (cache.key == key and now() - cache.at < 60000) then
        cache.key, cache.at, cache.ways, cache.asks, cache.doors = key, now(), {}, F.frontierAsks(p), nil
    end
    -- where the party stands counts as seen too (the trail may not have caught up)
    local cells = setmetatable({}, { __index = visited(lv) })
    for _, u in ipairs(party()) do
        local q = C.pos(u)
        if q then
            local cx, cz = math.floor(q[1] / CELL), math.floor(q[3] / CELL)
            for dx = -1, 1 do
                for dz = -1, 1 do cells[(cx + dx) .. "," .. (cz + dz)] = 1 end
            end
        end
    end
    -- the budget, doubled while nothing new has turned up yet
    local t0, anyNew = now(), false
    for _, w in ipairs(cache.ways) do anyNew = anyNew or F.firstNew(w, cells) ~= nil end
    while #cache.asks > 0 and now() - t0 < F.BUDGET_MS * (anyNew and 1 or 2) do
        local q = table.remove(cache.asks, 1)
        local near = false -- a way already ends close by: nothing new to learn
        for _, w in ipairs(cache.ways) do
            local last = w[#w]
            if flat(last, { q[1], 0, q[2] }) < q.reach * 0.6 then near = true end
        end
        local h = not near and F.floorNear(q[1], q[2], p[2])
        if h then
            local r = findPath(me, { q[1], h, q[2] }, q.reach, F.SEARCH)
            if r == nil then cache.asks = {} break end
            if r.found and #r.pts > 1 then
                cache.ways[#cache.ways + 1] = r.pts
                anyNew = anyNew or F.firstNew(r.pts, cells) ~= nil
            end
        end
    end
    local found = {}
    for _, w in ipairs(cache.ways) do
        local f = F.firstNew(w, cells)
        if f then found[#found + 1] = f end
    end
    table.sort(found, function(a, b) return a.walk < b.walk end)
    local keep = {}
    for _, f in ipairs(found) do
        local apart = true
        for _, k in ipairs(keep) do
            if flat(k.pos, f.pos) < F.APART and math.abs(k.pos[2] - f.pos[2]) < 3 then apart = false end
        end
        if apart and #keep < F.KEEP then keep[#keep + 1] = f end
    end
    if #keep > 0 and not cache.doors then
        local ways = {}
        for _, w in ipairs(cache.ways) do ways[#ways + 1] = w end
        cache.doors = F.doorsNear(ways)
    end
    local out = { more = #cache.asks > 0 or nil, spots = {} }
    for _, f in ipairs(keep) do
        local via = {}
        local named = {} -- a double door is two doors of one name
        for _, d in ipairs(cache.doors or {}) do
            -- a locked door is never passed (the way is found with CheckLockedDoors): one by
            -- the path is one the agent stands next to as she sets off
            local n = offPath(d.pos, f.upto) < 1.5 and not truthy(osi(Osi.IsLocked, d.id)) and C.name(d.id)
            if n and not named[n] then named[n] = true; via[#via + 1] = { id = d.id, name = n } end
        end
        local q = f.pos
        local dy = q[2] - p[2]
        out.spots[#out.spots + 1] = { pos = { r1(q[1]), r1(q[2]), r1(q[3]) }, dist = r1(flat(p, q)), dir = dir(p, q),
            walk_m = math.floor(f.walk + 0.5), via = #via > 0 and via or nil,
            dy = math.abs(dy) >= 2.5 and math.floor(dy + 0.5) or nil }
    end
    return out
end

------------------------------------------------------------------------
-- Exits in look: doors, ladders, stairs, portals and hatches, with whether the agent can get to
-- them and whether what lies past them is new. "Past" a door is a few metres on, away from the
-- agent; a ladder's or stairs' other end is the other floor at that spot. A frontier way through a
-- door also makes it new. Kept a minute per exit and spot.
------------------------------------------------------------------------

F.EXIT_WORDS = { { "stair", "stairs" }, { "ladder", "ladder" }, { "portal", "portal" }, { "teleport", "portal" },
    { "trapdoor", "hatch" }, { "hatch", "hatch" }, { "阶梯", "stairs" }, { "楼梯", "stairs" }, { "台阶", "stairs" },
    { "梯子", "ladder" }, { "传送", "portal" }, { "活板门", "hatch" }, { "暗门", "door" } }
F.EXITS_MAX, F.EXIT_REACH, F.PAST_M = 8, 2.5, 6

function F.exitKind(it)
    if it.kind == "door" or it.kind == "ladder" then return it.kind end
    if it.kind ~= "usable" and it.kind ~= "object" then return nil end
    local s = (tostring(it.name) .. " " .. tostring(osi(Osi.GetTemplate, it.id) or "")):lower()
    for _, w in ipairs(F.EXIT_WORDS) do
        if s:find(w[1], 1, true) then return w[2] end
    end
    return nil
end

-- Can the agent get to q: nil when it can, else why not.
function F.exitReach(me, q)
    for _, s in ipairs(goalSpots(me, q)) do
        local r = findPath(me, s, F.EXIT_REACH, F.SEARCH)
        if r == nil then return nil end
        if r.found then
            local last = r.pts[#r.pts]
            if flat(last, q) <= F.EXIT_REACH + 0.5 and math.abs(last[2] - q[2]) < 3 then return nil end
        end
    end
    local r = findPath(me, q, F.EXIT_REACH, { SearchHorizon = F.SEARCH.SearchHorizon, CheckLockedDoors = false })
    if r and r.found then
        local d = lockedDoorOn(r.pts)
        return "a locked door is in the way" .. (d and (" (" .. d.name .. ")") or "")
    end
    return "no way there on foot"
end

C.exitCache = C.exitCache or {}
-- The one other floor (2-12 m up or down) a ladder, stair or hatch at q leads to, or nil.
-- A ladder stands at its foot against a wall and its top landing is a metre or so off to
-- one side, so when straight above shows none the ground around it is tried.
function F.otherFloor(q)
    local function floorsAt(x, z, into)
        local ok, hs = pcall(Ext.Level.GetHeightsAt, x, z)
        for _, h in ipairs(ok and hs or {}) do
            local dy = math.abs(h - q[2])
            if dy >= 2 and dy <= 12 then
                local dup = false
                for _, g in ipairs(into) do if math.abs(g - h) < 0.7 then dup = true end end
                if not dup then into[#into + 1] = h end
            end
        end
        return into
    end
    local here = floorsAt(q[1], q[3], {})
    if #here == 1 then return here[1] end
    if #here > 1 then return nil end
    local around = {}
    for k = 0, 7 do
        local a = k * math.pi / 4
        floorsAt(q[1] + math.cos(a) * 1.2, q[3] + math.sin(a) * 1.2, around)
    end
    return #around == 1 and around[1] or nil
end

function C.exits(me, from, items, fronts)
    local lv = osi(Osi.GetRegion, me)
    local cells = visited(lv)
    local through = {}
    for _, f in ipairs(fronts and fronts.spots or {}) do
        for _, d in ipairs(f.via or {}) do through[bare(d.id)] = true end
    end
    local key = ("%s|%d,%d,%d"):format(tostring(lv), math.floor(from[1] / 2), math.floor(from[2] / 2), math.floor(from[3] / 2))
    local cache = C.exitCache
    if cache.key ~= key or now() - cache.at > 60000 then cache.key, cache.at, cache.rows = key, now(), {} end
    local n = 0
    for _, it in ipairs(items) do
        local kind = F.exitKind(it)
        if kind and n < F.EXITS_MAX then
            n = n + 1
            if kind ~= it.kind then it.kind = kind end
            local q = C.pos(it.id)
            local row = q and cache.rows[it.id]
            if q and not row then
                row = { why = F.exitReach(me, q) or false }
                if kind == "ladder" or kind == "stairs" or kind == "hatch" then
                    local h = F.otherFloor(q)
                    if h then row.dy = math.floor(h - q[2] + 0.5) end
                end
                if kind == "door" then
                    local dx, dz = q[1] - from[1], q[3] - from[3]
                    local l = math.sqrt(dx * dx + dz * dz)
                    if l > 0.5 then
                        local bx, bz = q[1] + dx / l * F.PAST_M, q[3] + dz / l * F.PAST_M
                        if F.floorNear(bx, bz, q[2]) then row.past = { bx, bz } end
                    end
                end
                cache.rows[it.id] = row
            end
            if row then
                it.unreachable = row.why or nil
                if row.dy then it.leads = (row.dy > 0 and "up " or "down ") .. math.abs(row.dy) .. " m" end
                local new = through[bare(it.id)] or (row.past and not cells[cellKey(row.past[1], row.past[2])])
                it.new_beyond = new or nil
            end
        end
    end
end

-- Without the mod, sample every 2 s so walks between tool calls count too. Runs once per Lua
-- state; the loop goes through C so a re-sent script takes over.
function C.trailLoop()
    pcall(C.noteTrail)
    pcall(function() Ext.Timer.WaitFor(2000, function() C.trailLoop() end) end)
end
if not C.trailRunning then
    C.trailRunning = true
    pcall(function() Ext.Timer.WaitFor(2000, function() C.trailLoop() end) end)
end

local function memoryVersion()
    local mods = rawget(_G, "Mods")
    return memoryMod() and mods and mods.BG3CoopMemory and tonumber(mods.BG3CoopMemory.VERSION) or nil
end

function C.ops.memory()
    local ok, info = pcall(Ext.Mod.GetMod, MEMORY_MOD)
    return { loaded = memoryMod(), version = memoryVersion(),
        name = ok and info and info.Info and info.Info.Name or nil }
end

------------------------------------------------------------------------
-- The agent's notes about the story. The memory mod (v2 on) keeps them in
-- the save; without it this Lua state does, until the next save load. The
-- bridge decides what goes in; here they are only read and written whole.
------------------------------------------------------------------------

local function notesInSave() return (memoryVersion() or 0) >= 2 end

-- Which playthrough this is: the mod's id, or the one it gives saves from before it.
local function campaign()
    if notesInSave() then
        local ok, c = pcall(function() return Ext.Vars.GetModVariables(MEMORY_MOD).Campaign end)
        if ok and c then return c end
    end
    local ok, rows = pcall(function() return Osi.DB_Avatars:Get(nil) end)
    local a = ok and rows and rows[1] and rows[1][1]
    return a and ("avatar-" .. bare(a)) or nil
end

function C.ops.notes_get()
    local list
    if notesInSave() then
        local ok, n = pcall(function() return Ext.Vars.GetModVariables(MEMORY_MOD).Notes end)
        list = ok and n or nil
    else
        list = C.notes
    end
    return { campaign = campaign(), store = notesInSave() and "save" or "session", notes = list or {} }
end

function C.ops.notes_put(args)
    local list = args.notes or {}
    if notesInSave() then
        Ext.Vars.GetModVariables(MEMORY_MOD).Notes = list
    else
        C.notes = list
    end
    return true
end

------------------------------------------------------------------------
-- The quest journal. The game keeps which quests are open in Osiris
-- databases; titles and step texts live in the quest file inside the
-- game's paks, read once per Lua state and only for the quests asked about.
-- Which steps are done is read from the story flags that DB_QuestDef_State
-- ties to each step, so a step reached any other way does not show.
------------------------------------------------------------------------

local QUEST_FILE = "Mods/GustavDev/Story/Journal/quest_prototypes.lsx"
C.questInfo = C.questInfo or {}

local function attr(block, id, kind)
    local key = 'id="' .. id .. '" type="' .. kind .. '" '
    local i = block:find(key, 1, true)
    if not i then return nil end
    return block:match((kind == "TranslatedString" and 'handle="([^"]*)"' or 'value="([^"]*)"'), i + #key)
end

local function readQuests(ids)
    local need = {}
    for _, q in ipairs(ids) do if C.questInfo[q] == nil then need[#need + 1] = q end end
    if #need == 0 then return end
    local ok, f = pcall(Ext.IO.LoadFile, QUEST_FILE, "data")
    for _, q in ipairs(need) do
        local info = false
        local i = ok and f and f:find('id="QuestID" type="FixedString" value="' .. q .. '"', 1, true)
        if i then
            local head = f:sub(math.max(1, i - 800), i)
            local s, k = nil, 0
            repeat k = head:find('<node id="Quest">', k + 1, true); s = k or s until not k
            local j = f:find('<node id="Quest">', i, true) or #f
            local block = f:sub(i, j)
            info = { title = loca(attr(block, "QuestTitle", "TranslatedString")),
                parent = attr(head:sub(s or 1), "ParentQuestID", "FixedString"),
                visible = attr(block, "QuestVisiblity", "bool") ~= "false", steps = {} }
            for step in block:gmatch('<node id="QuestStep">(.-)</node>') do
                local id = attr(step, "ID", "FixedString")
                if id then info.steps[#info.steps + 1] = { id = id, desc = attr(step, "Description", "TranslatedString") } end
            end
        end
        C.questInfo[q] = info
    end
end

local NULL_ENTITY = "NULL_00000000-0000-0000-0000-000000000000"

local function flagSet(flag, who)
    if truthy(osi(Osi.GetFlag, flag, NULL_ENTITY)) then return true end
    for _, p in ipairs(who) do
        if truthy(osi(Osi.GetFlag, flag, p)) then return true end
    end
    return false
end

function C.ops.quests()
    local closed, open = {}, {}
    local ok, rows = pcall(function() return Osi.DB_QuestIsClosed:Get(nil) end)
    for _, r in ipairs(ok and rows or {}) do closed[r[1]] = true end
    ok, rows = pcall(function() return Osi.DB_QuestIsAccepted:Get(nil) end)
    for _, r in ipairs(ok and rows or {}) do
        if not closed[r[1]] then open[#open + 1] = r[1] end
    end
    readQuests(open)
    local parents = {}
    for _, q in ipairs(open) do
        local info = C.questInfo[q]
        if info and info.parent and info.parent ~= "" then parents[#parents + 1] = info.parent end
    end
    readQuests(parents)
    local who = party()
    local out = {}
    for _, q in ipairs(open) do
        local info = C.questInfo[q]
        if info and info.visible and info.title then
            local done = {}
            local ok2, st = pcall(function() return Osi.DB_QuestDef_State:Get(nil, q, nil) end)
            for _, r in ipairs(ok2 and st or {}) do
                if not done[r[3]] and flagSet(r[1], who) then done[r[3]] = true end
            end
            local latest, n = nil, 0
            for _, s in ipairs(info.steps) do
                if done[s.id] then n = n + 1; latest = s end
            end
            local parent = info.parent ~= "" and info.parent or nil
            out[#out + 1] = { id = q, title = info.title, parent = parent and C.questInfo[parent] and C.questInfo[parent].title or parent,
                latest = latest and loca(latest.desc) or nil, steps_done = n }
        end
    end
    return { quests = out, me = C.agent and C.pos(C.agent) or nil }
end

------------------------------------------------------------------------
-- Spells
------------------------------------------------------------------------

local NAMED_RANGE = { MeleeMainWeaponRange = 1.5, MeleeOffHandWeaponRange = 1.5, RangedMainWeaponRange = 18,
    RangedOffHandWeaponRange = 18, ThrownObjectRange = 9 }

local function rangeOf(st)
    local r = st.TargetRadius
    if r == nil or r == "" then r = st.AreaRadius end
    if r == nil or r == "" then return nil end
    r = tonumber(r) or NAMED_RANGE[r] or r
    if r == 0 then return "self" end
    return r
end

local function costText(costs)
    local parts = {}
    for _, c in ipairs(costs) do
        if c.level then parts[#parts + 1] = "slot" .. c.level
        elseif c.name ~= "Movement" or c.amount > 0 then
            parts[#parts + 1] = (SHORT[c.name] or c.name) .. (c.amount ~= 1 and (" " .. c.amount) or "")
        end
    end
    return table.concat(parts, ", ")
end

-- The agent's actions: the spell container minus spells not prepared today.
-- Container children (Command_Halt under Command_Container) come as variants.
local function spellBook(me)
    local e = entity(me)
    local prepared = {}
    pcall(function()
        for _, s in ipairs(e.SpellBookPrepares.PreparedSpells) do prepared[s.OriginatorPrototype] = true end
    end)
    local rows, byId, children = {}, {}, {}
    pcall(function()
        for _, s in ipairs(e.SpellContainer.Spells) do
            local id = s.SpellId.OriginatorPrototype
            local parent = s.ContainerSpell
            if parent == "" then parent = nil end
            if not byId[id] then
                local row = { id = id, parent = parent,
                    needs_prep = tostring(s.PrepareType) == "RequiresPreparation" }
                byId[id] = row
                if parent then children[#children + 1] = row else rows[#rows + 1] = row end
            end
        end
    end)
    for _, c in ipairs(children) do
        local p = byId[c.parent]
        if p then p.variants = p.variants or {}; p.variants[#p.variants + 1] = c.id end
    end
    local function ready(row)
        if not row.needs_prep then return true end
        if prepared[row.id] then return true end
        local p = row.parent and byId[row.parent]
        return p ~= nil and (not p.needs_prep or prepared[p.id] == true)
    end
    return rows, byId, ready
end

local KINDS = { attack = { Damage = true }, heal = { Healing = true }, buff = { Buff = true },
    control = { Control = true, Debuff = true }, summon = { Summon = true }, utility = { Utility = true, None = true } }
-- the `kind` each row shows works as a filter too
KINDS.damage, KINDS.healing, KINDS.debuff = KINDS.attack, KINDS.heal, KINDS.control

function C.ops.spells(args)
    local me = agent()
    local combat = inCombat(me)
    local rows, _, ready = spellBook(me)
    local want = args.kind and KINDS[tostring(args.kind):lower()]
    if args.kind and not want then error("kind must be attack, heal, buff, control, summon or utility") end
    local out = {}
    for _, row in ipairs(rows) do
        local st = Ext.Stats.Get(row.id)
        if st and ready(row) and (not want or want[tostring(st.VerbalIntent)]) then
            local costs = parseCosts(st.UseCosts)
            local lvl = tonumber(st.Level) or 0
            local why = cannotPay(me, costs, combat)
            local up = {}
            if lvl > 0 then
                for L = lvl + 1, 9 do
                    if Ext.Stats.Get(row.id .. "_" .. L) and payer(me, { name = "SpellSlot", amount = 1, level = L }) then
                        up[#up + 1] = L
                    end
                end
            end
            out[#out + 1] = {
                spell = row.id, name = loca(st.DisplayName) or row.id, level = lvl > 0 and lvl or nil,
                kind = tostring(st.VerbalIntent):lower(), cost = costText(costs), range_m = rangeOf(st),
                usable = why == nil, why_not = why, upcast = #up > 0 and up or nil, variants = row.variants,
            }
            -- a shout has no target: it takes effect around the caster
            local area = tostring(st.SpellType) == "Shout" and tonumber(st.AreaRadius)
            if area and area > 0 then out[#out].range_m, out[#out].around_you_m = "self", area end
        end
    end
    return out
end

-- Prepared spells. Changes go through the game's own request queues
-- (SpellSystem.PlayerPrepareSpell / PlayerUnprepareSpell, what the spellbook
-- UI fills); the game applies them next frame. The engine does not check how
-- many a class may prepare (the UI does), so we check against the limit the
-- game keeps per class in SpellBookPrepares.ClassFallbackPreparedSpellCount
-- (e.g. Cleric 11 with WIS 18 -> 15; Paladin 7 with CHA 17 -> 10, not the
-- tabletop 6). Spells come from the spell container, grouped by
-- SpellId.ProgressionSource (the class), without container children.
local function prepBook(me)
    local e = entity(me)
    local limits = e.SpellBookPrepares.ClassFallbackPreparedSpellCount
    local chosen = {}
    for _, s in ipairs(e.PlayerPrepareSpell.Spells) do chosen[s.OriginatorPrototype] = Ext.Types.Serialize(s) end
    local classes, order, spell = {}, {}, {}
    for _, s in ipairs(e.SpellContainer.Spells) do
        local id = s.SpellId.OriginatorPrototype
        if tostring(s.PrepareType) == "RequiresPreparation" and (s.ContainerSpell or "") == "" and not spell[id] then
            local src = s.SpellId.ProgressionSource
            local c = classes[src]
            if not c then
                local max = tonumber(limits[src])
                local d = Ext.StaticData.Get(src, "ClassDescription")
                c = { src = src, name = d and (loca(d.DisplayName) or d.Name) or src, max = max, spells = {}, count = 0 }
                classes[src] = c
                order[#order + 1] = c
            end
            local row = { id = id, class = c, meta = Ext.Types.Serialize(s.SpellId), prepared = chosen[id] ~= nil }
            if row.prepared then c.count = c.count + 1 end
            c.spells[#c.spells + 1] = row
            spell[id] = row
        end
    end
    return order, spell, chosen
end

local function spellLevel(id)
    local st = Ext.Stats.Get(id)
    return st and tonumber(st.Level) or 0
end

local function prepLine(row)
    local st = Ext.Stats.Get(row.id)
    local lvl = spellLevel(row.id)
    return row.id .. " " .. (st and loca(st.DisplayName) or row.id) .. (lvl > 0 and (" (level " .. lvl .. ")") or "")
end

function C.ops.prepare(args)
    local me = agent()
    local order, spell, chosen = prepBook(me)
    local add, remove = args.add or {}, args.remove or {}
    if #add > 0 or #remove > 0 then
        if inCombat(me) then error("change prepared spells after the fight") end
        local delta, seen = {}, {}
        local unprep, prep = {}, {}
        for _, id in ipairs(remove) do
            local row = spell[id]
            if not row then error(id .. " is not a spell you prepare (see prepare)") end
            if not row.prepared then error(id .. " is not prepared") end
            if not seen[id] then
                seen[id] = true
                unprep[#unprep + 1] = chosen[id]
                delta[row.class] = (delta[row.class] or 0) - 1
            end
        end
        for _, id in ipairs(add) do
            local row = spell[id]
            if not row then error(id .. " is not a spell you can prepare (see prepare)") end
            if seen[id] then error(id .. " is in both add and remove") end
            if row.prepared then error(id .. " is already prepared") end
            seen[id] = true
            prep[#prep + 1] = row.meta
            delta[row.class] = (delta[row.class] or 0) + 1
        end
        for c, d in pairs(delta) do
            if c.max and c.count + d > c.max then
                error(c.name .. " can prepare " .. c.max .. " spells and has " .. c.count
                    .. (d > 0 and "; remove as many as you add" or ""))
            end
        end
        local sys = Ext.System.ServerSpell
        local ent = entity(me)
        if #unprep > 0 then sys.PlayerUnprepareSpell[ent] = unprep end
        if #prep > 0 then sys.PlayerPrepareSpell[ent] = prep end
        return { requested = true }
    end
    local out = {}
    for _, c in ipairs(order) do
        local yes, no = {}, {}
        local rows = {}
        for i, row in ipairs(c.spells) do rows[i] = { row = row, level = spellLevel(row.id), i = i } end
        table.sort(rows, function(a, b) if a.level ~= b.level then return a.level < b.level end return a.i < b.i end)
        for _, r in ipairs(rows) do
            local row = r.row
            local list = row.prepared and yes or no
            list[#list + 1] = prepLine(row)
        end
        out[#out + 1] = { class = c.name, prepared_count = c.count, max = c.max, prepared = yes, not_prepared = no }
    end
    return { classes = out }
end

function C.ops.cast(args)
    local me = agent()
    local spell = args.spell or error("spell required")
    local _, byId, ready = spellBook(me)
    local row = byId[spell]
    if not row then error("you do not have " .. spell .. " (see spells)") end
    if not ready(row) then error(spell .. " is not prepared today") end
    if row.variants then
        error(spell .. " needs a choice: cast one of " .. table.concat(row.variants, ", "))
    end
    local castId = spell
    if args.level then
        local L = tonumber(args.level)
        local base = Ext.Stats.Get(spell)
        if not (base and L and L >= (tonumber(base.Level) or 0)) then error("cannot cast " .. spell .. " at level " .. tostring(args.level)) end
        if L > (tonumber(base.Level) or 0) then
            castId = spell .. "_" .. L
            if not Ext.Stats.Get(castId) then error(spell .. " cannot be upcast") end
        end
    end
    local st = Ext.Stats.Get(castId)
    local opt = {}
    if st and tostring(st.SpellType) == "Shout" then opt = shoutCheck(me, st, args) end
    if st and args.id and raisesDead(castId) then
        -- Revivify and the Deva's: as with a revive scroll, the fallen one is the second target
        local who = args.id
        local name = C.name(who)
        opt.second = who
        opt.landing = args.pos and { tonumber(args.pos[1]), tonumber(args.pos[2]), tonumber(args.pos[3]) } or nil
        local why = reviveProblem(me, who, opt.landing)
        if why then error(why) end
        opt.failed = "the game would not bring them back"
        opt.report = function() return { revived = name, hp = (hp(who)) } end
        return startCast(me, castId, parseCosts(st.UseCosts), { id = who }, opt)
    end
    if st and args.id and C.groundOnly(st) then
        -- a summon (Flaming Sphere, Planar Ally) goes on the ground: aimed at a character, the
        -- game walked the caster off somewhere first (4.2 m, 2026-11-04)
        if not perceives(me, C.pos(me), args.id, C.pos(args.id)) then error("you cannot see that target") end
        local spot = C.spotBy(me, args.id, tonumber(st.TargetRadius))
        if not spot then error("this spell goes on the ground, and there is no free ground next to " .. C.name(args.id)
            .. " within its range: give x/y/z instead") end
        local note = "this spell goes on the ground: cast at the free spot next to " .. C.name(args.id)
        args.id, args.pos = nil, spot
        opt.report = function() return { note = note, at = { r1(spot[1]), r1(spot[2]), r1(spot[3]) } } end
    end
    if st and args.pos and C.hasFlag(st, "IsJump") then
        -- with the cast checks on, the game walked her a way before jumping (all 9 m of movement
        -- gone, 2026-11-05); without them it jumps straight there, so range and ground are ours
        local to = { tonumber(args.pos[1]), tonumber(args.pos[2]), tonumber(args.pos[3]) }
        local range, mp = C.jumpRange(me, st), C.pos(me)
        if range <= 0 then error("you are carrying too much to jump") end
        if mp and dist(mp, to) > range + 0.1 then
            error(("that is %.1f m away and you can jump %.1f m"):format(dist(mp, to), range))
        end
        if not C.groundNear(to) then error("there is no ground to land on at that spot") end
        C.provokeCheck(me, to, args)
        opt.keepChecks = true
    end
    -- the game stepped the caster about before a summon even with the spot in range (1.0 m and
    -- 0.45 m, the second into an opportunity attack, 2026-11-05); from the UI it does not move
    if st and C.groundOnly(st) then opt.noMove = true end
    return startCast(me, castId, parseCosts(st and st.UseCosts), args, opt)
end


-- Osi.UseSpell queues a request that skips attack rolls, saving throws and the
-- cast checks (range, sight, silence). A tick or two later it waits in
-- OsirisCastRequests, where those flags can be cleared so the game rolls and
-- checks as for a cast from the UI. IgnoreHasSpell stays: without it the cast
-- fails. A scroll is named as the request's item so the game uses it up;
-- `consumed` then runs. Throws and revivals have a second target (what is
-- thrown, where the revived land) and let the game check both targets. The
-- game still spends no resources on these requests.
local DROP_OPTIONS = { IgnoreSpellRolls = true, IgnoreCastChecks = true }
local CHECKED_DROP = { IgnoreSpellRolls = true, IgnoreCastChecks = true, IgnoreTargetChecks = true }

local function playByTheRules(me, castId, opt, consumed)
    local tries, action = 0, C.actionRevision
    local function look()
        if action ~= C.actionRevision then return end
        tries = tries + 1
        local found = false
        pcall(function()
            for _, r in ipairs(Ext.System.ServerCastRequest.OsirisCastRequests) do
                local sp = r.Spell
                if same(r.Caster.Uuid.EntityUuid, me) and (sp.Prototype == castId or sp.OriginatorPrototype == castId) then
                    found = true
                    local drop = opt.keepChecks and {} or opt.checkTargets and CHECKED_DROP or DROP_OPTIONS
                    local opts = {}
                    for _, o in ipairs(r.CastOptions) do
                        if not drop[o] then opts[#opts + 1] = o end
                    end
                    if opt.noMove then opts[#opts + 1] = "NoMovement" end
                    if opt.item then
                        r.Item = entity(opt.item)
                        opts[#opts + 1] = "DestroySource"
                    end
                    -- Osi.UseSpell(caster, spell, target, second) fills this in; at a position we do
                    if opt.landing then
                        r.Targets[1].Target2 = { Position = opt.landing }
                    elseif opt.second then
                        r.Targets[1].Target2 = { Target = entity(opt.second) }
                    end
                    r.CastOptions = opts
                    if opt.item then consumed() end
                    return
                end
            end
        end)
        -- a request with a second target shows up a tick later than others
        if not found and tries < 10 then pcall(Ext.Timer.WaitFor, 0, look) end
    end
    pcall(function() Ext.Timer.WaitFor(0, look) end)
end

-- Friendly fire: party members a harmful area spell would also catch. Skips
-- spells that spare allies by themselves (conditions that leave out allies,
-- Sculpt Spells, auras on the caster such as Spirit Guardians). The shapes
-- follow the stats: a radius around the target (or the caster for a shout),
-- or a cone or strip from the caster towards the target.
local HARMFUL_INTENT = { Damage = true, Control = true, Debuff = true }
local AREA_MARGIN = 0.5 -- metres: a body caught at the edge
-- creature types a spell may be limited to (Turn Undead): only allies of that type count
local CREATURE_TAGS = { "UNDEAD", "FIEND" }

local function tagged(uuid, name)
    local found = false
    pcall(function()
        for _, g in ipairs(entity(uuid).Tag.Tags) do
            local ok, t = pcall(Ext.StaticData.Get, g, "Tag")
            if ok and t and t.Name == name then found = true; return end
        end
    end)
    return found
end
C.tagged = tagged

local function stat(st, k)
    local ok, v = pcall(function() return st[k] end)
    if ok then return v end
    return nil
end

-- Living party members (but the agent) for whom inside(pos) holds; with `only`
-- tags, just those that carry one of them.
local function alliesInside(me, inside, only)
    local hit = {}
    for _, u in ipairs(party()) do
        if not same(u, me) and not truthy(osi(Osi.IsDead, u)) then
            local p = C.pos(u)
            local fits = #only == 0
            for _, tag in ipairs(only) do fits = fits or tagged(u, tag) end
            if p and fits and inside(p) then hit[#hit + 1] = C.name(u) end
        end
    end
    return #hit > 0 and hit or nil
end

local function alliesInArea(me, castId, args)
    local st = Ext.Stats.Get(castId)
    if not st or not HARMFUL_INTENT[tostring(stat(st, "VerbalIntent"))] then return nil end
    local cond = tostring(stat(st, "AoEConditions") or "")
    if cond == "" then cond = tostring(stat(st, "TargetConditions") or "") end
    if cond:find("SculptSpells", 1, true) and truthy(osi(Osi.HasPassive, me, "SculptSpells")) then return nil end
    cond = cond:gsub("not %(HasPassive%('SculptSpells'.-%) and Ally%(%)%)", "")
    if cond:find("not Ally()", 1, true) or cond:gsub("not Enemy%(%)", ""):find("Enemy()", 1, true) then return nil end
    local only = {}
    for _, tag in ipairs(CREATURE_TAGS) do
        local pat = "Tagged%('" .. tag .. "'%)"
        if cond:find(pat) and not cond:find("not " .. pat) then only[#only + 1] = tag end
    end
    local kind = tostring(stat(st, "SpellType"))
    local from = C.pos(me)
    local at = args.id and C.pos(args.id) or args.pos and { tonumber(args.pos[1]), tonumber(args.pos[2]), tonumber(args.pos[3]) }
    local inside
    if kind == "Zone" then
        if not (from and at) then return nil end
        local range = tonumber(stat(st, "Range")) or 0
        local cone = tostring(stat(st, "Shape")) == "Cone"
        local half = math.rad((tonumber(stat(st, "Angle")) or 0) / 2)
        local width = tonumber(stat(st, "Base")) or 0
        local fx, fz = at[1] - from[1], at[3] - from[3]
        local fl = math.sqrt(fx * fx + fz * fz)
        if fl < 0.01 then return nil end
        fx, fz = fx / fl, fz / fl
        inside = function(p)
            local dx, dz = p[1] - from[1], p[3] - from[3]
            local along, across = dx * fx + dz * fz, math.abs(dx * fz - dz * fx)
            if along < -AREA_MARGIN or along > range + AREA_MARGIN then return false end
            if cone then return along > 0 and math.atan(math.max(0, across - AREA_MARGIN), along) <= half end
            return across <= width / 2 + AREA_MARGIN
        end
    else
        local r = tonumber(stat(st, "AreaRadius")) or 0
        if kind == "Projectile" then r = math.max(r, tonumber(stat(st, "ExplodeRadius")) or 0) end
        if r <= 0 then return nil end
        if kind == "Shout" then
            if cond:match("^%s*Self%(%)%s*$") then return nil end
            at = from
        end
        at = at or from
        if not at then return nil end
        inside = function(p) return dist(p, at) <= r + AREA_MARGIN end
    end
    return alliesInside(me, inside, only)
end
C.alliesInArea = alliesInArea

-- Whether a spell restores hit points. VerbalIntent says little: Radiance of the Dawn, which
-- burns enemies, is "Healing" too. The spell's functors say it (RegainHitPoints).
function C.heals(st)
    local found = false
    for _, k in ipairs({ "SpellProperties", "SpellSuccess" }) do
        pcall(function()
            for _, g in ipairs(stat(st, k) or {}) do
                for _, f in ipairs(g.Functors or {}) do
                    if tostring(f.TypeId) == "RegainHitPoints" then found = true end
                end
            end
        end)
    end
    return found
end

-- Shouts (Mass Healing Word, Spirit Guardians...) take effect around the caster within
-- AreaRadius and have no target: the game does not walk anywhere for them. A target the
-- agent passes is dropped and the result says so; a healing shout that would reach no one
-- who needs it is refused, naming how far off the party is.
function shoutCheck(me, st, args)
    local r = tonumber(stat(st, "AreaRadius")) or 0
    local note
    if args.id or args.pos then
        note = "this spell has no target (it takes effect around you" .. (r > 0 and (" within " .. r .. " m") or "")
            .. "), so the target you gave was not used"
        args.id, args.pos = nil, nil
    end
    if r <= 0 then return { shout = true, report = function() return { note = note } end } end
    local mypos = C.pos(me)
    local function around()
        local inside, outside = {}, {}
        local ok, list = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerCharacter")
        for _, e in ipairs(ok and list or {}) do
            local u, p = entityUuid(e), entityPos(e)
            local d = u and p and mypos and dist(mypos, p)
            if d and not same(u, me) and not isDead(u) and not hidden(u) and d <= SIGHT then
                local rel = relation(me, u)
                if d <= r + AREA_MARGIN then inside[#inside + 1] = { u = u, text = C.name(u) .. " (" .. rel .. ")" }
                elseif rel == "party" then outside[#outside + 1] = C.name(u) .. " " .. r1(d) .. " m away" end
            end
        end
        return inside, outside
    end
    local inside, outside = around()
    if C.heals(st) then
        -- a scratch (85/86) is not worth a healing slot
        local function hurt(u) local h, m = hp(u); return isDowned(u) or (h and m and h < 0.9 * m) end
        local reach = hurt(me)
        for _, x in ipairs(inside) do if isParty(x.u) and hurt(x.u) then reach = true end end
        if not reach then
            error("no hurt party member is within " .. r .. " m of you, where this spell heals"
                .. (#outside > 0 and (" (" .. table.concat(outside, ", ") .. ")") or "")
                .. ": move closer first, then cast it")
        end
    end
    local around = {}
    for _, x in ipairs(inside) do
        if not C.heals(st) or isParty(x.u) then around[#around + 1] = x.u end
    end
    return { shout = true, around = around, report = function()
        local names = {}
        -- a healing shout heals the party: enemies around do not belong on the list
        local heals = C.heals(st)
        for _, x in ipairs(inside) do
            if not heals or isParty(x.u) then names[#names + 1] = x.text end
        end
        return { note = note, around_you = names, radius_m = r }
    end }
end

-- How far the character can jump: the spell's range, 1 m more per 2 Strength above 10 (bg3.wiki),
-- jump boosts, halved when encumbered, none when heavily encumbered.
function C.jumpRange(me, st)
    if truthy(osi(Osi.HasActiveStatus, me, "HEAVILY_ENCUMBERED")) then return 0 end
    local e = entity(me)
    local str = 10
    pcall(function() str = e.Stats.Abilities[2] end)
    local r = (tonumber(rangeOf(st)) or 4.5) + math.max(0, math.floor((str - 10) / 2))
    pcall(function() r = r + (tonumber(e.JumpMaxDistanceBonusBoost.DistanceBonus) or 0) end)
    pcall(function() r = r * (tonumber(e.JumpMaxDistanceMultiplierBoost.Amount) or 1) end)
    if truthy(osi(Osi.HasActiveStatus, me, "ENCUMBERED")) then r = r / 2 end
    return r
end

-- Ground within a metre and a half of `p`'s height.
function C.groundNear(p)
    local ok, hs = pcall(Ext.Level.GetHeightsAt, p[1], p[3])
    for _, h in ipairs(ok and hs or {}) do
        if math.abs(h - p[2]) < 1.5 then return true end
    end
    return false
end

-- Enemies whose opportunity attack leaving for `dest` would draw: in the fight, within their melee
-- reach of `me` now and not at `dest`, with a reaction left and not incapacitated. Nil out of
-- combat, after Disengage, or when nobody would strike. A jump out of reach provokes as a walk does,
-- and the blow cut the jump off (2026-11-05).
local REACH_M = 2.5 -- centre to centre: 1.5 m of reach plus two bodies
function C.provokers(me, dest)
    if not (dest and inCombat(me)) or truthy(osi(Osi.HasActiveStatus, me, "DISENGAGE")) then return nil end
    local mp = C.pos(me)
    if not mp then return nil end
    local out = {}
    local ok, list = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerCharacter")
    for _, e in ipairs(ok and list or {}) do
        local u, p = entityUuid(e), entityPos(e)
        if u and p and dist(p, mp) <= REACH_M and dist(p, dest) > REACH_M and truthy(osi(Osi.IsEnemy, me, u))
            and inCombat(u) and not isDead(u) and not isDowned(u)
            and not truthy(osi(Osi.HasActiveStatusWithGroup, u, "SG_Incapacitated")) then
            local reaction
            eachResource(u, function(n, r) if n == "ReactionActionPoint" then reaction = (reaction or 0) + (tonumber(r.Amount) or 0) end end)
            if reaction ~= 0 then out[#out + 1] = C.name(u) end
        end
    end
    return #out > 0 and out or nil
end

-- Refused once: the same call again from the same spot, with the same enemies about, goes ahead
-- (a ranged character with an enemy on it may have to take the blow and get away).
function C.provokeCheck(me, dest, args, why)
    if args.even_if_provoking then return end
    local who = C.provokers(me, dest)
    if not who then return end
    local mp = C.pos(me) or { 0, 0, 0 }
    local function at(p) return ("%d,%d,%d"):format(math.floor(p[1] + 0.5), math.floor(p[2] + 0.5), math.floor(p[3] + 0.5)) end
    local key = table.concat(who, ",") .. "@" .. at(mp) .. ">" .. at(dest)
    if C.provokeWarned == key then
        C.provokeWarned = nil
        return
    end
    C.provokeWarned = key
    error("leaving " .. table.concat(who, ", ") .. "'s reach draws an opportunity attack" .. (why or " (a jump too)") .. ":"
        .. " Disengage first (Shout_Disengage), or a teleport. To take the blow and go anyway, make the same call again")
end

-- Spells that cannot be cast at a character, only at the ground (summons: CannotTargetCharacter,
-- with "not Character()" in their conditions).
function C.hasFlag(st, flag)
    local f = stat(st, "SpellFlags")
    if type(f) == "table" then
        for _, x in ipairs(f) do if x == flag then return true end end
        return false
    end
    return tostring(f or ""):find(flag, 1, true) ~= nil
end

function C.groundOnly(st)
    -- a jump also has CannotTargetCharacter, but it is movement: NoMovement made the game refuse it
    return C.hasFlag(st, "CannotTargetCharacter") and not C.hasFlag(st, "IsJump")
end

-- Free ground next to a character, on the caster's side of it and within `range` of the caster.
-- Sight does not matter: a summon goes on any ground in range a body can stand on.
function C.spotBy(me, u, range)
    local mp, tp = C.pos(me), C.pos(u)
    if not (mp and tp) then return nil end
    local dx, dz = mp[1] - tp[1], mp[3] - tp[3]
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 0.01 then dx, dz, l = 1, 0, 1 end
    dx, dz = dx / l, dz / l
    local bodies = {}
    local ok, list = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerCharacter")
    for _, e in ipairs(ok and list or {}) do
        local p = entityPos(e)
        if p and dist(p, tp) < 4 then bodies[#bodies + 1] = p end
    end
    for _, a in ipairs({ 0, 30, -30, 60, -60, 90, -90 }) do
        local c, s_ = math.cos(math.rad(a)), math.sin(math.rad(a))
        local x, z = tp[1] + 1.5 * (dx * c - dz * s_), tp[3] + 1.5 * (dx * s_ + dz * c)
        local y = groundAt(x, z, tp[2])
        local spot = y and { x, y, z }
        local free = spot ~= nil and (not range or dist(mp, spot) <= range)
        for _, p in ipairs(bodies) do
            if free and dist(p, spot) < 0.9 then free = false end
        end
        if free then return spot end
    end
    return nil
end

-- Thrown grenades: their effect is not in any stats or template field the
-- script can read, only the surface some templates leave (CreateSurface radius).
local GRENADE_RADIUS = 4.0 -- metres when the template says nothing: the largest common grenade
local HARMLESS_GRENADES = { GRN_Spore_Haste = true, ALCH_Solution_Grenade_SporesHaste = true,
    ALCH_Solution_Grenade_Light = true }
local GRENADE_ONLY = { OBJ_HolyWaterFlask = { "UNDEAD", "FIEND" } }

local function surfaceRadius(item)
    local r
    pcall(function()
        local tpl = Ext.Template.GetTemplate(bare(osi(Osi.GetTemplate, item)))
        for _, a in ipairs(tpl.OnDestroyActions) do
            local ok, x = pcall(function() return tostring(a.Type) == "CreateSurface" and a.Radius end)
            if ok and tonumber(x) and tonumber(x) > (r or 0) then r = tonumber(x) end
        end
    end)
    return r
end

local function alliesInBlast(me, item, args)
    local sid, st = statsOf(entity(item))
    local ok, use = pcall(function() return st.ItemUseType end)
    if not (ok and tostring(use) == "Grenade") or HARMLESS_GRENADES[sid] then return nil end
    local at = args.id and C.pos(args.id) or args.pos and { tonumber(args.pos[1]), tonumber(args.pos[2]), tonumber(args.pos[3]) }
    if not at then return nil end
    local r = surfaceRadius(item) or GRENADE_RADIUS
    return alliesInside(me, function(p) return dist(p, at) <= r + AREA_MARGIN end, GRENADE_ONLY[sid] or {})
end
C.alliesInBlast = alliesInBlast

-- Casts castId at args.id / args.pos / self and pays `costs` once the game
-- reports the cast. opt (all optional): `after` runs then too, unless the game
-- used up `item` (the scroll being read) itself; `second` is the second target
-- (what Throw_Throw throws) and `landing` a position for it; `checkTargets` lets
-- the game check the targets; `report` adds to the job's result; `failed`
-- explains a refused cast.
function startCast(me, castId, costs, args, opt)
    opt = opt or {}
    local combat = combatGate(me)
    local why = cannotPay(me, costs, combat)
    if why then error(why) end
    local p = C.pos(me)
    if args.id and not perceives(me, p, args.id, C.pos(args.id)) then error("you cannot see that target") end
    -- out of range the game walks the caster up first, which can leave an enemy's reach
    local st = Ext.Stats.Get(castId)
    local range = st and tonumber(rangeOf(st))
    local tp = args.id and C.pos(args.id)
        or args.pos and { tonumber(args.pos[1]), tonumber(args.pos[2]), tonumber(args.pos[3]) }
    if range and tp and p and not opt.second and dist(p, tp) > range then
        local d = dist(p, tp)
        local k = (d - range + 0.5) / d
        C.provokeCheck(me, { p[1] + (tp[1] - p[1]) * k, p[2] + (tp[2] - p[2]) * k, p[3] + (tp[3] - p[3]) * k },
            args, (" (the target is %.1f m away, out of the %g m range: the game would walk you up first)"):format(d, range))
    end
    if not opt.second and not args.even_if_allies then
        local hit = alliesInArea(me, castId, args)
        if hit then
            error("that would also hit " .. table.concat(hit, ", ") ..
                " (in the area): aim elsewhere, or cast again with even_if_allies if you mean it")
        end
    end
    local j = newJob("cast", { started_in_combat = true, cast = true, from = p, jump = opt.keepChecks }) -- a cast may start the fight itself
    if C.listening.CastedSpell then
        local pend = { job = j.id, caster = me, spell = castId, costs = costs, combat = combat, after = opt.after,
            report = opt.report, failed = opt.failed, spot = not args.id, around = opt.around }
        C.pending = pend
        playByTheRules(me, castId, opt, function() pend.after = nil end)
    else
        -- no cast events on this build: pay up front and give it time
        pay(me, costs, combat)
        if opt.after then pcall(opt.after) end
        j.data.cast, j.data.wait_until, j.data.result_fn = nil, now() + 2500, opt.report
    end
    C.actedAt = now()
    if args.id then
        if opt.second then
            Osi.UseSpell(me, castId, args.id, opt.second)
        else
            Osi.UseSpell(me, castId, args.id)
        end
    elseif args.pos then
        Osi.UseSpellAtPosition(me, castId, tonumber(args.pos[1]), tonumber(args.pos[2]), tonumber(args.pos[3]))
    elseif opt.shout and p then
        -- UseSpell(me, shout, me) took effect on the caster alone (Mass Healing Word healed only
        -- Shadowheart, 2026-11-04); at the caster's feet the area is what counts
        Osi.UseSpellAtPosition(me, castId, p[1], p[2], p[3])
    else
        Osi.UseSpell(me, castId, me)
    end
    return { job = j.id }
end

-- Throw an item from the bag, an object or body on the ground, or a character,
-- as the game's Throw action does (Larian's scripts call it the same way). The
-- game decides whether it can be thrown (weight, worn gear), rolls to hit and
-- applies damage and the item's effects (grease, flash).
function C.ops.throw(args)
    local me = agent()
    local thrown = args.item or error("item required")
    if same(thrown, me) then error("you cannot throw yourself") end
    if args.id and same(args.id, thrown) then error("throw it at something else") end
    if not args.id and not args.pos then error("say what to throw it at: a target or x/y/z") end
    if not inBag(me, thrown) and not perceives(me, C.pos(me), thrown, C.pos(thrown)) then
        error("you cannot see that item")
    end
    if not args.even_if_allies then
        local hit = alliesInBlast(me, thrown, args)
        if hit then
            error("that would also hit " .. table.concat(hit, ", ") ..
                " (in the blast): aim elsewhere, or throw again with even_if_allies if you mean it")
        end
    end
    local st = Ext.Stats.Get("Throw_Throw")
    local name = C.name(thrown)
    local hp0 = args.id and hp(args.id)
    -- the game splits one off a stack and throws that, so count the bag by template
    local template = inBag(me, thrown) and osi(Osi.GetTemplate, thrown)
    local function count() return tonumber(osi(Osi.TemplateIsInInventory, template, me)) or 0 end
    local before = template and count()
    local function report()
        local r = { thrown = name, at = args.id and C.name(args.id) or args.pos }
        local h = args.id and hp(args.id)
        if h and hp0 then r.target_hp_change = h - hp0 end
        if template then
            r.left = count()
            if r.left >= before then r.effect = "it is still in your bag" end
        end
        return r
    end
    return startCast(me, "Throw_Throw", parseCosts(st and st.UseCosts), args, { second = thrown, checkTargets = true,
        report = report,
        failed = "the game would not throw it (too heavy for you, worn, fixed in place, or the target is not valid)" })
end

-- Hide (sneak) or stop sneaking. Hide is a plain action out of combat; in
-- combat it costs an action, or a bonus action for those who have the bonus
-- Hide (rogues, goblins). Osi.UseSpell spends nothing, so the cost is paid
-- here. Refused when someone has the agent in view: they would spot it at once.
function C.ops.sneak(args)
    local me = agent()
    if args.off then
        if sneaking(me) then
            C.sneakOff = now()
            osi(Osi.RemoveStatus, me, SNEAKING)
        end
        return { sneaking = sneaking(me) }
    end
    if sneaking(me) then return { sneaking = true, note = "already sneaking" } end
    local combat = combatGate(me)
    local p = C.pos(me)
    local seen = seenAt(aim(watchers(me, p)), p)
    if #seen > 0 and not args.anyway then
        error(whoSees(seen) .. " would spot you at once (you are in their view): get out of it first; "
            .. "sight lists nearby spots nobody watches")
    end
    local spell, costs = "Shout_Hide", {}
    if combat then
        local _, byId = spellBook(me)
        local bonus = byId.Shout_Hide_BonusAction and parseCosts(Ext.Stats.Get("Shout_Hide_BonusAction").UseCosts)
        if bonus and not cannotPay(me, bonus, true) then
            spell, costs = "Shout_Hide_BonusAction", bonus
        else
            costs = parseCosts(Ext.Stats.Get("Shout_Hide").UseCosts)
            local why = cannotPay(me, costs, true)
            if why then error(why) end
        end
        pay(me, costs, true)
    end
    local j = newJob("sneak", { started_in_combat = true })
    Osi.UseSpell(me, spell, me)
    -- the game may spot the agent a moment later, so look again after a while
    j.data.wait_until = now() + 800
    j.data.result_fn = function()
        local q = C.pos(me)
        local by = q and whoSees(seenAt(aim(watchers(me, q)), q)) or ""
        return { sneaking = sneaking(me), seen_by = by ~= "" and by or nil }
    end
    return { job = j.id }
end

function C.ops.end_turn()
    local me = agent()
    local tbm = turnBasedMode(me)
    if not inCombat(me) and not tbm then error("not in combat") end
    if not tbm and not myTurn(me) then error("it is not your turn") end
    Osi.EndTurn(me)
    -- what the End Turn button sets: a shared turn only moves on once every
    -- member has asked to end it, and Osi.EndTurn alone does not ask
    pcall(function()
        local tb = entity(me).TurnBased
        tb.RequestedEndTurn = true
        entity(me):Replicate("TurnBased")
    end)
    if type(C.turn.ended) ~= "table" then C.turn.ended = {} end
    C.turn.ended[bare(me)] = true
    local waiting = {}
    for _, p in ipairs(party()) do
        if not same(p, me) then
            pcall(function()
                local tb = entity(p).TurnBased
                if tb.IsActiveCombatTurn and not tb.RequestedEndTurn then waiting[#waiting + 1] = C.name(p) end
            end)
        end
    end
    local r = { ended = true }
    if #waiting > 0 then
        r.note = "you share this turn with " .. table.concat(waiting, ", ") .. "; it goes on when they end theirs"
    end
    return r
end

function C.stopActions()
    C.actionRevision = (C.actionRevision or 0) + 1
    local actors = {}
    if C.actor or C.agent then actors[C.actor or C.agent] = true end
    for _, j in pairs(C.jobs) do
        if j.status == "running" then
            if j.me then actors[j.me] = true end
            finish(j, "cancelled")
        end
    end
    C.pending, C.striking, C.starting, C.actedAt = nil, nil, nil, nil
    -- A companion can be reassigned by a multiplayer host between requests.
    local host = C.hostAvatar()
    if not C.agent or same(C.agent, host) or C.companionAllowed(C.agent) then
        for me in pairs(actors) do osi(Osi.PurgeOsirisQueue, me) end
    end
end

function C.ops.stop()
    C.stopActions()
    return true
end

function C.releaseActor()
    C.stopActions()
    if C.detachedForControl and C.agent and C.human and not same(C.agent, C.human)
        and C.companionAllowed(C.agent) then
        osi(Osi.AttachToPartyGroup, C.agent, C.human)
    end
    C.detachedForControl = nil
    if C.origReactions and C.companionAllowed(C.origReactions.owner) then
        pcall(setReactions, C.origReactions.owner, C.origReactions.modes)
    end
    C.origReactions, C.actor, C.agent, C.human = nil, nil, nil, nil
    C.dialogs, C.turn, C.fightId, C.fallenInit = {}, {}, nil, nil
    C.leftGroupAt = nil
end

-- A modal message box on the human's screen, for what cannot wait. The bridge rate-limits this.
function C.ops.say(args)
    local text = tostring(args.text or "")
    if text == "" then error("text required") end
    Osi.OpenMessageBox(human() or osi(Osi.GetHostCharacter), C.name(agent()) .. ": " .. text)
    return true
end

function C.ops.events(args)
    pcall(C.watchParty)
    pcall(C.watchFight)
    local since = tonumber(args.since) or 0
    if args.epoch ~= C.epoch then since = 0 end
    -- a bridge that just started asks only for recent events, not hours of backlog
    local oldest = args.max_age_ms and now() - tonumber(args.max_age_ms) or nil
    local out = {}
    for _, ev in ipairs(C.events) do
        if ev.seq > since and not (oldest and ev.t < oldest) then out[#out + 1] = ev end
    end
    return { epoch = C.epoch, latest = C.seq, events = out }
end

-- Something the human pointed at (middle click): what it is and where, seen from the agent.
function C.ops.pointed(args)
    local me = agent()
    local mypos = C.pos(me)
    local at = args.id and C.pos(args.id) or args.pos
    if not at then error("nothing there") end
    local out = { dist = mypos and r1(dist(mypos, at)), dir = mypos and dir(mypos, at) }
    if args.id then
        out.name = C.name(args.id)
        if same(args.id, me) then out.rel = "you"
        elseif comp(entity(args.id), "ServerCharacter") then out.rel = relation(me, args.id)
        else out.rel = "object" end
    end
    return out
end

function C.ops.ping()
    return { version = C.VERSION, agent = C.agent and C.name(C.agent) or nil }
end

------------------------------------------------------------------------
-- Combat overview: turn order, everyone's state, and what happened since
-- the agent's last turn (the combat log the human reads on screen).
------------------------------------------------------------------------

local COMBAT_RANGE = 60.0 -- metres: who counts as part of the agent's fight
local LOG_MAX = 80

-- Status groups that take control away (DOWNED has its own event).
local CONTROL = { SG_Incapacitated = true, SG_Paralyzed = true, SG_Stunned = true, SG_Sleeping = true,
    SG_Unconscious = true, SG_Charmed = true, SG_Dominated = true, SG_Frightened = true, SG_Restrained = true,
    SG_Prone = true, SG_Possessed = true, SG_Petrified = true }

local controlCache = {}
-- Display name of a status that takes control away, or false.
local function controlStatus(id)
    if id == nil or id == "DOWNED" then return false end
    if controlCache[id] ~= nil then return controlCache[id] end
    local res = false
    pcall(function()
        local st = Ext.Stats.Get(id)
        local groups = st and st.StatusGroups
        if type(groups) == "string" then
            local t = {}
            for x in groups:gmatch("[^;%s]+") do t[#t + 1] = x end
            groups = t
        end
        for _, x in ipairs(groups or {}) do
            if CONTROL[x] then res = loca(st.DisplayName) or id; break end
        end
    end)
    controlCache[id] = res
    return res
end

local function spellName(id)
    local ok, st = pcall(Ext.Stats.Get, id)
    return ok and st and loca(st.DisplayName) or id
end

local function concentrating(uuid)
    local c = comp(entity(uuid), "Concentration")
    if not c then return nil end
    local ok, id = pcall(function()
        local s = c.SpellId
        return (s.OriginatorPrototype ~= "" and s.OriginatorPrototype) or s.Prototype
    end)
    if ok and id and id ~= "" then return spellName(id) end
    return nil
end

-- What the game's examine window shows: damage resistances, status immunities, passive traits.
local DAMAGE = { "Slashing", "Piercing", "Bludgeoning", "Acid", "Thunder", "Necrotic", "Fire", "Lightning", "Cold",
    "Psychic", "Poison", "Radiant", "Force" }

local function serialize(c)
    local ok, t = pcall(Ext.Types.Serialize, c)
    return ok and type(t) == "table" and t or nil
end

-- { resist = {...}, immune = {...}, vulnerable = {...} }, "(nonmagical)" when magic gets through.
local function defenses(e)
    local out = {}
    local r = serialize(comp(e, "Resistances"))
    for i, flags in ipairs(r and r.Resistances or {}) do
        local dt = DAMAGE[i - 1]
        local has = {}
        -- a bitfield that prints as ResistanceBoostFlags(ResistantToMagical,...)
        if type(flags) == "table" then for _, f in ipairs(flags) do has[f] = true end
        else for f in (tostring(flags):match("%((.*)%)") or ""):gmatch("[%w_]+") do has[f] = true end end
        for _, kind in ipairs({ { "immune", "ImmuneTo" }, { "resist", "ResistantTo" }, { "vulnerable", "VulnerableTo" } }) do
            local magic, plain = has[kind[2] .. "Magical"], has[kind[2] .. "NonMagical"]
            if dt and (magic or plain) then
                local list = out[kind[1]] or {}
                list[#list + 1] = magic and dt or (dt .. " (nonmagical)")
                out[kind[1]] = list
                break
            end
        end
    end
    return out, r and r.AC
end

local function statusImmunities(e)
    local out = {}
    local si = serialize(comp(e, "StatusImmunities"))
    local ids = {}
    for id in pairs(si and si.PersonalStatusImmunities or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    -- a group (SG_Blinded) named next to a status in it (BLINDED) would show twice
    local covered = {}
    for _, id in ipairs(ids) do
        if not id:find("^SG_") then
            local ok, st = pcall(Ext.Stats.Get, id)
            local groups = ok and st and st.StatusGroups
            if type(groups) == "table" then
                for _, g in ipairs(groups) do covered[tostring(g)] = true end
            elseif type(groups) == "string" then
                for g in groups:gmatch("[^;]+") do covered[g] = true end
            end
        end
    end
    for _, id in ipairs(ids) do
        if id:find("^SG_") then
            if not covered[id] then out[#out + 1] = id:sub(4) end
        else
            local ok, st = pcall(Ext.Stats.Get, id)
            local n = ok and st and loca(st.DisplayName)
            if n and not n:find("^%%%%%%") then out[#out + 1] = n end
        end
    end
    return out
end

-- Tooltip text without markup, with [1]-style parameters filled in, at most `max` characters.
local function plainText(handle, params, max)
    local t = loca(handle)
    if not t then return nil end
    local p = {}
    for x in tostring(params or ""):gmatch("[^;]+") do
        p[#p + 1] = (x:match("%((.*)%)") or x):gsub(",", " ")
    end
    t = t:gsub("<br>", " "):gsub("<[^>]+>", ""):gsub("%[(%d+)%]", function(n) return p[tonumber(n)] end)
    t = t:gsub("%s+", " ")
    if utf8 and utf8.len(t) and utf8.len(t) > max then t = t:sub(1, utf8.offset(t, max + 1) - 1) .. "..." end
    return t
end

local function traits(e)
    local out = {}
    local pc = comp(e, "PassiveContainer")
    pcall(function()
        for _, pe in ipairs(pc.Passives) do
            local id = pe.Passive.PassiveId
            local st = Ext.Stats.Get(id)
            local props = {}
            for _, x in ipairs(st and type(st.Properties) == "table" and st.Properties or {}) do props[x] = true end
            local n = st and loca(st.DisplayName)
            if n and not n:find("^%%%%%%") and not props.IsHidden and not props.IsToggled then
                out[#out + 1] = { name = n, what = plainText(st.Description, st.DescriptionParams, 120) }
            end
        end
    end)
    return out
end

local ABILITIES = { "str", "dex", "con", "int", "wis", "cha" }

local function initiative(uuid)
    local cp = comp(entity(uuid), "CombatParticipant")
    local ok, v = pcall(function() return cp.InitiativeRoll end)
    return ok and v or nil
end

local K = {} -- combat helpers (the main chunk is near Lua's 200 locals)
K.BLOW_MS = 300 -- AttackedBy events this close together are one blow

C.clog = C.clog or { seq = 0, mark = 0, rows = {} }
C.fallen = C.fallen or {} -- [bare uuid] = true: party members already reported dead

local function mine(u) return same(u, C.agent) end
-- How the log names a fighter: "you", "使徒 (your summon)", or the name.
local function who(u)
    if mine(u) then return "you" end
    if C.isMySummon(u) then return C.name(u) .. " (your summon)" end
    return C.name(u)
end

local function inMyFight(u)
    if not (C.agent and inCombat(C.agent)) then return false end
    if same(u, C.agent) or isParty(u) then return true end
    if not inCombat(u) then return false end
    local d = dist(C.pos(C.agent), C.pos(u))
    return d ~= nil and d <= COMBAT_RANGE
end

local function logCombat(row)
    local L = C.clog
    -- one spell hitting several targets is one line
    local last = L.rows[#L.rows]
    local recent = last and now() - (last.t or 0) < 1000
    if row.cast and recent and last.cast == row.cast and last.by == row.by then
        -- a cast at a spot (a shout) is logged when it goes off; any per-target event joins it
        if row.on then
            last.on = last.on or {}
            local dup = false
            for _, x in ipairs(last.on) do dup = dup or x == row.on[1] end
            if not dup then last.on[#last.on + 1] = row.on[1] end
        end
        return
    end
    -- one blow raises AttackedBy once per damage type (a slash and its fire): one line, the sum
    local blow = last and recent and now() - (last.t or 0) < K.BLOW_MS and last.by == row.by
    if blow and (row.hit or row.no_damage) and (last.hit or last.no_damage) == (row.hit or row.no_damage) then
        if row.hit then
            last.damage = (tonumber(last.damage) or 0) + (tonumber(row.damage) or 0)
            last.hit, last.no_damage = row.hit, nil
        end
        return
    end
    L.seq = L.seq + 1
    row.n = L.seq
    row.t = now()
    L.rows[#L.rows + 1] = row
    while #L.rows > LOG_MAX do table.remove(L.rows, 1) end
end

-- Log lines after the agent's previous turn, the newest `max`.
local function sinceMyTurn(max)
    local L, out = C.clog, {}
    for _, r in ipairs(L.rows) do
        if r.n > L.mark then
            local row = {}
            for k, v in pairs(r) do if k ~= "n" and k ~= "t" then row[k] = v end end
            out[#out + 1] = row
        end
    end
    while #out > (max or 30) do table.remove(out, 1) end
    return out
end

local function turnBudget(me)
    local res = C.resources(me)
    local function left(k) return res[k] and res[k][1] or nil end
    return { movement_m = left("Movement"), actions = left("ActionPoint"), bonus_actions = left("BonusActionPoint"),
        reactions = left("ReactionActionPoint") }
end

function C.ops.examine(args)
    local me = agent()
    local u = args.target
    if not u or u == "" then error("target required") end
    local p = C.pos(u)
    if not p then error("no such character") end
    if not same(u, me) and (hidden(u) or not perceives(me, C.pos(me), u, p)) then error("you cannot see them") end
    local e = entity(u)
    if not comp(e, "ServerCharacter") then error("examine works on characters; use look for objects") end
    local hv, mh = hp(u)
    local def, ac = defenses(e)
    local out = { name = C.name(u), rel = same(u, me) and "you" or relation(me, u), ac = ac,
        resist = def.resist, immune = def.immune, vulnerable = def.vulnerable, immune_to = statusImmunities(e),
        statuses = statuses(u), concentrating = concentrating(u), traits = traits(e),
        dead = truthy(osi(Osi.IsDead, u)) or nil }
    pcall(function() out.level = e.EocLevel.Level end)
    pcall(function()
        local a, t = e.Stats.Abilities, {}
        for i, k in ipairs(ABILITIES) do t[k] = a[i + 1] end
        out.abilities = t
    end)
    if out.rel == "you" or out.rel == "party" then out.hp = hv; out.max_hp = mh
    elseif hv and mh and mh > 0 then out.hp_pct = math.floor(hv * 100 / mh) end
    out.pos = { r1(p[1]), r1(p[2]), r1(p[3]) }
    if out.rel ~= "you" then out.walk_m = K.walkTo(me, p, C.pos(me)) end
    return out
end


-- Everyone in the agent's fight within COMBAT_RANGE, and party members who are down or dead
-- (the game takes the dead, and at times the downed, out of the fight's lists).
function K.fighters(me)
    local cg = osi(Osi.CombatGetGuidFor, me)
    local mypos = C.pos(me)
    local out = {}
    local ok, list = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerCharacter")
    for _, e in ipairs(ok and list or {}) do
        local u, p = entityUuid(e), entityPos(e)
        local d = u and p and mypos and dist(mypos, p)
        if d and d <= COMBAT_RANGE then
            local fighting = inCombat(u) and (same(u, me) or not hidden(u))
                and (cg == nil or same(osi(Osi.CombatGetGuidFor, u), cg))
            if fighting or (isParty(u) and (isDead(u) or isDowned(u))) then
                out[#out + 1] = { u = u, e = e, p = p, d = d }
            end
        end
    end
    return out
end

function K.hpText(u, rel)
    local h, m = hp(u)
    if not (h and m and m > 0) then return nil end
    if rel == "you" or rel == "party" then return h .. "/" .. m end
    return math.floor(h * 100 / m) .. "%"
end

-- Everyone's HP, named statuses and downed/dead state, to compare with at the agent's next turn.
function K.snapshot(me)
    local snap = {}
    for _, f in ipairs(K.fighters(me)) do
        local rel = same(f.u, me) and "you" or (C.isMySummon(f.u) and "party") or relation(me, f.u)
        local st = {}
        for _, n in ipairs(statusNames(statusIds(f.u), 30, true)) do st[n] = true end
        snap[bare(f.u)] = { u = f.u, who = who(f.u), hp = K.hpText(f.u, rel), st = st,
            state = (isDead(f.u) and "dead") or (isDowned(f.u) and "downed") or nil }
    end
    return snap
end

-- The end of the agent's turn: the log and everyone's state start over from here.
function K.markTurn(me)
    C.clog.mark = C.clog.seq
    local ok, snap = pcall(K.snapshot, me)
    C.clog.snap = ok and snap or nil
end

-- What changed for each fighter since the agent's last turn: HP, statuses gained and lost,
-- downed or dead, who came into the fight (summons, reinforcements) and who left it.
function K.changesSince(me)
    local before = C.clog.snap
    if not before then return nil end
    local after = K.snapshot(me)
    local out = {}
    for k, a in pairs(after) do
        local b = before[k]
        local row, changed = { who = a.who }, false
        if not b then
            row.joined, changed = true, true
        else
            if a.hp and b.hp and a.hp ~= b.hp then row.hp, changed = b.hp .. " -> " .. a.hp, true end
            local gained, lost = {}, {}
            for n in pairs(a.st) do if not b.st[n] then gained[#gained + 1] = n end end
            for n in pairs(b.st) do if not a.st[n] then lost[#lost + 1] = n end end
            table.sort(gained); table.sort(lost)
            if #gained > 0 then row.now, changed = gained, true end
            if #lost > 0 then row.no_longer, changed = lost, true end
            if a.state ~= b.state then row.became, changed = a.state or "back on their feet", true end
        end
        if changed then out[#out + 1] = row end
    end
    for k, b in pairs(before) do
        if not after[k] then
            -- the invisible (a cultist that hid) are not listed but still fight
            local gone = isDead(b.u) and "dead" or (inCombat(b.u) and "hidden (still in the fight)") or "out of the fight"
            out[#out + 1] = { who = b.who, became = gone }
        end
    end
    table.sort(out, function(x, y) return x.who < y.who end)
    return out
end

-- A party member died. Osiris raises Died when one drops to 0 HP (downed, not dead), but not
-- again when a downed one fails the death saves, so the party is also looked at on every poll.
function K.noteDeath(u)
    local k = bare(u)
    if C.fallen[k] then return end
    C.fallen[k] = true
    if inMyFight(u) then logCombat({ died = who(u) }) end
    push("died", { name = C.name(u), you = mine(u) or nil, human = same(u, human()) or nil })
end

function C.watchParty()
    if not C.agent then return end
    local first = not C.fallenInit -- the already dead are not news
    C.fallenInit = true
    for _, u in ipairs(party()) do
        if isDead(u) then
            if first then C.fallen[bare(u)] = true else K.noteDeath(u) end
        else
            C.fallen[bare(u)] = nil
        end
    end
end

-- Movement it takes `me` to get next to (1.5 m of) p, as the game reckons it: a number, false
-- when there is no way on foot, nil when unknown (too far to bother, or no pathfinder).
function K.walkTo(me, p, from)
    if not (p and from) or flat(from, p) > 40 then return nil end
    if flat(from, p) <= 1.5 then return 0 end
    local plan = C.plan(me, p, 1.5)
    if plan == nil then return nil end
    if plan.why or not plan.pts then return false end
    return r1(plan.cost_m or plan.walk_m)
end

function C.ops.combat()
    local me = agent()
    if not inCombat(me) then error("not in combat") end
    pcall(C.watchParty)
    local mypos = C.pos(me)
    local h = human()
    local order, summons = {}, {}
    -- an enemy's traits come once per fight, the first time it is listed
    C.clog.described = C.clog.described or {}
    C.clog.explained = C.clog.explained or {}
    local described, explained = C.clog.described, C.clog.explained
    C.clog.calls = (C.clog.calls or 0) + 1
    local call = C.clog.calls
    for _, f in ipairs(K.fighters(me)) do
        local u, e, p, d = f.u, f.e, f.p, f.d
        local rel = same(u, me) and "you" or relation(me, u)
        local yours = C.isMySummon(u)
        local hv, mh = hp(u)
        local info = {}
        -- what an enemy's statuses do, each status once per fight (like traits)
        local explain = rel == "enemy" and function(dn, st)
            if explained[dn] then return end
            explained[dn] = true
            local what = plainText(stat(st, "Description"), stat(st, "DescriptionParams"), 100)
            if what and what ~= "" and not what:find("^%%%%%%") then info[#info + 1] = { name = dn, what = what } end
        end or nil
        local row = { id = u, name = C.name(u), rel = rel, initiative = initiative(u),
            human = same(u, h) or nil, downed = isDowned(u) or nil, dead = isDead(u) or nil,
            your_summon = yours or nil, concentrating = concentrating(u),
            statuses = statusNames(statusIds(u), 12, false, explain) }
        if #info > 0 then row.status_info = info end
        if p then row.pos = { r1(p[1]), r1(p[2]), r1(p[3]) } end
        if rel ~= "you" then
            row.dist = r1(d); row.dir = dir(mypos, p)
            if not row.dead then row.walk_m = K.walkTo(me, p, mypos) end
        end
        if rel == "you" or rel == "party" or yours then row.hp = hv; row.max_hp = mh
        else
            if hv and mh and mh > 0 then row.hp_pct = math.floor(hv * 100 / mh) end
            local def, ac = defenses(e)
            row.resist, row.immune, row.vulnerable = def.resist, def.immune, def.vulnerable
            row.immune_to = statusImmunities(e)
            row.ac = ac
            pcall(function() row.level = e.EocLevel.Level end)
            if rel == "enemy" and not described[bare(u)] then
                described[bare(u)] = true
                -- the same kind of enemy (six 巴尔之镰) has the same traits: one listing gives them
                -- for all of that kind (the bridge puts them on one line), later ones not again
                local t = traits(e)
                local names = {}
                for _, x in ipairs(t) do names[#names + 1] = x.name end
                local sig = "traits:" .. table.concat(names, "|")
                if #t > 0 and (described[sig] == nil or described[sig] == call) then
                    described[sig] = call
                    row.traits = t
                end
            end
        end
        local tb = comp(e, "TurnBased")
        local ok2, active = pcall(function() return tb.IsActiveCombatTurn end)
        if ok2 and active == true then row.current = true end
        if yours then
            local its, ended = turnState(u)
            local s = turnBudget(u)
            s.id, s.name, s.its_turn, s.turn_ended = u, row.name, its or nil, ended or nil
            summons[#summons + 1] = s
        end
        order[#order + 1] = row
    end
    table.sort(order, function(a, b) return (a.initiative or -999) > (b.initiative or -999) end)
    local mine_, ended = turnState(me)
    local out = turnBudget(me)
    out.my_turn = mine_
    out.turn_ended = ended or nil
    out.order = order
    out.since_your_last_turn = sinceMyTurn(30)
    out.changes_since_your_last_turn = K.changesSince(me)
    if #summons > 0 then out.your_summons = summons end
    return out
end

-- Cheap enough for every tool call: is it the agent's turn, and which one (the bridge hands
-- the whole picture over once per turn, with the first result of that turn).
function C.ops.turn_check()
    if not (C.agent and inCombat(C.agent)) then return { epoch = C.epoch, n = C.turn.n or 0 } end
    local mine_, ended = turnState(C.agent)
    return { epoch = C.epoch, n = C.turn.n or 0, my_turn = (mine_ and not ended) or nil }
end

------------------------------------------------------------------------
-- Visible events. Listeners are registered once per Lua state and dispatch
-- through C.on, so re-sending this file updates them.
------------------------------------------------------------------------

-- The agent's turn begins: once per turn, whichever sees it first. TurnStarted names only the
-- first of a group that shares one turn (party members next to each other in initiative), so the
-- agent's own TurnBased.IsActiveCombatTurn is watched too, at every TurnStarted and every call.
function C.turnBegins(u)
    if C.turn.live then return end
    C.turn.live = true
    C.turn.ended = {}
    C.turn.n = (C.turn.n or 0) + 1
    push("your_turn", turnBudget(u))
end

function C.watchTurn()
    if not (C.agent and inCombat(C.agent)) then C.turn.live = nil return end
    local tb = comp(entity(C.agent), "TurnBased")
    local ok, active = pcall(function() return tb.IsActiveCombatTurn end)
    if not (tb and ok) then return end
    if active == true then C.turnBegins(C.agent) else C.turn.live = nil end
end

C.on.TurnStarted = function(u)
    C.turn.current = u
    if mine(u) then
        C.turnBegins(u)
    else
        pcall(C.watchTurn) -- a shared turn starting with someone else, or someone else's turn
    end
    if C.isMySummon(u) then
        local ev = turnBudget(u)
        ev.name, ev.id = C.name(u), u
        push("summon_turn", ev)
    end
end
C.on.TurnEnded = function(u)
    if same(C.turn.current, u) then C.turn.current = nil end
    if mine(u) then K.markTurn(u) end
end
-- A fight the agent is in starts over: the log, the snapshot, what was told about enemies.
function C.fightBegins()
    C.fightId = osi(Osi.CombatGetGuidFor, C.agent) or true
    C.clog.mark, C.clog.snap, C.clog.described, C.clog.explained = C.clog.seq, nil, {}, {}
    push("combat_started", {})
end

-- The agent can be drawn into a fight after it started (it stood too far off when the human's
-- dialogue ended in one, 2026-11-04): CombatStarted came while it was not in it. Each poll looks.
function C.watchFight()
    if not C.agent then return end
    if not inCombat(C.agent) then
        -- its fight ended without a CombatEnded for it (it fled, or the flag lagged behind the event)
        if C.fightId ~= nil then C.fightEnds() end
        return
    end
    local cg = osi(Osi.CombatGetGuidFor, C.agent) or true
    if C.fightId == nil or (C.fightId ~= true and cg ~= true and C.fightId ~= cg) then C.fightBegins() end
end

C.on.CombatStarted = function()
    if C.agent and inCombat(C.agent) and C.fightId == nil then C.fightBegins() end
end
-- Once per fight the agent was in, from whichever of CombatEnded and the poll sees it first.
function C.fightEnds()
    C.fightId = nil
    C.turn.ended = {}
    C.clog.snap, C.clog.described, C.clog.explained = nil, {}, {}
    push("combat_ended", {})
end
C.on.CombatEnded = function(cg)
    if C.fightId == nil then
        -- a fight without the agent (the human's, say): still worth a word
        C.turn.ended = {}
        push("combat_ended", {})
    elseif C.fightId == true or C.fightId == cg or not (C.agent and inCombat(C.agent)) then
        C.fightEnds()
    end
    -- another fight than the agent's, or IsInCombat still set: the next poll looks again
end
C.on.DialogStarted = function(_, inst)
    if not C.agent then return end
    -- actors join right after the start event
    local function check() if dialogOf(C.agent) == inst then noteDialog(inst, false) end end
    check()
    pcall(function() Ext.Timer.WaitFor(300, function() pcall(check) end) end)
end
C.on.DialogActorJoined = function(_, inst, actor)
    if not mine(actor) then return end
    -- a bark may only be listed as automated once its start has been handled
    pcall(function() Ext.Timer.WaitFor(300, function() pcall(noteDialog, inst, false) end) end)
end
C.on.DialogEnded = function(_, inst)
    local d = C.dialogs[inst]
    if d then
        C.dialogs[inst] = nil
        push("dialogue_ended", { yours = d.yours })
    end
end
C.on.CastedSpell = function(caster, spell)
    local pend = C.pending
    if not (pend and same(caster, pend.caster) and spell == pend.spell) then return end
    C.pending = nil
    pay(caster, pend.costs, pend.combat)
    if pend.after then pcall(pend.after) end
    -- a cast at a spot (shouts go at the caster's feet) raises no UsingSpellOnTarget: log it here
    if pend.spot and inMyFight(caster) then
        local on = {}
        if pend.around then
            if C.heals(Ext.Stats.Get(spell)) then on[1] = who(caster) end
            for _, u in ipairs(pend.around) do on[#on + 1] = who(u) end
        end
        logCombat({ by = who(caster), cast = spellName(spell), on = #on > 0 and on or nil })
    end
    local j = C.jobs[pend.job]
    if j then
        j.data.cast = nil
        j.data.wait_until = now() + 500
        j.data.result_fn = function()
            local r = pend.report and pend.report() or {}
            r.cast = spell
            return r
        end

    end
end
C.on.CastSpellFailed = function(caster, spell)
    local pend = C.pending
    if not (pend and same(caster, pend.caster) and spell == pend.spell) then return end
    C.pending = nil
    local j = C.jobs[pend.job]
    if not j then return end
    -- struck as it began: a jump out of an enemy's reach drew an opportunity attack that cut it off
    -- (2026-11-05), and the blow is reported after the failure, so give it a moment; a summon whose
    -- caster fell to one went off all the same
    C.striking = pend
    j.data.cast, j.data.wait_until = nil, now() + 400
    j.data.fail_fn = function()
        if C.striking == pend then C.striking = nil end
        if pend.struck then
            return pend.struck .. " struck you as it began (an opportunity attack if you were leaving its reach)"
                .. " and cut it off, or it went off anyway (`combat` shows which). Nothing was spent: try again;"
                .. " that enemy's reaction is used up now"
        end
        return pend.failed or "the game refused the cast: the target may not be valid for it (Help needs a downed ally), or out of sight or reach"
    end
end
-- Osiris also raises Died for a player character who is only downed, so
-- whether they died is looked at a moment later (the downed event covers the rest).
C.on.Died = function(u)
    if not C.agent then return end
    -- before the near check: the dead may already have left the fight
    local fight = inCombat(C.agent) and (isParty(u) or (dist(C.pos(C.agent), C.pos(u)) or 1e9) <= COMBAT_RANGE)
    local function report()
        if isParty(u) then
            if isDead(u) then K.noteDeath(u) end
            return
        end
        if fight then logCombat({ died = who(u) }) end
        if mine(u) or (dist(C.pos(C.agent), C.pos(u) or { 1e9, 0, 0 }) or 1e9) < SIGHT then
            push("died", { name = C.name(u), you = mine(u) or nil })
        end
    end
    if not (isParty(u) and pcall(function() Ext.Timer.WaitFor(300, function() pcall(report) end) end)) then report() end
end
-- AttackedBy(defender, attackerOwner, attacker, damageType, damage, cause, story): the owner of a
-- summon is the summoner, so the one who struck is the third argument.
C.on.AttackedBy = function(defender, owner, attacker, _, damage)
    if attacker == nil or attacker == "" or tostring(attacker):find("^NULL_") then attacker = owner end
    if mine(defender) then push("attacked", { by = C.name(attacker), damage = damage }) end
    for _, pend in ipairs({ C.pending or false, C.striking or false }) do
        if pend and same(defender, pend.caster) then pend.struck = C.name(attacker) end
    end
    if not inMyFight(defender) then return end
    -- a miss, a passed save or an immunity still raises AttackedBy, with 0 damage
    if (tonumber(damage) or 0) > 0 then
        logCombat({ by = who(attacker), hit = who(defender), damage = damage })
    else
        logCombat({ by = who(attacker), no_damage = who(defender) })
    end
end
C.on.UsingSpellOnTarget = function(caster, target, spell)
    if inMyFight(caster) then
        logCombat({ by = who(caster), cast = spellName(spell), on = { who(target) } })
    end
end
C.on.StatusApplied = function(u, status, causee)
    if not C.agent then return end
    if status == "DOWNED" then
        if isParty(u) then
            push("downed", { name = C.name(u), you = mine(u) or nil, human = same(u, human()) or nil })
        end
        if inMyFight(u) then logCombat({ downed = who(u) }) end
        return
    end
    local ctl = controlStatus(status)
    if not ctl then return end
    if mine(u) then
        local by = causee and not mine(causee) and C.name(causee) or nil
        push("controlled", { status = ctl, by = by ~= "?" and by or nil })
    end
    if inMyFight(u) then logCombat({ status = ctl, on = who(u) }) end
end
C.on.StatusRemoved = function(u, status)
    -- a downed party member who failed the death saves dies without a Died event
    if status == "DOWNED" and isParty(u) then
        pcall(function() Ext.Timer.WaitFor(500, function() pcall(C.watchParty) end) end)
    end
    if mine(u) and controlStatus(status) then push("control_ended", { status = controlStatus(status) }) end
    if mine(u) and status == SNEAKING then
        if C.sneakOff and now() - C.sneakOff < 3000 then
            C.sneakOff = nil -- sneak off asked for it
            return
        end
        local p = C.pos(C.agent)
        local by = p and whoSees(seenAt(aim(watchers(C.agent, p)), p)) or ""
        push("stealth_lost", { seen_by = by ~= "" and by or nil,
            note = by == "" and "nobody you can see had you in view: you may have acted (attacked, cast, talked), or someone you cannot see spotted you" or nil })
    end
end
C.on.LeveledUp = function(u) if mine(u) then push("level_up", {}) end end
-- Passive checks (spotting a hidden item or trap: GLO_CONST_HiddenItemCheck...) raise
-- RollResult with isActiveRoll 0; resultType 1 is a success. A save against the agent's spell
-- comes the same way (GAMEPLAY_SpellSavingThrowSave, the enemy as subject, 2026-11-04): not a find.
C.on.RollResult = function(event, roller, subject, result, active)
    if not (mine(roller) and tonumber(active) == 0 and tonumber(result) == 1) then return end
    local ev = tostring(event)
    if ev:find("SavingThrow") or ev:find("Spell") then return end
    local me, at = C.pos(C.agent), C.pos(subject)
    push("noticed", { name = C.name(subject), id = subject,
        dist = me and at and r1(dist(me, at)) or nil, dir = me and at and dir(me, at) or nil,
        check = tostring(event):gsub("^GLO_CONST_", "") })
end

do -- (a block: the main chunk is near Lua's 200 locals)
local ARITY = { TurnStarted = 1, TurnEnded = 1, CombatStarted = 1, CombatEnded = 1, DialogStarted = 2,
    DialogActorJoined = 4, DialogEnded = 2, CastedSpell = 5, CastSpellFailed = 5, Died = 1, AttackedBy = 7,
    LeveledUp = 1, UsingSpellOnTarget = 6, StatusApplied = 4, StatusRemoved = 4, RollResult = 6 }

if type(C.listening) ~= "table" then C.listening = {} end
for name, arity in pairs(ARITY) do
    if not C.listening[name] then
        local ok = pcall(Ext.Osiris.RegisterListener, name, arity, "after", function(...)
            local fn = C.on[name]
            if not fn then return end
            local ok2, err = pcall(fn, ...)
            if not ok2 then push("listener_error", { name = name, error = tostring(err) }) end
        end)
        C.listening[name] = ok
    end
end
end

------------------------------------------------------------------------
-- RPC entry point
------------------------------------------------------------------------

-- What a summon of the agent can be told to do (args.as names it).
C.ACTS_FOR_SUMMON = { move = true, cast = true, end_turn = true, spells = true, stop = true }

function C.summonOf(q)
    if not C.agent then error("no agent character chosen yet: call set_agent first") end
    local low = tostring(q):lower()
    for _, u in ipairs(C.mySummons()) do
        if same(u, q) or C.name(u):lower():find(low, 1, true) then return u end
    end
    error("you have no summon " .. tostring(q) .. " (combat lists yours)")
end

-- The debugger owner binds the local client to a short-lived controller session.
-- Only the host's local panel sends consent. None of these functions are RPC ops.
do
    local channel = "BG3COOP_LocalControl"
    local read = {
        party=true, status=true, look=true, sight=true, events=true, combat=true,
        turn_check=true, dialogue=true, dialogue_roll=true, examine=true, inventory=true, spells=true, quests=true,
        memory=true, notes_get=true, notes_put=true, ping=true, pointed=true,
        stop=true,
    }
    local function revoke()
        if not C.protagonist then return end
        C.protagonist, C.protagonistGrant = nil, nil
        C.controlRevision = C.controlRevision + 1
        C.releaseActor()
    end
    local function check()
        if C.controlUntil and now() < C.controlUntil
            and tostring(Ext.Utils.GetGameState()) == "Running" then
            if C.protagonist and not same(C.protagonist, C.hostAvatar()) then revoke() end
            return
        end
        C.controlReset()
    end
    function C.controlTicket()
        return C.protagonist and (C.epoch .. ":" .. tostring(C.controlRevision)) or nil
    end
    function C.controlHeartbeat(session, lease, request)
        check()
        local existing = session == C.controlSession
        if not existing then
            C.controlReset()
            C.controlSession = session
        end
        C.controlUntil = now() + lease
        local consent
        if request then
            consent = { id = request.id }
            if not existing or request.session ~= session or request.epoch ~= C.epoch then
                consent.error = "存档或控制器连接已变更，请重新启用接管"
            elseif not C.controlSubscribed then
                consent.error = "游戏缺少接管所需的会话与心跳监控"
            elseif not C.protagonist then
                local avatar, reason = C.hostAvatar()
                if not avatar then
                    consent.error = reason
                else
                    C.releaseActor()
                    C.controlRevision = (C.controlRevision or 0) + 1
                    C.protagonistGrant = C.epoch .. ":" .. C.controlRevision
                    C.protagonist, C.agent, C.human = avatar, avatar, avatar
                end
            end
        end
        return Ext.Json.Stringify({ ticket = C.controlTicket(), grant = C.protagonistGrant, consent = consent,
            id = C.agent, human = human(),
            name = C.agent and C.name(C.agent) or nil, epoch = C.epoch, revision = C.controlRevision or 0 })
    end
    function C.controlReset()
        if C.protagonist then
            revoke()
        elseif C.controlSession then
            C.controlStop()
        end
        C.controlSession, C.controlUntil = nil, nil
    end
    function C.controlStop()
        C.controlRevision = (C.controlRevision or 0) + 1
        C.stopActions()
        return Ext.Json.Stringify({ ticket = C.controlTicket(), epoch = C.epoch, revision = C.controlRevision })
    end
    function C.checkControl(op, ticket)
        local current = C.controlTicket()
        if ticket and ticket ~= current then error("protagonist permission changed") end
        if current and not read[op] and ticket ~= current then
            error("protagonist actions require an active local Free Explore task")
        end
        if current and (op == "trade_open" or op == "trade_check" or op == "travel" or op == "reactions") then
            error("this action is unavailable during protagonist takeover")
        end
        if C.agent and not current and not C.companionAllowed(C.agent) then
            C.releaseActor()
            error("this companion is now reserved for another player")
        end
    end
    -- The network shortcut can only stop or revoke. The random session is
    -- installed only in the owning debugger's local client, never broadcast.
    function C.onLocalControl(_, payload)
        check()
        if not C.controlSession or type(payload) ~= "string" then return end
        local session, cmd = payload:match("^([0-9a-f]+):(%a+)$")
        if session ~= C.controlSession then return end
        if cmd == "off" then
            revoke()
        elseif cmd == "stop" then
            C.controlStop()
        end
    end
    if not C.controlSubscribed and Ext.Events.Tick then
        if Ext.RegisterNetListener then
            pcall(Ext.RegisterNetListener, channel, function(...) C.onLocalControl(...) end)
        end
        Ext.Events.Tick:Subscribe(function() C.checkControlLease() end)
        if Ext.Events.SessionLoading then
            Ext.Events.SessionLoading:Subscribe(function() C.controlReset() end)
        end
        C.controlSubscribed = true
    end
    C.checkControlLease = check
end

-- Match the actual requested roll to the dialogue and its actor. No outcome is written here.
function C.dialogueRoll(id, instance)
    local ok, result = pcall(function()
        local me = entity(id)
        local roll = Ext.System.ServerRoll.EntityToRollEntity[me]
        local r = roll and roll.RequestedRoll
        if not r or r.Canceled or not r.RollUuid or r.DialogId ~= tonumber(instance)
            or r.Roller ~= me then return nil end
        return tostring(r.RollUuid)
    end)
    return ok and result or nil
end

function C.ops.dialogue_roll(args)
    if not C.protagonist or dialogOf(C.protagonist) ~= tonumber(args.instance) then
        return { verified = false }
    end
    local id = C.dialogueRoll(C.protagonist, args.instance)
    return { verified = id ~= nil, roll_id = id and id:lower() or nil }
end

function C.checkTask(authority)
    C.checkControlLease()
    if authority.epoch and authority.epoch ~= C.epoch then error("save changed during the task") end
    if authority.revision and authority.revision ~= (C.controlRevision or 0) then
        error("control changed during the task")
    end
end

function C.authorizeUI(json)
    local request = Ext.Json.Parse(json)
    local a = request.authority
    local ok, result = pcall(function()
        C.checkTask(a)
        C.checkControl(request.op, a.ticket)
        local args = request.args
        if not args then
            if C.protagonist then error("use the guarded local protagonist UI") end
            return true
        end
        if not C.protagonist or not same(args.owner, C.protagonist) then
            error("protagonist permission changed")
        end
        if dialogOf(C.protagonist) ~= tonumber(args.instance) then
            error("the protagonist's dialogue changed")
        end
        if request.op == "roll" or request.op == "roll_boost" or request.op == "roll_state" then
            local id = C.dialogueRoll(C.protagonist, args.instance)
            if not id or id:lower() ~= args.roll_id then error("the requested dialogue roll changed") end
        end
        return true
    end)
    return Ext.Json.Stringify(ok and { ok = true, result = result } or { ok = false, error = tostring(result) })
end

function C.rpc(json)
    local ok, req = pcall(Ext.Json.Parse, json)
    if not ok or type(req) ~= "table" then
        return Ext.Json.Stringify({ ok = false, error = "bad request" })
    end
    local fn = C.ops[req.op]
    if not fn then return Ext.Json.Stringify({ ok = false, error = "unknown op " .. tostring(req.op) }) end
    local args = req.args or {}
    C.actor = nil
    local ok2, res = pcall(function()
        C.checkTask(req)
        C.checkControl(req.op, req.ticket)
        pcall(C.watchFight)
        pcall(C.watchTurn)
        if args.as then
            if not C.ACTS_FOR_SUMMON[req.op] then error(req.op .. " cannot be done by a summon") end
            C.actor = C.summonOf(args.as)
        end
        return fn(args)
    end)
    C.actor = nil
    if ok2 then
        return Ext.Json.Stringify({ ok = true, result = res }, { Beautify = false, StringifyInternalTypes = true })
    end
    local msg = tostring(res):gsub("^.-:%d+: ", "")
    return Ext.Json.Stringify({ ok = false, error = msg })
end

return "BG3COOP server v" .. C.VERSION
