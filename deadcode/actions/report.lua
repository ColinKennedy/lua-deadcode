-- Render findings as text.
--
-- Returns a string rather than printing it. Keeping output out of the analysis
-- path is what lets the whole tool be tested by calling `main()` and comparing
-- one string, with no capture of stdout anywhere.

local tach = require('deadcode.tach')

local RED = '\27[91m'
local BOLD = '\27[1m'
local RESET = '\27[0m'

--- How much of a suggested `tach.lua` to write out.
--
-- Enough to be worth pasting, not so much that the advice buries the findings
-- it is about. Whatever is left over is counted rather than dropped silently -
-- a truncated suggestion that looks complete would be worse than none.
local HINT_MODULES = 3
local HINT_NAMES = 5

--- Where a suggested entry stops fitting on one line and gets split.
local HINT_WIDTH = 78

--- Render findings as text.
---@class deadcode.report
local report = {}

--- One report line: position, code, message.
---@param item deadcode.CodeItem
---@param use_color boolean
---@return string
local function format_item(item, use_color)
  local code = item.code
  local text = item:text()

  if use_color then
    code = RED .. code .. RESET
    -- Names are already delimited by backticks in the message templates.
    text = text:gsub('`([^`]*)`', '`' .. BOLD .. '%1' .. RESET .. '`')
  end

  return string.format('%s %s %s', item:position(), code, text)
end

--- Build the report body. Returns nil when there is nothing to say.
---@param items deadcode.CodeItem[]
---@param args deadcode.Args
---@return string|nil
function report.build(items, args)
  if args.quiet then return nil end
  if args.count then return tostring(#items) end
  if #items == 0 then return nil end

  local use_color = not args.no_color
  local lines = {}
  for index, item in ipairs(items) do
    lines[index] = format_item(item, use_color)
  end
  return table.concat(lines, '\n')
end

--- Quote a name so a tach regex matches it and nothing else.
--
-- Escaped twice over, and both are real: `\.` is what makes the pattern mean a
-- literal dot, and `\\.` is what makes the Lua file the pattern lives in
-- contain a `\`. A suggestion that pasted as `mylib.cli` would quietly also
-- match `mylibXcli`, and one that pasted as `mylib\.cli` would not load at all
-- from Lua 5.2 on.
---@param text string
---@return string
local function regex_literal(text)
  return (tostring(text):gsub('[%^%$%(%)%%%.%[%]%*%+%-%?{}|\\]', '\\\\%0'))
end

--- Group the findings a declaration could cover, by the module they are in.
---@param items deadcode.CodeItem[]
---@return string[] modules in report order
---@return table<string, string[]> names each module's names, deduplicated
local function exposable(items)
  local modules = {}
  local names = {}
  local seen = {}

  for _, item in ipairs(items) do
    if tach.can_expose(item) and item.name ~= '' then
      local list = names[item.module]
      if not list then
        list = {}
        names[item.module] = list
        modules[#modules + 1] = item.module
      end
      local key = item.module .. '\0' .. item.name
      if not seen[key] then
        seen[key] = true
        list[#list + 1] = item.name
      end
    end
  end

  return modules, names
end

--- One `interfaces` entry, as a user would write it.
--
-- On one line where that fits a terminal, and split where it does not. Advice
-- is only worth printing if it is worth reading.
---@param module string
---@param names string[]
---@param lines string[] appended to in place
---@return integer dropped names left off the end
local function interface_entry(module, names, lines)
  local quoted = {}
  local shown = math.min(#names, HINT_NAMES)
  for index = 1, shown do
    quoted[index] = string.format("'%s'", regex_literal(names[index]))
  end

  local expose = string.format('expose = { %s }', table.concat(quoted, ', '))
  local from = string.format("from = { '%s' }", regex_literal(module))
  local single = string.format('      { %s, %s },', expose, from)

  if #single <= HINT_WIDTH then
    lines[#lines + 1] = single
  else
    lines[#lines + 1] = '      {'
    lines[#lines + 1] = '        ' .. expose .. ','
    lines[#lines + 1] = '        ' .. from .. ','
    lines[#lines + 1] = '      },'
  end

  return #names - shown
end

--- The nudge towards declaring an interface, shown when there is one to make.
--
-- A finding is this tool saying "nothing here reaches this name", which for a
-- library is not the same as "delete it": its callers are outside the checkout
-- and no scan can see them. Rather than leave people to discover `tach.lua` in
-- the README, the report says so at the moment the question comes up, with the
-- names it just reported already filled in.
--
-- Only when the project has no `tach.lua` yet. Once it has one, the syntax has
-- been learned and repeating it every run would be nagging.
---@param items deadcode.CodeItem[]
---@param args deadcode.Args
---@return string|nil nil when there is nothing a declaration could cover
function report.interface_hint(items, args)
  if args.quiet or args.count or args.no_tach then return nil end

  local modules, names = exposable(items)
  if #modules == 0 then return nil end

  local entries = {}
  local dropped = 0
  for index = 1, math.min(#modules, HINT_MODULES) do
    local module = modules[index]
    dropped = dropped + interface_entry(module, names[module], entries)
  end
  for index = HINT_MODULES + 1, #modules do
    dropped = dropped + #names[modules[index]]
  end
  if dropped > 0 then entries[#entries + 1] = string.format('      -- ... and %d more', dropped) end

  return table.concat({
    '',
    'Some of these may be public API this scan cannot see a caller for. To declare',
    'them public rather than delete them, add a tach.lua beside your source:',
    '',
    '  -- tach.lua',
    '  return {',
    '    interfaces = {',
    table.concat(entries, '\n'),
    '    },',
    '  }',
    '',
    '`expose` names the symbols and `from` names the modules that publish them.',
    'Both are regular expressions matching the whole name, and leaving `from` out',
    'means every module. Anything a declaration covers is never reported again.',
  }, '\n')
end

--- The message shown when a run finds nothing.
---@param args deadcode.Args
---@return string|nil nil when the run was asked to stay silent
function report.all_clear(args)
  if args.quiet or args.count then return nil end
  if args.no_color then return 'Well done! No dead code found.' end
  return BOLD .. 'Well done!' .. RESET .. ' No dead code found.'
end

return report
