-- Locals are resolved exactly, by lexical scope. These tests pin that down:
-- shadowing, declaration order and redeclaration must all behave the way Lua
-- itself does, or the "exact" claim is empty.

local support = require('tests.support')
local run, findings = support.run, support.findings
local assert_list_equal, assert_equal = support.assert_list_equal, support.assert_equal

return {

  ['unused local is reported'] = function()
    local output = run({ ['a.lua'] = 'local x = 1\n' })
    assert_list_equal(findings(output), { 'DC01 x' })
  end,

  ['used local is not reported'] = function()
    support.assert_clean({ ['a.lua'] = 'local x = 1\nprint(x)\n' })
  end,

  ['write-only local is still dead'] = function()
    local output = run({ ['a.lua'] = 'local x\nx = 5\n' })
    assert_list_equal(findings(output), { 'DC01 x' }, 'assignment is not a use')
  end,

  ['an initialiser reads the outer binding, not the one being declared'] = function()
    -- `local x = x` refers to the enclosing x: the new one is not in scope yet.
    support.assert_clean({ ['a.lua'] = [[
local x = 1
do
  local x = x
  print(x)
end
]] })
  end,

  ['shadowed outer local is reported when only the inner one is used'] = function()
    local output = run({ ['a.lua'] = [[
local x = 1
do
  local x = 2
  print(x)
end
]] })
    assert_list_equal(findings(output), { 'DC01 x' })
    assert_equal(
      support.lines(output)[1]:match('^[^ ]+'),
      'a.lua:1:7:',
      'the outer declaration is the one reported'
    )
  end,

  ['redeclaration in the same scope kills the first binding'] = function()
    local output = run({ ['a.lua'] = [[
local x = 1
local x = 2
print(x)
]] })
    assert_list_equal(findings(output), { 'DC01 x' })
    assert_equal(support.lines(output)[1]:match('^[^ ]+'), 'a.lua:1:7:')
  end,

  ['underscore and underscore-prefixed names are never reported'] = function()
    support.assert_clean({ ['a.lua'] = 'local _ = 1\nlocal _ignored = 2\n' })
  end,

  ['multiple assignment pairs names with values by position'] = function()
    local output = run({ ['a.lua'] = 'local a, b, c = 1, 2, 3\nprint(b)\n' })
    assert_list_equal(findings(output), { 'DC01 a', 'DC01 c' })
  end,

  ['repeat-until condition can see locals from the body'] = function()
    support.assert_clean({ ['a.lua'] = 'repeat\n  local done = true\nuntil done\n' })
  end,

  ['locals in a do-block are scoped to it'] = function()
    local output = run({ ['a.lua'] = [[
do
  local inner = 1
end
]] })
    assert_list_equal(findings(output), { 'DC01 inner' })
  end,

  ['parameters are not reported by default'] = function()
    support.assert_clean({ ['a.lua'] = 'local function f(a) return 1 end\nprint(f(1))\n' })
  end,

  ['parameters are reported with --check-params'] = function()
    local output = run(
      { ['a.lua'] = 'local function f(a) return 1 end\nprint(f(1))\n' },
      { '.', '--check-params' }
    )
    assert_list_equal(findings(output), { 'DC06 a' })
  end,

  ['the implicit self of a method is never reported as a parameter'] = function()
    local output = run(
      { ['a.lua'] = [[
local M = {}
function M:go() return 1 end
return M
]] },
      { '.', '--check-params' }
    )
    assert_list_equal(
      findings(output),
      { 'DC04 go' },
      'self is inserted by the language, not written by the author'
    )
  end,

  ['a local holding a function is reported as a function'] = function()
    local output = run({ ['a.lua'] = 'local f = function() return 1 end\n' })
    assert_list_equal(findings(output), { 'DC02 f' })
  end,

  ['a local bound to require is reported as a require'] = function()
    local output = run({ ['a.lua'] = 'local socket = require("socket")\n' })
    assert_list_equal(findings(output), { 'DC07 socket' })
  end,

  ['a used require is not reported'] = function()
    support.assert_clean({ ['a.lua'] = 'local os = require("os")\nprint(os.time())\n' })
  end,
}
