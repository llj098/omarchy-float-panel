local binds = {}
local handlers = {}
local dispatched = {}
local commands = {}
local unbound = {}
local bind_options = {}
local window_rules = {}

local function workspace(id, name, special)
  local value = { id = id, name = name, special = special == true, windows = {} }
  function value:get_windows() return self.windows end
  return value
end

local ws1 = workspace(1, "1", false)
local ws2 = workspace(2, "2", false)
local special = workspace(-99, "special:test", true)
local w1 = { workspace = ws1, floating = false, pid = 1 }
local w2 = { workspace = ws1, floating = false, pid = 1 }
ws1.windows = { w1, w2 }

local active_workspace = ws1
local active_window = w1

hl = {
  dsp = {
    window = {
      float = function(params) return { kind = "float", params = params } end,
      move = function(params) return { kind = "move", params = params } end,
      resize = function(params) return { kind = "resize", params = params } end,
      tag = function(params) return { kind = "tag", params = params } end,
      cycle_next = function(params) return { kind = "cycle_next", params = params } end,
      bring_to_top = function() return { kind = "bring_to_top", params = {} } end,
    },
    focus = function(params) return { kind = "focus", params = params } end,
    global = function(name) return { kind = "global", name = name } end,
  },
  dispatch = function(action)
    table.insert(dispatched, action)
    if action.kind == "float" then
      action.params.window.floating = action.params.action == "on"
    elseif action.kind == "move" then
      action.params.window.moved_to = action.params.workspace
      action.params.window.position = { x = action.params.x, y = action.params.y }
    elseif action.kind == "resize" then
      action.params.window.size = { width = action.params.x, height = action.params.y }
    elseif action.kind == "tag" then
      action.params.window.order_tag = action.params.tag
    end
  end,
  exec_cmd = function(command) table.insert(commands, command) end,
  get_active_workspace = function() return active_workspace end,
  get_active_window = function() return active_window end,
  get_windows = function() return { w1, w2 } end,
  get_active_monitor = function()
    return {
      x = 10,
      y = 20,
      width = 2000,
      height = 1000,
      scale = 2,
      transform = 0,
      reserved = { left = 10, right = 20, top = 30, bottom = 40 },
    }
  end,
  get_workspaces = function() return { ws1, ws2, special } end,
  get_config = function(name)
    if name == "general.gaps_out" then return { top = 10, right = 10, bottom = 10, left = 10 } end
    if name == "general.gaps_in" then return { top = 5, right = 5, bottom = 5, left = 5 } end
    if name == "general.border_size" then return 2 end
    return nil
  end,
  on = function(name, callback) handlers[name] = callback end,
  unbind = function(keys) table.insert(unbound, keys) end,
  window_rule = function(rule) table.insert(window_rules, rule) end,
}

o = {
  bind = function(keys, _, callback, options)
    binds[keys] = callback
    bind_options[keys] = options
  end,
  shell_quote = function(value) return "'" .. value:gsub("'", "'\\''") .. "'" end,
}

dofile("hypr/float-panel.lua")

assert(type(binds["SUPER + LEFT"]) == "function")
assert(type(binds["SUPER + RIGHT"]) == "function")
assert(type(binds["SUPER + SHIFT + T"]) == "function")
assert(type(binds["SUPER + M"]) == "function")
assert(type(binds["SUPER + TAB"]) == "function")
assert(type(binds["SUPER + SHIFT + TAB"]) == "function")
assert(binds["ALT + TAB"].kind == "global" and binds["ALT + TAB"].name == "fatlj.float-panel:alt-tab-next")
assert(binds["ALT + SHIFT + TAB"].name == "fatlj.float-panel:alt-tab-previous")
assert(binds["ALT + ALT_L"].name == "fatlj.float-panel:alt-release")
assert(bind_options["ALT + ALT_L"].release == true and bind_options["ALT + ALT_R"].release == true)
assert(bind_options["ALT + ALT_L"].transparent == true and bind_options["ALT + ALT_R"].transparent == true,
  "Alt release binds must survive shadowing by the intervening Alt+Tab chord")
