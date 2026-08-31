local binds = {}
local handlers = {}
local dispatched = {}
local commands = {}
local unbound = {}
local bind_options = {}
local window_rules = {}
local configs = {}
local resize_adjustment = nil
local native_semantics_by_address = {}
local semantics_calls = {}
local operation_log = {}
local windows_by_address = {}
local debug_log_path = (os.getenv("HOME") or "") .. "/float-panel-debug-test.log"
FLOAT_PANEL_DEBUG_LOG_PATH = debug_log_path
os.remove(debug_log_path)
os.remove(debug_log_path .. ".1")
local debug_marker = assert(io.open((os.getenv("HOME") or "") .. "/.local/state/omarchy/float-panel-debug", "w"))
debug_marker:close()

local function window_semantics_bridge(address)
  table.insert(semantics_calls, address)
  local semantics = native_semantics_by_address[address]
  if semantics == "error" then error("synthetic native bridge failure") end
  return semantics or {
    found = true,
    xwayland = true,
    has_parent = false,
    transient = false,
    override_redirect = false,
    window_type = "normal",
    program_position = false,
    user_position = false,
    position_specified = false,
  }
end

local function workspace(id, name, special)
  local value = { id = id, name = name, config_name = tostring(name), special = special == true, windows = {} }
  function value:get_windows() return self.windows end
  return value
end

local ws1 = workspace(1, "1", false)
local ws2 = workspace(2, "2", false)
local ws3 = workspace(3, "3", false)
local special = workspace(-99, "special:omarchy-minimized-1", true)
local w1 = { workspace = ws1, floating = false, mapped = true, fullscreen = 0, pid = 1, tags = {} }
local w2 = { workspace = ws1, floating = false, mapped = true, fullscreen = 0, pid = 1, tags = {} }
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
      alter_zorder = function(params) return { kind = "alter_zorder", params = params } end,
      set_prop = function(params) return { kind = "set_prop", params = params } end,
    },
    focus = function(params) return { kind = "focus", params = params } end,
    global = function(name) return { kind = "global", name = name } end,
  },
  dispatch = function(action)
    table.insert(dispatched, action)
    table.insert(operation_log, {
      kind = action.kind,
      window = action.params and action.params.window or nil,
    })
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
      window.size = {
        x = action.params.x + (resize_adjustment and resize_adjustment.x or 0),
        y = action.params.y + (resize_adjustment and resize_adjustment.y or 0),
      }
    elseif action.kind == "set_prop" then
      local window = action.params.window
      window.applied_props = window.applied_props or {}
      window.applied_props[action.params.prop] = action.params.value
    elseif action.kind == "tag" then
      local window, tag = action.params.window, action.params.tag
      if tag:sub(1, 1) == "+" then
        local raw = tag:sub(2)
        table.insert(window.tags, raw)
        if raw:match("^float%-panel%-order%-%d+$") then window.order_tag = tag end
      elseif tag:sub(1, 1) == "-" then
        local raw = tag:sub(2)
        for index = #window.tags, 1, -1 do
          if window.tags[index] == raw then table.remove(window.tags, index) end
        end
      end
    end
  end,
  exec_cmd = function(command) table.insert(commands, command) end,
  get_active_workspace = function() return active_workspace end,
  get_active_window = function() return active_window end,
  get_windows = function() return { w1, w2 } end,
  get_window = function(selector)
    local address = type(selector) == "string" and selector:match("^address:(0x%x+)$") or nil
    return address and windows_by_address[address] or nil
  end,
  get_active_monitor = function() return active_monitor end,
  get_workspaces = function() return { ws1, ws2, ws3, special } end,
  get_workspace = function(selector)
    local id = tonumber(selector)
    for _, candidate in ipairs({ ws1, ws2, ws3, special }) do
      if candidate.id == id then return candidate end
    end
    return nil
  end,
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
  plugin = {
    load = function() end,
    float_panel = {
      window_semantics = window_semantics_bridge,
    },
  },
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
for _, keys in ipairs({ "SUPER + CTRL + TAB", "SUPER + ALT + TAB", "ALT + 1", "ALT + 2", "ALT + 3", "ALT + 4", "ALT + 5", "ALT + 6", "ALT + 7", "ALT + 8", "ALT + 9" }) do
  assert(not unbound_set[keys] and binds[keys] == nil, keys .. " must remain owned by Omarchy")
end
assert(#configs == 1 and configs[1].general.float_gaps == -1,
  "native floating work areas must inherit the configured outer gaps")
assert(type(handlers["window.open"]) == "function")
assert(type(handlers["window.close"]) == "function")
assert(type(handlers["hyprland.shutdown"]) == "function")
assert(type(handlers["window.move_to_workspace"]) == "function")
assert(type(handlers["workspace.move_to_monitor"]) == "function")
assert(type(handlers["monitor.layout_changed"]) == "function")
assert(type(handlers["layer.opened"]) == "function")
assert(handlers["workspace.work_area_changed"] == nil)
assert(handlers["monitor.removed"] == nil,
  "monitor removal is too broad; migrated workspace geometry must use the authoritative workspace event")
