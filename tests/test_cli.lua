-- Command-line surface: output shape, filters and exit codes.

local support = require('tests.support')
local cli = require('deadcode.cli')
local constants = require('deadcode.constants')
local run, findings = support.run, support.findings
local assert_list_equal, assert_equal = support.assert_list_equal, support.assert_equal
local assert_contains = support.assert_contains

return {

  ['a finding is formatted as file, line, column, code, message'] = function()
    local output = run({ ['a.lua'] = 'local x = 1\n' })
    assert_equal(output, 'a.lua:1:7: DC01 Variable `x` is never used')
  end,

  ['a clean run says so and exits zero'] = function()
    local output, code = run({ ['a.lua'] = 'print(1)\n' })
    assert_equal(output, 'Well done! No dead code found.')
    assert_equal(code, 0)
  end,

  ['findings exit with status one'] = function()
    local _, code = run({ ['a.lua'] = 'local x = 1\n' })
    assert_equal(code, 1)
  end,

  ['--count prints only the number'] = function()
    local output, code = run({ ['a.lua'] = 'local x = 1\nlocal y = 2\n' }, { '.', '--count' })
    assert_equal(output, '2')
    assert_equal(code, 1)
  end,

  ['--count prints zero for a clean run'] = function()
    local output, code = run({ ['a.lua'] = 'print(1)\n' }, { '.', '--count' })
    assert_equal(output, '0')
    assert_equal(code, 0)
  end,

  ['--quiet prints nothing but keeps the exit code'] = function()
    local output, code = run({ ['a.lua'] = 'local x = 1\n' }, { '.', '--quiet' })
    assert_equal(output, nil)
    assert_equal(code, 1)
  end,

  ['--version prints the version'] = function()
    local output, code = run({}, { '--version' })
    assert_equal(output, constants.VERSION)
    assert_equal(code, 0)
  end,

  ['--help prints usage'] = function()
    local output, code = run({}, { '--help' })
    assert_contains(output, 'Usage: deadcode')
    assert_equal(code, 0)
  end,

  ['no paths is a usage error'] = function()
    local output, code = run({}, {})
    assert_contains(output, 'no paths given')
    assert_equal(code, 2)
  end,

  ['an unknown option is a usage error'] = function()
    local output, code = run({}, { '.', '--bogus' })
    assert_contains(output, "unknown option '--bogus'")
    assert_equal(code, 2)
  end,

  ['a missing path is reported and exits two'] = function()
    local output, code = run({ ['a.lua'] = 'print(1)\n' }, { 'nowhere' })
    assert_contains(output, 'could not be found')
    assert_equal(code, 2)
  end,

  ['--only restricts reporting to matching files'] = function()
    local output = run({
      ['a.lua'] = 'local x = 1\n',
      ['b.lua'] = 'local y = 2\n',
    }, { '.', '--only', 'b.lua' })
    assert_list_equal(findings(output), { 'DC01 y' })
  end,

  ['--only also restricts the count'] = function()
    local output = run({
      ['a.lua'] = 'local x = 1\n',
      ['b.lua'] = 'local y = 2\n',
    }, { '.', '--only', 'b.lua', '--count' })
    assert_equal(output, '1', 'count and listing must agree')
  end,

  ['--exclude prunes by directory name'] = function()
    local output = run({
      ['src/a.lua'] = 'local x = 1\n',
      ['vendor/b.lua'] = 'local y = 2\n',
    }, { '.', '--exclude', 'vendor' })
    assert_list_equal(findings(output), { 'DC01 x' })
  end,

  ['--ignore-names accepts a glob'] = function()
    local output = run({
      ['a.lua'] = 'local handler_a = 1\nlocal other = 2\n',
    }, { '.', '--ignore-names', 'handler_*' })
    assert_list_equal(findings(output), { 'DC01 other' })
  end,

  ['--ignore-names accepts a comma-separated list'] = function()
    support.assert_clean(
      { ['a.lua'] = 'local a = 1\nlocal b = 2\n' },
      { '.', '--ignore-names', 'a,b' }
    )
  end,

  ['--ignore-names accepts several values'] = function()
    support.assert_clean(
      { ['a.lua'] = 'local a = 1\nlocal b = 2\n' },
      { '.', '--ignore-names', 'a', 'b' }
    )
  end,

  ['--ignore-codes disables a rule'] = function()
    local output = run({
      ['a.lua'] = 'local x = 1\nfor i = 1, 3 do print("x") end\n',
    }, { '.', '--ignore-codes', 'DC08' })
    assert_list_equal(findings(output), { 'DC01 x' })
  end,

  ['--ignore-codes is case-insensitive'] = function()
    support.assert_clean({ ['a.lua'] = 'local x = 1\n' }, { '.', '--ignore-codes', 'dc01' })
  end,

  ['findings are sorted by file then position'] = function()
    local output = run({
      ['b.lua'] = 'local later = 1\n',
      ['a.lua'] = 'local first = 1\nlocal second = 2\n',
    })
    assert_list_equal(findings(output), { 'DC01 first', 'DC01 second', 'DC01 later' })
  end,

  ['colour is on by default and off with --no-color'] = function()
    local coloured = cli.main(
      { '.', '--no-config' },
      { fs = support.virtual_fs({ ['a.lua'] = 'local x = 1\n' }) }
    )
    assert_contains(coloured, '\27[', 'expected ANSI escapes by default')

    local plain = run({ ['a.lua'] = 'local x = 1\n' })
    assert_equal(plain:find('\27', 1, true), nil, 'expected no escapes with --no-color')
  end,

  ['a path after -- is not read as an option value'] = function()
    local output = run(
      { ['a.lua'] = 'local x = 1\n' },
      { '--ignore-names', 'nothing', '--', 'a.lua' }
    )
    assert_list_equal(findings(output), { 'DC01 x' })
  end,
}
