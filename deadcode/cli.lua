-- Entry point.
--
-- `main` returns `output, exit_code` instead of printing. Everything the tool
-- does is therefore observable from one function call, which is what makes the
-- test suite as simple as it is - no stdout capture, no temp directories.

local Args = require('deadcode.args')
local constants = require('deadcode.constants')
local default_fs = require('deadcode.fs')
local find_lua_files = require('deadcode.actions.find_lua_files')
local find_unused_names = require('deadcode.actions.find_unused_names')
local report = require('deadcode.actions.report')

--- Entry point.
---@class deadcode.cli
---@field EXIT_OK integer
---@field EXIT_FINDINGS integer
---@field EXIT_ERROR integer
local cli = {}

cli.EXIT_OK = 0
cli.EXIT_FINDINGS = 1
cli.EXIT_ERROR = 2

--- Diagnostics carry their severity in their text, so that the collectors can
--- append to one list without also threading a severity through.
---@param diagnostic string
---@return boolean
local function is_error(diagnostic)
  return diagnostic:sub(1, 6) == 'Error:'
end

--- What `cli.main` accepts in place of the real implementations. Only the
--- filesystem is swappable, which is all the test suite needs.
---@class deadcode.cli.Deps
---@field fs deadcode.FS|nil

--- Run an analysis.
---@param argv string[]|nil array of command-line arguments
---@param deps deadcode.cli.Deps|nil substitutes for tests
---@return string|nil output nil when there is nothing to print
---@return integer exit_code one of the `EXIT_` constants
function cli.main(argv, deps)
  deps = deps or {}
  local fs = deps.fs or default_fs

  local args, err = Args.resolve(argv)
  if not args then return 'Error: ' .. err, cli.EXIT_ERROR end
  if args.help then return Args.USAGE, cli.EXIT_OK end
  if args.version then return constants.VERSION, cli.EXIT_OK end
  if #args.paths == 0 then return 'Error: no paths given\n\n' .. Args.USAGE, cli.EXIT_ERROR end

  local files, discovery_diagnostics = find_lua_files(args, fs)
  local items, analysis_diagnostics = find_unused_names(files, args, fs)

  local diagnostics = {}
  local had_error = false
  for _, list in ipairs({ discovery_diagnostics, analysis_diagnostics }) do
    for _, diagnostic in ipairs(list) do
      if is_error(diagnostic) then had_error = true end
      diagnostics[#diagnostics + 1] = diagnostic
    end
  end

  local chunks = {}
  if not args.quiet and not args.count then
    for _, diagnostic in ipairs(diagnostics) do
      chunks[#chunks + 1] = diagnostic
    end
  end

  local body = report.build(items, args)
  if body then chunks[#chunks + 1] = body end

  if #items == 0 and not had_error then
    local clear = report.all_clear(args)
    if clear then chunks[#chunks + 1] = clear end
  end

  local exit_code = cli.EXIT_OK
  if #items > 0 then
    exit_code = cli.EXIT_FINDINGS
  elseif had_error then
    exit_code = cli.EXIT_ERROR
  end

  local output = #chunks > 0 and table.concat(chunks, '\n') or nil
  return output, exit_code
end

--- Print the result of `main` and return the exit code.
---@param argv string[]|nil
---@return integer exit_code
function cli.run(argv)
  local output, exit_code = cli.main(argv)
  if output and output ~= '' then io.stdout:write(output, '\n') end
  return exit_code
end

return cli
