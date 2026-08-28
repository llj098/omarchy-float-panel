local binds = {}
local handlers = {}
local dispatched = {}
local commands = {}
local unbound = {}
local bind_options = {}
local window_rules = {}
local configs = {}

local function workspace(id, name, special)
  local value = { id = id, name = name, special = special == true, windows = {} }
  function value:get_windows() return self.windows end
  return value
end

local ws1 = workspace(1, "1", false)
local ws2 = workspace(2, "2", false)
local special = workspace(-99, "special:test", true)
local w1 = { workspace = ws1, floating = false, mapped = true, fullscreen = 0, pid = 1 }
local w2 = { workspace = ws1, floating = false, mapped = true, fullscreen = 0, pid = 1 }
ws1.windows = { w1, w2 }

local own_monitor = {
  x = 10,
  y = 20,
  width = 2000,
  height = 1000,
  scale = 2,
  transform = 0,
  reserved = { left = 10, right = 20, top = 30, bottom = 40 },
}
local active_monitor = own_monitor
w1.at = { x = 200, y = 100 }
w1.size = { x = 400, y = 200 }
w1.monitor = own_monitor

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
      fullscreen = function(params) return { kind = "fullscreen", params = params } end,
      fullscreen_state = function(params) return { kind = "fullscreen_state", params = params } end,
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
      if action.params.x ~= nil and action.params.y ~= nil then
        action.params.window.position = { x = action.params.x, y = action.params.y }
        action.params.window.at = { x = action.params.x, y = action.params.y }
      end
    elseif action.kind == "resize" and action.params.window then
      local window = action.params.window
      local old_size = window.size or { x = action.params.x, y = action.params.y }
      if action.params.relative ~= true and window.at then
        window.at = {
          x = window.at.x - (action.params.x - old_size.x) / 2,
          y = window.at.y - (action.params.y - old_size.y) / 2,
        }
      end
      window.size = { x = action.params.x, y = action.params.y }
    elseif action.kind == "tag" then
      action.params.window.order_tag = action.params.tag
    end
  end,
  exec_cmd = function(command) table.insert(commands, command) end,
  get_active_workspace = function() return active_workspace end,
  get_active_window = function() return active_window end,
  get_windows = function() return { w1, w2 } end,
  get_active_monitor = function() return active_monitor end,
  get_workspaces = function() return { ws1, ws2, special } end,
  get_config = function(name)
    if name == "general.gaps_out" then return { top = 10, right = 10, bottom = 10, left = 10 } end
    if name == "general.float_gaps" then return -1 end
    if name == "general.gaps_in" then return { top = 5, right = 5, bottom = 5, left = 5 } end
    if name == "general.border_size" then return 2 end
    return nil
  end,
  on = function(name, callback) handlers[name] = callback end,
  unbind = function(keys) table.insert(unbound, keys) end,
  window_rule = function(rule) table.insert(window_rules, rule) end,
  config = function(config) table.insert(configs, config) end,
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
assert(type(binds["SUPER + UP"]) == "function")
assert(type(binds["SUPER + DOWN"]) == "function")
assert(type(binds["SUPER + F"]) == "function")
assert(type(binds["SUPER + SHIFT + T"]) == "function")
assert(type(binds["SUPER + M"]) == "function")
assert(type(binds["SUPER + TAB"]) == "function")
assert(type(binds["SUPER + SHIFT + TAB"]) == "function")
local resize_routes = {
  { "SUPER + code:20", -100, 0 },
  { "SUPER + code:21", 100, 0 },
  { "SUPER + SHIFT + code:20", 0, -100 },
  { "SUPER + SHIFT + code:21", 0, 100 },
  { "SUPER + ALT + code:20", -25, 0 },
  { "SUPER + ALT + code:21", 25, 0 },
  { "SUPER + SHIFT + ALT + code:20", 0, -25 },
  { "SUPER + SHIFT + ALT + code:21", 0, 25 },
  { "SUPER + CTRL + code:20", -300, 0 },
  { "SUPER + CTRL + code:21", 300, 0 },
  { "SUPER + CTRL + SHIFT + code:20", 0, -300 },
  { "SUPER + CTRL + SHIFT + code:21", 0, 300 },
}
for _, route in ipairs(resize_routes) do assert(type(binds[route[1]]) == "function", route[1] .. " must be rebound") end
assert(binds["ALT + TAB"].kind == "global" and binds["ALT + TAB"].name == "fatlj.float-panel:alt-tab-next")
assert(binds["ALT + SHIFT + TAB"].name == "fatlj.float-panel:alt-tab-previous")
assert(binds["ALT + ALT_L"].name == "fatlj.float-panel:alt-release")
assert(bind_options["ALT + ALT_L"].release == true and bind_options["ALT + ALT_R"].release == true)
assert(bind_options["ALT + ALT_L"].transparent == true and bind_options["ALT + ALT_R"].transparent == true,
  "Alt release binds must survive shadowing by the intervening Alt+Tab chord")
