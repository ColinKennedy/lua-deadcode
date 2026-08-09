#!/usr/bin/env lua
-- Minimal test runner.
--
-- Deliberately dependency-free: `make test` must work on a bare Lua install,
-- with no LuaRocks step between a fresh clone and a green suite. Each test
-- file returns a table of `description -> function`.

local script = arg and arg[0] or 'tests/run.lua'
local script_dir = script:match('^(.*)[/\\][^/\\]+$') or '.'
local root = script_dir .. '/..'
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path

local function discover()
  local names = {}
  local pipe = io.popen(
    string.format("find '%s/tests' -maxdepth 1 -type f -name 'test_*.lua' -print 2>/dev/null", root)
  )
  if pipe then
    for line in pipe:lines() do
      local base = line:match('([^/\\]+)%.lua$')
      if base then names[#names + 1] = base end
    end
    pipe:close()
  end
  table.sort(names)
  return names
end

local only = arg and arg[1]
local modules = discover()

local passed, failed, errored = 0, 0, 0
local failures = {}

for _, module_name in ipairs(modules) do
  if not only or module_name:find(only, 1, true) then
    local ok, tests = pcall(require, 'tests.' .. module_name)

    if not ok then
      errored = errored + 1
      failures[#failures + 1] =
        string.format('%s: could not load: %s', module_name, tostring(tests))
    else
      -- Sort so a run is reproducible regardless of hash order.
      local names = {}
      for name in pairs(tests) do
        names[#names + 1] = name
      end
      table.sort(names)

      for _, name in ipairs(names) do
        local success, err = pcall(tests[name])
        if success then
          passed = passed + 1
          io.write('.')
        else
          local message
          if type(err) == 'table' and err.deadcode_test_failure then
            failed = failed + 1
            message = err.message
            io.write('F')
          else
            errored = errored + 1
            message = tostring(err)
            io.write('E')
          end
          failures[#failures + 1] = string.format('%s / %s\n  %s', module_name, name, message)
        end
      end
    end
  end
end

io.write('\n\n')

for _, failure in ipairs(failures) do
  io.write(failure, '\n\n')
end

io.write(string.format('%d passed, %d failed, %d errored\n', passed, failed, errored))

if failed + errored > 0 then os.exit(1) end
os.exit(0)