assert(#window_rules == 1, "only the auxiliary no-border rule must be installed")
local auxiliary_rule = window_rules[1]
assert(auxiliary_rule and auxiliary_rule.border_size == 0 and
  auxiliary_rule.match.tag == "float-panel-auxiliary-no-border",
  "standard auxiliary-window facts must feed one tag-matched no-border rule")
assert(w1.applied_props and w1.applied_props.min_size == "1 1" and
  w2.applied_props and w2.applied_props.min_size == "1 1",
  "all existing mapped applications must receive the highest-priority minimum-size override")
assert(w1.order_tag and w1.order_tag:match("^%+float%-panel%-order%-%d+$"), "existing windows must receive a launch-order tag")
assert(w2.order_tag and w2.order_tag:match("^%+float%-panel%-order%-%d+$"), "all existing windows must receive a launch-order tag")

binds["SUPER + SHIFT + T"]()
assert(w1.floating and w2.floating, "toggle on must float every current window")
assert(#commands == 1 and commands[1]:find("floating", 1, true), "toggle must notify its mode")

local ui_window = { workspace = ws2, floating = false, mapped = true, fullscreen = 0, pid = 1, tags = {} }
ws2.windows = { ui_window }
assert(type(fatlj_float_panel) == "table" and type(fatlj_float_panel.toggle_workspace_mode) == "function",
  "the bar widget must have a narrow Lua toggle bridge")
fatlj_float_panel.toggle_workspace_mode(2)
assert(ui_window.floating, "UI toggle must float the selected monitor workspace")
fatlj_float_panel.toggle_workspace_mode(2)
assert(not ui_window.floating, "second UI toggle must restore tiling")
assert(#commands == 3 and commands[2]:find("floating", 1, true) and commands[3]:find("tiling", 1, true),
  "UI toggle must issue the same mode notifications as the keyboard binding")
ws2.windows = {}

local function side_tag(window)
  for _, tag in ipairs(window.tags) do
    if tag:match("^float%-panel%-side%-v1%-") then return tag end
  end
end

-- Startup-only adoption covers plugin-style halves that predate side tags.
w1.at, w1.size = { x = 32, y = 62 }, { x = 466, y = 406 }
w2.at, w2.size, w2.monitor = { x = 512, y = 62 }, { x = 464, y = 405 }, own_monitor
local malformed_half = {
  workspace = ws1, floating = true, mapped = true, fullscreen = 0, monitor = own_monitor,
  at = { x = 32, y = 62 }, size = { x = 466, y = 400 }, tags = {},
}
ws1.windows = { w1, w2, malformed_half }
dofile("hypr/float-panel.lua")
assert(side_tag(w1):match("%-l%-") and side_tag(w2):match("%-r%-"),
  "reload must adopt exact pre-existing left/right halves, including <=2px client increments")
assert(not side_tag(malformed_half) and malformed_half.size.y == 400,
  "short malformed/free windows must not be adopted or enlarged")
for _, window in ipairs({ w1, w2 }) do
  for index = #window.tags, 1, -1 do
    if window.tags[index]:match("^float%-panel%-side%-v1%-") then table.remove(window.tags, index) end
  end
end
ws1.windows = { w1, w2 }

active_workspace = ws3
active_window = nil
binds["SUPER + SHIFT + T"]()
active_workspace = ws1
active_window = w1

-- Window operations must derive mode and geometry from the active window,
-- even when pointer-driven monitor focus names a different workspace.
local context_monitor = {
  x = 5000, y = 0, width = 1000, height = 700, scale = 1.5, transform = 0,
  reserved = { left = 0, right = 0, top = 0, bottom = 0 },
}
local context_window = {
  workspace = ws3, floating = true, mapped = true, fullscreen = 0, monitor = context_monitor,
  at = { x = 5100, y = 100 }, size = { x = 300, y = 200 }, tags = {},
}
active_workspace = ws2
active_monitor = own_monitor
active_window = context_window
local before_context_snap = #dispatched
binds["SUPER + RIGHT"]()
assert(dispatched[before_context_snap + 1].kind == "float" and dispatched[before_context_snap + 2].kind == "resize" and
  dispatched[before_context_snap + 2].params.window == context_window,
  "Float routing must follow the active window workspace, not the focused monitor workspace")
assert(context_window.at.x == 5340 and context_window.at.y == 12 and context_window.size.x == 315 and context_window.size.y == 443,
  "fractional monitor geometry must use Hyprland's nearest-logical-pixel rounding")
assert(side_tag(context_window):match("%-p3%-33$"), "side intent must record the active window's real workspace")

local tiled_context = {
  workspace = ws2, floating = false, mapped = true, fullscreen = 0, monitor = own_monitor,
  at = { x = 100, y = 100 }, size = { x = 300, y = 200 }, tags = {},
}
active_workspace = ws1
active_window = tiled_context
local before_context_tiling = #dispatched
binds["SUPER + LEFT"]()
assert(#dispatched == before_context_tiling + 1 and dispatched[#dispatched].kind == "focus",
  "Tiling routing must follow the active window workspace even when the focused monitor workspace is Float")
active_workspace = ws1
active_monitor = own_monitor
active_window = w1

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
local other_float = {
  workspace = ws3, floating = true, mapped = true, fullscreen = 0, monitor = migrated_monitor,
  at = { x = 4000, y = 300 }, size = { x = 100, y = 100 },
}
local tiling_candidate = {
  workspace = ws2, floating = true, mapped = true, fullscreen = 0, monitor = migrated_monitor,
  at = { x = 4000, y = 300 }, size = { x = 100, y = 100 },
}
local special_candidate = {
  workspace = special, floating = true, mapped = true, fullscreen = 0, monitor = migrated_monitor,
  at = { x = 4000, y = 300 }, size = { x = 100, y = 100 },
}
ws3.windows = { other_float }
ws2.windows = { tiling_candidate }
special.windows = { special_candidate }
local before_migration = #dispatched
handlers["monitor.layout_changed"]()
assert(#dispatched == before_migration + 4,
  "monitor layout changes must scan every Float workspace and change only windows needing fitting")
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
assert(dispatched[before_migration + 4].params.window == other_float and other_float.at.x == -532,
  "the payload-free monitor event must scan another enabled Float workspace")
assert(inside.at.x == -1000 and inside.at.y == 300,
  "an already-fitting on-screen migrated window must not move")
assert(unmapped.at.x == 4000 and hidden.at.x == 4000 and tiled.at.x == 4000 and maximized.at.x == 4000 and fullscreen.at.x == 4000,
  "unmapped, hidden, tiled, maximized, and fullscreen windows must be left to native behavior")
assert(tiling_candidate.at.x == 4000 and special_candidate.at.x == 4000,
  "the monitor event must skip Tiling and special workspaces")
local before_idempotent_fit = #dispatched
handlers["monitor.layout_changed"]()
handlers["workspace.move_to_monitor"](ws1, migrated_monitor)
assert(#dispatched == before_idempotent_fit,
  "repeated layout and migration routes must be geometrically idempotent through their common fitter")

local pinned = {
  workspace = ws1, floating = true, pinned = true, mapped = true, fullscreen = 0, monitor = migrated_monitor,
  at = { x = 4000, y = 300 }, size = { x = 100, y = 100 }, tags = {},
}
local previous_ws1_windows = ws1.windows
ws1.windows = { pinned }
handlers["monitor.layout_changed"]()
assert(pinned.at.x == -532, "pinned windows must retain the existing monitor-bound fitting behavior")
ws1.windows = previous_ws1_windows

local edp_monitor = {
  x = 0, y = 0, width = 1920, height = 1080, scale = 1.25, transform = 0,
  reserved = { left = 0, right = 0, top = 0, bottom = 0 },
}
local layer_max = {
  workspace = ws3, floating = true, mapped = true, fullscreen = 0, monitor = edp_monitor,
  at = { x = 12, y = 12 }, size = { x = 1512, y = 840 },
  tags = { "float-panel-geometric-max-v1-p100-p100-p500-p400-p3-33" },
}
local layer_side = {
  workspace = ws3, floating = true, mapped = true, fullscreen = 0, monitor = edp_monitor,
  at = { x = 12, y = 12 }, size = { x = 749, y = 840 },
  tags = { "float-panel-side-v1-l-p12-p12-p749-p840-p0-p0-p3-33" },
}
local layer_free = {
  workspace = ws3, floating = true, mapped = true, fullscreen = 0, monitor = edp_monitor,
  at = { x = 800, y = 12 }, size = { x = 200, y = 840 }, tags = {},
}
ws1.monitor, ws2.monitor, ws3.monitor, special.monitor = migrated_monitor, edp_monitor, edp_monitor, edp_monitor
ws3.windows = { layer_max, layer_side, layer_free }
local untouched_tiling_x, untouched_special_x, untouched_other_x = tiling_candidate.at.x, special_candidate.at.x, w1.at.x
edp_monitor.reserved.bottom = 26
local before_layer_opened = #dispatched
handlers["layer.opened"]({ monitor = edp_monitor })
assert(layer_max.size.y == 814 and layer_side.size.y == 814 and layer_free.size.y == 814,
  "post-arrange layer.opened must refit every Float window from stale 840px to final 814px height")
assert(side_tag(layer_side):find("p749%-p814"), "layer reflow must update side intent with observed final geometry")
assert(tiling_candidate.at.x == untouched_tiling_x and special_candidate.at.x == untouched_special_x and w1.at.x == untouched_other_x,
  "layer.opened must leave Tiling, special, and other-monitor workspaces untouched")
local after_layer_opened = #dispatched
handlers["layer.opened"]({ monitor = edp_monitor })
assert(#dispatched == after_layer_opened and after_layer_opened > before_layer_opened,
  "repeated layer.opened fitting must be idempotent")

local before_wrong_routes = #dispatched
handlers["workspace.move_to_monitor"](ws2, migrated_monitor)
handlers["workspace.move_to_monitor"](special, migrated_monitor)
assert(#dispatched == before_wrong_routes, "tiling and special workspaces must not route defensive fitting")
local route_window = {
  address = "0xroute", workspace = ws1, floating = false, mapped = true, fullscreen = 0, monitor = migrated_monitor,
  at = { x = 4000, y = 4000 }, size = { x = 2000, y = 2000 },
}
local before_window_route = #dispatched
local before_window_route_hints = #semantics_calls
handlers["window.move_to_workspace"](route_window, ws1)
local route_hint_reads = 0
for index = before_window_route_hints + 1, #semantics_calls do
  if semantics_calls[index] == route_window.address then route_hint_reads = route_hint_reads + 1 end
end
assert(route_hint_reads >= 1,
  "moving a window to a regular workspace must refresh scale-corrected size hints")
assert(#dispatched == before_window_route + 1 and dispatched[#dispatched].kind == "float",
  "window.move_to_workspace must keep only its workspace-mode routing")
assert(route_window.at.x == 4000 and route_window.size.x == 2000,
  "window.move_to_workspace fires before monitor reassignment and must not route migration geometry")

local minimized3 = workspace(-103, "special:omarchy-minimized-3", true)
local minimized_during_unplug = {
  workspace = minimized3, floating = true, mapped = true, hidden = false, fullscreen = 0, monitor = edp_monitor,
  at = { x = 12, y = -276 }, size = { x = 1005, y = 1102 },
  tags = { "float-panel-side-v1-r-n1017-p12-p1005-p1102-n2048-p0-p3-33" },
}
local minimized_free = {
  workspace = minimized3, floating = true, mapped = true, hidden = false, fullscreen = 0, monitor = edp_monitor,
  at = { x = -500, y = -400 }, size = { x = 2000, y = 1200 }, tags = {},
}
local minimized2 = workspace(-102, "special:omarchy-minimized-2", true)
local unrelated_minimized = {
  workspace = minimized2, floating = true, mapped = true, hidden = false, fullscreen = 0, monitor = edp_monitor,
  at = { x = -600, y = -500 }, size = { x = 1900, y = 1300 }, tags = {},
}
local original_get_windows = hl.get_windows
hl.get_windows = function() return { minimized_during_unplug, minimized_free, unrelated_minimized } end
handlers["workspace.move_to_monitor"](ws3, edp_monitor)
hl.get_windows = original_get_windows
assert(minimized_during_unplug.at.x == 775 and minimized_during_unplug.at.y == 12 and
  minimized_during_unplug.size.x == 749 and minimized_during_unplug.size.y == 814,
  "display migration must recompute a source workspace's minimized side windows")
assert(side_tag(minimized_during_unplug):find("%-r%-p775%-p12%-p749%-p814%-p0%-p0%-p3%-33$"),
  "minimized reflow must replace stale external-monitor side metadata")
assert(minimized_free.at.x == 12 and minimized_free.at.y == 12 and
  minimized_free.size.x == 1512 and minimized_free.size.y == 814,
  "display migration must shrink and clamp oversized minimized free windows")
assert(unrelated_minimized.at.x == -600 and unrelated_minimized.at.y == -500 and
  unrelated_minimized.size.x == 1900 and unrelated_minimized.size.y == 1300,
  "a source workspace reflow must not alter another workspace's minimized windows")

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

resize_adjustment = { x = -2, y = -1 }
binds["SUPER + LEFT"]()
assert(w1.size.x == 464 and w1.size.y == 405 and side_tag(w1):find("p464%-p405"),
  "snap tags must record live client-adjusted geometry rather than the request")
handlers["monitor.layout_changed"]()
assert(side_tag(w1) and w1.size.x == 464 and w1.size.y == 405,
  "observed increment-adjusted geometry must survive the next reflow")
resize_adjustment = nil

binds["SUPER + LEFT"]()
assert(w1.position.x == 32 and w1.position.y == 62, "left snap must preserve tiling outer gaps and borders")
assert(w1.size.x == 466 and w1.size.y == 406 and side_tag(w1):match("%-l%-"),
  "left snap must fill half the gapped work area and record left intent")
local before_side_resize = #dispatched
binds["SUPER + ALT + code:21"]()
assert(not side_tag(w1) and #dispatched == before_side_resize + 3,
  "explicit keyboard resize must clear side intent before resizing")

binds["SUPER + LEFT"]()
w1.at.x = w1.at.x + 1
handlers["monitor.layout_changed"]()
assert(not side_tag(w1), "reflow must clear stale side intent after manual geometry changes")

binds["SUPER + RIGHT"]()
assert(w1.position.x == 512 and w1.position.y == 62, "right snap must preserve the tiling inner gap")
assert(w1.size.x == 466 and w1.size.y == 406 and side_tag(w1):match("%-r%-"),
  "right snap must fill the other gapped half and replace side intent")

-- Simulate Hyprland's workspace-origin translation before each authoritative
-- workspace.move_to_monitor event; managed halves must recompute, not fit-only.
ws1.windows = { w1 }
w1.monitor = migrated_monitor
w1.at = { x = -1098, y = 242 }
handlers["workspace.move_to_monitor"](ws1, migrated_monitor)
assert(w1.at.x == -998 and w1.at.y == 242 and w1.size.x == 566 and w1.size.y == 696,
  "a managed right half must recompute exactly on the destination monitor")
w1.monitor = own_monitor
w1.at = { x = 612, y = 62 }
handlers["workspace.move_to_monitor"](ws1, own_monitor)
assert(w1.at.x == 512 and w1.at.y == 62 and w1.size.x == 466 and w1.size.y == 406,
  "small/large round trips must regrow a managed half to exact current-monitor geometry")
ws1.windows = { w1, w2 }

local function geometric_tag(window)
  for _, tag in ipairs(window.tags) do
    if tag:match("^float%-panel%-geometric%-max%-v1%-") then return tag end
  end
end

local w1_restore = { x = w1.at.x, y = w1.at.y, width = w1.size.x, height = w1.size.y }
local before_max = #dispatched
binds["SUPER + UP"]()
assert(w1.floating and w1.fullscreen == 0, "geometry-maximized windows must remain non-fullscreen floats")
assert(w1.at.x == 32 and w1.at.y == 62 and w1.size.x == 946 and w1.size.y == 406,
  "Float Super+Up must fill the active window monitor's floating work area")
assert(geometric_tag(w1) == "float-panel-geometric-max-v1-p512-p62-p466-p406-p1-31",
  "Float Super+Up must save exact restore geometry and source identity in one versioned tag")
assert(#dispatched == before_max + 4 and dispatched[before_max + 1].kind == "tag" and
  dispatched[before_max + 2].kind == "resize" and dispatched[before_max + 3].kind == "move" and
  dispatched[before_max + 4].kind == "alter_zorder",
  "geometry maximize must tag, resize, move, and raise synchronously")
local before_repeat = #dispatched
binds["SUPER + UP"]()
assert(#dispatched == before_repeat, "repeated Super+Up on a tagged window must be idempotent")

local tag_before_reload = geometric_tag(w1)
local before_reload = #dispatched
dofile("hypr/float-panel.lua")
assert(w1.floating and geometric_tag(w1) == tag_before_reload and w1.at.x == 32 and w1.size.x == 946,
  "reload must preserve a tagged geometry-maximized floating window")
for index = before_reload + 1, #dispatched do
  local action = dispatched[index]
  assert(not ((action.kind == "resize" or action.kind == "move") and action.params.window == w1),
    "reload must not perturb an already exact max geometry")
end

w2.at = { x = 150, y = 120 }
w2.size = { x = 360, y = 240 }
w2.monitor = own_monitor
w2.floating = true
active_window = w2
local w2_restore = { x = w2.at.x, y = w2.at.y, width = w2.size.x, height = w2.size.y }
binds["SUPER + UP"]()
local ordinary_float = {
  workspace = ws1, floating = true, mapped = true, fullscreen = 0, monitor = own_monitor,
  at = { x = 250, y = 180 }, size = { x = 200, y = 120 }, tags = {},
}
ws1.windows = { w1, w2, ordinary_float }
assert(w1.floating and w2.floating and ordinary_float.floating and geometric_tag(w1) and geometric_tag(w2),
  "multiple geometry-maximized windows and ordinary workspace windows must all remain floating")
assert(w1.size.x == 946 and w2.size.x == 946, "independent max peers must keep the same full work-area geometry")

local before_minimize = #dispatched
binds["SUPER + M"]()
assert(dispatched[#dispatched].kind == "move" and geometric_tag(w2), "minimize must retain geometry-max metadata")
handlers["window.move_to_workspace"](w2, special)
assert(w2.floating and geometric_tag(w2), "the source minimized special workspace must retain max metadata")
handlers["window.move_to_workspace"](w2, ws1)
assert(w2.floating and geometric_tag(w2), "restoring to the source Float workspace must retain max metadata")

active_window = w1
binds["SUPER + DOWN"]()
assert(w1.floating and not geometric_tag(w1) and w1.at.x == w1_restore.x and w1.at.y == w1_restore.y and
  w1.size.x == w1_restore.width and w1.size.y == w1_restore.height,
  "Float Super+Down must restore only the selected window's exact geometry")
assert(geometric_tag(w2) and w2.size.x == 946, "restoring one max peer must not alter another")
binds["SUPER + UP"]()
assert(geometric_tag(w1), "a restored float must be independently maximizable again")

w1.monitor = migrated_monitor
w2.monitor = migrated_monitor
ws1.windows = { w1, w2 }
local before_max_migration = #dispatched
handlers["monitor.layout_changed"]()
assert(#dispatched == before_max_migration + 4, "monitor layout changes must resize then move each tagged max peer")
assert(w1.floating and w2.floating and w1.at.x == -1578 and w1.at.y == 242 and w1.size.x == 1146 and w1.size.y == 696,
  "migration must refill the first tagged max against the new work area")
assert(w2.at.x == -1578 and w2.at.y == 242 and w2.size.x == 1146 and w2.size.y == 696,
  "migration must refill every tagged max peer")

active_window = w1
binds["SUPER + DOWN"]()
assert(not geometric_tag(w1) and geometric_tag(w2), "post-migration restore must remain per-window")
assert(w1.at.x == -998 and w1.at.y == 242 and w1.size.x == 566 and w1.size.y == 696 and side_tag(w1),
  "Down after monitor/scale changes must restore max-from-half to the current-monitor half")
active_window = w2
binds["SUPER + DOWN"]()
assert(not geometric_tag(w2), "restoring the second peer must clear only its own tag")
assert(w2.at.x == -792 and w2.at.y == 242 and w2.size.x == w2_restore.width and w2.size.y == w2_restore.height,
  "max-from-free must retain defensive exact free-geometry restore semantics")

w1.monitor = own_monitor
w2.monitor = own_monitor
ws1.windows = { w1, w2 }
w1.at = { x = 100, y = 100 }
w1.size = { x = 300, y = 200 }
w1.floating = true
active_window = w1
binds["SUPER + UP"]()
handlers["window.move_to_workspace"](w1, ws2)
assert(not geometric_tag(w1) and not side_tag(w1) and not w1.floating,
  "moving a tagged max/half to another regular Tiling workspace must clear placement metadata")
w1.workspace = ws1
w1.floating = true
binds["SUPER + RIGHT"]()
binds["SUPER + UP"]()
binds["SUPER + SHIFT + T"]()
assert(not geometric_tag(w1) and not side_tag(w1) and not w1.floating and not w2.floating,
  "switching the source workspace to Tiling must clear max and side metadata and tile its windows")
binds["SUPER + SHIFT + T"]()
assert(w1.floating and w2.floating, "the Float workspace must remain usable after deterministic tag cleanup")

binds["SUPER + F"]()
last = dispatched[#dispatched]
assert(last.kind == "fullscreen_state" and last.params.internal == 2 and last.params.client == 0 and last.params.action == "toggle",
  "floating fullscreen must toggle compositor-only fullscreen")

active_workspace = ws2
active_window = { workspace = ws2, monitor = own_monitor }
active_monitor = migrated_monitor
local before_monitor_aligned_tab = #dispatched
binds["SUPER + TAB"]()
assert(#dispatched == before_monitor_aligned_tab + 2 and dispatched[before_monitor_aligned_tab + 1].params.monitor == own_monitor,
  "Super+Tab must first select the active window's monitor when compositor monitor focus differs")
assert(dispatched[#dispatched].kind == "focus" and dispatched[#dispatched].params.workspace == "m+1",
  "Super+Tab must route workspace 2 to the next existing regular workspace 3")
active_monitor = own_monitor
active_workspace = ws3
active_window = { workspace = ws3 }
binds["SUPER + TAB"]()
assert(dispatched[#dispatched].kind == "focus" and dispatched[#dispatched].params.workspace == "m+1",
  "Super+Tab must use Hyprland's same-monitor wrap from workspace 3 back to 2")
active_workspace = ws2
active_window = { workspace = ws2 }
binds["SUPER + SHIFT + TAB"]()
assert(dispatched[#dispatched].kind == "focus" and dispatched[#dispatched].params.workspace == "m-1",
  "reverse navigation must wrap from workspace 2 back to 3 without selecting the special workspace")
active_workspace = ws1
active_window = w1

local opened = { workspace = ws1, floating = false, pid = 1, tags = {} }
handlers["window.open"](opened)
assert(opened.floating, "new windows on a floating workspace must float")
assert(opened.order_tag and opened.order_tag:match("^%+float%-panel%-order%-%d+$"), "new windows must receive a launch-order tag")

handlers["window.move_to_workspace"](opened, ws2)
assert(not opened.floating, "a window moved to a tiling workspace must tile")

handlers["window.move_to_workspace"](opened, special)
assert(not opened.floating, "special workspaces must not change floating state")

active_workspace = ws2
opened.workspace = ws2
active_window = opened
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
local before_workspace_switch = #dispatched
binds["SUPER + TAB"]()
assert(#dispatched == before_workspace_switch + 1 and dispatched[#dispatched].kind == "focus" and dispatched[#dispatched].params.workspace == "m+1",
  "Super+Tab on a tiling workspace must keep wrapped same-monitor workspace navigation")
binds["SUPER + SHIFT + TAB"]()
assert(#dispatched == before_workspace_switch + 2 and dispatched[#dispatched].kind == "focus" and dispatched[#dispatched].params.workspace == "m-1",
  "Super+Shift+Tab on a tiling workspace must keep reverse wrapped navigation")
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
assert(persisted == "1\n3\n", "workspace modes must be persisted independently and atomically")

local function persisted_window(address, class, x, y, width, height)
  return {
    address = address, initial_class = class, class = class, xdg_tag = nil,
    workspace = ws1, monitor = own_monitor, floating = false, mapped = true, hidden = false,
    fullscreen = 0, pid = 1, tags = {}, at = { x = x, y = y }, size = { x = width, y = height },
    xwayland = true,
  }
end

local function has_auxiliary_no_border_tag(window)
  for _, tag in ipairs(window.tags or {}) do
    if tag == "float-panel-auxiliary-no-border" then return true end
  end
  return false
end

local parent = persisted_window("0x5000", "ParentApp", 400, 180, 500, 300)
windows_by_address[parent.address] = parent
local function parent_semantics(parent_address, position_specified)
  return {
    found = true,
    xwayland = true,
    has_parent = parent_address ~= nil,
    parent_address = parent_address,
    transient = parent_address ~= nil,
    override_redirect = false,
    window_type = parent_address and "utility" or "normal",
    program_position = position_specified == true,
    user_position = false,
    position_specified = position_specified == true,
  }
end

-- A parented window without PPosition/USPosition is centered after its desired size is known.
local centered = persisted_window("0x5002", "ChildApp", 80, 70, 200, 100)
native_semantics_by_address[centered.address] = parent_semantics(parent.address, false)
handlers["window.open"](centered)
assert(centered.at.x == 550 and centered.at.y == 280,
  "a parented window without an explicit position must center over its concrete parent")
assert(has_auxiliary_no_border_tag(centered), "a standard X11 utility must receive the no-border lifecycle tag")
assert(not table.concat(centered.tags, "\n"):find("float%-panel%-geometry%-slot%-v1%-"),
  "parented utility windows must remain outside geometry persistence")

local positioned = persisted_window("0x5003", "PositionedChild", 440, 210, 180, 120)
native_semantics_by_address[positioned.address] = parent_semantics(parent.address, true)
handlers["window.open"](positioned)
assert(positioned.at.x == 440 and positioned.at.y == 210,
  "PPosition/USPosition must preserve the application's initial placement")

local missing_parent = persisted_window("0x5004", "MissingParentChild", 460, 220, 180, 120)
native_semantics_by_address[missing_parent.address] = parent_semantics("0xdead", false)
handlers["window.open"](missing_parent)
assert(missing_parent.at.x == 460 and missing_parent.at.y == 220,
  "an unresolved parent address must preserve application placement")

local wechat_image = persisted_window("0x5005", "WeChatImage", 470, 230, 190, 130)
native_semantics_by_address[wechat_image.address] = parent_semantics(nil, true)
handlers["window.open"](wechat_image)
assert(wechat_image.applied_props and wechat_image.applied_props.min_size == "1 1",
  "newly opened applications must ignore their minimum-size hints")
assert(wechat_image.at.x == 470 and wechat_image.at.y == 230 and
  wechat_image.size.x == 190 and wechat_image.size.y == 130,
  "a no-parent explicitly positioned image window must remain unchanged without a class hack")
assert(not has_auxiliary_no_border_tag(wechat_image), "a normal X11 window must retain its compositor border")

local dialog = persisted_window("0x5010", "DialogApp", 470, 230, 190, 130)
native_semantics_by_address[dialog.address] = parent_semantics(nil, false)
native_semantics_by_address[dialog.address].window_type = "dialog"
handlers["window.open"](dialog)
assert(not has_auxiliary_no_border_tag(dialog), "an ordinary X11 dialog must retain its compositor border")

for index, window_type in ipairs({ "tooltip", "menu", "popup_menu", "dropdown_menu" }) do
  local auxiliary = persisted_window(string.format("0x502%d", index), "AuxiliaryApp", 470, 230, 190, 130)
  native_semantics_by_address[auxiliary.address] = parent_semantics(nil, false)
  native_semantics_by_address[auxiliary.address].window_type = window_type
  handlers["window.open"](auxiliary)
  assert(has_auxiliary_no_border_tag(auxiliary), window_type .. " must receive the no-border lifecycle tag")
end

local override_redirect = persisted_window("0x5030", "OverrideApp", 470, 230, 190, 130)
native_semantics_by_address[override_redirect.address] = parent_semantics(nil, false)
native_semantics_by_address[override_redirect.address].override_redirect = true
handlers["window.open"](override_redirect)
assert(has_auxiliary_no_border_tag(override_redirect), "override-redirect windows must receive the no-border lifecycle tag")

local bridge_failure = persisted_window("0x5006", "BridgeFailure", 480, 240, 180, 120)
native_semantics_by_address[bridge_failure.address] = "error"
local bridge_ok = pcall(handlers["window.open"], bridge_failure)
native_semantics_by_address[bridge_failure.address] = nil
assert(bridge_ok and bridge_failure.floating and bridge_failure.at.x == 480 and bridge_failure.at.y == 240,
  "a native bridge error must fail safely without blocking normal Float placement")

hl.plugin.float_panel.window_semantics = nil
dofile("hypr/float-panel.lua")
local bridge_absent = persisted_window("0x5009", "BridgeAbsent", 490, 250, 170, 110)
assert(pcall(handlers["window.open"], bridge_absent) and bridge_absent.floating,
  "an absent native bridge must fail safely")
hl.plugin.float_panel.window_semantics = window_semantics_bridge
dofile("hypr/float-panel.lua")

-- A first-open record must capture the final post-fit application placement.
local post_fit = persisted_window("0x5008", "PostFitPersist", 2000, 100, 200, 100)
handlers["window.open"](post_fit)
assert(post_fit.at.x == 778 and post_fit.at.y == 100, "first open must fit application placement to the work area")
local post_fit_file = assert(io.open((os.getenv("HOME") or "") .. "/.local/state/omarchy/float-panel-geometries", "r"))
local post_fit_state = post_fit_file:read("*a")
post_fit_file:close()
local post_fit_record
for line in post_fit_state:gmatch("[^\n]+") do
  if line:find("506f737446697450657273697374", 1, true) then post_fit_record = line end
end
assert(post_fit_record and post_fit_record:find("\t778\t100\t200\t100\t", 1, true),
  "new geometry persistence must run after full work-area fitting")

-- A free Float window must reopen at its last closed geometry.
local saved = persisted_window("0x1001", "PersistApp", 200, 100, 400, 200)
handlers["window.open"](saved)
saved.at, saved.size = { x = 260, y = 140 }, { x = 430, y = 230 }
handlers["window.close"](saved)
-- Reload the Lua module so restoration is proven from disk, not its old in-memory table.
dofile("hypr/float-panel.lua")
local reopened = persisted_window("0x1002", "PersistApp", 50, 70, 180, 120)
handlers["window.open"](reopened)
assert(reopened.at.x == 260 and reopened.at.y == 140 and reopened.size.x == 430 and reopened.size.y == 230,
  "window.close/open must restore the final free geometry")

local edge_saved = persisted_window("0x1101", "EdgeApp", 548, 238, 430, 230)
handlers["window.open"](edge_saved)
handlers["window.close"](edge_saved)
local compact_monitor = {
  x = 2000, y = 100, width = 700, height = 500, scale = 1, transform = 0,
  reserved = { left = 0, right = 0, top = 0, bottom = 0 },
}
local edge_reopened = persisted_window("0x1102", "EdgeApp", 30, 40, 100, 80)
edge_reopened.monitor = compact_monitor
handlers["window.open"](edge_reopened)
assert(edge_reopened.at.x == 2381 and edge_reopened.at.y == 318 and
  edge_reopened.size.x == 307 and edge_reopened.size.y == 270,
  "free geometry must scale size proportionally and retain right/bottom placement on a different work area")

-- Identical windows claim separate slots; reopening B while A is live must restore B.
local multi_a = persisted_window("0x2001", "MultiApp", 120, 90, 300, 180)
local multi_b = persisted_window("0x2002", "MultiApp", 500, 210, 360, 240)
handlers["window.open"](multi_a)
handlers["window.open"](multi_b)
multi_a.at, multi_a.size = { x = 140, y = 110 }, { x = 320, y = 190 }
multi_b.at, multi_b.size = { x = 520, y = 190 }, { x = 370, y = 250 }
handlers["window.close"](multi_b)
local multi_b_reopened = persisted_window("0x2003", "MultiApp", 40, 70, 160, 100)
handlers["window.open"](multi_b_reopened)
assert(multi_b_reopened.at.x == 520 and multi_b_reopened.at.y == 190 and
  multi_b_reopened.size.x == 370 and multi_b_reopened.size.y == 250,
  "an identical app window must reclaim the unoccupied geometry slot")

-- Lua owns the persistence policy over raw native metadata. Accepted cases
-- must claim a fresh slot, semantic rejections must purge stale tags, and
-- bridge failures/not-found must fail closed without stripping live tags.
local stale_policy_tag = "float-panel-geometry-slot-v1-31-5374616c65--99"
local policy_cases = {
  { "wayland", { found = true, xwayland = false, has_parent = false, transient = false, override_redirect = false, window_type = "wayland" }, "accept" },
  { "normal", { found = true, xwayland = true, has_parent = false, transient = false, override_redirect = false, window_type = "normal" }, "accept" },
  { "dialog", { found = true, xwayland = true, has_parent = false, transient = false, override_redirect = false, window_type = "dialog" }, "accept" },
  { "parent", { found = true, xwayland = true, has_parent = true, transient = false, override_redirect = false, window_type = "normal" }, "reject" },
  { "transient", { found = true, xwayland = true, has_parent = false, transient = true, override_redirect = false, window_type = "normal" }, "reject" },
  { "override", { found = true, xwayland = true, has_parent = false, transient = false, override_redirect = true, window_type = "normal" }, "reject" },
  { "utility", { found = true, xwayland = true, has_parent = false, transient = false, override_redirect = false, window_type = "utility" }, "reject" },
  { "tooltip", { found = true, xwayland = true, has_parent = false, transient = false, override_redirect = false, window_type = "tooltip" }, "reject" },
  { "bridge-error", "error", "preserve" },
  { "not-found", { found = false }, "preserve" },
}
for index, case in ipairs(policy_cases) do
  local address = string.format("0x26%02x", index)
  native_semantics_by_address[address] = case[2]
  local candidate = persisted_window(address, "Policy" .. tostring(index), 180, 120, 260, 170)
  candidate.tags = { stale_policy_tag }
  handlers["window.open"](candidate)
  local geometry_tags = {}
  for _, tag in ipairs(candidate.tags) do
    if tag:find("^float%-panel%-geometry%-slot%-v1%-") then table.insert(geometry_tags, tag) end
  end
  if case[3] == "accept" then
    assert(#geometry_tags == 1 and geometry_tags[1] ~= stale_policy_tag,
      case[1] .. " must claim a fresh geometry slot")
  elseif case[3] == "reject" then
    assert(#geometry_tags == 0, case[1] .. " must remain outside the geometry slot pool")
  else
    assert(#geometry_tags == 1 and geometry_tags[1] == stale_policy_tag,
      case[1] .. " must fail closed without stripping an existing tag")
  end
  handlers["window.close"](candidate)
end

-- Parent/transient/type metadata, not app class or title, must keep auxiliary
-- windows out of the geometry slot pool and preserve each requested box.
local transient_main = persisted_window("0x2051", "TransientApp", 140, 100, 320, 200)
handlers["window.open"](transient_main)
handlers["window.close"](transient_main)
for _, address in ipairs({ "0x2052", "0x2053" }) do
  native_semantics_by_address[address] = {
    found = true,
    xwayland = true,
    has_parent = true,
    transient = true,
    override_redirect = false,
    window_type = "utility",
  }
end
local transient_a = persisted_window("0x2052", "TransientApp", 470, 190, 350, 230)
transient_a.tags = { "float-panel-geometry-slot-v1-31-5472616e7369656e74417070--2" }
handlers["window.open"](transient_a)
assert(transient_a.at.x == 470 and transient_a.at.y == 190 and
  transient_a.size.x == 350 and transient_a.size.y == 230,
  "a transient utility must retain application-requested geometry")
assert(not table.concat(transient_a.tags, "\n"):find("float%-panel%-geometry%-slot%-v1%-"),
  "a transient utility must not claim a geometry slot")
transient_a.at, transient_a.size = { x = 80, y = 90 }, { x = 180, y = 120 }
handlers["window.close"](transient_a)
local transient_b = persisted_window("0x2053", "TransientApp", 520, 220, 280, 180)
handlers["window.open"](transient_b)
assert(transient_b.at.x == 520 and transient_b.at.y == 220 and
  transient_b.size.x == 280 and transient_b.size.y == 180,
  "a later same-class transient must not restore an earlier transient box")
assert(not table.concat(transient_b.tags, "\n"):find("float%-panel%-geometry%-slot%-v1%-"),
  "later transient instances must remain outside the slot pool")

local role_main = persisted_window("0x2101", "RoleApp", 130, 100, 300, 180)
local role_tool = persisted_window("0x2102", "RoleApp", 480, 200, 360, 240)
role_main.xdg_tag, role_tool.xdg_tag = "main", "tool"
handlers["window.open"](role_main)
handlers["window.open"](role_tool)
handlers["window.close"](role_main)
handlers["window.close"](role_tool)
local role_tool_reopened = persisted_window("0x2103", "RoleApp", 40, 70, 160, 100)
role_tool_reopened.xdg_tag = "tool"
handlers["window.open"](role_tool_reopened)
assert(role_tool_reopened.at.x == 480 and role_tool_reopened.at.y == 200 and
  role_tool_reopened.size.x == 360 and role_tool_reopened.size.y == 240,
  "xdg_tag must separate stable roles within one application class")

-- Semantic side/max placement must be recomputed and max-down must retain its free restore box.
local side_saved = persisted_window("0x3001", "SideApp", 180, 100, 340, 220)
handlers["window.open"](side_saved)
active_workspace, active_window = ws1, side_saved
binds["SUPER + LEFT"]()
handlers["window.close"](side_saved)
local side_reopened = persisted_window("0x3002", "SideApp", 80, 80, 200, 120)
handlers["window.open"](side_reopened)
assert(side_reopened.at.x == 32 and side_reopened.at.y == 62 and
  side_reopened.size.x == 466 and side_reopened.size.y == 406 and side_tag(side_reopened),
  "managed halves must reopen from semantic side intent")

local max_saved = persisted_window("0x4001", "MaxApp", 180, 120, 350, 220)
handlers["window.open"](max_saved)
active_window = max_saved
binds["SUPER + UP"]()
handlers["window.close"](max_saved)
local max_reopened = persisted_window("0x4002", "MaxApp", 70, 80, 190, 130)
handlers["window.open"](max_reopened)
assert(max_reopened.at.x == 32 and max_reopened.at.y == 62 and
  max_reopened.size.x == 946 and max_reopened.size.y == 406 and geometric_tag(max_reopened),
  "geometric max intent must survive close/reopen")
active_window = max_reopened
binds["SUPER + DOWN"]()
assert(max_reopened.at.x == 180 and max_reopened.at.y == 120 and
  max_reopened.size.x == 350 and max_reopened.size.y == 220,
  "restoring a reopened max window must recover its saved free geometry")

local geometry_file = assert(io.open((os.getenv("HOME") or "") .. "/.local/state/omarchy/float-panel-geometries", "r"))
local geometry_state = geometry_file:read("*a")
geometry_file:close()
assert(geometry_state:find("\tv1\t", 1, true) == nil and geometry_state:find("v1\t", 1, true) == 1,
  "geometry state must use the versioned flat format")

-- Free-window topology reflow is always derived from one immutable source box:
-- grow proportionally, shrink proportionally, then restore exactly at source.
local anchor_window = persisted_window("0xanchor1", "AnchorApp", 678, 268, 300, 200)
anchor_window.title = "DO_NOT_LOG_REFLOW_SECRET"
ws1.monitor, ws1.windows = own_monitor, { anchor_window }
handlers["window.open"](anchor_window)
local grow_monitor = {
  name = "grow", x = 2000, y = 100, width = 1600, height = 900, scale = 1, transform = 0,
  reserved = { left = 0, right = 0, top = 0, bottom = 0 },
}
anchor_window.monitor = grow_monitor
anchor_window.at = { x = 2668, y = 348 } -- compositor-style origin translation; size stays unchanged
ws1.monitor = grow_monitor
handlers["workspace.move_to_monitor"](ws1, grow_monitor)
assert(anchor_window.at.x == 3088 and anchor_window.at.y == 556 and
  anchor_window.size.x == 500 and anchor_window.size.y == 432,
  "a larger work area must scale free-window size and preserve right/bottom free-space ratios")

local small_monitor = {
  name = "small", x = -1000, y = 50, width = 700, height = 450, scale = 1, transform = 0,
  reserved = { left = 0, right = 0, top = 0, bottom = 0 },
}
anchor_window.monitor, ws1.monitor = small_monitor, small_monitor
handlers["workspace.move_to_monitor"](ws1, small_monitor)
assert(anchor_window.at.x == -526 and anchor_window.at.y == 278 and
  anchor_window.size.x == 214 and anchor_window.size.y == 210,
  "a smaller work area must recompute from the source anchor rather than the prior enlarged box")
assert(anchor_window.at.x >= -988 and anchor_window.at.y >= 62 and
  anchor_window.at.x + anchor_window.size.x <= -312 and anchor_window.at.y + anchor_window.size.y <= 488,
  "proportional free reflow must remain wholly inside current floating bounds")

anchor_window.monitor, ws1.monitor = own_monitor, own_monitor
handlers["workspace.move_to_monitor"](ws1, own_monitor)
assert(anchor_window.at.x == 678 and anchor_window.at.y == 268 and
  anchor_window.size.x == 300 and anchor_window.size.y == 200,
  "large-small-large/source round trips must reproduce the immutable anchor box")

-- The same source anchor follows a window while it is minimized; neither that
-- special-workspace reflow nor shutdown persistence may rebase it.
local minimized_anchor = persisted_window("0xanchor2", "MinimizedAnchorApp", 678, 268, 300, 200)
ws1.windows = { minimized_anchor }
handlers["window.open"](minimized_anchor)
active_window = minimized_anchor
binds["SUPER + M"]()
minimized_anchor.workspace = special
handlers["window.move_to_workspace"](minimized_anchor, special)
minimized_anchor.monitor, ws1.monitor = small_monitor, small_monitor
local get_windows_before_anchor_test = hl.get_windows
hl.get_windows = function() return { minimized_anchor } end
handlers["workspace.move_to_monitor"](ws1, small_monitor)
assert(minimized_anchor.at.x == -526 and minimized_anchor.at.y == 278 and
  minimized_anchor.size.x == 214 and minimized_anchor.size.y == 210,
  "minimized free windows must use the source workspace's proportional anchor")
handlers["hyprland.shutdown"]()
minimized_anchor.monitor, ws1.monitor = own_monitor, own_monitor
handlers["workspace.move_to_monitor"](ws1, own_monitor)
assert(minimized_anchor.at.x == 678 and minimized_anchor.at.y == 268 and
  minimized_anchor.size.x == 300 and minimized_anchor.size.y == 200,
  "minimized reflow and shutdown must not overwrite the pre-reflow anchor")
hl.get_windows = get_windows_before_anchor_test

local debug_file = assert(io.open(debug_log_path, "r"))
local debug_payload = debug_file:read("*a")
debug_file:close()
local anchor_log = {}
for line in debug_payload:gmatch("[^\n]+") do
  if line:find("window=0xanchor1", 1, true) and line:find("trigger=workspace.move_to_monitor", 1, true) then
    table.insert(anchor_log, line)
  end
end
local joined_anchor_log = table.concat(anchor_log, "\n")
assert(#anchor_log >= 9 and joined_anchor_log:find("reflow.window_before", 1, true) and
  joined_anchor_log:find("reflow.window_decision", 1, true) and joined_anchor_log:find("reflow.window_after", 1, true),
  "debug-marker reflow logging must include per-window before/decision/after records")
for _, field in ipairs({
  "source_bounds=32,62,946,406", "target_bounds=2012,112,1576,876",
  "anchor=678,268,300,200", "placement_ratios=", "requested_resize=500,432",
  "requested_move=3088,556", "actual_geometry=3088,556,500,432",
}) do
  assert(joined_anchor_log:find(field, 1, true), "reflow debug payload is missing " .. field)
end
assert(not joined_anchor_log:find("DO_NOT_LOG_REFLOW_SECRET", 1, true) and
  not joined_anchor_log:find("AnchorApp", 1, true),
  "privacy-safe reflow records must never include titles or class/content identifiers")
os.remove(debug_log_path)
os.remove(debug_log_path .. ".1")

print("LUA_TESTS_OK")