local unbound_set = {}
for _, keys in ipairs(unbound) do unbound_set[keys] = true end
for _, route in ipairs(resize_routes) do assert(unbound_set[route[1]], route[1] .. " stock binding must be unbound") end
for _, keys in ipairs({ "SUPER + LEFT", "SUPER + RIGHT", "SUPER + UP", "SUPER + DOWN", "SUPER + F" }) do
  assert(unbound_set[keys], keys .. " stock binding must be unbound")
end
assert(#configs == 1 and configs[1].general.float_gaps == -1,
  "native floating work areas must inherit the configured outer gaps")
assert(type(handlers["window.open"]) == "function")
assert(type(handlers["window.move_to_workspace"]) == "function")
assert(type(handlers["workspace.move_to_monitor"]) == "function")
assert(handlers["monitor.removed"] == nil,
  "monitor removal is too broad; migrated workspace geometry must use the authoritative workspace event")
assert(#window_rules == 1, "the WeChat size override must be registered once")
assert(window_rules[1].match.class == "^wechat$" and window_rules[1].match.xwayland == true)
assert(window_rules[1].min_size[1] == 1 and window_rules[1].min_size[2] == 1)
assert(w1.order_tag and w1.order_tag:match("^%+float%-panel%-order%-%d+$"), "existing windows must receive a launch-order tag")
assert(w2.order_tag and w2.order_tag:match("^%+float%-panel%-order%-%d+$"), "all existing windows must receive a launch-order tag")

binds["SUPER + SHIFT + T"]()
assert(w1.floating and w2.floating, "toggle on must float every current window")
assert(#commands == 1 and commands[1]:find("floating", 1, true), "toggle must notify its mode")

local migrated_monitor = {
  x = -1600,
  y = 200,
  width = 1600,
  height = 2400,
  scale = 2,
  transform = 1,
  reserved = { left = 10, right = 20, top = 30, bottom = 50 },
}
w1.monitor = migrated_monitor
w1.at = { x = 2000, y = -500 }
w1.size = { x = 1400, y = 300 }
w2.monitor = migrated_monitor
w2.at = { x = -3000, y = 1000 }
w2.size = { x = 400, y = 200 }
local inside = {
  workspace = ws1, floating = true, mapped = true, fullscreen = 0, monitor = migrated_monitor,
  at = { x = -1000, y = 300 }, size = { x = 100, y = 100 },
}
local unmapped = {
  workspace = ws1, floating = true, mapped = false, fullscreen = 0, monitor = migrated_monitor,
  at = { x = 4000, y = 4000 }, size = { x = 2000, y = 2000 },
}
local hidden = {
  workspace = ws1, floating = true, mapped = true, hidden = true, fullscreen = 0, monitor = migrated_monitor,
  at = { x = 4000, y = 4000 }, size = { x = 2000, y = 2000 },
}
local tiled = {
  workspace = ws1, floating = false, mapped = true, fullscreen = 0, monitor = migrated_monitor,
  at = { x = 4000, y = 4000 }, size = { x = 2000, y = 2000 },
}
local maximized = {
  workspace = ws1, floating = true, mapped = true, fullscreen = 1, monitor = migrated_monitor,
  at = { x = 4000, y = 4000 }, size = { x = 2000, y = 2000 },
}
local fullscreen = {
  workspace = ws1, floating = true, mapped = true, fullscreen = 2, monitor = migrated_monitor,
  at = { x = 4000, y = 4000 }, size = { x = 2000, y = 2000 },
}
ws1.windows = { w1, w2, inside, unmapped, hidden, tiled, maximized, fullscreen }
local before_migration = #dispatched
handlers["workspace.move_to_monitor"](ws1, migrated_monitor)
assert(#dispatched == before_migration + 3,
  "a migrated Float workspace must resize/move only mapped floating non-fullscreen windows that need fitting")
local migrated_resize = dispatched[before_migration + 1]
local migrated_oversize_move = dispatched[before_migration + 2]
local migrated_offscreen_move = dispatched[before_migration + 3]
assert(migrated_resize.kind == "resize" and migrated_resize.params.window == w1,
  "oversize migration repair must resize before moving")
assert(migrated_resize.params.x == 1146 and migrated_resize.params.y == 300,
  "migration repair must shrink only the dimension exceeding the transformed logical work area")
assert(migrated_oversize_move.kind == "move" and migrated_oversize_move.params.x == -1578 and migrated_oversize_move.params.y == 242,
  "oversize migration repair must clamp against the negative-origin work area")
assert(migrated_offscreen_move.kind == "move" and migrated_offscreen_move.params.window == w2,
  "an offscreen mapped Float-workspace window that already fits must move without resizing")
assert(migrated_offscreen_move.params.x == -1578 and migrated_offscreen_move.params.y == 738,
  "offscreen migration repair must account for reserved bottom space, gaps, and borders")
assert(w2.size.x == 400 and w2.size.y == 200,
  "a migrated window that already fits must preserve both dimensions")
assert(inside.at.x == -1000 and inside.at.y == 300,
  "an already-fitting on-screen migrated window must not move")
assert(unmapped.at.x == 4000 and hidden.at.x == 4000 and tiled.at.x == 4000 and maximized.at.x == 4000 and fullscreen.at.x == 4000,
  "unmapped, hidden, tiled, maximized, and fullscreen windows must be left to native behavior")
local before_wrong_routes = #dispatched
handlers["workspace.move_to_monitor"](ws2, migrated_monitor)
handlers["workspace.move_to_monitor"](special, migrated_monitor)
assert(#dispatched == before_wrong_routes, "tiling and special workspaces must not route migration geometry")
local route_window = {
  workspace = ws1, floating = false, mapped = true, fullscreen = 0, monitor = migrated_monitor,
  at = { x = 4000, y = 4000 }, size = { x = 2000, y = 2000 },
}
local before_window_route = #dispatched
handlers["window.move_to_workspace"](route_window, ws1)
assert(#dispatched == before_window_route + 1 and dispatched[#dispatched].kind == "float",
  "window.move_to_workspace must keep only its workspace-mode routing")
assert(route_window.at.x == 4000 and route_window.size.x == 2000,
  "window.move_to_workspace fires before monitor reassignment and must not route migration geometry")

ws1.windows = { w1, w2 }
w1.monitor = own_monitor
w2.monitor = own_monitor
for _, route in ipairs(resize_routes) do
  local dx, dy = route[2], route[3]
  w1.at = { x = 250, y = dy < 0 and 80 or 218 }
  w1.size = { x = 500, y = dy < 0 and 350 or 100 }
  local old_x, old_y = w1.at.x, w1.at.y
  local old_width, old_height = w1.size.x, w1.size.y
  local before = #dispatched
  binds[route[1]]()
  local resized, moved = dispatched[before + 1], dispatched[before + 2]
  assert(#dispatched == before + 2 and resized.kind == "resize" and moved.kind == "move",
    route[1] .. " floating resize must resize then move synchronously")
  assert(resized.params.relative == nil and resized.params.x == old_width + dx and resized.params.y == old_height + dy,
    route[1] .. " floating resize must apply its exact delta")
  assert(moved.params.x == old_x - dx / 2 and moved.params.y == old_y - dy / 2,
    route[1] .. " floating resize must retain the window center")
end

active_monitor = { x = -5000, y = -5000, width = 100, height = 100, scale = 1, reserved = {} }
w1.at = { x = 900, y = 100 }
w1.size = { x = 50, y = 100 }
for _ = 1, 20 do binds["SUPER + code:21"]() end
assert(w1.at.x == 32 and w1.size.x == 946,
  "repeated growth must stop at the active window's own monitor floating work-area boundary")
assert(w1.at.y == 100 and w1.size.y == 100, "horizontal resize must not change vertical geometry")
w1.at = { x = 100, y = 400 }
w1.size = { x = 100, y = 50 }
binds["SUPER + CTRL + SHIFT + code:21"]()
binds["SUPER + CTRL + SHIFT + code:21"]()
assert(w1.at.y == 62 and w1.size.y == 406, "large vertical growth must clamp to the usable work area")
active_monitor = own_monitor

binds["SUPER + LEFT"]()
assert(w1.position.x == 32 and w1.position.y == 62, "left snap must preserve tiling outer gaps and borders")
assert(w1.size.x == 466 and w1.size.y == 406, "left snap must fill half the gapped work area")
binds["SUPER + RIGHT"]()
assert(w1.position.x == 512 and w1.position.y == 62, "right snap must preserve the tiling inner gap")
assert(w1.size.x == 466 and w1.size.y == 406, "right snap must fill the other gapped half")

binds["SUPER + UP"]()
local last = dispatched[#dispatched]
assert(last.kind == "fullscreen" and last.params.mode == "maximized" and last.params.action == "set",
  "Super+Up must set native maximization in floating mode")
binds["SUPER + DOWN"]()
last = dispatched[#dispatched]
assert(last.kind == "fullscreen" and last.params.mode == "maximized" and last.params.action == "unset",
  "Super+Down must unset native maximization in floating mode")
binds["SUPER + F"]()
last = dispatched[#dispatched]
assert(last.kind == "fullscreen_state" and last.params.internal == 2 and last.params.client == 0 and last.params.action == "toggle",
  "floating fullscreen must toggle compositor-only fullscreen")

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
for _, binding in ipairs({ { "SUPER + LEFT", "l" }, { "SUPER + RIGHT", "r" }, { "SUPER + UP", "u" }, { "SUPER + DOWN", "d" } }) do
  binds[binding[1]]()
  assert(dispatched[#dispatched].kind == "focus" and dispatched[#dispatched].params.direction == binding[2],
    "tiling mode must preserve directional focus for " .. binding[1])
end
assert(#dispatched == before_focus + 4, "tiling directional bindings must each dispatch exactly once")
for _, route in ipairs(resize_routes) do
  local before = #dispatched
  binds[route[1]]()
  last = dispatched[#dispatched]
  assert(#dispatched == before + 1 and last.kind == "resize" and last.params.relative == true,
    route[1] .. " tiling resize must keep the stock relative dispatcher")
  assert(last.params.x == route[2] and last.params.y == route[3], route[1] .. " tiling resize delta changed")
end
binds["SUPER + F"]()
last = dispatched[#dispatched]
assert(last.kind == "fullscreen" and last.params.mode == "fullscreen" and last.params.action == nil,
  "tiling Super+F must preserve Omarchy's synchronized fullscreen toggle")
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
last = dispatched[#dispatched]
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
