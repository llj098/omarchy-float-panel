-- Lua-owned policy for resizing a titlebar window from its top corners.
-- The native bridge owns the attached input rectangle and starts the exact
-- core resize operation; this module only decides eligibility and lifecycle.
local M = {}
local LEFT_BUTTON = 272

function M.new(native, policy)
  local states, addresses = {}, {}
  local stopped = false
  local ok, caps = pcall(function() return native.capabilities() end)
  local enabled = ok and type(caps) == "table" and
    caps.decoration_input_v1 == true and caps.drag_lifecycle_v1 == true
  for _, name in ipairs({ "decoration_set", "decoration_remove", "decoration_capture",
    "decoration_release", "drag_begin", "drag_finish" }) do
    enabled = enabled and type(native[name]) == "function"
  end

  local function call(name, ...)
    local success, result = pcall(native[name], ...)
    return success and result == true
  end

  local function address(window) return window and tostring(window.address) end

  local function remove(state)
    if not state then return end
    states[state.identity] = nil
    if addresses[state.address] == state then addresses[state.address] = nil end
    if state.owned then call("drag_finish", state.address) end
    if state.captured then call("decoration_release", state.address) end
    call("decoration_remove", state.address)
  end

  local function lookup(window)
    local identity = policy.identity(window)
    local state = identity and states[identity]
    if state and state.address == address(window) then return state end
  end

  local function same_options(a, b)
    if not a or not b then return false end
    for key, value in pairs(a) do if b[key] ~= value then return false end end
    for key, value in pairs(b) do if a[key] ~= value then return false end end
    return true
  end

  local api = {}
  function api.enabled() return enabled and not stopped end

  function api.reconcile(window)
    if not enabled or stopped then return end
    local a = address(window)
    local identity = policy.identity(window)
    if not identity or not a or not policy.eligible(window) then
      if identity then remove(states[identity]) end
      if a then call("decoration_remove", a) end
      return
    end

    local state = lookup(window)
    if state and state.address ~= a then remove(state); state = nil end
    local options = {
      height = policy.height,
      hit_inset = 0,
      corner = policy.corner,
      color = 0,
      visible = false,
      cursor = "",
    }
    if state and same_options(state.options, options) then
      state.window = window
      return
    end

    if not call("decoration_set", a, options) then
      if state then remove(state) end
      return
    end
    if not state then
      state = { identity = identity, address = a }
      states[identity] = state
      addresses[a] = state
    end
    state.window = window
    state.options = options
  end

  function api.pointer(window, phase, button)
    if not enabled or stopped then return end
    local state = lookup(window)
    if not state then return end

    if phase == "press-left" or phase == "press-right" then
      if state.captured or state.owned then return end
      if policy.focus then pcall(policy.focus, window) end
      state.captured = true
      if not call("decoration_capture", state.address, button) then
        state.captured = false
        return
      end
      state.owned = true
      local corner = phase == "press-left" and "top-left" or "top-right"
      if not call("drag_begin", state.address, "resize", corner) then
        call("drag_finish", state.address)
        call("decoration_release", state.address)
        state.owned, state.captured = false, false
      end
    elseif phase == "release" then
      state.owned, state.captured = false, false
      call("decoration_release", state.address)
    elseif phase == "lost" then
      state.owned, state.captured = false, false
      call("drag_finish", state.address)
      call("decoration_release", state.address)
    end
  end

  function api.forget(window)
    local state = lookup(window)
    if state then remove(state) end
  end

  function api.shutdown()
    if stopped then return end
    stopped = true
    for _, state in pairs(states) do remove(state) end
    states, addresses = {}, {}
  end

  return api
end

return M
