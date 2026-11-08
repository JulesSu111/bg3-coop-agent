-- A tiny fake BG3 world for offline tests: just enough Ext/Osi for server.lua.
-- PY_* globals are provided by the Python side (JSON, clock).

local W = {
    host = "S_Player_Tav_11111111-1111-1111-1111-111111111111",
    sh = "S_Player_ShadowHeart_3ed74f06-3c60-42dc-83f6-f034cb47c679",
    gob = "Goblin_22222222-2222-2222-2222-222222222222",
    npc = "Trader_33333333-3333-3333-3333-333333333333",
    chest = "Chest_44444444-4444-4444-4444-444444444444",
    potion = "Potion_55555555-5555-5555-5555-555555555555",
    wall_gob = "Hidden_66666666-6666-6666-6666-666666666666",
    -- Shadowheart's own things
    heal = "HealPot_77777777-7777-7777-7777-777777777771",
    scroll = "Scroll_77777777-7777-7777-7777-777777777773",
    helm = "Helm_77777777-7777-7777-7777-777777777774",
    worn = "Circlet_77777777-7777-7777-7777-777777777775",
    grease = "Grease_77777777-7777-7777-7777-777777777776",
    revive = "Revive_77777777-7777-7777-7777-777777777777",
}
MOCK = W

local function g(id) return id:match("(%x+%-%x+%-%x+%-%x+%-%x+)$") or id end

W.pos = {
    [g(W.host)] = { 0, 0, 0 }, [g(W.sh)] = { 2, 0, 0 }, [g(W.gob)] = { 12, 0, 0 },
    [g(W.npc)] = { 0, 0, 8 }, [g(W.chest)] = { -5, 0, 0 }, [g(W.potion)] = { -5, 0, 0 },
    [g(W.wall_gob)] = { 3, 0, 3 },
}
W.names = {
    [g(W.host)] = "Tav", [g(W.sh)] = "Shadowheart", [g(W.gob)] = "Goblin", [g(W.npc)] = "Arron",
    [g(W.chest)] = "Chest", [g(W.potion)] = "Potion of Healing", [g(W.wall_gob)] = "Sneaky Goblin",
    [g(W.heal)] = "Potion of Healing", [g(W.scroll)] = "Scroll of Bless", [g(W.helm)] = "Iron Helmet",
    [g(W.worn)] = "Circlet", [g(W.grease)] = "Bottle of Grease",
    [g(W.revive)] = "Scroll of Revivify",
}
-- Shadowheart's items: stats id, owner, how many. The potions are one stack made of two
-- entities, as the game does after items are added to a stack.
W.item = {
    [g(W.heal)] = { stats = "OBJ_Potion_Healing", owner = W.sh, total = 2 },
    [g(W.scroll)] = { stats = "OBJ_Scroll_Bless", owner = W.sh, total = 1 },
    [g(W.helm)] = { stats = "ARM_Helmet", owner = W.sh, total = 1, slot = "Helmet" },
    [g(W.worn)] = { stats = "ARM_Circlet", owner = W.sh, total = 1, slot = "Helmet", equipped = true },
    [g(W.grease)] = { stats = "OBJ_Grease", owner = W.sh, total = 2 },
    [g(W.revive)] = { stats = "OBJ_Scroll_Revivify", owner = W.sh, total = 1 },
}
W.itemOrder = { W.heal, W.scroll, W.helm, W.worn, W.grease, W.revive }
W.chars = { W.host, W.sh, W.gob, W.npc, W.wall_gob }
W.items = { W.chest }
W.combat = false
W.turn = nil
W.dialog = {}
W.barks = {} -- dialogue instances that are barks (automated)
W.detached = {}
W.casts = {}
W.inv = {}
W.listeners = {}
W.res = {}
W.prefs = {}
W.nextDialog = 100
W.statuses = {} -- gained by Shadowheart during the test
W.timers = {}
W.rot = {} -- [uuid] = rotation quaternion
W.walls = {} -- { x, z, r }: round pillars that block sight
W.noPath = false -- pathfinding finds no way (one can only stay where one is)
W.mods = {} -- [uuid] = true for loaded mods
W.modvars = {} -- [uuid] = mod variables, as kept in the save
W.subs = {} -- Ext.Events subscribers by event name
W.wp_village = "WP_Trigger_Village_88888888-8888-8888-8888-888888888881"
W.wp_grove = "WP_Trigger_Grove_88888888-8888-8888-8888-888888888882"
W.wp_moon = "WP_Trigger_Moon_88888888-8888-8888-8888-888888888883"
W.pos[g(W.wp_village)] = { 100, 0, 0 }
W.pos[g(W.wp_grove)] = { 0, 0, 50 }
W.pos[g(W.wp_moon)] = { 900, 0, 900 }
W.camp = {} -- who is in camp: where they came from
W.castq = {} -- Osi.UseSpell requests waiting for the next tick
-- Shadowheart's chosen spells (PlayerPrepareSpell); the cleric may prepare W.prepMax
W.prepared = { Projectile_GuidingBolt = true }
W.prepMax = 1
local function prepQueue(on)
    return setmetatable({}, { __newindex = function(_, e, list)
        for _, s in ipairs(list) do W.prepared[s.OriginatorPrototype] = on or nil end
    end })
