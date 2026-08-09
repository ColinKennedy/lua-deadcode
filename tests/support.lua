-- Test harness.
--
-- Tests declare a whole virtual project as a table of path -> source, call
-- `main`, and assert on what comes back. Nothing touches the disk and nothing
-- captures stdout, which keeps every test a single readable expression.

local real_fs = require('deadcode.fs')
local cli = require('deadcode.cli')

--- The table thrown by `fail`, so that the runner can tell a failed
--- assertion apart from an error the code under test did not expect.
---@class deadcode.test.Failure
---@field deadcode_test_failure true
---@field message string

--- A virtual project: path -> source. Every test declares one of these.
---@alias deadcode.test.Files table<string, string>

--- Test harness.
---@class deadcode.test.support
local support = {}

--- Build a filesystem table backed by an in-memory `{ path = source }` map.
---@param files deadcode.test.Files
---@return deadcode.FS
function support.virtual_fs(files)
  local normalised = {}
  for path, source in pairs(files) do
    normalised[real_fs.normalise(path)] = source
  end

  return {
    normalise = real_fs.normalise,

    read_file = function(path)
      local source = normalised[real_fs.normalise(path)]
      if not source then return nil, string.format('could not open %s', path) end
      return source
    end,

    exists = function(path)
      path = real_fs.normalise(path)
      if path == '.' or normalised[path] then return true end
      for name in pairs(normalised) do
        if name:sub(1, #path + 1) == path .. '/' then return true end
      end
      return false
    end,

    list_lua_files = function(path)
      path = real_fs.normalise(path)
      local found = {}
      for name in pairs(normalised) do
        local under = (path == '.') or (name == path) or (name:sub(1, #path + 1) == path .. '/')
        if under and name:sub(-4) == '.lua' then found[#found + 1] = name end
      end
      if #found == 0 and path ~= '.' then
        return nil, string.format('%s could not be found', path)
      end
      table.sort(found)
      return found
    end,
  }
end

---@param argv string[]
---@param flag string
---@return boolean
local function has_flag(argv, flag)
  for _, value in ipairs(argv) do
    if value == flag then return true end
  end
  return false
end

--- Run the tool over a virtual project.
-- `--no-color` and `--no-config` are forced on so results are stable and the
-- developer's own `.deadcoderc` can never leak into a test.
---@param files deadcode.test.Files
---@param argv string[]|nil defaults to `{ '.' }`
---@return string|nil output
---@return integer exit_code
function support.run(files, argv)
  argv = argv or { '.' }

  -- Prepended, not appended: a test may end its argv with `--`, after which
  -- everything is a path and an appended flag would be read as one.
  local effective = {}
  if not has_flag(argv, '--no-color') then effective[#effective + 1] = '--no-color' end
  if not has_flag(argv, '--no-config') then effective[#effective + 1] = '--no-config' end
  for _, value in ipairs(argv) do
    effective[#effective + 1] = value
  end

  return cli.main(effective, { fs = support.virtual_fs(files) })
end

--- Reduce report output to `CODE name` pairs, which is what most tests care
-- about. Position formatting is asserted separately, in one place.
---@param output string|nil
---@return string[]
function support.findings(output)
  local found = {}
  for line in tostring(output or ''):gmatch('[^\n]+') do
    local code = line:match('(DC%d%d)')
    if code then
      local name = line:match('`([^`]*)`')
      found[#found + 1] = name and (code .. ' ' .. name) or code
    end
  end
  return found
end

--- Split output into lines, treating nil as empty.
---@param output string|nil
---@return string[]
function support.lines(output)
  local result = {}
  for line in tostring(output or ''):gmatch('[^\n]+') do
    result[#result + 1] = line
  end
  return result
end

-- ------------------------------------------------------------- assertions

--- Format a value for a failure message. Lists are rendered one entry per
--- line, because that is the shape most assertions here compare.
---@param value any
---@return string
local function render(value)
  if type(value) ~= 'table' then return string.format('%q', tostring(value)) end
  local parts = {}
  for index, entry in ipairs(value) do
    parts[index] = tostring(entry)
  end
  return '{\n    ' .. table.concat(parts, ',\n    ') .. '\n  }'
end

--- Abandon the current test. Never returns.
---@param message string
local function fail(message)
  error({ deadcode_test_failure = true, message = message }, 0)
end

---@param actual any
---@param expected any
---@param context string|nil prefixed to the failure message
function support.assert_equal(actual, expected, context)
  if actual ~= expected then
    fail(
      string.format(
        '%sexpected %s\n  got      %s',
        context and (context .. ': ') or '',
        render(expected),
        render(actual)
      )
    )
  end
end

---@param actual any[]
---@param expected any[]
---@param context string|nil prefixed to the failure message
function support.assert_list_equal(actual, expected, context)
  local same = #actual == #expected
  if same then
    for index = 1, #expected do
      if actual[index] ~= expected[index] then
        same = false
        break
      end
    end
  end
  if not same then
    fail(
      string.format(
        '%sexpected %s\n  got      %s',
        context and (context .. ': ') or '',
        render(expected),
        render(actual)
      )
    )
  end
end

---@param haystack string|nil
---@param needle string matched literally, not as a pattern
---@param context string|nil prefixed to the failure message
function support.assert_contains(haystack, needle, context)
  if not tostring(haystack or ''):find(needle, 1, true) then
    fail(
      string.format(
        '%sexpected output to contain %q\n  got      %s',
        context and (context .. ': ') or '',
        needle,
        render(haystack)
      )
    )
  end
end

---@param value any
---@param context string|nil prefixed to the failure message
function support.assert_true(value, context)
  if not value then fail((context or 'assertion') .. ': expected a truthy value') end
end

--- Assert the tool finds nothing in the given project.
---@param files deadcode.test.Files
---@param argv string[]|nil
function support.assert_clean(files, argv)
  local output, code = support.run(files, argv)
  support.assert_list_equal(support.findings(output), {}, 'expected no findings')
  support.assert_equal(code, 0, 'exit code')
end

return support
