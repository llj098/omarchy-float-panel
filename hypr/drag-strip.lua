-- Lua-controlled interaction policy; native owns attached paint/input mechanisms.
-- This module owns interaction policy, never native rendering or pointer motion.
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

  local function lookup(window)
    local identity = policy.identity(window)
    local state = identity and states[identity]
    if state and state.address == policy.address(window) then return state end
  end

  local function live(state)
    return not stopped and states[state.identity] == state and
      addresses[state.address] == state
  end

  local function same_options(a, b)
    if not a or not b then return false end
    for key, value in pairs(a) do if b[key] ~= value then return false end end
    for key, value in pairs(b) do if a[key] ~= value then return false end end
    return true
  end

  local function paint(state, visible)
    if not live(state) then return false end
    local options = {}
    for key, value in pairs(policy.style(state.window)) do options[key] = value end
    options.visible = visible
    if same_options(state.options, options) or same_options(state.inflight, options) then return true end
    state.version = (state.version or 0) + 1
    local version = state.version
    state.inflight = options
    local success = call("decoration_set", state.address, options)
    if live(state) and state.version == version then
      state.inflight = nil
      if success then state.options = options end
    end
    return success
  end

  local function release(state)
    if not state.captured then return end
    state.captured = false
    call("decoration_release", state.address)
  end

  local function cancel(state)
    -- Invalidate BEFORE native finish: finish may synchronously emit post-end.
    state.pending = nil
    local owned = state.owned
    state.owned = false
    if owned then call("drag_finish", state.address) end
    release(state)
  end

  local function remove(state)
    -- Detach before callbacks so close/reload/reused addresses cannot inherit it.
    states[state.identity] = nil
    if addresses[state.address] == state then addresses[state.address] = nil end
    cancel(state)
    call("decoration_remove", state.address)
  end

  local api = {}
  function api.enabled() return enabled and not stopped end

  function api.reconcile(window)
    if not api.enabled() then return end
    local state = lookup(window)
    if not policy.eligible(window) then
      if state then remove(state) end
      return
    end
    if state then
      state.window = window
      paint(state, state.hovered == true or state.owned == true)
      return
    end
    local identity, address = policy.identity(window), policy.address(window)
    if not identity or not address then return end
    -- Address reuse is a new interaction, even if an old close event was lost.
    if addresses[address] then remove(addresses[address]) end
    state = { identity = identity, address = address, window = window }
    states[identity], addresses[address] = state, state
    if not paint(state, false) and live(state) then remove(state) end
  end

  function api.pointer(window, phase, button)
    if not api.enabled() then return end
    local state = lookup(window)
    if not state then return end
    if not policy.eligible(window) then remove(state); return end
    if phase == "enter" then
      state.hovered = true
      paint(state, true)
    elseif phase == "leave" then
      state.hovered = false
      if not state.owned then paint(state, false) end
    elseif phase == "lost" then
      cancel(state)
      state.hovered = false
      paint(state, false)
    elseif phase == "press" and button == LEFT_BUTTON then
      if state.captured or state.pending then return end
      -- Capture is valid only within delivery of this native decoration press.
      -- Set provisional ownership before calls to cover synchronous loss/close.
      state.captured = true
      if not call("decoration_capture", state.address, button) then
        state.captured = false
        return
      end
      if not live(state) or not state.captured then return end
      state.owned = true
      local started = call("drag_begin", state.address, "move")
      if not live(state) or not state.owned then return end
      if not started then
        cancel(state)
        paint(state, state.hovered == true)
      else
        paint(state, true)
      end
    elseif phase == "release" and button == LEFT_BUTTON and state.captured then
      -- Native must deliver this independently of hit position, after bookkeeping.
      local owned = state.owned
      state.owned = false
      if owned then call("drag_finish", state.address) end
      if not live(state) then return end
      release(state)
      paint(state, state.hovered == true)
    end
  end

  function api.drag(window, phase, mode, sequence)
    if not api.enabled() then return end
    local state = lookup(window)
    if not state then return end
    if phase == "begin" then
      if not policy.eligible(window) then return end
      if mode ~= "move" and mode ~= "resize" then return end
      if sequence == nil then return end
      -- Duplicate announcements cannot replace the original before snapshot.
      if state.pending and state.pending.sequence == sequence then return end
      state.pending = { sequence = sequence, before = policy.snapshot(window) }
      return
    end
    local pending = state.pending
    if not pending or pending.sequence ~= sequence then return end
    if phase ~= "end" and phase ~= "abort" and phase ~= "rejected" then return end
    state.pending = nil -- duplicate/reentrant end can never accept twice
    state.owned = false
    release(state)
    paint(state, state.hovered == true)
    if phase ~= "end" then return end
    -- The bridge guarantees this runs AFTER the final synchronous native step.
    -- snapshot/equal include geometry; destination_valid guards monitor/work area.
    if policy.eligible(window) and policy.destination_valid(window) then
      local final = policy.snapshot(window)
      if pending.before and final and not policy.equal(pending.before, final) then
        policy.accept(window, final, pending.before)
      end
    end
  end

  function api.active(window)
    local state = lookup(window)
    return api.enabled() and state ~= nil and state.pending ~= nil
  end

  function api.forget(window)
    local state = lookup(window)
    if state then remove(state) end
  end

  function api.interrupt(window)
    local state = lookup(window)
    if not state then return end
    cancel(state)
    state.hovered = false
    paint(state, false)
  end

  function api.shutdown()
    if stopped then return end
    stopped = true
    local old = states
    states, addresses = {}, {}
    for _, state in pairs(old) do
      cancel(state)
      call("decoration_remove", state.address)
    end
  end
  return api
end

return M