end
W.castOptions = {} -- the options each cast went off with
W.thrown = {} -- what each throw threw
W.dead = {} -- who is dead
W.picked = {} -- items picked up with Osi.Pickup: by whom
W.owners = {} -- who items belong to
W.flags = {} -- story flags that are set, as "flag@entity"
-- A cut-down quest_prototypes.lsx: a main quest with three steps, a sub-quest, a closed and a hidden one.
local function quest(id, parent, title, visible, steps)
    local out = { '<node id="Quest">', '<attribute id="CategoryID" type="FixedString" value="Cat"/>',
        '<attribute id="ParentQuestID" type="FixedString" value="' .. parent .. '"/>',
        '<attribute id="QuestID" type="FixedString" value="' .. id .. '"/>',
        '<attribute id="QuestTitle" type="TranslatedString" handle="' .. title .. '" version="1"/>',
        '<attribute id="QuestVisiblity" type="bool" value="' .. visible .. '"/>', '<children>' }
    for _, st in ipairs(steps) do
        out[#out + 1] = '<node id="QuestStep"><attribute id="Description" type="TranslatedString" handle="' .. st[2]
            .. '" version="1"/><attribute id="ID" type="FixedString" value="' .. st[1]
            .. '"/><attribute id="QuestTitleOverride" type="TranslatedString" handle="x" version="0"/></node>'
    end
    out[#out + 1] = '</children></node>'
    return table.concat(out, "\n")
end
W.questFile = table.concat({ '<save><region id="Quests"><node id="root"><children>',
    quest("Q_Done", "", "An Old Errand", "true", { { "Over", "It is over." } }),
    quest("Q_Main", "", "Find the <LSTag>Relic</LSTag>", "true", { { "Met", "We met the priest." },
        { "Found", "We found the <LSTag Type='Image'>relic</LSTag> in the crypt." }, { "Won", "All done." } }),
    quest("Q_Sub", "Q_Main", "Ask the Priest", "true", { { "Ask", "Ask him." } }),
    quest("HIDDEN_Boosters", "", "Boosters", "false", {}),
    '</children></node></region></save>' }, "\n")
W.landed = {} -- where each revival put them

local function fire(name, ...)
    for _, fn in ipairs(W.listeners[name] or {}) do fn(...) end
end
W.fire = fire
W.init = {} -- initiative rolls in combat
W.conc = {} -- spell each character concentrates on
W.active = { [g(W.wall_gob)] = { SNEAKING = true } } -- [uuid] = { STATUS = true }

-- Resources and reaction preferences persist per entity, like components do.
local function resources(u)
    W.res[u] = W.res[u] or {
        ["ap-guid"] = { { Amount = 1, MaxAmount = 1, Level = 0 } },
        ["ba-guid"] = { { Amount = 1, MaxAmount = 1, Level = 0 } },
        ["mv-guid"] = { { Amount = 9, MaxAmount = 9, Level = 0 } },
        ["slot-guid"] = { { Amount = 2, MaxAmount = 2, Level = 1 } },
    }
    return W.res[u]
end

local function prefs(u)
    if not W.prefs[u] then
        local store = { Interrupt_WardingFlare = { "Ask", "Enabled" }, Interrupt_Shield = { "Ask", "Enabled" },
            Interrupt_AttackOfOpportunity = { "Enabled" } }
        local view = {}
        setmetatable(view, {
            __index = function(_, k)
                local f = store[k]
                return f and ("InterruptInteractionTypes(" .. table.concat(f, ",") .. ")") or nil
            end,
            __newindex = function(_, k, v) store[k] = v end,
            __pairs = function()
                return function(_, k)
                    local nk = next(store, k)
                    if nk then return nk, view[nk] end
                end, view, nil
            end,
        })
        W.prefs[u] = { store = store, view = view }
    end
    return W.prefs[u]
end

local ent
function ent(id)
    local u = g(id)
    local e = {
        Uuid = { EntityUuid = u },
        -- the way each one faces: no rotation looks along -Z (south)
        Transform = { Transform = { Translate = W.pos[u], RotationQuat = W.rot[u] or { 0, 0, 0, 1 } } },
        Sight = { Sight = 16.0, FOV = 90.0 },
        Health = (W.hp and W.hp[u]) or { Hp = 20, MaxHp = 25 }, -- MOCK.hp[uuid] = { Hp =, MaxHp = }
        -- MOCK.turns[uuid] = true: also in the turn (the agent and its summon share one)
        TurnBased = { IsActiveCombatTurn = W.combat and (W.turn == u or (W.shared_turn and u == g(W.host))
            or (W.turns ~= nil and W.turns[u] == true)) },
        -- MOCK.summons[uuid] = { summon ids }
        SummonContainer = { Characters = (function()
                local out = {}
                for _, id in ipairs(W.summons and W.summons[u] or {}) do out[#out + 1] = { Uuid = { EntityUuid = g(id) } } end
                return out
            end)() },
        FleeCapability = { Flags = W.fleeFlags or {}, CurrentFleeDistance = 27, FleeDistance = 4.2 },
        CombatParticipant = { InitiativeRoll = W.init[u] or -100 },
        -- the goblin resists fire, is immune to poison, takes double radiant and cannot be charmed
        Resistances = u == g(W.gob) and { AC = 15, Resistances = { {}, {}, {}, {}, {}, {}, {}, { "ResistantToMagical", "ResistantToNonMagical" },
            {}, {}, {}, "ResistanceBoostFlags(ImmuneToMagical,ImmuneToNonMagical)" --[[ the game's bitfield prints like this ]], { "VulnerableToMagical" }, {} } } or nil,
        StatusImmunities = u == g(W.gob) and { PersonalStatusImmunities = { SG_Charmed = {}, SG_Sleeping = {}, SLEEPING = {} } } or nil,
        PassiveContainer = u == g(W.gob) and { Passives = { { Passive = { PassiveId = "Darkvision" } },
            { Passive = { PassiveId = "Hidden_Passive" } }, { Passive = { PassiveId = "Nimble" } } } } or nil,
        EocLevel = { Level = 3 },
        ServerCharacter = (function() for _, c in ipairs(W.chars) do if g(c) == u then return {} end end end)(),
        Stats = { Abilities = { 0, 8, 14, 10, 10, 8, 8 } },
        Concentration = { SpellId = { OriginatorPrototype = W.conc[u] or "", Prototype = W.conc[u] or "" } },
        ActionResources = { Resources = resources(u) },
        SpellContainer = { Spells = {
            { SpellId = { OriginatorPrototype = "Target_MainHandAttack" }, ContainerSpell = "", PrepareType = "AlwaysPrepared" },
            { SpellId = { OriginatorPrototype = "Projectile_GuidingBolt", ProgressionSource = "cleric-guid" }, ContainerSpell = "", PrepareType = "RequiresPreparation" },
            { SpellId = { OriginatorPrototype = "Target_CureWounds", ProgressionSource = "cleric-guid" }, ContainerSpell = "", PrepareType = "RequiresPreparation" },
            { SpellId = { OriginatorPrototype = "Projectile_Fireball" }, ContainerSpell = "", PrepareType = "AlwaysPrepared" },
            { SpellId = { OriginatorPrototype = "Zone_BurningHands" }, ContainerSpell = "", PrepareType = "AlwaysPrepared" },
            { SpellId = { OriginatorPrototype = "Shout_SpiritGuardians" }, ContainerSpell = "", PrepareType = "AlwaysPrepared" },
            { SpellId = { OriginatorPrototype = "Shout_TurnUndead" }, ContainerSpell = "", PrepareType = "AlwaysPrepared" },
            { SpellId = { OriginatorPrototype = "Shout_HealingWord_Mass" }, ContainerSpell = "", PrepareType = "AlwaysPrepared" },
            { SpellId = { OriginatorPrototype = "Shout_RadianceOfTheDawn" }, ContainerSpell = "", PrepareType = "AlwaysPrepared" },
            { SpellId = { OriginatorPrototype = "Target_FlamingSphere" }, ContainerSpell = "", PrepareType = "AlwaysPrepared" },
            { SpellId = { OriginatorPrototype = "Teleportation_Revivify" }, ContainerSpell = "", PrepareType = "AlwaysPrepared" },
            { SpellId = { OriginatorPrototype = "Projectile_Jump" }, ContainerSpell = "", PrepareType = "AlwaysPrepared" },
        } },
        SpellBookPrepares = { PreparedSpells = (function()
                local out = { { OriginatorPrototype = "Target_MainHandAttack" } }
                for id in pairs(W.prepared) do out[#out + 1] = { OriginatorPrototype = id } end
                return out
            end)(), ClassFallbackPreparedSpellCount = { ["cleric-guid"] = W.prepMax } },
        PlayerPrepareSpell = { Spells = (function()
                local out = {}
                for id in pairs(W.prepared) do out[#out + 1] = { OriginatorPrototype = id, ProgressionSource = "cleric-guid" } end
                return out
            end)() },
        InterruptPreferences = { Preferences = prefs(u).view },
        StatusContainer = { Statuses = { "BLESSED", table.unpack(u == g(W.sh) and W.statuses
            or (W.st and W.st[u]) or {}) } }, -- MOCK.st[uuid] = { statuses } for others
        Replicate = function() end,
        Tag = { Tags = (W.undead and W.undead[u]) and { "undead-tag" } or {} },
    }
    local it = W.item[u]
    if it then
        e.Data = { StatsId = it.stats }
        if it.slot then e.Equipable = { Slot = it.slot } end
        if it.total > 1 then e.InventoryStack = { Entries = { { EntityIndex = 0, Quantity = 1 },
            { EntityIndex = 1, Quantity = it.total - 1 } } } end
        if it.stats == "OBJ_Scroll_Bless" then e.SpellBook = { Spells = { { Id = { OriginatorPrototype = "Target_Bless" } } } } end
        if it.stats == "OBJ_Scroll_Revivify" then
            e.SpellBook = { Spells = { { Id = { OriginatorPrototype = "Teleportation_Revivify_Scroll" } } } }
        end
    end
    if u == g(W.sh) then
        local main, worn = {}, {}
        for i, id in ipairs(W.itemOrder) do
            local x = W.item[g(id)]
            if x and g(x.owner) == u then
                local list = x.equipped and worn or main
                list[i] = { Item = ent(id) }
            end
        end
        e.InventoryOwner = { Inventories = {
            { InventoryData = { Type = "Main" }, InventoryContainer = { Items = main } },
            { InventoryData = { Type = "Equipment" }, InventoryContainer = { Items = worn } },
        } }
    end
    if W.doors and W.doors[u] then e.ServerItem = { IsDoor = true, CanUse = true } end
    if W.usable and W.usable[u] then e.ServerItem = { CanUse = true } end -- MOCK.usable: objects one can use
    if u == g(W.chest) then
        e.ServerItem = { IsContainer = true }
        e.InventoryOwner = { Inventories = { { InventoryContainer = { Items = { { Item = { Uuid = { EntityUuid = g(W.potion) } } } } } } } }
    end
    return e
end

local resNames = { ["cleric-guid"] = "Cleric", ["ap-guid"] = "ActionPoint", ["ba-guid"] = "BonusActionPoint", ["mv-guid"] = "Movement",
    ["slot-guid"] = "SpellSlot" }

Ext = {
    Utils = { MonotonicTime = function() return PY_now() end, GetGameState = function() return "Running" end,
        GenerateGuid = function() return "aaaaaaaa-0000-0000-0000-000000000001" end },
    -- the memory mod: loaded only when a test loads it (load_memory_mod); its variables are the save's
    Mod = { IsModLoaded = function(u) return W.mods[u] == true end,
        GetMod = function(u) return W.mods[u] and { Info = { Name = "BG3 Co-op Memory" } } or nil end },
    Vars = { RegisterModVariable = function() end, GetModVariables = function(u)
        W.modvars[u] = W.modvars[u] or {}
        return W.modvars[u]
    end },
    Events = setmetatable({}, { __index = function(t, name)
        local ev = { Subscribe = function(self, fn) W.subs[name] = W.subs[name] or {}; table.insert(W.subs[name], fn) end }
        rawset(t, name, ev)
        return ev
    end }),
    RegisterNetListener = function(channel, fn)
        W.net = W.net or {}
        W.net[channel] = fn
    end,
    Json = { Parse = function(s) return PY_parse(s) end, Stringify = function(v) return PY_stringify(v) end },
    Loca = { GetTranslatedString = function(h) return h end },
    IO = { LoadFile = function(path, ctx)
        if path:find("quest_prototypes", 1, true) and ctx == "data" then return W.questFile end
        return nil
    end },
    Entity = {
        Get = function(id) return ent(id) end,
        GetAllEntitiesWithComponent = function(name)
            local out = {}
            if name == "ServerRoomTrigger" then return W.rooms or {} end -- MOCK.rooms: { {Transform=..., TriggerArea=...} }
            -- MOCK.summoner[summon uuid] = summoner (Osi.CharacterGetOwner); IsSummon is on them
            if name == "IsSummon" then
                for u in pairs(W.summoner or {}) do out[#out + 1] = ent(u) end
                return out
            end
            local list = name == "ServerCharacter" and W.chars or W.items
            for _, id in ipairs(list) do out[#out + 1] = ent(id) end
            return out
        end,
    },
    Types = { Serialize = function(c) return c end },
    -- the grease bottle's template leaves a 3 m puddle
    Template = { GetTemplate = function(id)
        if id == "TPL_OBJ_Grease" then return { OnDestroyActions = { { Type = "PlaySound" },
            { Type = "CreateSurface", Radius = 3.0, SurfaceType = "Grease" } } } end
    end },
    StaticData = { Get = function(guid) return { Name = guid == "undead-tag" and "UNDEAD" or resNames[guid] } end },
    Stats = { Get = function(name)
        if name == "Target_MainHandAttack" then return { DisplayName = "Attack", Level = 0, UseCosts = "ActionPoint:1",
            TargetRadius = "MeleeMainWeaponRange", VerbalIntent = "Damage" } end
        if name == "Projectile_GuidingBolt" then return { DisplayName = "Guiding Bolt", Level = 1,
            UseCosts = "ActionPoint:1;SpellSlotsGroup:1:1:1", TargetRadius = "18", VerbalIntent = "Damage",
            TargetConditions = "not Dead()" } end
        if name == "Target_CureWounds" then return { DisplayName = "Cure Wounds", Level = 1,
            UseCosts = "ActionPoint:1;SpellSlotsGroup:1:1:1", TargetRadius = "1.5", VerbalIntent = "Healing" } end
        -- area spells, with the fields the friendly-fire check reads (as in the game's stats)
        if name == "Projectile_Fireball" then return { DisplayName = "Fireball", Level = 0, UseCosts = "ActionPoint:1",
            TargetRadius = "18", VerbalIntent = "Damage", SpellType = "Projectile", AreaRadius = "4", ExplodeRadius = "4",
            TargetConditions = "not (HasPassive('SculptSpells', context.Source) and Ally())" } end
        if name == "Zone_BurningHands" then return { DisplayName = "Burning Hands", Level = 0, UseCosts = "ActionPoint:1",
            VerbalIntent = "Damage", SpellType = "Zone", Range = "5", Shape = "Cone", Angle = "60",
            TargetConditions = "not Dead() and not (HasPassive('SculptSpells', context.Source) and Ally())" } end
        if name == "Shout_SpiritGuardians" then return { DisplayName = "Spirit Guardians", Level = 0, UseCosts = "ActionPoint:1",
            VerbalIntent = "Damage", SpellType = "Shout", AreaRadius = "3", TargetConditions = "Self()" } end
        if name == "Shout_TurnUndead" then return { DisplayName = "Turn Undead", Level = 0, UseCosts = "ActionPoint:1",
            VerbalIntent = "Control", SpellType = "Shout", AreaRadius = "9",
            TargetConditions = "Character() and Tagged('UNDEAD') or HasStatus('LOW_GHOST_POSSESSED')" } end
        if name == "Shout_HealingWord_Mass" then return { DisplayName = "Mass Healing Word", Level = 0,
            UseCosts = "BonusActionPoint:1", VerbalIntent = "Healing", SpellType = "Shout", AreaRadius = "9",
            TargetConditions = "Ally() and not Dead()",
            SpellProperties = { { Functors = { { TypeId = "RegainHitPoints" } } } } } end
        -- burns enemies, though the game calls it a healing spell
        if name == "Shout_RadianceOfTheDawn" then return { DisplayName = "Radiance of the Dawn", Level = 0,
            UseCosts = "ActionPoint:1", VerbalIntent = "Healing", SpellType = "Shout", AreaRadius = "9",
            TargetConditions = "Enemy() and Character()", SpellSuccess = { { Functors = { { TypeId = "DealDamage" } } } } } end
        if name == "Interrupt_WardingFlare" then return { DisplayName = "Warding Flare", Cost = "ReactionActionPoint:1" } end
        if name == "Interrupt_Shield" then return { DisplayName = "Shield", Cost = "ReactionActionPoint:1;SpellSlotsGroup:1:1:1" } end
        if name == "Interrupt_AttackOfOpportunity" then return { DisplayName = "Attack of Opportunity", Cost = "ReactionActionPoint:1" } end
        if name == "BLESSED" then return { DisplayName = "Blessed" } end
        if name == "Darkvision" then return { DisplayName = "Darkvision", Properties = { "Highlighted" },
            Description = "Can see in the <LSTag Tooltip=\"Dark\">dark</LSTag> up to [1].", DescriptionParams = "Distance(12)" } end
        if name == "Hidden_Passive" then return { DisplayName = "Technical", Properties = { "IsHidden" } } end
        if name == "Nimble" then return { DisplayName = "Nimble Escape", Properties = {}, Description = "Disengage or hide as a bonus action." } end
        if name == "SLEEPING" then return { DisplayName = "Asleep", StatusGroups = { "SG_Condition", "SG_Sleeping" } } end
        if name == "BURNING" then return { DisplayName = "Burning", StatusGroups = "SG_Surface;SG_Light",
            Description = "Takes [1] at the start of <LSTag>each</LSTag> turn.", DescriptionParams = "DealDamage(1d4,Fire)" } end
        -- kept off the portraits, out of the combat log, or only unlocking an action for a turn
        if name == "DIFFICULTY" then return { DisplayName = "Hardcore", StatusPropertyFlags = { "DisableOverhead", "DisablePortraitIndicator" } } end
        if name == "GWM_BONUS_ATTACK" then return { DisplayName = "GWM: Bonus Attack", StatusPropertyFlags = { "DisableOverhead", "DisableCombatlog" },
            Boosts = "UnlockSpell(Target_GreatWeaponMaster_BonusAttack)" } end
        if name == "MARTIAL_ARTS" then return { DisplayName = "Martial Arts", StatusPropertyFlags = {},
            Boosts = "UnlockSpell(Target_UnarmedStrike_Monk)" } end
        -- a summon: it goes on the ground, not on a character
        if name == "Target_FlamingSphere" then return { DisplayName = "Flaming Sphere", Level = 0, UseCosts = "ActionPoint:1",
            TargetRadius = "18", SpellType = "Target", VerbalIntent = "Summon", SpellFlags = { "IsSpell", "CannotTargetCharacter" },
            TargetConditions = "CanStand('x') and not Character() and not Self()" } end
        -- a jump is movement: it also cannot target a character
        if name == "Projectile_Jump" then return { DisplayName = "Jump", Level = 0, TargetRadius = "4.5",
            UseCosts = "BonusActionPoint:1;Movement:3", SpellType = "Projectile", VerbalIntent = "Utility",
            SpellFlags = { "IsJump", "CannotTargetCharacter", "CannotTargetItems" } } end
        if name == "Target_Bless" then return { DisplayName = "Bless", Level = 1, UseCosts = "ActionPoint:1;SpellSlotsGroup:1:1:1" } end
        if name == "OBJ_Potion_Healing" then return { ModifierList = "Object", ItemUseType = "Potion",
            ObjectCategory = "PotionHealing", UseCosts = "BonusActionPoint:1" } end
        if name == "OBJ_Scroll_Bless" then return { ModifierList = "Object", ItemUseType = "Scroll", UseCosts = "ActionPoint:1" } end
        if name == "ARM_Helmet" or name == "ARM_Circlet" then return { ModifierList = "Armor", UseCosts = "ActionPoint:1" } end
        if name == "POTION_HEALING" then return { DisplayName = "Healing" } end
        if name == "OBJ_Grease" then return { ModifierList = "Object", ItemUseType = "Grenade", UseCosts = "ActionPoint:1" } end
        if name == "Throw_Throw" then return { DisplayName = "Throw", UseCosts = "ActionPoint:1" } end
        if name == "OBJ_Scroll_Revivify" then return { ModifierList = "Object", ItemUseType = "Scroll", UseCosts = "ActionPoint:1" } end
        if name == "Teleportation_Revivify" then return { DisplayName = "Revivify", Level = 3, UseCosts = "ActionPoint:1",
            SpellType = "Teleportation", TargetConditions = "not Character()",
            OriginTargetConditions = "(Dead() or IsDowned()) and Tagged('PLAYABLE')" } end
        if name == "Teleportation_Revivify_Scroll" then return { DisplayName = "Revivify", Level = 3, UseCosts = "ActionPoint:1",
            OriginTargetConditions = "(Dead() or IsDowned()) and Tagged('PLAYABLE')" } end
        return nil
    end },
    Timer = { WaitFor = function(_, fn) W.timers[#W.timers + 1] = fn end },
    -- ground everywhere, except east of MOCK.edgeX when a test sets it
    Level = { GetHeightsAt = function(x) if W.edgeX and x > W.edgeX then return {} end return { 0 } end,
        -- a hit when the segment passes through one of MOCK.walls (on the ground plane)
        RaycastAny = function(a, b)
            for _, w in ipairs(W.walls) do
                local dx, dz = b[1] - a[1], b[3] - a[3]
                local l2 = dx * dx + dz * dz
                local t = l2 > 0 and math.max(0, math.min(1, ((w[1] - a[1]) * dx + (w[2] - a[3]) * dz) / l2)) or 0
                local px, pz = a[1] + dx * t - w[1], a[3] + dz * t - w[2]
                if px * px + pz * pz <= w[3] * w[3] then return true end
            end
            return false
        end,
        -- the one move/use/talk ask before setting off: a straight way to the goal, none with
        -- MOCK.noPath, when the goal is off the ground (MOCK.edgeX) or past one of MOCK.blocks
        -- ({ x, z, r, door = true | ladder = true }: a locked door is passed with CheckLockedDoors
        -- off, a ladder with CanUseLadders). Like the game, a large CloseEnoughMax ends the way at
        -- the closest point it gets to; MOCK.pathShort ends every way that far short of the goal.
        BeginPathfindingImmediate = function(e, to)
            local p = e.Transform.Transform.Translate
            return { from = { p[1], p[2], p[3] }, to = { to[1], to[2], to[3] }, CloseEnoughMax = 3.5,
                CheckLockedDoors = true, CanUseLadders = false, GoalFound = false, Nodes = {} }
        end,
        FindPath = function(path)
            W.pathAsked = (W.pathAsked or 0) + 1
            local a, b = path.from, path.to
            if W.edgeX and b[1] > W.edgeX then return false end
            local dx, dz = b[1] - a[1], b[3] - a[3]
            local len = math.sqrt(dx * dx + dz * dz)
            local stop = W.noPath and 0 or 1 -- how far along the way gets
            for _, k in ipairs(W.blocks or {}) do
                local passed = (k.door and not path.CheckLockedDoors) or (k.ladder and path.CanUseLadders)
                if not passed and len > 0 then
                    local t = math.max(0, math.min(1, ((k[1] - a[1]) * dx + (k[2] - a[3]) * dz) / (len * len)))
                    local px, pz = a[1] + dx * t - k[1], a[3] + dz * t - k[2]
                    local off = math.sqrt(px * px + pz * pz)
                    if off < k[3] then stop = math.min(stop, math.max(0, t - math.sqrt(k[3] ^ 2 - off ^ 2) / len - 0.2 / len)) end
                end
            end
            local reach = path.CloseEnoughMax
            if (1 - stop) * len > reach then return false end
            if stop == 1 and W.pathShort and len > 0 then stop = math.max(0, 1 - math.min(W.pathShort, reach) / len) end
            local q = { a[1] + dx * stop, a[2] + (b[2] - a[2]) * stop, a[3] + dz * stop }
            -- Distance: the movement the way costs (W.pathCostScale: e.g. a cheap ladder climb)
            local cost = len * stop * (W.pathCostScale or 1)
            path.GoalFound, path.Nodes = true, { { Position = a, Distance = 0 }, { Position = q, Distance = cost } }
            return true
        end,
        ReleasePath = function() end },
    System = { ServerCastRequest = { OsirisCastRequests = W.castq },
        ServerSpell = { PlayerPrepareSpell = prepQueue(true), PlayerUnprepareSpell = prepQueue(false) } },
    Osiris = { RegisterListener = function(name, _, _, fn)
        W.listeners[name] = W.listeners[name] or {}
        table.insert(W.listeners[name], fn)
    end },
}

local function b(x) return x and 1 or 0 end

local function moveTo(ch, p) W.pos[g(ch)] = { p[1], p[2], p[3] } end

local function runTimers()
    local timers = W.timers
    W.timers = {}
    for _, fn in ipairs(timers) do fn() end
end

-- Like the game: the request waits a tick (timers run then and may edit it), then the cast goes off.
-- A throw at a character (`thrown` given) shows up a tick later and names what is thrown itself.
local function castLater(c, s, target, thrown)
    if thrown then runTimers() end
    if W.walkOnCast then local p = W.pos[g(c)]; moveTo(c, { p[1] + W.walkOnCast, p[2], p[3] }) end
    W.castq[1] = { Caster = ent(c), Spell = { Prototype = s, OriginatorPrototype = s },
        CastOptions = { "IgnoreSpellRolls", "AvoidDangerousAuras", "IgnoreCastChecks", "IgnoreTargetChecks", "IgnoreHasSpell" },
        Targets = { { Target = target and ent(target) or nil, Position = not target and { 1, 0, 1 } or nil,
            TargetingType = s == "Throw_Throw" and "Throw" or "Target",
            Target2 = thrown and { Target = ent(thrown) } or nil } } }
    runTimers()
    local r = table.remove(W.castq, 1)
    local opts = {}
    for _, o in ipairs(r.CastOptions) do opts[o] = true end
    W.castOptions[#W.castOptions + 1] = opts
    if W.opportunist then
        -- an enemy's opportunity attack as the caster leaves its reach cuts the cast off
        local a = W.opportunist
        W.opportunist = nil
        -- the game reports the failure first, then the blow
        fire("CastSpellFailed", c, s, "", "", 1)
        return fire("AttackedBy", c, a, a, "Slashing", 18, "", 1)
    end
    if s == "Teleportation_Revivify_Scroll" or s == "Teleportation_Revivify" then
        local t = r.Targets[1]
        if not opts.IgnoreTargetChecks and not (t.Target and W.dead[g(t.Target.Uuid.EntityUuid)]) then
            return fire("CastSpellFailed", c, s, "", "", 1)
        end
        local u = g(t.Target.Uuid.EntityUuid)
        W.dead[u] = nil
        W.landed[#W.landed + 1] = t.Target2 and t.Target2.Position
        if t.Target2 and t.Target2.Position then moveTo(u, t.Target2.Position) end
    end
    if s == "Throw_Throw" then
        -- the game checks what is thrown only without IgnoreTargetChecks
        local t2 = r.Targets[1].Target2
        local u = t2 and g(t2.Target.Uuid.EntityUuid)
        local x = u and W.item[u]
        if not u or (x and x.equipped and not opts.IgnoreTargetChecks) then
            return fire("CastSpellFailed", c, s, "", "", 1)
        end
        W.thrown[#W.thrown + 1] = u
        if x then
            x.total = x.total - 1
            if x.total <= 0 then W.item[u] = nil end
        end
    end
    if r.Item and opts.DestroySource then
        local u = g(r.Item.Uuid.EntityUuid)
        local x = W.item[u]
        x.total = x.total - 1
        if x.total <= 0 then W.item[u] = nil end
    end
    fire("CastedSpell", c, s, "target", "", 1)
end

Osi = {
    DB_PartyMembers = { Get = function() return { { W.host }, { W.sh } } end },
    DB_Avatars = { Get = function() return W.avatars or { { W.host } } end },
    DB_Dialogs = { Get = function(_, npc)
        if g(npc) == g(W.npc) then return { { W.npc, "Arron_Dialog" } } end
        return {}
    end },
    DB_DialogPlayers = { Get = function(_, inst)
        local out = {}
        for u, i in pairs(W.dialog) do if i == inst then out[#out + 1] = { inst, u, #out + 1 } end end
        return out
    end },
    DB_PlayerInCamp = { Get = function(_, u) return W.camp[g(u)] and { { u } } or {} end },
    QRY_Camp_IsPlayerBlockedFromTeleportToCamp = function() return W.campBlocked == true end,
    DB_QuestIsAccepted = { Get = function() return { { "Q_Main" }, { "Q_Sub" }, { "Q_Done" }, { "HIDDEN_Boosters" } } end },
    DB_QuestIsClosed = { Get = function() return { { "Q_Done" } } end },
    DB_QuestDef_State = { Get = function(_, _, q)
        local all = { { "FLAG_Met", "Q_Main", "Met" }, { "FLAG_Found", "Q_Main", "Found" }, { "FLAG_Won", "Q_Main", "Won" } }
        local out = {}
        for _, r in ipairs(all) do if r[2] == q then out[#out + 1] = r end end
        return out
    end },
    GetFlag = function(flag, who) return W.flags[flag .. "@" .. tostring(who)] and 1 or 0 end,
    DB_CurrentLevel = { Get = function() return { { "WLD_Main_A" } } end },
    DB_WaypointInfo = { Get = function() return {
        { "Act1", "WAYP_Village", "WP_Item_1", W.wp_village },
        { "Act1", "WAYP_Grove", "WP_Item_2", W.wp_grove },
        { "Act2", "WAYP_Moonrise", "WP_Item_3", W.wp_moon },
    } end },
    DB_WaypointUnlocked = { Get = function(_, id) return id ~= "WAYP_Grove" and { { id } } or {} end },
    QRY_WaypointTeleport_PlayerBlocked = function() return W.wpBlocked == true end,
    QRY_GLO_BlockTeleportToWaypoint = function() return false end,
    PROC_WaypointTeleportTo = function(u, trigger)
        for _, c in ipairs({ W.host, W.sh }) do
            if g(c) == g(u) or (not W.detached[g(c)] and not W.detached[g(u)]) then moveTo(c, W.pos[g(trigger)]) end
        end
    end,
    DB_Camp_NightMode = { Get = function() return W.campNight and { { 1 } } or {} end },
    InSamePartyGroup = function(x, y)
        if W.staleGroup then W.staleGroup = nil; return 1 end
        return b(not W.detached[g(x)] and not W.detached[g(y)])
    end,
    -- like the game: entering brings chained characters, the button's leave sends out everyone in camp
    PROC_TeleportToFromCamp = function(u)
        if W.camp[g(u)] then
            for k in pairs(W.camp) do Osi.PROC_Camp_Leave(k) end
            return
        end
        for _, c in ipairs({ W.host, W.sh }) do
            if g(c) == g(u) or (not W.detached[g(c)] and not W.detached[g(u)]) then
                W.camp[g(c)] = W.pos[g(c)]; moveTo(c, { 500, 0, 500 })
            end
        end
    end,
    PROC_Camp_Leave = function(u) local k = g(u); moveTo(k, W.camp[k]); W.camp[k] = nil end,
    GetHostCharacter = function() return W.selected or W.host end,
    GetReservedUserID = function(id) return (W.reserved or {})[g(id)] or 1 end,
    GetDisplayName = function(u) return W.names[g(u)] end,
    GetPosition = function(u) local p = W.pos[g(u)]; if p then return p[1], p[2], p[3] end end,
    IsOnStage = function(u) return b(not (W.offstage and W.offstage[g(u)])) end,
    IsInvisible = function(u) return b(W.invisible and W.invisible[g(u)]) end, -- MOCK.invisible[uuid] = true
    IsInvisibleByScript = function() return 0 end,
    IsOpened = function(u) return b(W.opened and W.opened[g(u)]) end, -- MOCK.opened[uuid] = true
    CanSee = function(_, u) return b(g(u) ~= g(W.wall_gob) and not (W.doors and W.doors[g(u)])) end,
    HasLineOfSight = function(_, u) return b(g(u) ~= g(W.wall_gob) and not (W.doors and W.doors[g(u)])) end,
    IsEnemy = function(_, u) return b(g(u) == g(W.gob)) end,
    IsAlly = function() return 0 end,
    IsDead = function(u) return b(W.dead[g(u)]) end,
    HasPassive = function(_, name) return b(name == "SculptSpells" and W.sculpt) end,
    -- everyone is in the fight unless the test names the fighters
    IsInCombat = function(u) return b(W.combat and (not W.fighters or W.fighters[g(u)])) end,
    -- MOCK.ftb: the party is in turn-based mode outside combat
    IsInForceTurnBasedMode = function(u) return b(W.ftb) end,
    CombatGetGuidFor = function(u) if Osi.IsInCombat(u) == 1 then return "combat-1" end end,
    DB_Is_InCombat = { Get = function()
        local out = {}
        for _, c in ipairs(W.chars) do if Osi.IsInCombat(c) == 1 then out[#out + 1] = { c, "combat-1" } end end
        return out
    end },
    DB_CombatFlee_BlockedFor = { Get = function(_, u) return W.fleeBlocked and { { u } } or {} end },
    -- the story's answer to the event: wait until the player left combat, then send them to camp
    FleeFromCombat = function(u, id) W.fled = { g(u), id } end,
    LeaveCombat = function(u)
        W.fighters = W.fighters or {}
        for _, c in ipairs(W.chars) do if W.fighters[g(c)] == nil then W.fighters[g(c)] = true end end
        W.fighters[g(u)] = false
        if W.fled and W.fled[1] == g(u) then W.camp[g(u)] = { table.unpack(W.pos[g(u)]) } end
    end,
    HasActiveStatus = function(u, st) return b(W.active[g(u)] and W.active[g(u)][st]) end,
    SpeakerGetDialog = function(u, n) local i = W.dialog[g(u)]; if i and (n or 1) == 1 then return "Some_Dialog", i end end,
    DB_AutomatedDialog = { Get = function(_, inst) return W.barks[inst] and { { inst } } or {} end },
    GetHasDefaultDialog = function(u) return b(g(u) == g(W.npc)) end,
    GetHasOsirisDialog = function() return 0 end,
    CanTrade = function(u) return b(g(u) == g(W.npc)) end,
    GetCanInteract = function() return 1 end,
    -- MOCK.traps[uuid] = { discovered = bool, armed = bool }
    IsTrap = function(u) return b(W.traps and W.traps[g(u)]) end,
    IsTrapDiscovered = function(u) local t = W.traps and W.traps[g(u)]; return b(t and t.discovered) end,
    IsTrapArmed = function(u) local t = W.traps and W.traps[g(u)]; return b(t and t.armed) end,
    IsLocked = function(u) return b(W.locked and W.locked[g(u)]) end,
    GetRegion = function(u) return g(u) == g(W.wp_moon) and "MOO_Main_A" or "WLD_Main_A" end,
    PartyGetGold = function() return 120 end,
    GetStackAmount = function() return 1 end, -- like the game: only the first entity of a stack
    GetInventoryOwner = function(it)
        if W.picked[g(it)] then return W.picked[g(it)] end
        if g(it) == g(W.potion) then return W.chest end
        local x = W.item[g(it)]
        return x and x.owner or nil
    end,
    IsEquipped = function(it) local x = W.item[g(it)]; return b(x and x.equipped) end,
    Equip = function(_, it)
        local x = W.item[g(it)]
        for _, y in pairs(W.item) do if y.slot == x.slot then y.equipped = nil end end
        x.equipped = true
    end,
    Unequip = function(_, it) W.item[g(it)].equipped = nil end,
    GetTemplate = function(it) local x = W.item[g(it)]; return x and ("TPL_" .. x.stats) end,
    TemplateIsInInventory = function(tpl, ch)
        local n = 0
        for _, x in pairs(W.item) do
            if "TPL_" .. x.stats == tpl and g(x.owner) == g(ch) then n = n + x.total end
        end
        return n
    end,
    TemplateRemoveFrom = function(tpl, ch, n)
        for u, x in pairs(W.item) do
            if "TPL_" .. x.stats == tpl and g(x.owner) == g(ch) then
                x.total = x.total - n
                if x.total <= 0 then W.item[u] = nil end
                return
            end
        end
    end,
    -- like the game: the group check sees the unchain a moment later
    DetachFromPartyGroup = function(u) W.detached[g(u)] = true; W.staleGroup = true end,
    AttachToPartyGroup = function(u) W.detached[g(u)] = nil end,
    CharacterMoveTo = function(ch, target) W.movedToObject = true; moveTo(ch, W.pos[g(target)]) end,
    CharacterMoveToPosition = function(ch, x, y, z, how)
        W.walked_how = how
        if not W.slow then moveTo(ch, { x, y, z }) end -- MOCK.slow: still on the way
    end,
    PurgeOsirisQueue = function(u) W.purged = g(u) end,
    Use = function(ch, it)
        local x = W.item[g(it)]
        if not x then -- using a world object: MOCK.onUse[uuid](who) does what it does
            local f = W.onUse and W.onUse[g(it)]
            if f then f(ch) end
            return
        end
        W.statuses[#W.statuses + 1] = "POTION_HEALING"
        x.total = x.total - 1
        if x.total <= 0 then W.item[g(it)] = nil end
    end,
    -- picking up as a click does; the game would also raise CharacterStoleItem for owned items
    Pickup = function(ch, it) W.picked[g(it)] = ch end,
    GetOwner = function(it) return W.owners[g(it)] end,
    ToInventory = function(it, to, n)
        W.inv[#W.inv + 1] = g(it)
        local x = W.item[g(it)]
        if x then x.owner = to; x.given = n end
    end,
    QRY_SelectAndStartDialog = function(npc, pl)
        W.selectedDialog = true
        return Osi.QRY_StartDialog_Fixed(Osi.DB_Dialogs:Get(npc)[1][2], npc, pl)
    end,
    QRY_StartDialog_Fixed = function(dlg, npc, pl)
        W.nextDialog = W.nextDialog + 1
        W.dialog[g(pl)] = W.nextDialog
        fire("DialogStarted", dlg, W.nextDialog)
        return false -- like the game: the return value says nothing
    end,
    RemoveStatus = function(u, st)
        if W.active[g(u)] and W.active[g(u)][st] then
            W.active[g(u)][st] = nil
            fire("StatusRemoved", u, st, "", 1)
        end
    end,
    UseSpell = function(c, s, t, thrown)
        if s == "Shout_Hide" or s == "Shout_Hide_BonusAction" then
            W.active[g(c)] = W.active[g(c)] or {}
            W.active[g(c)].SNEAKING = true
        end
        W.casts[#W.casts + 1] = s .. "@" .. g(t); castLater(c, s, t, thrown) end,
    UseSpellAtPosition = function(c, s, x, y, z)
        W.casts[#W.casts + 1] = s .. "@pos"; W.castAt = { x, y, z }; castLater(c, s) end,
    CharacterGetOwner = function(u) return W.summoner and W.summoner[g(u)] or nil end,
    EndTurn = function() if not W.shared_turn then W.turn = nil end end,
    OpenMessageBox = function(_, text) W.message = text end,
    ShowNotification = function(_, text) W.notice = text end,
}
