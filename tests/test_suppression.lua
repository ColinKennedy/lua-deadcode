-- Inline directives, and the deliberate difference between muting a file and
-- excluding it.

local support = require('tests.support')
local run, findings = support.run, support.findings
local assert_list_equal, assert_equal = support.assert_list_equal, support.assert_equal

return {

  ['a trailing directive suppresses its own line'] = function()
    support.assert_clean({ ['a.lua'] = 'local x = 1  -- deadcode: ignore\n' })
  end,

  ['a directive listing the matching code suppresses'] = function()
    support.assert_clean({ ['a.lua'] = 'local x = 1  -- deadcode: ignore DC01\n' })
  end,

  ['a directive listing a different code does not suppress'] = function()
    -- The DC13 is the other half of the same story: the DC02 was not only
    -- powerless over the DC01, it had nothing at all to do on this line.
    local output = run({ ['a.lua'] = 'local x = 1  -- deadcode: ignore DC02\n' })
    assert_list_equal(findings(output), { 'DC01 x', 'DC13 DC02' })
  end,

  ['several codes can be listed'] = function()
    support.assert_clean({
      ['a.lua'] = 'local function f(a) end  -- deadcode: ignore DC06, DC02\n',
    }, { '.', '--check-params' })
  end,

  ['a directive on its own line governs the next line of code'] = function()
    support.assert_clean({ ['a.lua'] = '-- deadcode: ignore\nlocal x = 1\n' })
  end,

  ['a standalone directive skips blank lines to reach the code'] = function()
    support.assert_clean({ ['a.lua'] = '-- deadcode: ignore\n\n\nlocal x = 1\n' })
  end,

  ['a standalone directive does not leak onto earlier lines'] = function()
    local output = run({ ['a.lua'] = 'local x = 1\n-- deadcode: ignore\nlocal y = 2\n' })
    assert_list_equal(findings(output), { 'DC01 x' })
  end,

  ['noqa spelling is accepted'] = function()
    support.assert_clean({ ['a.lua'] = 'local x = 1  -- noqa\n' })
  end,

  ['noqa with a code is accepted'] = function()
    support.assert_clean({ ['a.lua'] = 'local x = 1  -- noqa: DC01\n' })
  end,

  ['luacheck ignore is accepted'] = function()
    support.assert_clean({ ['a.lua'] = 'local x = 1  -- luacheck: ignore\n' })
  end,

  ['a word merely containing noqa is not a directive'] = function()
    local output = run({ ['a.lua'] = 'local x = 1  -- broken-noqa-ish note\n' })
    assert_list_equal(findings(output), { 'DC01 x' })
  end,

  ['ignore-file mutes every finding in the file'] = function()
    support.assert_clean({
      ['a.lua'] = '-- deadcode: ignore-file\nlocal x = 1\nunused_global = 2\n',
    })
  end,

  ['a muted file still contributes usages'] = function()
    -- This is the whole reason ignore-file mutes rather than skips: the file is
    -- read, so what it uses keeps the rest of the codebase honest.
    support.assert_clean({
      ['mod.lua'] = 'local M = {}\nfunction M.helper() return 1 end\nreturn M\n',
      ['main.lua'] = '-- deadcode: ignore-file\nlocal M = require("mod")\nprint(M.helper())\n',
    })
  end,

  ['an excluded file contributes nothing, so its callees look dead'] = function()
    -- The contrast with the previous test, stated as behaviour: --exclude means
    -- "do not read", which is fast but blind.
    local output = run({
      ['mod.lua'] = 'local M = {}\nfunction M.helper() return 1 end\nreturn M\n',
      ['main.lua'] = 'local M = require("mod")\nprint(M.helper())\n',
    }, { '.', '--exclude', 'main.lua' })
    assert_list_equal(findings(output), { 'DC05 helper' })
  end,

  ['ignore-names-in-files reads the file but reports nothing from it'] = function()
    local output = run({
      ['mod.lua'] = 'local M = {}\nfunction M.helper() return 1 end\nreturn M\n',
      ['main.lua'] = 'local M = require("mod")\nprint(M.helper())\nlocal dead = 1\n',
    }, { '.', '--ignore-names-in-files', 'main.lua' })
    assert_list_equal(findings(output), {}, 'usages counted, findings suppressed')
  end,

  ['a long comment can carry a directive'] = function()
    support.assert_clean({ ['a.lua'] = 'local x = 1  --[[ deadcode: ignore ]]\n' })
  end,

  ['directives are case-insensitive on the keyword'] = function()
    support.assert_clean({ ['a.lua'] = 'local x = 1  -- Deadcode: ignore\n' })
  end,

  ['suppression does not change the exit code for other findings'] = function()
    local _, code = run({ ['a.lua'] = 'local x = 1 -- deadcode: ignore\nlocal y = 2\n' })
    assert_equal(code, 1)
  end,

  -- ------------------------------------------------- DC13: unused directives

  ['a directive that suppresses nothing is reported'] = function()
    local output = run({ ['a.lua'] = 'print(1)  -- deadcode: ignore\n' })
    assert_list_equal(findings(output), { 'DC13' })
  end,

  ['a working directive is not reported'] = function()
    support.assert_clean({ ['a.lua'] = 'local x = 1  -- deadcode: ignore\n' })
  end,

  ['only the code that went unused is reported'] = function()
    local output = run({ ['a.lua'] = 'local x = 1  -- deadcode: ignore DC01, DC07\n' })
    assert_list_equal(findings(output), { 'DC13 DC07' })
  end,

  ['the finding points at the comment, not at the code it governs'] = function()
    local output = run({ ['a.lua'] = '-- deadcode: ignore\nprint(1)\n' })
    assert_list_equal(
      support.lines(output),
      { 'a.lua:1:1: DC13 Ignore comment suppresses nothing; remove it' }
    )
  end,

  ['a standalone directive with no code after it is reported'] = function()
    -- The lexer points a trailing standalone comment at its own line, so the
    -- directive is inert. Inert is exactly what DC13 exists to say out loud.
    local output = run({ ['a.lua'] = 'print(1)\n-- deadcode: ignore\n' })
    assert_list_equal(findings(output), { 'DC13' })
  end,

  ["another tool's directive is never reported"] = function()
    -- Deleting a `luacheck: ignore` on this tool's say-so would be advice about
    -- a linter it cannot see.
    support.assert_clean({
      ['a.lua'] = 'print(1)  -- luacheck: ignore\nprint(2)  -- noqa: DC01\n',
    })
  end,

  ['a redundant directive on an already-exempt name is reported'] = function()
    -- `_x` is exempt by naming convention, so the directive adds nothing. This
    -- is the case the check is really for: suppression left behind after the
    -- code it covered was changed.
    local output = run({ ['a.lua'] = 'local _x = 1  -- deadcode: ignore DC01\n' })
    assert_list_equal(findings(output), { 'DC13 DC01' })
  end,

  ['a directive cannot excuse itself'] = function()
    -- Were DC13 suppressible by the directive it is about, every bare
    -- directive would justify its own existence and the check would be inert.
    local output = run({ ['a.lua'] = 'print(1)  -- deadcode: ignore DC13\n' })
    assert_list_equal(findings(output), { 'DC13 DC13' })
  end,

  ['a neighbouring directive can excuse an unused one'] = function()
    -- The escape hatch, for a directive worth keeping through a change that
    -- has not landed yet. The excusing directive is then doing work itself, so
    -- it is not reported either.
    support.assert_clean({
      ['a.lua'] = '-- deadcode: ignore DC13\nprint(1)  -- deadcode: ignore DC01\n',
    })
  end,

  ['--ignore-codes turns the whole check off'] = function()
    support.assert_clean({
      ['a.lua'] = 'print(1)  -- deadcode: ignore\n',
    }, { '.', '--ignore-codes', 'DC13' })
  end,

  ['a muted file is not nagged about its directives'] = function()
    -- `ignore-file` already said nothing here is being listened to.
    support.assert_clean({
      ['a.lua'] = '-- deadcode: ignore-file\nprint(1)  -- deadcode: ignore\n',
    })
  end,

  ['an unused directive fails the run like any other finding'] = function()
    local _, code = run({ ['a.lua'] = 'print(1)  -- deadcode: ignore\n' })
    assert_equal(code, 1)
  end,
}
