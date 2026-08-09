-- Functions, fields and methods, including the recursion rule: a function
-- whose only caller is itself is dead, and saying so is the whole point.

local support = require('tests.support')
local run, findings = support.run, support.findings
local assert_list_equal = support.assert_list_equal

return {

  ['unused local function is reported'] = function()
    local output = run({ ['a.lua'] = 'local function f() return 1 end\n' })
    assert_list_equal(findings(output), { 'DC02 f' })
  end,

  ['a function that only calls itself is dead'] = function()
    local output = run({
      ['a.lua'] = [[
local function countdown(n)
  if n > 0 then return countdown(n - 1) end
  return 0
end
]],
    })
    assert_list_equal(findings(output), { 'DC02 countdown' }, 'self-recursion is not a use')
  end,

  ['a recursive function called from outside is live'] = function()
    support.assert_clean({
      ['a.lua'] = [[
local function countdown(n)
  if n > 0 then return countdown(n - 1) end
  return 0
end
print(countdown(3))
]],
    })
  end,

  ['forward-declared self-recursion is still detected'] = function()
    local output = run({ ['a.lua'] = [[
local loop
loop = function() return loop() end
]] })
    assert_list_equal(findings(output), { 'DC02 loop' })
  end,

  ['mutual recursion is a known blind spot'] = function()
    -- Documents current behaviour rather than endorsing it: neither function is
    -- reachable, but each is read by the other, so both look used.
    support.assert_clean({
      ['a.lua'] = [[
local ping, pong
function ping() return pong() end
function pong() return ping() end
]],
    }, { '.' })
  end,

  ['unused module field is reported'] = function()
    local output = run({ ['a.lua'] = [[
local M = {}
function M.helper() return 1 end
return M
]] })
    assert_list_equal(findings(output), { 'DC05 helper' })
  end,

  ['unused method is reported as a method'] = function()
    local output = run({ ['a.lua'] = [[
local M = {}
function M:go() return 1 end
return M
]] })
    assert_list_equal(findings(output), { 'DC04 go' })
  end,

  ['a field used from another file is live'] = function()
    support.assert_clean({
      ['mod.lua'] = 'local M = {}\nfunction M.helper() return 1 end\nreturn M\n',
      ['main.lua'] = 'local M = require("mod")\nprint(M.helper())\n',
    })
  end,

  ['a method used from another file is live'] = function()
    support.assert_clean({
      ['mod.lua'] = 'local M = {}\nfunction M:go() return 1 end\nreturn M\n',
      ['main.lua'] = 'local M = require("mod")\nprint(M:go())\n',
    })
  end,

  ['a field that only calls itself is dead'] = function()
    local output =
      run({ ['a.lua'] = [[
local M = {}
function M.loop(n) return M.loop(n) end
return M
]] })
    assert_list_equal(findings(output), { 'DC05 loop' })
  end,

  ['bracket access with a literal string counts as a use'] = function()
    support.assert_clean({ ['a.lua'] = [[
local M = {}
M.value = 1
print(M["value"])
]] })
  end,

  ['named fields of a bound table constructor are definitions'] = function()
    local output =
      run({ ['a.lua'] = [[
local M = { alive = 1, dead = 2 }
print(M.alive)
return M
]] })
    assert_list_equal(findings(output), { 'DC05 dead' })
  end,

  ['an inline table argument is configuration, not definition'] = function()
    -- `f{ verbose = true }` must not claim to define a field called `verbose`;
    -- treating call-site tables as definitions is a false-positive factory.
    support.assert_clean({ ['a.lua'] = 'configure{ verbose = true }\n' })
  end,

  ['metamethods are never reported'] = function()
    -- The VM calls these; no Lua code ever names them, so static reachability
    -- would condemn every metatable in existence.
    support.assert_clean({
      ['a.lua'] = [[
local Point = {}
Point.__index = Point
function Point.__tostring(p) return tostring(p.x) end
function Point.__add(a, b) return a.x + b.x end
return Point
]],
    })
  end,

  ['a double-underscore name that is not a metamethod is still reported'] = function()
    local output = run({ ['a.lua'] = [[
local M = {}
M.__secret = 1
return M
]] })
    assert_list_equal(findings(output), { 'DC05 __secret' })
  end,

  ['a field assigned through self is matched by name'] = function()
    support.assert_clean({
      ['a.lua'] = [[
local M = {}
function M:init() self.count = 0 end
function M:get() return self.count end
print(M.init, M.get)
return M
]],
    })
  end,
}
