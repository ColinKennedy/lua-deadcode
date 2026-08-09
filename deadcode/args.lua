-- Command-line and configuration-file parsing.
--
-- Options come from two places, merged additively the way the Python original
-- merges CLI flags with `[tool.deadcode]`: list options from the config file
-- are appended to whatever the command line supplied, and boolean options from
-- the config apply only where the command line stayed silent, so an explicit
-- flag always wins.
--
-- Configuration lives in `.deadcoderc`, which is a Lua file returning a table.
-- A Lua tool reading a Lua config needs no extra parser, and matches what the
-- ecosystem already does with `.luacheckrc`.

local constants = require('deadcode.constants')

local Args = {}

Args.CONFIG_FILENAME = '.deadcoderc'

local LIST_OPTIONS = {
  exclude = true,
  only = true,
  ignore_names = true,
  ignore_names_in_files = true,
  ignore_codes = true,
}

local FLAG_OPTIONS = {
  check_params = true,
  no_color = true,
  quiet = true,
  count = true,
  verbose = true,
  version = true,
  help = true,
}

Args.USAGE = [[
Usage: deadcode <path>... [options]

Finds Lua code that is never used. Reports only; it never edits your files.

Options:
  --exclude <glob>...                Skip these paths entirely.
  --only <glob>...                   Report findings only in these paths.
  --ignore-names <glob>...           Drop findings whose name matches.
  --ignore-names-in-files <glob>...  Drop all findings in matching paths.
  --ignore-codes <code>...           Disable rules, e.g. DC06,DC08.
  --check-params                     Also report unused function parameters.
  --count                            Print the number of findings only.
  --quiet                            Print nothing; exit status still reflects findings.
  --no-color                         Disable ANSI colour.
  --config <path>                    Use this config file instead of .deadcoderc.
  --no-config                        Ignore .deadcoderc entirely.
  -v, --verbose                      Explain what is being skipped and why.
  --version                          Print the version.
  -h, --help                         Print this message.

Inline suppression:
  local x = 1  -- deadcode: ignore DC01
  -- deadcode: ignore-file

Rules:
]]

do
  local lines = {}
  for _, entry in ipairs(constants.CODES) do
    lines[#lines + 1] = string.format('  %s  %s', entry.code, entry.name)
  end
  Args.USAGE = Args.USAGE .. table.concat(lines, '\n') .. '\n'
end

local function new_defaults()
  return {
    paths = {},
    exclude = {},
    only = {},
    ignore_names = {},
    ignore_names_in_files = {},
    ignore_codes = {},
    check_params = false,
    no_color = false,
    quiet = false,
    count = false,
    verbose = false,
    version = false,
    help = false,
    config = nil,
    no_config = false,
  }
end

--- `--ignore-names a,b` and `--ignore-names a b` mean the same thing.
local function append_values(target, value)
  for piece in tostring(value):gmatch('[^,]+') do
    piece = piece:match('^%s*(.-)%s*$')
    if piece ~= '' then target[#target + 1] = piece end
  end
end

local function normalise_key(key)
  return (tostring(key):gsub('^%-%-', ''):gsub('%-', '_'))
end

--- Parse an argv-style array.
-- Returns `args, err`; `err` is a human-readable message on bad input.
function Args.parse(argv)
  local args = new_defaults()
  local explicit = {}
  argv = argv or {}

  local index = 1
  while index <= #argv do
    local token = argv[index]

    if token == '-h' then
      args.help = true
      explicit.help = true
      index = index + 1
    elseif token == '-v' then
      args.verbose = true
      explicit.verbose = true
      index = index + 1
    elseif token == '--' then
      -- Everything after `--` is a path, even if it looks like a flag.
      for rest = index + 1, #argv do
        args.paths[#args.paths + 1] = argv[rest]
      end
      break
    elseif token:sub(1, 2) == '--' then
      local name, inline = token:match('^%-%-([^=]+)=(.*)$')
      if not name then name = token:sub(3) end
      local key = normalise_key(name)

      if FLAG_OPTIONS[key] then
        if inline then return nil, string.format('option --%s does not take a value', name) end
        args[key] = true
        explicit[key] = true
        index = index + 1
      elseif key == 'no_config' then
        args.no_config = true
        explicit.no_config = true
        index = index + 1
      elseif key == 'config' then
        if inline then
          args.config = inline
          index = index + 1
        else
          local value = argv[index + 1]
          if not value or value:sub(1, 2) == '--' then
            return nil, 'option --config requires a value'
          end
          args.config = value
          index = index + 2
        end
        explicit.config = true
      elseif LIST_OPTIONS[key] then
        explicit[key] = true
        if inline then
          append_values(args[key], inline)
          index = index + 1
        else
          local consumed = 0
          index = index + 1
          while index <= #argv and argv[index]:sub(1, 2) ~= '--' do
            append_values(args[key], argv[index])
            consumed = consumed + 1
            index = index + 1
          end
          if consumed == 0 then
            return nil, string.format('option --%s requires at least one value', name)
          end
        end
      else
        return nil, string.format("unknown option '--%s'", name)
      end
    else
      args.paths[#args.paths + 1] = token
      index = index + 1
    end
  end

  args._explicit = explicit
  return args
end

--- Load `.deadcoderc` (a Lua chunk returning a table).
-- Returns `config, err`. A missing file is not an error: `nil, nil`.
function Args.load_config(path)
  local handle = io.open(path, 'r')
  if not handle then return nil, nil end
  local source = handle:read('*a')
  handle:close()

  local chunk, err = loadstring(source, '@' .. path)
  if not chunk then return nil, string.format('could not parse %s: %s', path, err) end

  -- The config is user code; a bad one must not take the whole run down.
  local ok, result = pcall(chunk)
  if not ok then return nil, string.format('could not evaluate %s: %s', path, tostring(result)) end
  if type(result) ~= 'table' then return nil, string.format('%s must return a table', path) end
  return result
end

--- Fold config-file values into parsed CLI args.
function Args.merge_config(args, config)
  if not config then return args end

  for raw_key, value in pairs(config) do
    local key = normalise_key(raw_key)

    if LIST_OPTIONS[key] then
      if type(value) ~= 'table' then
        return nil, string.format('config option %s must be a list', raw_key)
      end
      for _, entry in ipairs(value) do
        args[key][#args[key] + 1] = entry
      end
    elseif FLAG_OPTIONS[key] then
      -- An explicit flag on the command line beats the config file.
      if not args._explicit[key] then args[key] = value and true or false end
    elseif key == 'paths' then
      if type(value) == 'table' and #args.paths == 0 then
        for _, entry in ipairs(value) do
          args.paths[#args.paths + 1] = entry
        end
      end
    else
      return nil, string.format("unknown config option '%s'", raw_key)
    end
  end

  return args
end

--- Full resolution: parse argv, then merge the config file unless suppressed.
function Args.resolve(argv)
  local args, err = Args.parse(argv)
  if not args then return nil, err end
  if args.help or args.version then return args end

  if not args.no_config then
    local path = args.config or Args.CONFIG_FILENAME
    local config, config_err = Args.load_config(path)
    if config_err then return nil, config_err end
    if not config and args.config then
      return nil, string.format('config file %s could not be found', args.config)
    end
    local merged, merge_err = Args.merge_config(args, config)
    if not merged then return nil, merge_err end
    args = merged
  end

  -- Normalise codes so `dc06` and `DC06` both work.
  for i, code in ipairs(args.ignore_codes) do
    args.ignore_codes[i] = code:upper()
  end

  return args
end

return Args
