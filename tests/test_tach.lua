-- Reading a `tach.lua`: the declared public interface, and what a declaration
-- is and is not allowed to say.

local support = require('tests.support')
local run, findings = support.run, support.findings
local assert_list_equal, assert_equal = support.assert_list_equal, support.assert_equal

--- A module with one public-looking field nothing in the project calls.
local LIBRARY = 'local M = {}\nfunction M.setup() end\nreturn M\n'

return {

  -- ------------------------------------------------------------- interfaces

  ['an exposed name is not dead code'] = function()
    support.assert_clean({
      ['tach.lua'] = "return { interfaces = { { expose = { 'setup' }, from = { 'mylib' } } } }\n",
      ['mylib.lua'] = LIBRARY,
    })
  end,

  ['the same name in another module is still dead'] = function()
    -- Both halves of an entry have to match: `from` is what keeps `expose`
    -- from being a project-wide amnesty.
    local output = run({
      ['tach.lua'] = "return { interfaces = { { expose = { 'setup' }, from = { 'mylib' } } } }\n",
      ['mylib.lua'] = LIBRARY,
      ['other.lua'] = LIBRARY,
    })
    assert_list_equal(findings(output), { 'DC05 setup' })
  end,

  ['an entry with no from applies to every module'] = function()
    support.assert_clean({
      ['tach.lua'] = "return { interfaces = { { expose = { 'setup' } } } }\n",
      ['mylib.lua'] = LIBRARY,
      ['other.lua'] = LIBRARY,
    })
  end,

  ['expose is a regular expression, not a glob'] = function()
    support.assert_clean({
      ['tach.lua'] = "return { interfaces = { { expose = { 'on_.*' } } } }\n",
      ['mylib.lua'] = 'local M = {}\nfunction M.on_attach() end\nfunction M.on_exit() end\nreturn M\n',
    })
  end,

  ['a regex is anchored at both ends'] = function()
    -- `setup` exposes `setup` and not `setup_helper`, matching tach.
    local output = run({
      ['tach.lua'] = "return { interfaces = { { expose = { 'setup' } } } }\n",
      ['mylib.lua'] = 'local M = {}\nfunction M.setup() end\nfunction M.setup_helper() end\nreturn M\n',
    })
    assert_list_equal(findings(output), { 'DC05 setup_helper' })
  end,

  ['methods and globals can be exposed too'] = function()
    support.assert_clean({
      ['tach.lua'] = "return { interfaces = { { expose = { '.*' } } } }\n",
      ['mylib.lua'] = 'local M = {}\nfunction M:render() end\nreturn M\n',
      ['globals.lua'] = 'function on_load() end\n',
    })
  end,

  ['a declaration cannot resurrect a local'] = function()
    -- An interface says code outside the checkout reaches a name. Nothing
    -- outside can reach a local, a loop variable or a label, so a declaration
    -- that silenced them would just be a way to switch the tool off.
    local output = run({
      ['tach.lua'] = "return { interfaces = { { expose = { '.*' } } } }\n",
      ['mylib.lua'] = 'local unused = 1\nfor index = 1, 2 do end\n::spot::\n',
    })
    assert_list_equal(findings(output), { 'DC01 unused', 'DC08 index', 'DC12 spot' })
  end,

  -- ----------------------------------------------------------- source roots

  ['source_roots decide what a module is called'] = function()
    support.assert_clean({
      ['tach.lua'] = 'return {\n'
        .. "  source_roots = { 'lua' },\n"
        .. "  interfaces = { { expose = { 'setup' }, from = { 'mylib' } } },\n"
        .. '}\n',
      ['lua/mylib.lua'] = LIBRARY,
    })
  end,

  ['a directory module is named by its init.lua'] = function()
    support.assert_clean({
      ['tach.lua'] = 'return {\n'
        .. "  source_roots = { 'lua' },\n"
        .. "  interfaces = { { expose = { 'setup' }, from = { 'mylib' } } },\n"
        .. '}\n',
      ['lua/mylib/init.lua'] = LIBRARY,
    })
  end,

  ['without source_roots a path is a module name from the project root'] = function()
    support.assert_clean({
      ['tach.lua'] = "return { interfaces = { { expose = { 'setup' }, from = { 'lua.mylib' } } } }\n",
      ['lua/mylib.lua'] = LIBRARY,
    })
  end,

  ['a from pattern can span a namespace'] = function()
    -- A long bracket, because the escape has to survive into the generated
    -- file: a literal dot is `\.` to the regex, which is `\\.` in Lua source.
    support.assert_clean({
      ['tach.lua'] = [[
        return { interfaces = { { expose = { 'setup' }, from = { 'libs\\..*' } } } }
      ]],
      ['libs/one.lua'] = LIBRARY,
      ['libs/two.lua'] = LIBRARY,
    })
  end,

  -- --------------------------------------------------------------- modules

  ['an unchecked module reports nothing'] = function()
    support.assert_clean({
      ['tach.lua'] = "return { modules = { { path = 'vendored', unchecked = true } } }\n",
      ['vendored.lua'] = 'local dead = 1\n',
    })
  end,

  ['an unchecked module still contributes usages'] = function()
    -- The same deliberate difference as `ignore-file` against `--exclude`: the
    -- file is read, so what it uses keeps the rest of the codebase honest.
    support.assert_clean({
      ['tach.lua'] = "return { modules = { { path = 'main', unchecked = true } } }\n",
      ['mod.lua'] = 'local M = {}\nfunction M.helper() return 1 end\nreturn M\n',
      ['main.lua'] = 'local M = require("mod")\nprint(M.helper())\nlocal dead = 1\n',
    })
  end,

  ['a module glob covers a namespace'] = function()
    support.assert_clean({
      ['tach.lua'] = "return { modules = { { paths = { 'vendor.**' }, unchecked = true } } }\n",
      ['vendor/one.lua'] = 'local dead = 1\n',
      ['vendor/deep/two.lua'] = 'local dead = 1\n',
    })
  end,

  -- ----------------------------------------------------------------- rules

  ['unused_ignore_directives off disables DC13'] = function()
    support.assert_clean({
      ['tach.lua'] = "return { rules = { unused_ignore_directives = 'off' } }\n",
      ['a.lua'] = 'print(1)  -- deadcode: ignore\n',
    })
  end,

  ['warn leaves DC13 on, since there is no level below reported'] = function()
    local output = run({
      ['tach.lua'] = "return { rules = { unused_ignore_directives = 'warn' } }\n",
      ['a.lua'] = 'print(1)  -- deadcode: ignore\n',
    })
    assert_list_equal(findings(output), { 'DC13' })
  end,

  -- ------------------------------------------------------- reading the file

  ['the tach file is not itself reported'] = function()
    support.assert_clean({
      ['tach.lua'] = "return { modules = { { path = 'mylib' } } }\n",
      ['mylib.lua'] = 'local M = {}\nfunction M.setup() end\nreturn M\n',
      ['main.lua'] = 'local M = require("mylib")\nM.setup()\n',
    })
  end,

  ['--no-tach ignores the file entirely'] = function()
    local output = run({
      ['tach.lua'] = "return { interfaces = { { expose = { '.*' } } } }\n",
      ['mylib.lua'] = LIBRARY,
    }, { '.', '--no-tach' })
    assert_list_equal(findings(output), { 'DC05 setup' })
  end,

  ['--tach names a different file'] = function()
    support.assert_clean({
      ['config/tach.lua'] = "return { interfaces = { { expose = { 'setup' } } } }\n",
      ['mylib.lua'] = LIBRARY,
    }, { '.', '--tach', 'config/tach.lua' })
  end,

  ['a --tach path that does not exist is an error'] = function()
    local output, code = run({ ['a.lua'] = 'print(1)\n' }, { '.', '--tach', 'nope.lua' })
    support.assert_contains(output, 'Error: nope.lua could not be found')
    assert_equal(code, 2)
  end,

  ['no tach.lua is not an error'] = function()
    local output = run({ ['mylib.lua'] = LIBRARY })
    assert_list_equal(findings(output), { 'DC05 setup' })
  end,

  -- ------------------------------------------------------------ validation

  ['an unknown top-level setting is refused'] = function()
    local output, code = run({
      ['tach.lua'] = 'return { modules_ = {} }\n',
      ['a.lua'] = 'print(1)\n',
    })
    support.assert_contains(output, "unknown tach setting 'modules_'")
    assert_equal(code, 2)
  end,

  ['an unknown interfaces setting is refused'] = function()
    local output, code = run({
      ['tach.lua'] = "return { interfaces = { { expose = { 'a' }, exposes = { 'b' } } } }\n",
      ['a.lua'] = 'print(1)\n',
    })
    support.assert_contains(output, "interfaces[1]: unknown setting 'exposes'")
    assert_equal(code, 2)
  end,

  ['an interfaces entry needs an expose list'] = function()
    local output, code = run({
      ['tach.lua'] = "return { interfaces = { { from = { 'mylib' } } } }\n",
      ['a.lua'] = 'print(1)\n',
    })
    support.assert_contains(output, 'interfaces[1] needs an `expose` list')
    assert_equal(code, 2)
  end,

  ['a modules entry needs a path'] = function()
    local output, code = run({
      ['tach.lua'] = 'return { modules = { { unchecked = true } } }\n',
      ['a.lua'] = 'print(1)\n',
    })
    support.assert_contains(output, 'modules[1] needs a `path` or `paths`')
    assert_equal(code, 2)
  end,

  ['a regex Lua patterns cannot express is refused, not approximated'] = function()
    -- Silently dropping the alternation would leave a pattern that matches
    -- something other than what it says, which is worse than not loading.
    local output, code = run({
      ['tach.lua'] = "return { interfaces = { { expose = { 'get|set' } } } }\n",
      ['a.lua'] = 'print(1)\n',
    })
    support.assert_contains(output, 'alternation is not supported in a pattern')
    assert_equal(code, 2)
  end,

  ['every problem is reported, not just the first'] = function()
    local output = run({
      ['tach.lua'] = 'return { exact = 1, root_module = "nope" }\n',
      ['a.lua'] = 'print(1)\n',
    })
    support.assert_contains(output, 'exact must be true or false')
    support.assert_contains(output, "root_module must be 'ignore'")
  end,

  ['a tach file that is not a table is refused'] = function()
    local output, code = run({
      ['tach.lua'] = 'return 1\n',
      ['a.lua'] = 'print(1)\n',
    })
    support.assert_contains(output, 'tach.lua must return a table')
    assert_equal(code, 2)
  end,

  ['a tach file that will not parse is refused'] = function()
    local output, code = run({
      ['tach.lua'] = 'return {\n',
      ['a.lua'] = 'print(1)\n',
    })
    support.assert_contains(output, 'could not parse tach.lua')
    assert_equal(code, 2)
  end,

  ['keys that describe an import graph are accepted and ignored'] = function()
    -- A file shared with tach has to load here unchanged, so the whole schema
    -- is understood even though most of it asks a question this tool does not.
    support.assert_clean({
      ['tach.lua'] = 'return {\n'
        .. "  exclude = { 'build/' },\n"
        .. "  layers = { 'ui', { name = 'core', closed = true } },\n"
        .. '  exact = true,\n'
        .. '  forbid_circular_dependencies = true,\n'
        .. "  respect_gitignore = 'if_git_repo',\n"
        .. "  root_module = 'ignore',\n"
        .. "  cache = { file_dependencies = { 'src/*.rs' } },\n"
        .. "  external = { exclude = { 'busted' } },\n"
        .. '  modules = {\n'
        .. "    { path = 'mylib', depends_on = { 'other', { path = 'deep' } }, layer = 'core' },\n"
        .. '  },\n'
        .. "  interfaces = { { expose = { 'setup' }, visibility = { 'app' }, exclusive = true } },\n"
        .. '}\n',
      ['mylib.lua'] = LIBRARY,
    })
  end,

  -- --------------------------------------------- the suggestion in the report

  ['a report suggests declaring an interface'] = function()
    local output = run({ ['mylib.lua'] = LIBRARY })
    support.assert_contains(output, 'add a tach.lua beside your source')
    support.assert_contains(output, [[{ expose = { 'setup' }, from = { 'mylib' } },]])
  end,

  ['the suggestion pastes into a working tach.lua'] = function()
    -- The point of printing a config is that it can be used. This is the
    -- previous test's output, verbatim, doing its job.
    support.assert_clean({
      ['tach.lua'] = [[
        return {
          interfaces = {
            { expose = { 'setup' }, from = { 'mylib' } },
          },
        }
      ]],
      ['mylib.lua'] = LIBRARY,
    })
  end,

  ['a dot in a module name is escaped for the regex'] = function()
    -- `nested.mylib` unescaped would also match `nestedXmylib`. Doubled,
    -- because the pattern is being written into a Lua file.
    local output = run({ ['nested/mylib.lua'] = LIBRARY })
    support.assert_contains(output, [[from = { 'nested\\.mylib' }]])
  end,

  ['the escaped suggestion is one this tool accepts'] = function()
    support.assert_clean({
      ['tach.lua'] = [[
        return {
          interfaces = {
            { expose = { 'setup' }, from = { 'nested\\.mylib' } },
          },
        }
      ]],
      ['nested/mylib.lua'] = LIBRARY,
    })
  end,

  ['each module gets its own entry'] = function()
    local output = run({
      ['one.lua'] = LIBRARY,
      ['two.lua'] = 'local M = {}\nfunction M.render() end\nreturn M\n',
    })
    support.assert_contains(output, [[{ expose = { 'setup' }, from = { 'one' } },]])
    support.assert_contains(output, [[{ expose = { 'render' }, from = { 'two' } },]])
  end,

  ['an entry too wide for a terminal is split across lines'] = function()
    local output = run({
      ['a_rather_long_module_name.lua'] = 'local M = {}\n'
        .. 'function M.first_public_thing() end\n'
        .. 'function M.second_public_thing() end\n'
        .. 'return M\n',
    })
    support.assert_contains(
      output,
      "        expose = { 'first_public_thing', 'second_public_thing' },\n"
        .. "        from = { 'a_rather_long_module_name' },\n"
    )
  end,

  ['the split suggestion pastes in too'] = function()
    support.assert_clean({
      ['tach.lua'] = [[
        return {
          interfaces = {
            {
              expose = { 'first_public_thing', 'second_public_thing' },
              from = { 'a_rather_long_module_name' },
            },
          },
        }
      ]],
      ['a_rather_long_module_name.lua'] = 'local M = {}\n'
        .. 'function M.first_public_thing() end\n'
        .. 'function M.second_public_thing() end\n'
        .. 'return M\n',
    })
  end,

  ['a long suggestion is capped, and says how much it left out'] = function()
    local files = {}
    for index = 1, 6 do
      files[string.format('mod%d.lua', index)] = LIBRARY
    end
    local output = run(files)
    support.assert_contains(output, '-- ... and 3 more')
  end,

  ['nothing a declaration could cover means no suggestion'] = function()
    -- Advising a `tach.lua` for an unused local would be advice that cannot
    -- work: nothing outside the file can reach one.
    local output = run({ ['a.lua'] = 'local dead = 1\n' })
    assert_list_equal(findings(output), { 'DC01 dead' })
    assert_equal(tostring(output):find('tach.lua', 1, true), nil, 'no suggestion')
  end,

  ['a project that already has a tach.lua is not nagged'] = function()
    local output = run({
      ['tach.lua'] = 'return {}\n',
      ['mylib.lua'] = LIBRARY,
    })
    assert_list_equal(findings(output), { 'DC05 setup' })
    assert_equal(tostring(output):find('add a tach.lua', 1, true), nil, 'no suggestion')
  end,

  ['--no-tach suppresses the suggestion too'] = function()
    local output = run({ ['mylib.lua'] = LIBRARY }, { '.', '--no-tach' })
    assert_equal(tostring(output):find('add a tach.lua', 1, true), nil, 'no suggestion')
  end,

  ['--count and --quiet stay machine-readable'] = function()
    local counted = run({ ['mylib.lua'] = LIBRARY }, { '.', '--count' })
    assert_equal(counted, '1')

    local quiet, code = run({ ['mylib.lua'] = LIBRARY }, { '.', '--quiet' })
    assert_equal(quiet, nil)
    assert_equal(code, 1)
  end,
}
