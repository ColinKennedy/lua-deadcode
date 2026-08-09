-- Globals are matched by name across the whole program, because that is the
-- only thing Lua can guarantee about them statically.

local support = require('tests.support')
local run, findings = support.run, support.findings
local assert_list_equal = support.assert_list_equal

return {

  ['unused global is reported'] = function()
    local output = run({ ['a.lua'] = 'config = 1\n' })
    assert_list_equal(findings(output), { 'DC03 config' })
  end,

  ['a global read in another file is live'] = function()
    support.assert_clean({
      ['a.lua'] = 'shared = 1\n',
      ['b.lua'] = 'print(shared)\n',
    })
  end,

  ['a global read in the same file is live'] = function()
    support.assert_clean({ ['a.lua'] = 'shared = 1\nprint(shared)\n' })
  end,

  ['a global function that only calls itself is dead'] = function()
    local output = run({ ['a.lua'] = [[
function spin() return spin() end
]] })
    assert_list_equal(findings(output), { 'DC03 spin' })
  end,

  ['repeated assignment produces one finding'] = function()
    local output = run({ ['a.lua'] = 'counter = 1\ncounter = 2\n' })
    assert_list_equal(findings(output), { 'DC03 counter' })
  end,

  ['reading an undefined global is not a finding'] = function()
    -- We only report globals this codebase assigns; anything else belongs to
    -- the standard library or the host environment.
    support.assert_clean({ ['a.lua'] = 'print(string.format("%d", 1))\n' })
  end,

  ['globals in test files are left alone'] = function()
    -- Frameworks reach these by name at runtime, so reachability proves nothing.
    support.assert_clean({ ['spec/thing_spec.lua'] = 'helper_global = 1\n' })
  end,

  ['fields in test files are left alone'] = function()
    support.assert_clean({
      ['spec/thing_spec.lua'] = [[
local T = {}
function T.test_something() return 1 end
return T
]],
    })
  end,

  ['locals in test files are still reported'] = function()
    local output = run({ ['spec/thing_spec.lua'] = 'local unused = 1\n' })
    assert_list_equal(findings(output), { 'DC01 unused' }, 'a dead local is dead wherever it lives')
  end,
}
