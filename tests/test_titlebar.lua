-- Focused titlebar-mode contract, with a synthetic compositor. No real windows.
local installed = io.open("/usr/lib/omarchy-hyprland-titlebars/titlebars.so", "r")
if not installed then
  print("TITLEBAR_TESTS_SKIPPED: titlebars package not installed")
  return
end
installed:close()

local dispatched, tags, configs, buttons, rules = {}, {}, {}, {}, {}
local w1
local ws1 = {
  id = 1, name = "1", config_name = "1", special = false,
  get_windows = function() return { w1 } end,
}
local monitor = {
  id = 1, name = "test", x = 0, y = 0,
  width = 1000, height = 800, scale = 1, transform = 0,
  reserved = { left = 0, right = 0, top = 0, bottom = 0 },
  activeWorkspace = ws1,
}
w1 = {
  address = "0x1", stable_id = 1, initial_class = "TestApp", class = "TestApp",
  title = "Test window", pid = 1, workspace = ws1, monitor = monitor,
  floating = false, mapped = true, hidden = false, visible = true,
  fullscreen = 0, tags = {}, at = { x = 100, y = 0 }, size = { x = 400, y = 300 },
  xdg_tag = nil,
}
ws1.monitor = monitor

local function action(kind, params)
  table.insert(dispatched, { kind = kind, params = params })
  if kind == "float" then
    params.window.floating = params.action == "on"
  elseif kind == "tag" then
    local window, value = params.window, params.tag
    if value:sub(1, 1) == "+" then
      table.insert(window.tags, value:sub(2))
    elseif value:sub(1, 1) == "-" then
      local raw = value:sub(2)
      for index = #window.tags, 1, -1 do
        if window.tags[index] == raw then table.remove(window.tags, index) end
      end
    end
  elseif kind == "resize" and params.window and params.relative ~= true then
    params.window.size = { x = params.x, y = params.y }
  elseif kind == "move" and params.window and params.x ~= nil and params.y ~= nil then
    params.window.at = { x = params.x, y = params.y }
  elseif kind == "set_prop" and params.window then
    params.window.applied_props = params.window.applied_props or {}
    params.window.applied_props[params.prop] = params.value
  end
  return { kind = kind, params = params }
end

local function dsp_window(name)
  return function(params) return action(name, params or {}) end
end

hl = {
  dsp = {
    window = {
      float = dsp_window("float"), move = dsp_window("move"), resize = dsp_window("resize"),
      tag = dsp_window("tag"), set_prop = dsp_window("set_prop"),
      alter_zorder = dsp_window("alter_zorder"), close = dsp_window("close"),
      fullscreen = dsp_window("fullscreen"), fullscreen_state = dsp_window("fullscreen_state"),
    },
    focus = function(params) return action("focus", params or {}) end,
    global = function(name) return { kind = "global", name = name } end,
    exec_cmd = function(command) return action("exec_cmd", { command = command }) end,
  },
  dispatch = function(value) return action(value.kind, value.params or {}) end,
  config = function(value) table.insert(configs, value) end,
  get_active_window = function() return w1 end,
  get_active_workspace = function() return ws1 end,
  get_active_monitor = function() return monitor end,
  get_windows = function() return { w1 } end,
  get_workspaces = function() return { ws1 } end,
  get_monitors = function() return { monitor } end,
  get_workspace = function(selector)
    if tostring(selector) == tostring(ws1.id) or selector == "name:1" then return ws1 end
  end,
  get_window = function(selector)
    if selector == "address:" .. w1.address then return w1 end
  end,
  get_config = function(name)
    if name == "general.gaps_out" then return { top = 0, right = 0, bottom = 0, left = 0 } end
    if name == "general.float_gaps" then return { top = 0, right = 0, bottom = 0, left = 0 } end
    if name == "general.gaps_in" then return { top = 0, right = 0, bottom = 0, left = 0 } end
    if name == "general.border_size" then return 0 end
    return nil
  end,
  exec_cmd = function() end,
  on = function() end,
  unbind = function() end,
  window_rule = function(spec)
    local rule = { enabled = spec.enabled ~= false }
    function rule:set_enabled(value) self.enabled = value == true end
    rules[spec.name] = rule
    return rule
  end,
  plugin = {
    load = function() end,
    hyprbars = {
      add_button = function(button) table.insert(buttons, button) end,
    },
  },
}
o = {
  bind = function() end,
  shell_quote = function(value) return "'" .. value:gsub("'", "'\\''") .. "'" end,
}

float_panel_options = { chrome = "titlebar" }
dofile("hypr/float-panel.lua")

local hyprbars
for _, value in ipairs(configs) do
  if value.plugin and value.plugin.hyprbars then hyprbars = value.plugin.hyprbars end
end
assert(hyprbars, "titlebar mode must configure plugin:hyprbars")
assert(hyprbars.enabled == true, "titlebar mode must enable the plugin")
assert(hyprbars.workspace_tag == "fatlj-float-titlebar", "titlebar mode must scope bars to the plugin tag")
assert(hyprbars.bar_height == 30, "titlebar height must reach the plugin")
assert(hyprbars.bar_part_of_window == true, "titlebar must reserve window space like the official mode")
assert(#buttons == 3, "close, maximize and minimize must be registered")
for _, button in ipairs(buttons) do
  assert(button.action:find("hyprctl dispatch", 1, true), "buttons must dispatch a command")
  assert(button.action:find("%WINDOW%", 1, true), "buttons must target the clicked window")
end

local tagged = false
for _, tag in ipairs(w1.tags) do if tag == "fatlj-float-titlebar" then tagged = true end end
assert(tagged, "Float windows must receive the titlebar tag")
assert(w1.at.y == 30, "the main surface must stay one bar height below the work-area top")
assert(w1.size.y == 300, "the titlebar must not shrink the main surface on a free window")

-- The titlebar action is address-targeted and keeps the plugin's semantics.
w1.floating = true
fatlj_float_panel.titlebar_action(w1.address, "maximize")
assert(w1.size.y == 770, "geometric maximize must use the titlebar-reduced work area")
assert(w1.at.y == 30, "geometric maximize must leave room for the titlebar")
local maximized = false
for _, tag in ipairs(w1.tags) do
  if tag:find("float%-panel%-geometric%-max%-v1%-") then maximized = true end
end
assert(maximized, "titlebar maximize must use the plugin's geometric max tag")

w1.at = { x = 100, y = 30 }
w1.size = { x = 400, y = 300 }
fatlj_float_panel.titlebar_action(w1.address, "minimize")
local minimized = false
for _, record in ipairs(dispatched) do
  if record.kind == "move" and record.params.workspace == "special:omarchy-minimized-1" then minimized = true end
end
assert(minimized, "titlebar minimize must use the plugin's per-workspace store")

print("TITLEBAR_TESTS_OK")
