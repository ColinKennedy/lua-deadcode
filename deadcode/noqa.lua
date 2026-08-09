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
--
-- Directives are also tracked in the other direction: one that never suppresses
-- anything is itself reported, as DC13. A suppression comment outlives the code
-- it was written for, and nothing else in a codebase ever prompts you to delete
-- it. See `noqa.unused`.

local constants = require('deadcode.constants')

--- One parsed directive, and the record of what it went on to suppress.
---@class deadcode.Directive
---@field line integer the line the comment is written on - the line to delete
---@field col integer where that comment starts
---@field target integer the line of code the directive governs
---@field codes string[]|nil the `DCxx` codes listed; nil when none were, which
--- means every code
---@field owned boolean true only for the `deadcode:` spelling
---@field used table<string, boolean> the codes this directive actually
--- suppressed, which is a subset of `codes` when any were listed
---@field used_any boolean true once the directive has suppressed anything

--- Every inline directive found in one file.
---@class deadcode.Directives
---@field list deadcode.Directive[] all of them, in source order
---@field by_target table<integer, deadcode.Directive[]> line of code -> the
--- directives governing it, so suppression is a lookup rather than a scan
---@field ignore_file boolean true when the whole file is muted

--- A directive, or one code listed on it, that suppressed nothing.
---@class deadcode.UnusedDirective
---@field line integer the line the comment is written on
---@field col integer
---@field code string|nil the listed code that went unused; nil when the
--- directive listed no codes at all and still suppressed nothing
---@field directive deadcode.Directive the directive itself, so that the
--- finding it produces cannot be suppressed by that same directive

--- Inline suppression directives.
---@class deadcode.noqa
local noqa = {}

--- Does `directive` cover `code`? A directive that listed no codes covers all.
---@param directive deadcode.Directive
---@param code string
---@return boolean
local function covers(directive, code)
  if not directive.codes then return true end
  for _, listed in ipairs(directive.codes) do
    if listed == code then return true end
  end
  return false
end

--- Build a directive index from the comment list the lexer produced.
---@param comments deadcode.Comment[]|nil
---@return deadcode.Directives empty but usable when `comments` is nil
function noqa.parse(comments)
  local directives = { list = {}, by_target = {}, ignore_file = false }
  if not comments then return directives end

  for _, comment in ipairs(comments) do
    local text = comment.text or ''
    local target = comment.applies_to or comment.line

    -- A directive must open the comment. Searching anywhere in the text turns
    -- prose like "broken-noqa-ish" into an accidental suppression.
    if text:find('^%s*[Dd]eadcode%s*:%s*ignore%-file%f[%A]') then
      directives.ignore_file = true
    else
      -- `owned` records whether this tool is the one being addressed. Only its
      -- own spelling is ever reported as unused; see `noqa.unused`.
      local owned = true
      local rest = text:match('^%s*[Dd]eadcode%s*:%s*ignore%f[%A](.*)$')
      if not rest then
        owned = false
        rest = text:match('^%s*[Nn]oqa%f[%A](.*)$')
        if not rest and text:find('^%s*[Ll]uacheck%s*:%s*ignore%f[%A]') then rest = '' end
      end

      if rest then
        local codes
        for code in rest:gmatch('DC%d%d') do
          codes = codes or {}
          codes[#codes + 1] = code
        end

        local directive = {
          line = comment.line,
          col = comment.col,
          target = target,
          codes = codes,
          owned = owned,
          used = {},
          used_any = false,
        }

        directives.list[#directives.list + 1] = directive
        local governing = directives.by_target[target]
        if not governing then
          governing = {}
          directives.by_target[target] = governing
        end
        governing[#governing + 1] = directive
      end
    end
  end

  return directives
end

--- Is a finding with `code` on `line` suppressed by a directive?
-- Records the suppression on the directive that made it, which is what lets an
-- unsuppressing directive be told apart from a working one.
---@param directives deadcode.Directives|nil nil for a file that was never parsed
---@param line integer
---@param code string a `DCxx` code
---@param except deadcode.Directive|nil a directive that may not answer, used
--- when the finding is the complaint that `except` itself suppresses nothing:
--- letting it silence that would make every unused directive self-justifying
---@return boolean
function noqa.is_ignored(directives, line, code, except)
  if not directives then return false end
  local governing = directives.by_target[line]
  if not governing then return false end

  for _, directive in ipairs(governing) do
    if directive ~= except and covers(directive, code) then
      directive.used_any = true
      directive.used[code] = true
      return true
    end
  end

  return false
end

--- Every directive, or listed code, that has not suppressed anything.
---@param directives deadcode.Directives
---@return deadcode.UnusedDirective[] in source order
local function collect(directives)
  local found = {}

  for _, directive in ipairs(directives.list) do
    -- A `luacheck: ignore` or a bare `noqa` is addressed to another tool. It
    -- may well be doing its job over there, and advising its deletion would be
    -- a claim about a linter this one cannot see.
    if directive.owned then
      if not directive.codes then
        if not directive.used_any then
          found[#found + 1] = { line = directive.line, col = directive.col, directive = directive }
        end
      else
        local seen = {}
        for _, code in ipairs(directive.codes) do
          if not directive.used[code] and not seen[code] then
            seen[code] = true
            found[#found + 1] =
              { line = directive.line, col = directive.col, code = code, directive = directive }
          end
        end
      end
    end
  end

  return found
end

---@param set table<deadcode.Directive, table<string|boolean, boolean>>
---@param candidate deadcode.UnusedDirective
---@param value boolean|nil written when given, read when not
---@return boolean
local function silenced(set, candidate, value)
  local codes = set[candidate.directive]
  if value == nil then return codes ~= nil and codes[candidate.code or true] == true end
  if not codes then
    codes = {}
    set[candidate.directive] = codes
  end
  codes[candidate.code or true] = value
  return value
end

--- Directives that suppress nothing, and so are only clutter to delete.
--
-- Two passes over the same set. Asking whether an unused directive is itself
-- suppressed can be exactly what puts a *different* directive to work, so the
-- second pass recomputes from the usage the first one recorded. Without that, a
-- directive could be reported as unused in the same run that used it.
---@param directives deadcode.Directives|nil
---@return deadcode.UnusedDirective[] in source order
function noqa.unused(directives)
  -- A muted file reports nothing, and a directive inside one is beside the
  -- point: `ignore-file` already says the whole file is not being listened to.
  if not directives or directives.ignore_file then return {} end

  local code = constants.TYPE_TO_CODE.unused_ignore
  local quiet = {}

  for _, candidate in ipairs(collect(directives)) do
    if noqa.is_ignored(directives, candidate.line, code, candidate.directive) then
      silenced(quiet, candidate, true)
    end
  end

  local found = {}
  for _, candidate in ipairs(collect(directives)) do
    if not silenced(quiet, candidate) then found[#found + 1] = candidate end
  end

  return found
end

return noqa
