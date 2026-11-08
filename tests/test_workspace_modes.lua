-- Focused mode regression: actual integration, no compositor/native plugin.
local state_path = (os.getenv("HOME") or "") .. "/.local/state/omarchy/float-panel-workspaces"
local rules, handlers, bindings = {}, {}, {}
local workspaces = {}
local function workspace(id, name, special)
  return { id = id, name = name, special = special == true, get_windows = function() return {} end }
end
local one = workspace(1, "1")
local eleven = workspace(11, "11")
local named = workspace(-10, "dev")
local special = workspace(-99, "special:scratch", true)
workspaces = { one, eleven, named, special }
hl = {
  config = function() end, unbind = function() end,
  dsp = { global = function() end },
  on = function(name, fn) handlers[name] = fn end,
  get_windows = function() return {} end,
  get_monitors = function() return {} end,
  get_workspaces = function() return workspaces end,
  get_config = function() return nil end,
  get_active_window = function() return nil end,
  get_active_workspace = function() return one end,
  get_active_monitor = function() return nil end,
  get_workspace = function(selector)
    for _, ws in ipairs(workspaces) do
      if tostring(ws.id) == tostring(selector) or "name:" .. ws.name == selector then return ws end
    end
  end,
  exec_cmd = function() end,
  window_rule = function(spec)
    local rule = { enabled = spec.enabled ~= false, spec = spec }
    function rule:set_enabled(value) self.enabled = value end
    rules[spec.name] = rule
    return rule
  end,
}
o = { bind = function(keys, _, fn) bindings[keys] = fn end, shell_quote = function(s) return string.format("%q", s) end }
local function load(contents)
  -- Empty file and missing file share the same default. Use a fresh HOME in CI.
  if contents ~= nil then
    local file = assert(io.open(state_path, "w")); file:write(contents); file:close()
  end
  rules, handlers = {}, {}
  dofile("hypr/float-panel.lua")
end
local function floats(name) return rules["fatlj-float-workspace-" .. name].enabled end
load(nil)
assert(floats("1") and floats("11") and floats("dev"), "missing state defaults all regular workspaces to Float")
assert(not rules["fatlj-float-workspace-special:scratch"], "special workspaces must never receive Float rules")
local new_workspace = workspace(21, "21")
handlers["workspace.created"](new_workspace)
assert(floats("21"), "new monitor workspace blocks float without a toggle/reload")
local count = 0
for _ in pairs(rules) do count = count + 1 end
handlers["workspace.active"](new_workspace)
local after = 0
for _ in pairs(rules) do after = after + 1 end
assert(after == count, "activating a workspace must not duplicate rules")
load("1\n11\n")
assert(floats("1") and floats("11") and floats("dev"), "legacy positive lists migrate to default Float")
fatlj_float_panel.toggle_workspace_mode(11)
assert(not floats("11") and floats("1"), "Tiling is an independent explicit opt-out")
load(nil)
assert(not floats("11") and floats("1") and floats("dev"), "explicit Tiling survives reload")
fatlj_float_panel.toggle_workspace_mode(11)
load(nil)
assert(floats("11"), "toggling back to Float clears the persisted opt-out")
load("# float-panel-workspaces-v2\r\ntile\tdev\r\ntile\t21\r\n")
assert(not floats("dev") and floats("1"), "named overrides and CRLF parse consistently")
handlers["workspace.created"](new_workspace)
assert(not floats("21"), "an override is respected even when the workspace did not exist at startup")
load("")
assert(floats("1") and floats("dev"), "resetting state restores default Float")
print("WORKSPACE_MODE_TESTS_OK")
