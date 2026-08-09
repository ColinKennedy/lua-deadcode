-- Parser coverage and, just as importantly, what happens when parsing fails:
-- a file this tool cannot read must never take the run down with it.

local support = require('tests.support')
local Parser = require('deadcode.parser')
local run, findings = support.run, support.findings
local assert_list_equal, assert_equal = support.assert_list_equal, support.assert_equal
local assert_contains, assert_true = support.assert_contains, support.assert_true

-- Delimited with `[===[` because the tour itself contains `]]`.
local SYNTAX_TOUR = [===[
#!/usr/bin/env lua
local long = [==[ nested ]] brackets ]==]
--[[ a long
     comment ]]
local hex, float, exp = 0xff, 1.5, 1e-3
local t = { 1, 2, x = 3, ["y"] = 4, [hex] = 5; 6 }
local s = 'escapes: \t \65 \x42 \
continued'
local function varargs(...) return select('#', ...) end
local obj = setmetatable({}, {})
function obj.field() end
function obj:method() end
obj:method()
print(obj.field, long, float, exp, t, s, varargs())
for i = 1, 10, 2 do print(i) end
for k, v in pairs(t) do print(k, v) end
while true do break end
repeat local q = 1 until q
do local scoped = 1 print(scoped) end
if hex then elseif float then else end
print(#t, -hex, not float, hex .. "", hex ^ 2 ^ 3)
]===]

return {

  ['an empty file is reported'] = function()
    local output = run({ ['a.lua'] = '' })
    assert_list_equal(findings(output), { 'DC11' })
  end,

  ['a whitespace-only file is reported as empty'] = function()
    local output = run({ ['a.lua'] = '\n\n   \n' })
    assert_list_equal(findings(output), { 'DC11' })
  end,

  ['a comment-only file is reported as empty'] = function()
    local output = run({ ['a.lua'] = '-- nothing to see here\n' })
    assert_list_equal(findings(output), { 'DC11' })
  end,

  ['an unparsable file is reported and skipped'] = function()
    local output, code = run({ ['bad.lua'] = 'local x = \n' })
    assert_contains(output, 'failed to parse bad.lua')
    assert_equal(code, 2)
  end,

  ['an unparsable file does not stop the other files'] = function()
    local output, code = run({
      ['bad.lua'] = 'function f(\n',
      ['good.lua'] = 'local y = 1\n',
    })
    assert_contains(output, 'failed to parse bad.lua')
    assert_list_equal(findings(output), { 'DC01 y' })
    assert_equal(code, 1)
  end,

  ['a broad syntax tour parses cleanly'] = function()
    local output = run({ ['a.lua'] = SYNTAX_TOUR })
    assert_equal(
      tostring(output):find('failed to parse'),
      nil,
      'every construct in the tour must parse'
    )
  end,

  ['the parser returns errors rather than raising'] = function()
    local cases = {
      'local x = ',
      'function f(',
      "local s = 'unterminated",
      'local s = [[ unclosed',
      '1 + 1',
      'end',
      'local t = {',
    }
    for _, source in ipairs(cases) do
      local ok, chunk, err = pcall(Parser.parse, source, 'x.lua')
      assert_true(ok, 'parse must not raise for: ' .. source)
      assert_equal(chunk, nil, 'expected no chunk for: ' .. source)
      assert_true(type(err) == 'string' and #err > 0, 'expected a message for: ' .. source)
    end
  end,

  ['line numbers survive long strings and comments'] = function()
    local output =
      run({ ['a.lua'] = [[
local text = [==[
one
two
three
]==]
local dead = 1
print(text)
]] })
    assert_equal(
      support.lines(output)[1]:match('^[^ ]+'),
      'a.lua:6:7:',
      'a multi-line string must not shift later line numbers'
    )
  end,

  ['line numbers survive CRLF endings'] = function()
    local output = run({ ['a.lua'] = 'print(1)\r\nprint(2)\r\nlocal dead = 1\r\n' })
    assert_equal(support.lines(output)[1]:match('^[^ ]+'), 'a.lua:3:7:')
  end,
}
