-- Dead branches, unreachable statements, labels and loop variables.
--
-- The truthiness tests matter more than they look: in Lua only `nil` and
-- `false` are falsy, so `if 0 then` and `if "" then` are both live branches.
-- Porting Python's notion of falsiness here would produce confident nonsense.

local support = require('tests.support')
local run, findings = support.run, support.findings
local assert_list_equal = support.assert_list_equal

return {

  ['if false is a dead branch'] = function()
    local output = run({ ['a.lua'] = 'if false then print(1) end\n' })
    assert_list_equal(findings(output), { 'DC10 if' })
  end,

  ['if nil is a dead branch'] = function()
    local output = run({ ['a.lua'] = 'if nil then print(1) end\n' })
    assert_list_equal(findings(output), { 'DC10 if' })
  end,

  ['zero is truthy in Lua'] = function()
    support.assert_clean({ ['a.lua'] = 'if 0 then print(1) end\n' })
  end,

  ['the empty string is truthy in Lua'] = function()
    support.assert_clean({ ['a.lua'] = 'if "" then print(1) end\n' })
  end,

  ['and-false folds to a dead branch'] = function()
    local output = run({ ['a.lua'] = 'if false and x then print(1) end\n' })
    assert_list_equal(findings(output), { 'DC10 if' })
  end,

  ['not true folds to a dead branch'] = function()
    local output = run({ ['a.lua'] = 'if not true then print(1) end\n' })
    assert_list_equal(findings(output), { 'DC10 if' })
  end,

  ['an unknown condition is left alone'] = function()
    support.assert_clean({ ['a.lua'] = 'if os.time() > 0 then print(1) end\n' })
  end,

  ['a branch after an always-true branch is dead'] = function()
    local output = run({ ['a.lua'] = [[
if true then
  print(1)
else
  print(2)
end
]] })
    assert_list_equal(findings(output), { 'DC10 if' })
  end,

  ['an elseif after an always-true branch is dead'] = function()
    local output =
      run({ ['a.lua'] = [[
if true then
  print(1)
elseif other then
  print(2)
end
]] })
    assert_list_equal(findings(output), { 'DC10 if' })
  end,

  ['while false is a dead loop'] = function()
    local output = run({ ['a.lua'] = 'while false do print(1) end\n' })
    assert_list_equal(findings(output), { 'DC10 while' })
  end,

  ['while true is idiomatic, not dead'] = function()
    support.assert_clean({ ['a.lua'] = 'while true do print(1) break end\n' })
  end,

  ['statements after break are unreachable'] = function()
    local output = run({ ['a.lua'] = [[
while true do
  break
  print("never")
end
]] })
    assert_list_equal(findings(output), { 'DC09 break' })
  end,

  ['statements after goto are unreachable'] = function()
    local output =
      run({ ['a.lua'] = [[
while true do
  goto continue
  print("never")
  ::continue::
end
]] })
    assert_list_equal(findings(output), { 'DC09 goto' })
  end,

  ['an unused label is reported'] = function()
    local output = run({ ['a.lua'] = '::top::\nprint(1)\n' })
    assert_list_equal(findings(output), { 'DC12 top' })
  end,

  ['a label targeted by a goto is live'] = function()
    support.assert_clean({
      ['a.lua'] = [[
for i = 1, 3 do
  if i == 2 then goto continue end
  print(i)
  ::continue::
end
]],
    })
  end,

  ['an unused numeric loop variable is reported'] = function()
    local output = run({ ['a.lua'] = 'for i = 1, 10 do print("x") end\n' })
    assert_list_equal(findings(output), { 'DC08 i' })
  end,

  ['an unused generic loop variable is reported'] = function()
    local output = run({ ['a.lua'] = 'for k, v in pairs(t) do print(k) end\n' })
    assert_list_equal(findings(output), { 'DC08 v' })
  end,

  ['the underscore placeholder in a loop is never reported'] = function()
    support.assert_clean({ ['a.lua'] = 'for _, v in ipairs(t) do print(v) end\n' })
  end,
}
