-- A deliberately messy module, used by `make demo` to show what the tool
-- reports and — just as importantly — what it correctly leaves alone.

local socket = require('socket')          -- DC07: required but never used
local os_clock = require('os')            -- live: used by stamp() below

local Inventory = {}
Inventory.__index = Inventory             -- quiet: metamethods are exempt

local MAX_ITEMS = 100                     -- live: read by add()
local LEGACY_LIMIT = 20                   -- DC01: nothing reads this

local function stamp()                    -- live: called by add()
  return os_clock.time()
end

local function migrate_v1(rows)           -- DC02: nothing calls this
  return rows
end

local function retry(n)                   -- DC02: only ever calls itself
  if n > 0 then return retry(n - 1) end
  return 0
end

function Inventory.new()                  -- live: used by examples/shop.lua
  return setmetatable({ items = {}, added_at = stamp() }, Inventory)
end

function Inventory:add(item)              -- live: used by examples/shop.lua
  if #self.items >= MAX_ITEMS then return false end
  self.items[#self.items + 1] = item
  return true
end

function Inventory:drain()                -- DC04: never invoked anywhere
  self.items = {}
end

Inventory.debug_mode = false              -- DC05: never read

for index = 1, 3 do                       -- DC08: `index` is never read
  print('warming up')
end

if false then                             -- DC10: never taken
  print('disabled')
end

if 0 then                                 -- quiet: 0 is TRUE in Lua
  print('this really does run')
end

::cleanup::                               -- DC12: no goto targets it

report_count = 0                          -- DC03: assigned, never read

return Inventory
