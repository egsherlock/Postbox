-- Postbox foundation :: saved-variable persistence + the chat printer.
--
-- Publishes:
--   ns.Core.Store.Bind(ns, globalName)   -> installs ns.Store
--   ns.Core.Logger.Bind(ns, label, hex)  -> installs ns.Print / ns.PrintError
--
-- Nothing here reads or writes the saved-variables global at file-chunk time:
-- the client restores saved variables *after* our Lua runs and just before
-- ADDON_LOADED, so every access is lazy and driven by the first call.

local ADDON_NAME, ns = ...

ns.Core = ns.Core or {}
local Core = ns.Core
Core.Store = Core.Store or {}
Core.Logger = Core.Logger or {}

local Store = Core.Store
local Logger = Core.Logger

-------------------------------------------------------------
-- Chat printer
-------------------------------------------------------------

local DEFAULT_LABEL_COLOR = "ffd100"
local ERROR_COLOR = "ff5555"

-- Six hex digits, no escape prefix. A malformed |cff… swallows the rest of the
-- chat line, so anything that is not exactly six hex digits is rejected.
local function NormalizeHex(color, fallback)
  if type(color) ~= "string" then return fallback end
  local hex = color:gsub("^#", "")
  if hex:match("^%x%x%x%x%x%x$") then return hex end
  return fallback
end

-- Joins varargs the way print() does, coercing every part.
local function JoinParts(...)
  local count = select("#", ...)
  if count == 0 then return "" end
  if count == 1 then return tostring((...)) end

  local parts = {}
  for i = 1, count do
    parts[i] = tostring((select(i, ...)))
  end
  return table.concat(parts, " ")
end

local function Emit(prefix, ...)
  local frame = DEFAULT_CHAT_FRAME
  if not frame or type(frame.AddMessage) ~= "function" then return end
  frame:AddMessage(prefix .. " " .. JoinParts(...))
end

-- Installs ns.Print / ns.PrintError onto the given namespace table.
-- `colorHex` is six RGB hex digits with no escape prefix; this function owns
-- the escape sequence so no call site has to know about it.
function Logger.Bind(target, label, colorHex)
  if type(target) ~= "table" then return false end

  local text = tostring(label or "")
  if text == "" then text = tostring(ADDON_NAME or "Postbox") end

  local prefix = ("|cff%s%s|r"):format(NormalizeHex(colorHex, DEFAULT_LABEL_COLOR), text)
  local errorPrefix = ("|cff%s%s|r"):format(ERROR_COLOR, text)

  target.Print = function(...) Emit(prefix, ...) end
  target.PrintError = function(...) Emit(errorPrefix, ...) end
  return true
end

-------------------------------------------------------------
-- Persistence
-------------------------------------------------------------

local MAX_DEFAULT_DEPTH = 16

local globalName          -- the ## SavedVariables entry, set by Bind
local cachedRoot          -- last table seen at _G[globalName]
local nodeCache = {}      -- path string -> resolved node

-- Deep copy so a caller's defaults table is never aliased into saved variables:
-- a later mutation of one profile's settings would otherwise mutate the shared
-- defaults for every other profile.
local function CopyValue(value, depth)
  if type(value) ~= "table" or depth > MAX_DEFAULT_DEPTH then return value end
  local out = {}
  for key, inner in pairs(value) do
    out[key] = CopyValue(inner, depth + 1)
  end
  return out
end

-- A key that already holds any non-nil value (including false) is never
-- touched. That is what lets a later addon version extend the defaults without
-- resetting settings the user has already changed.
local function ApplyDefaults(node, defaults, depth)
  if depth > MAX_DEFAULT_DEPTH then return node end

  for key, value in pairs(defaults) do
    local current = node[key]
    if current == nil then
      node[key] = CopyValue(value, depth)
    elseif type(current) == "table" and type(value) == "table" then
      ApplyDefaults(current, value, depth + 1)
    end
  end

  return node
end

-- Materialises the saved-variables global lazily. A restored value that is not
-- a table (corrupt or hand-edited saved variables) is replaced rather than
-- allowed to crash the addon.
local function Root()
  local root = globalName and _G[globalName] or nil
  if type(root) ~= "table" then
    root = {}
    if globalName then _G[globalName] = root end
  end

  if root ~= cachedRoot then
    -- The client swapped the global in under us (first restore, or a reset).
    -- Every memoised node belongs to the old tree.
    cachedRoot = root
    nodeCache = {}
  end

  return root
end

-- Walks dot-separated segments from the root, creating an empty table for any
-- missing segment, and returns the node at the end. Always returns a table.
-- Empty segments (leading, trailing or doubled dots) are skipped.
--
-- The memo is safe because no caller ever replaces an ensured node wholesale;
-- they only mutate its contents. Replacing the root itself is detected above.
local function Resolve(path)
  local root = Root()
  if type(path) ~= "string" or path == "" then return root end

  local node = nodeCache[path]
  if node ~= nil then return node end

  node = root
  for segment in path:gmatch("[^%.]+") do
    local child = node[segment]
    if type(child) ~= "table" then
      if child ~= nil and ns.PrintError then
        -- Losing a value silently is how "my settings reset themselves" bugs
        -- start; say so rather than swallowing it.
        ns.PrintError(("saved variable '%s' held a %s where a table was expected; replaced."):
          format(segment, type(child)))
      end
      child = {}
      node[segment] = child
    end
    node = child
  end

  nodeCache[path] = node
  return node
end

-- Resolve a dotted path, creating each missing level, and optionally merge a
-- table of defaults into the result. Returns the node.
function Store.EnsurePath(path, defaults)
  local node = Resolve(path)
  if type(defaults) == "table" then
    ApplyDefaults(node, defaults, 1)
  end
  return node
end

-- Read-only sibling of EnsurePath: resolves without creating anything, so
-- merely checking a setting cannot write empty tables into saved variables.
-- Returns `fallback` (default nil) when any segment is missing.
function Store.Get(path, fallback)
  local node = Root()
  if type(path) ~= "string" or path == "" then return node end

  for segment in path:gmatch("[^%.]+") do
    if type(node) ~= "table" then return fallback end
    node = node[segment]
    if node == nil then return fallback end
  end

  return node
end

-- Associates the store with a named global and publishes it as ns.Store.
-- EnsurePath/Get are plain function fields, callable with dot syntax.
function Store.Bind(target, name)
  if type(target) ~= "table" or type(name) ~= "string" or name == "" then
    return false
  end

  globalName = name
  cachedRoot = nil
  nodeCache = {}

  target.Store = target.Store or {}
  target.Store.EnsurePath = Store.EnsurePath
  target.Store.Get = Store.Get
  return true
end
