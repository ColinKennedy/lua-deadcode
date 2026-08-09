-- Argument parsing and `.deadcoderc` merging, tested directly rather than
-- through the CLI so the merge rules are pinned in isolation.

local support = require('tests.support')
local Args = require('deadcode.args')
local assert_list_equal, assert_equal = support.assert_list_equal, support.assert_equal
local assert_true, assert_contains = support.assert_true, support.assert_contains

--- Write `contents` to a temporary `.deadcoderc`, run `body` against its path,
--- and remove the file however `body` ends.
---@param contents string
---@param body fun(path: string)
local function with_temp_config(contents, body)
  local path = os.tmpname()
  local handle = assert(io.open(path, 'w'))
  handle:write(contents)
  handle:close()

  local ok, err = pcall(body, path)
  os.remove(path)
  if not ok then error(err, 0) end
end

return {

  ['paths are collected positionally'] = function()
    local args = assert(Args.parse({ 'src', 'spec' }))
    assert_list_equal(args.paths, { 'src', 'spec' })
  end,

  ['a list option splits on commas'] = function()
    local args = assert(Args.parse({ 'src', '--ignore-names', 'a,b,c' }))
    assert_list_equal(args.ignore_names, { 'a', 'b', 'c' })
  end,

  ['a list option accepts several values'] = function()
    local args = assert(Args.parse({ 'src', '--ignore-names', 'a', 'b' }))
    assert_list_equal(args.ignore_names, { 'a', 'b' })
  end,

  ['a list option accepts the equals form'] = function()
    local args = assert(Args.parse({ 'src', '--ignore-names=a,b' }))
    assert_list_equal(args.ignore_names, { 'a', 'b' })
  end,

  ['a list option greedily consumes following words'] = function()
    -- Documents a real wart inherited from the original's `nargs="*"`: a path
    -- placed after a list option is swallowed as a value. Put paths first, or
    -- separate them with `--`.
    local args = assert(Args.parse({ '--ignore-names', 'a', 'src' }))
    assert_list_equal(args.ignore_names, { 'a', 'src' })
    assert_list_equal(args.paths, {})
  end,

  ['a double dash ends option parsing'] = function()
    local args = assert(Args.parse({ '--ignore-names', 'a', '--', 'src' }))
    assert_list_equal(args.ignore_names, { 'a' })
    assert_list_equal(args.paths, { 'src' })
  end,

  ['a flag with a value is rejected'] = function()
    local args, err = Args.parse({ 'src', '--quiet=yes' })
    assert_equal(args, nil)
    assert_contains(err, 'does not take a value')
  end,

  ['a list option with no value is rejected'] = function()
    local args, err = Args.parse({ 'src', '--ignore-names' })
    assert_equal(args, nil)
    assert_contains(err, 'requires at least one value')
  end,

  ['an unknown option is rejected'] = function()
    local args, err = Args.parse({ 'src', '--nope' })
    assert_equal(args, nil)
    assert_contains(err, "unknown option '--nope'")
  end,

  ['config lists extend command-line lists'] = function()
    local args = assert(Args.parse({ 'src', '--ignore-names', 'fromcli' }))
    args = assert(Args.merge_config(args, { ignore_names = { 'fromconfig' } }))
    assert_list_equal(args.ignore_names, { 'fromcli', 'fromconfig' })
  end,

  ['config booleans apply when the flag was not given'] = function()
    local args = assert(Args.parse({ 'src' }))
    args = assert(Args.merge_config(args, { check_params = true }))
    assert_true(args.check_params)
  end,

  ['an explicit flag beats the config file'] = function()
    local args = assert(Args.parse({ 'src', '--check-params' }))
    args = assert(Args.merge_config(args, { check_params = false }))
    assert_true(args.check_params, 'the command line is the more specific intent')
  end,

  ['config keys may use dashes'] = function()
    local args = assert(Args.parse({ 'src' }))
    args = assert(Args.merge_config(args, { ['ignore-names'] = { 'x' } }))
    assert_list_equal(args.ignore_names, { 'x' })
  end,

  ['an unknown config key is rejected'] = function()
    local args = assert(Args.parse({ 'src' }))
    local merged, err = Args.merge_config(args, { nonsense = true })
    assert_equal(merged, nil)
    assert_contains(err, "unknown config option 'nonsense'")
  end,

  ['a config list given as a scalar is rejected'] = function()
    local args = assert(Args.parse({ 'src' }))
    local merged, err = Args.merge_config(args, { ignore_names = 'oops' })
    assert_equal(merged, nil)
    assert_contains(err, 'must be a list')
  end,

  ['a config file is loaded from disk'] = function()
    with_temp_config('return { ignore_names = { "generated_*" } }', function(path)
      local config = assert(Args.load_config(path))
      assert_list_equal(config.ignore_names, { 'generated_*' })
    end)
  end,

  ['a config file that is not a table is rejected'] = function()
    with_temp_config('return 42', function(path)
      local config, err = Args.load_config(path)
      assert_equal(config, nil)
      assert_contains(err, 'must return a table')
    end)
  end,

  ['a config file with a syntax error is reported, not raised'] = function()
    with_temp_config('return {', function(path)
      local config, err = Args.load_config(path)
      assert_equal(config, nil)
      assert_contains(err, 'could not parse')
    end)
  end,

  ['a config file that throws is reported, not raised'] = function()
    with_temp_config('error("boom")', function(path)
      local config, err = Args.load_config(path)
      assert_equal(config, nil)
      assert_contains(err, 'could not evaluate')
    end)
  end,

  ['a missing config file is not an error unless asked for by name'] = function()
    local config, err = Args.load_config('definitely/not/here/.deadcoderc')
    assert_equal(config, nil)
    assert_equal(err, nil)

    local args, resolve_err = Args.resolve({ 'src', '--config', 'definitely/not/here' })
    assert_equal(args, nil)
    assert_contains(resolve_err, 'could not be found')
  end,

  ['resolve normalises rule codes to upper case'] = function()
    local args = assert(Args.resolve({ 'src', '--no-config', '--ignore-codes', 'dc01,Dc02' }))
    assert_list_equal(args.ignore_codes, { 'DC01', 'DC02' })
  end,
}