assert(unbound[1] == "SUPER + LEFT" and unbound[2] == "SUPER + RIGHT")
assert(type(handlers["window.open"]) == "function")
assert(type(handlers["window.move_to_workspace"]) == "function")
assert(#window_rules == 1, "the WeChat size override must be registered once")
assert(window_rules[1].match.class == "^wechat$" and window_rules[1].match.xwayland == true)
assert(window_rules[1].min_size[1] == 1 and window_rules[1].min_size[2] == 1)
assert(w1.order_tag and w1.order_tag:match("^%+float%-panel%-order%-%d+$"), "existing windows must receive a launch-order tag")
assert(w2.order_tag and w2.order_tag:match("^%+float%-panel%-order%-%d+$"), "all existing windows must receive a launch-order tag")

binds["SUPER + SHIFT + T"]()
assert(w1.floating and w2.floating, "toggle on must float every current window")
assert(#commands == 1 and commands[1]:find("floating", 1, true), "toggle must notify its mode")

binds["SUPER + LEFT"]()
assert(w1.position.x == 32 and w1.position.y == 62, "left snap must preserve tiling outer gaps and borders")
assert(w1.size.width == 466 and w1.size.height == 406, "left snap must fill half the gapped work area")
binds["SUPER + RIGHT"]()
assert(w1.position.x == 512 and w1.position.y == 62, "right snap must preserve the tiling inner gap")
assert(w1.size.width == 466 and w1.size.height == 406, "right snap must fill the other gapped half")

binds["SUPER + TAB"]()
assert(dispatched[#dispatched].kind == "focus" and dispatched[#dispatched].params.workspace == "e+1",
  "Super+Tab on a floating workspace must use Omarchy's next-workspace action")
binds["SUPER + SHIFT + TAB"]()
assert(dispatched[#dispatched].kind == "focus" and dispatched[#dispatched].params.workspace == "e-1",
  "Super+Shift+Tab on a floating workspace must use Omarchy's previous-workspace action")

local opened = { workspace = ws1, floating = false, pid = 1 }
handlers["window.open"](opened)
assert(opened.floating, "new windows on a floating workspace must float")
assert(opened.order_tag and opened.order_tag:match("^%+float%-panel%-order%-%d+$"), "new windows must receive a launch-order tag")

handlers["window.move_to_workspace"](opened, ws2)
assert(not opened.floating, "a window moved to a tiling workspace must tile")

handlers["window.move_to_workspace"](opened, special)
assert(not opened.floating, "special workspaces must not change floating state")

active_workspace = ws2
opened.workspace = ws2
ws2.windows = { opened }
local before_focus = #dispatched
binds["SUPER + LEFT"]()
assert(#dispatched == before_focus + 1, "tiling mode must dispatch directional focus")
assert(dispatched[#dispatched].kind == "focus" and dispatched[#dispatched].params.direction == "l")
local before_cycle = #dispatched
binds["SUPER + TAB"]()
assert(#dispatched == before_cycle + 2 and dispatched[#dispatched - 1].kind == "cycle_next" and dispatched[#dispatched].kind == "bring_to_top",
  "Super+Tab on a tiling workspace must cycle and raise")
binds["SUPER + SHIFT + TAB"]()
assert(dispatched[#dispatched - 1].kind == "cycle_next" and dispatched[#dispatched - 1].params.next == false,
  "reverse Super+Tab on a tiling workspace must cycle backward")
binds["SUPER + SHIFT + T"]()
assert(opened.floating, "each workspace must toggle independently")

active_window = opened
binds["SUPER + M"]()
local last = dispatched[#dispatched]
assert(last.kind == "move")
assert(last.params.workspace == "special:omarchy-minimized-2")
assert(last.params.follow == false)
assert(last.params.window == opened)

binds["SUPER + SHIFT + T"]()
assert(not opened.floating, "toggle off must tile every current window")

local state_file = assert(io.open((os.getenv("HOME") or "") .. "/.local/state/omarchy/float-panel-workspaces", "r"))
local persisted = state_file:read("*a")
state_file:close()
assert(persisted == "1\n", "workspace modes must be persisted independently and atomically")

print("LUA_TESTS_OK")
