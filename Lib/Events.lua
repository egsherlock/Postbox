-- Postbox foundation :: game-event bus.
--
-- One shared hidden frame fans WoW events out to any number of handlers, so no
-- consumer needs its own frame and a handler that errors cannot stop the other
-- handlers for the same event from running.
--
-- Publishes: ns.Core.Events.NewBus(logFn)

local _, ns = ...

ns.Core = ns.Core or {}
local Core = ns.Core
Core.Events = Core.Events or {}

local Events = Core.Events

-- C_EventUtils.IsEventValid is the purpose-built check; falling back to a
-- protected RegisterEvent keeps this working on a client that predates it.
local function IsKnownEvent(eventName)
  if C_EventUtils and type(C_EventUtils.IsEventValid) == "function" then
    local ok, valid = pcall(C_EventUtils.IsEventValid, eventName)
    if ok then return valid and true or false end
  end
  return nil
end

function Events.NewBus(logFn)
  local frame = CreateFrame("Frame")
  local handlers = {}
  local bus = {}

  local function Log(...)
    if type(logFn) == "function" then logFn(...) end
  end

  -- Removed handlers leave a `false` tombstone so a dispatch in progress keeps
  -- its indices; the list is compacted once the dispatch has finished.
  local function Compact(eventName, list)
    local write = 0
    for read = 1, #list do
      local handler = list[read]
      list[read] = nil
      if handler then
        write = write + 1
        list[write] = handler
      end
    end

    if write == 0 then
      handlers[eventName] = nil
      frame:UnregisterEvent(eventName)
    end
  end

  frame:SetScript("OnEvent", function(_, eventName, ...)
    local list = handlers[eventName]
    if not list then return end

    local holes = false
    -- `#list` is evaluated once, so a handler registering another handler
    -- during dispatch cannot extend the iteration under us.
    for i = 1, #list do
      local handler = list[i]
      if handler then
        local ok, err = pcall(handler, eventName, ...)
        if not ok then
          Log(("event handler error (%s): %s"):format(eventName, tostring(err)))
        end
      else
        holes = true
      end
    end

    if holes then Compact(eventName, list) end
  end)

  -- Handlers are invoked as handler(eventName, ...) — the event name first,
  -- payload after. Registering the same event twice subscribes once and runs
  -- both handlers in registration order.
  function bus.Register(eventName, handler)
    if type(eventName) ~= "string" or eventName == "" then return false end
    if type(handler) ~= "function" then return false end

    local list = handlers[eventName]
    if not list then
      -- Subscribing to an event this client does not know must not raise; that
      -- happens across expansion boundaries when an event is removed.
      local known = IsKnownEvent(eventName)
      if known == false then
        Log(("unknown event ignored: %s"):format(eventName))
        return false
      end

      local ok, err = pcall(frame.RegisterEvent, frame, eventName)
      if not ok then
        Log(("could not register event %s: %s"):format(eventName, tostring(err)))
        return false
      end

      list = {}
      handlers[eventName] = list
    end

    list[#list + 1] = handler
    return true
  end

  function bus.Unregister(eventName, handler)
    local list = handlers[eventName]
    if not list or type(handler) ~= "function" then return false end

    local found = false
    for i = 1, #list do
      if list[i] == handler then
        list[i] = false
        found = true
      end
    end

    if found then Compact(eventName, list) end
    return found
  end

  function bus.UnregisterAll(eventName)
    if not handlers[eventName] then return false end
    handlers[eventName] = nil
    frame:UnregisterEvent(eventName)
    return true
  end

  -- ADDON_LOADED fires once per addon in the session (dozens of times).
  -- This runs the handler for one addon only and then stops listening, so no
  -- consumer has to string-compare the payload or stay subscribed for the
  -- rest of the session.
  function bus.OnAddonLoaded(addonName, handler)
    if type(addonName) ~= "string" or addonName == "" then return false end
    if type(handler) ~= "function" then return false end

    local wrapper
    wrapper = function(_, loaded)
      if loaded ~= addonName then return end
      bus.Unregister("ADDON_LOADED", wrapper)
      handler(addonName)
    end

    return bus.Register("ADDON_LOADED", wrapper)
  end

  return bus
end
