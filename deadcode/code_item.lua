-- A single dead-code finding.
--
-- Unlike the Python original, a CodeItem carries no source extent - only the
-- point where the offending name is written. Nothing in this tool rewrites
-- source, so an end position would be dead weight.

local constants = require('deadcode.constants')

--- A single dead-code finding, ready to be reported.
---@class deadcode.CodeItem
---@field name string the offending name, or '' where the finding has none
---@field type deadcode.FindingType
---@field code string the `DCxx` code derived from `type`
---@field file string path as the user typed it
---@field module string the dotted module name `file` denotes, which is how a
--- `tach.lua` refers to it
---@field line integer 1-based; 0 when the finding has no position
---@field col integer 1-based; 0 when the finding has no position
---@field message string|nil overrides the template for `type` when set
---@field exact boolean true when lexical scoping, not name matching, found it
local CodeItem = {}
CodeItem.__index = CodeItem

--- Everything `CodeItem.new` accepts. Only `name`, `type` and `file` are
--- required; a finding with no meaningful position leaves `line` and `col` out.
---@class deadcode.CodeItem.Opts
---@field name string
---@field type deadcode.FindingType
---@field file string
---@field module string|nil defaults to `file`, for a caller with no interest
--- in module names
---@field line integer|nil defaults to 0
---@field col integer|nil defaults to 0
---@field message string|nil

--- Create a finding.
---@param opts deadcode.CodeItem.Opts
---@return deadcode.CodeItem
function CodeItem.new(opts)
  local code = constants.TYPE_TO_CODE[opts.type]
  assert(code, 'unknown finding type: ' .. tostring(opts.type))

  return setmetatable({
    name = opts.name,
    type = opts.type,
    code = code,
    file = opts.file,
    module = opts.module or opts.file,
    line = opts.line or 0,
    col = opts.col or 0,
    message = opts.message,
    exact = constants.EXACT_TYPES[opts.type] or false,
  }, CodeItem)
end

--- The `file:line:col:` prefix a report line opens with.
--
-- Reached as `item:position()` on an instance, never as `CodeItem.position`,
-- which is invisible to a scanner that matches reads by receiver.
---@return string
function CodeItem:position()
  return string.format('%s:%d:%d:', self.file, self.line, self.col)
end

--- The human-readable sentence describing this finding.
-- Reached as `item:text()`; see the note on `position`.
---@return string
function CodeItem:text()
  if self.message then return self.message end
  local template = constants.MESSAGE_FOR_TYPE[self.type]
  if self.type == 'empty_file' then return template end
  return string.format(template, self.name)
end

--- Stable ordering for reports: by file, then line, then column, then code.
---@param a deadcode.CodeItem
---@param b deadcode.CodeItem
---@return boolean `true` when `a` sorts before `b`
function CodeItem.compare(a, b)
  if a.file ~= b.file then return a.file < b.file end
  if a.line ~= b.line then return a.line < b.line end
  if a.col ~= b.col then return a.col < b.col end
  return a.code < b.code
end

return CodeItem
