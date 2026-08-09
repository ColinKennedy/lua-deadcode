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
    local output = run({ ['a.lua'] = 'local x = 1  -- deadcode: ignore DC02\n' })
    assert_list_equal(findings(output), { 'DC01 x' })
  end,

  ['several codes can be listed'] = function()
    support.assert_clean({ ['a.lua'] = 'local x = 1  -- deadcode: ignore DC02, DC01\n' })
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
}
