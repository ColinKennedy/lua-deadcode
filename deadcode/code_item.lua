-- A single dead-code finding.
--
-- Unlike the Python original, a CodeItem carries no source extent - only the
-- point where the offending name is written. Nothing in this tool rewrites
-- source, so an end position would be dead weight.

local constants = require('deadcode.constants')

local CodeItem = {}
CodeItem.__index = CodeItem

--- Create a finding.
-- @param opts table with: name, type, file, line, col, and optional message
function CodeItem.new(opts)
  local code = constants.TYPE_TO_CODE[opts.type]
  assert(code, 'unknown finding type: ' .. tostring(opts.type))

  return setmetatable({
    name = opts.name,
    type = opts.type,
    code = code,
    file = opts.file,
    line = opts.line or 0,
    col = opts.col or 0,
    message = opts.message,
    exact = constants.EXACT_TYPES[opts.type] or false,
  }, CodeItem)
end

function CodeItem:position()
  return string.format('%s:%d:%d:', self.file, self.line, self.col)
end

function CodeItem:text()
  if self.message then return self.message end
  local template = constants.MESSAGE_FOR_TYPE[self.type]
  if self.type == 'empty_file' then return template end
  return string.format(template, self.name)
end

--- Stable ordering for reports: by file, then line, then column, then code.
function CodeItem.compare(a, b)
  if a.file ~= b.file then return a.file < b.file end
  if a.line ~= b.line then return a.line < b.line end
  if a.col ~= b.col then return a.col < b.col end
  return a.code < b.code
end

return CodeItem
