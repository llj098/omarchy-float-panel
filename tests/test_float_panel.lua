local binds = {}
local handlers = {}
local dispatched = {}
local commands = {}
local unbound = {}

local function workspace(id, name, special)
  local value = { id = id, name = name, special = special == true, windows = {} }
  function value:get_windows() return self.windows end
  return value
end

local ws1 = workspace(1, "1", false)
local ws2 = workspace(2, "2", false)
local special = workspace(-99, "special:test", true)
local w1 = { workspace = ws1, floating = false }
local w2 = { workspace = ws1, floating = false }
ws1.windows = { w1, w2 }

local active_workspace = ws1
local active_window = w1

hl = {
  dsp = {
    window = {
      float = function(params) return { kind = "float", params = params } end,
      move = function(params) return { kind = "move", params = params } end,
      resize = function(params) return { kind = "resize", params = params } end,
    },
    focus = function(params) return { kind = "focus", params = params } end,
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
    end
  end,
  exec_cmd = function(command) table.insert(commands, command) end,
  get_active_workspace = function() return active_workspace end,
  get_active_window = function() return active_window end,
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
}

o = {
  bind = function(keys, _, callback) binds[keys] = callback end,
  shell_quote = function(value) return "'" .. value:gsub("'", "'\\''") .. "'" end,
}

dofile("hypr/float-panel.lua")

assert(type(binds["SUPER + LEFT"]) == "function")
assert(type(binds["SUPER + RIGHT"]) == "function")
assert(type(binds["SUPER + SHIFT + T"]) == "function")
assert(type(binds["SUPER + M"]) == "function")
assert(unbound[1] == "SUPER + LEFT" and unbound[2] == "SUPER + RIGHT")
assert(type(handlers["window.open"]) == "function")
assert(type(handlers["window.move_to_workspace"]) == "function")

binds["SUPER + SHIFT + T"]()
assert(w1.floating and w2.floating, "toggle on must float every current window")
assert(#commands == 1 and commands[1]:find("floating", 1, true), "toggle must notify its mode")

binds["SUPER + LEFT"]()
assert(w1.position.x == 32 and w1.position.y == 62, "left snap must preserve tiling outer gaps and borders")
assert(w1.size.width == 466 and w1.size.height == 406, "left snap must fill half the gapped work area")
binds["SUPER + RIGHT"]()
assert(w1.position.x == 512 and w1.position.y == 62, "right snap must preserve the tiling inner gap")
assert(w1.size.width == 466 and w1.size.height == 406, "right snap must fill the other gapped half")

local opened = { workspace = ws1, floating = false }
handlers["window.open"](opened)
assert(opened.floating, "new windows on a floating workspace must float")

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
