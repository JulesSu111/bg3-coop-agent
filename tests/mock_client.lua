-- Fake client-side Ext for offline tests: JSON, an empty UI root, and just enough IMGUI and
-- events for the chat panel. MOCK_C.windows holds every window made; MOCK_C.subs the handlers.

MOCK_C = { windows = {}, subs = {} }

local function element(kind, label)
    local el = { kind = kind, Label = label, Children = {}, colors = {} }
    function el:SetColor(name, c) self.colors[name] = c end
    function el:SetSize(size) self.size = size end
    function el:SetScroll(v) self.scrolled = v end
    function el:SetCollapsed(v) self.collapsed = v end
    function el:SetStyle(name, a, b) self.styles = self.styles or {}; self.styles[name] = b and { a, b } or a end
    function el:SetSizeConstraints(lo, hi) self.limits = { lo, hi } end
    function el:Tooltip() self.tip = self.tip or element("tooltip") return self.tip end
    function el:Destroy() self.destroyed = true end
    function el:RemoveAllChildren() self.Children = {} end
    local function add(k)
        return function(self, lbl, value)
            local child = element(k, lbl)
            if k == "input" then child.Text = value or "" end
            self.Children[#self.Children + 1] = child
            return child
        end
    end
    el.AddText = add("text")
    el.AddButton = add("button")
    el.AddInputText = add("input")
    el.AddChildWindow = add("child")
    el.AddGroup = add("group")
    el.AddCollapsingHeader = add("header")
    el.AddSpacing = add("spacing")
    el.AddSeparator = add("separator")
    el.AddTabBar = add("tabbar")
    el.AddTabItem = add("tab")
    el.AddTable = add("table")
    el.AddRow = add("row")
    el.AddCell = add("cell")
    el.AddProgressBar = add("progress")
    return el
end

local function event(name)
    return {
        Subscribe = function(_, fn)
            MOCK_C.subs[name] = MOCK_C.subs[name] or {}
            local list = MOCK_C.subs[name]
            list[#list + 1] = fn
            return #list
        end,
        Unsubscribe = function(_, id) MOCK_C.subs[name][id] = false end,
    }
end

function MOCK_C.fire(name, e)
    for _, fn in ipairs(MOCK_C.subs[name] or {}) do
        if fn then fn(e) end
    end
end

-- The panel as the human sees it: the newest window and its message log.
function MOCK_C.panel()
    local w = MOCK_C.windows[#MOCK_C.windows]
    return w, w.Children[4].Children[1].Children[1]
end

Ext = {
    Json = { Parse = function(s) return PY_parse(s) end, Stringify = function(v) return PY_stringify(v) end },
    -- MOCK_C.pick: what the mouse is over, as the picking helper reports it
    -- MOCK_C.root: a UI tree to read dialogues from (nil: nothing on screen)
    UI = { GetRoot = function() return MOCK_C.root end, GetPickingHelper = function() return MOCK_C.pick end,
        Defer = function(fn)
            if MOCK_C.holdUI then MOCK_C.deferred = fn else fn() end
        end },
    ClientNet = { PostMessageToServer = function(channel, payload) PY_client_net(channel, payload) end },
    Loca = { GetTranslatedString = function(h) return (MOCK_C.loca or {})[h] or "" end },
    IMGUI = {
        GetViewportSize = function() return { 2560, 1440 } end,
        NewWindow = function(label)
            local w = element("window", label)
            w.Open = true
            MOCK_C.windows[#MOCK_C.windows + 1] = w
            return w
        end,
    },
    -- MOCK_C.turns[uuid]: the TurnBased component the client sees for that character
    Entity = { Get = function(u) local tb = (MOCK_C.turns or {})[u] return tb and { TurnBased = tb } end },
    Events = { KeyInput = event("KeyInput"), Tick = event("Tick"), MouseButtonInput = event("MouseButtonInput") },
    Utils = { MonotonicTime = function() return MOCK_C.now or 0 end,
        GetGlobalSwitches = function() return { Language = MOCK_C.language or "English" } end },
}
