-- Inline suppression directives.
--
-- Following the Python original's lead, this reuses spellings people already
-- type rather than inventing a new one. Three forms are recognised, all
-- equivalent:
--
--   local x = 1  -- deadcode: ignore DC01
--   local x = 1  -- luacheck: ignore
--   local x = 1  -- noqa: DC01
--
-- With no codes listed, every finding on the line is suppressed. A directive
-- in a trailing comment governs its own line; one on a line of its own governs
-- the next line of code, which is how people actually write them.
--
--   -- deadcode: ignore-file
--
-- anywhere in a file skips that file entirely.
--
-- Note: luacheck's whole-file and push/pop directives are NOT interpreted;
-- `-- luacheck: ignore` is always treated as line-scoped here. That can leave
-- a finding unsuppressed, never the reverse. Use `ignore-file` for a whole file.

--- Every inline directive found in one file, indexed by the line it governs.
---@class deadcode.Directives
---@field all table<integer, boolean> lines where every code is suppressed
---@field by_code table<string, table<integer, boolean>> code -> suppressed lines
---@field ignore_file boolean true when the whole file is muted

--- Inline suppression directives.
---@class deadcode.noqa
local noqa = {}

---@param set table<integer, boolean>
---@param line integer
local function add(set, line)
  set[line] = true
end

--- Build a directive index from the comment list the lexer produced.
---@param comments deadcode.Comment[]|nil
---@return deadcode.Directives empty but usable when `comments` is nil
function noqa.parse(comments)
  local directives = { all = {}, by_code = {}, ignore_file = false }
  if not comments then return directives end

  for _, comment in ipairs(comments) do
    local text = comment.text or ''
    local target = comment.applies_to or comment.line

    -- A directive must open the comment. Searching anywhere in the text turns
    -- prose like "broken-noqa-ish" into an accidental suppression.
    if text:find('^%s*[Dd]eadcode%s*:%s*ignore%-file%f[%A]') then
      directives.ignore_file = true
    else
      local rest = text:match('^%s*[Dd]eadcode%s*:%s*ignore%f[%A](.*)$')
        or text:match('^%s*[Nn]oqa%f[%A](.*)$')

      if not rest and text:find('^%s*[Ll]uacheck%s*:%s*ignore%f[%A]') then rest = '' end

      if rest then
        local listed = false
        for code in rest:gmatch('DC%d%d') do
          local set = directives.by_code[code]
          if not set then
            set = {}
            directives.by_code[code] = set
          end
          add(set, target)
          listed = true
        end
        if not listed then add(directives.all, target) end
      end
    end
  end

  return directives
end

--- Is a finding with `code` on `line` suppressed by a directive?
---@param directives deadcode.Directives|nil nil for a file that was never parsed
---@param line integer
---@param code string a `DCxx` code
---@return boolean
function noqa.is_ignored(directives, line, code)
  if not directives then return false end
  if directives.all[line] then return true end
  local set = directives.by_code[code]
  return set ~= nil and set[line] == true
end

return noqa
