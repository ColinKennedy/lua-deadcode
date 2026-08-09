-- Render findings as text.
--
-- Returns a string rather than printing it. Keeping output out of the analysis
-- path is what lets the whole tool be tested by calling `main()` and comparing
-- one string, with no capture of stdout anywhere.

local RED = '\27[91m'
local BOLD = '\27[1m'
local RESET = '\27[0m'

--- Render findings as text.
---@class deadcode.report
local report = {}

--- One report line: position, code, message.
---@param item deadcode.CodeItem
---@param use_color boolean
---@return string
function report.format_item(item, use_color)
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
    lines[index] = report.format_item(item, use_color)
  end
  return table.concat(lines, '\n')
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
