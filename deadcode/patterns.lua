-- Translate the pattern syntaxes a `tach.lua` uses into Lua patterns.
--
-- tach describes a public interface with regular expressions and names modules
-- with globs. Lua has neither syntax: `string.find` takes Lua patterns, which
-- look like regular expressions and are not one - `%` escapes rather than `\`,
-- `\d` is a syntax error, and there is no alternation at all.
--
-- Translating is the only way a pattern written for tach can be honoured here
-- rather than approximated. What Lua patterns cannot express - alternation,
-- grouping, repetition counts - is reported as a configuration problem instead
-- of being quietly dropped: these patterns decide which names the tool calls
-- public, and one that silently matches something else is worse than one that
-- refuses to load.
--
-- Both syntaxes match a whole string, matching tach: an `expose` entry names a
-- symbol outright, not a substring of one.
--
-- The globbing here is deliberately not `ignore.lua`'s. That one implements
-- this tool's own `--exclude` syntax, where `*` crosses separators; tach's does
-- not, and spells the crossing one `**`.

--- Translate tach's pattern syntaxes into Lua patterns.
---@class deadcode.patterns
local patterns = {}

--- Characters Lua patterns give a meaning to, which a literal has to escape.
local MAGIC = {
  ['^'] = true,
  ['$'] = true,
  ['('] = true,
  [')'] = true,
  ['%'] = true,
  ['.'] = true,
  ['['] = true,
  [']'] = true,
  ['*'] = true,
  ['+'] = true,
  ['-'] = true,
  ['?'] = true,
}

--- Regex shorthand classes that have an exact Lua counterpart.
--
-- Only these translate. `\b` and `\B` are word boundaries, which Lua patterns
-- spell `%f[%w]` and only approximately, so they are refused rather than
-- guessed at.
local CLASS_ESCAPES = {
  d = '%d',
  D = '%D',
  w = '%w',
  W = '%W',
  s = '%s',
  S = '%S',
}

--- Regex constructs with no Lua pattern equivalent, and what to call them.
local UNSUPPORTED = {
  ['|'] = 'alternation',
  ['('] = 'a group',
  [')'] = 'a group',
  ['{'] = 'a repetition count',
  ['}'] = 'a repetition count',
}

--- The placeholder standing in for `**` between expansion and translation.
--
-- A control character, because it has to be a byte no glob would contain: the
-- expansion below rewrites `**` into alternatives before any escaping happens,
-- and a placeholder a user could have typed would be indistinguishable from
-- their own text by the time it is read back.
local GLOBSTAR = '\1'

--- Quote one character so a Lua pattern matches it literally.
---@param char string a single character
---@return string
local function escape(char)
  if MAGIC[char] then return '%' .. char end
  return char
end

--- Translate a bracketed character class, which both syntaxes share.
--
-- Lua's own class syntax is close enough to copy through: ranges and a leading
-- negating `^` mean the same thing. What differs is the escape character, so a
-- `%` inside the class is doubled and a `\x` is re-spelled.
---@param source string
---@param position integer index of the opening `[`
---@return string|nil text the Lua class, including its brackets
---@return string|integer rest the index after the closing `]`, or the reason
local function bracket(source, position)
  local out = { '[' }
  local index = position + 1

  if source:sub(index, index) == '^' then
    out[#out + 1] = '^'
    index = index + 1
  end

  -- A `]` written first is a literal in both syntaxes, so only a later one
  -- closes the class.
  local first = true
  while index <= #source do
    local char = source:sub(index, index)
    if char == ']' and not first then
      out[#out + 1] = ']'
      return table.concat(out), index + 1
    end

    if char == '\\' then
      local escaped = source:sub(index + 1, index + 1)
      if escaped == '' then return nil, 'pattern ends in a backslash' end
      out[#out + 1] = CLASS_ESCAPES[escaped] or escape(escaped)
      index = index + 2
    elseif char == '%' or char == ']' then
      out[#out + 1] = '%' .. char
      index = index + 1
    else
      out[#out + 1] = char
      index = index + 1
    end
    first = false
  end

  return nil, 'unterminated character class in pattern'
end

--- Translate a regular expression into an anchored Lua pattern.
--
-- The supported subset is the one tach configurations actually use: literals,
-- `.`, the three quantifiers, character classes, and backslash escapes. A
-- leading `^` and a trailing `$` are accepted and dropped, since the result is
-- anchored either way; an anchor anywhere else is refused, because it would be
-- asserting something about a partial match that cannot happen here.
---@param source string
---@return string|nil pattern
---@return string|nil reason set only when `pattern` is nil
function patterns.from_regex(source)
  if type(source) ~= 'string' then return nil, 'pattern must be a string' end

  local out = {}
  local index = 1
  local stop = #source

  if source:sub(1, 1) == '^' then index = 2 end
  if stop > 0 and source:sub(stop, stop) == '$' and source:sub(stop - 1, stop - 1) ~= '\\' then
    stop = stop - 1
  end

  -- Whether the last thing emitted can carry a quantifier. False after a
  -- quantifier as well as at the start, so `a**` is refused rather than
  -- translated into a Lua pattern that means something else entirely.
  local quantifiable = false

  while index <= stop do
    local char = source:sub(index, index)

    if char == '\\' then
      local escaped = source:sub(index + 1, index + 1)
      if escaped == '' then return nil, 'pattern ends in a backslash' end
      local class = CLASS_ESCAPES[escaped]
      if class then
        out[#out + 1] = class
      elseif escaped:find('^%a') then
        return nil, "unsupported escape '\\" .. escaped .. "' in pattern"
      else
        out[#out + 1] = escape(escaped)
      end
      index = index + 2
      quantifiable = true
    elseif char == '[' then
      local text, rest = bracket(source, index)
      if text == nil then return nil, tostring(rest) end
      out[#out + 1] = text
      ---@cast rest integer
      index = rest
      quantifiable = true
    elseif char == '.' then
      out[#out + 1] = '.'
      index = index + 1
      quantifiable = true
    elseif char == '*' or char == '+' or char == '?' then
      if not quantifiable then return nil, "'" .. char .. "' has nothing to repeat in pattern" end
      out[#out + 1] = char
      index = index + 1
      quantifiable = false
    elseif char == '^' or char == '$' then
      return nil, "'" .. char .. "' is only supported at the ends of a pattern"
    elseif UNSUPPORTED[char] then
      return nil, UNSUPPORTED[char] .. ' is not supported in a pattern'
    else
      out[#out + 1] = escape(char)
      index = index + 1
      quantifiable = true
    end
  end

  return '^' .. table.concat(out) .. '$'
end

--- Rewrite every `**` into the alternatives a Lua pattern can express.
--
-- `**` spans separators and, next to one, spans zero of them too: tach matches
-- `libs` as well as `libs.thing` for `libs.**`. Lua patterns have no optional
-- group, so the optionality is expanded into separate patterns and the caller
-- matches against any of them. Real configurations hold one or two `**`, so the
-- expansion stays small.
---@param glob string
---@param separator string
---@return string[] globs holding `GLOBSTAR` in place of every `**`
local function expand_globstar(glob, separator)
  local before, after = glob:match('^(.-)%*%*(.*)$')
  if before == nil then return { glob } end

  local variants = {}
  local function expand(candidate)
    local rest = expand_globstar(candidate, separator)
    for i = 1, #rest do
      variants[#variants + 1] = rest[i]
    end
  end

  if after:sub(1, #separator) == separator then
    -- `**.rest`: no leading segments at all, or any number of them.
    expand(before .. after:sub(#separator + 1))
    expand(before .. GLOBSTAR .. after)
  elseif after == '' and before:sub(-#separator) == separator then
    -- `prefix.**`: the prefix itself, or anything beneath it.
    expand(before:sub(1, #before - #separator))
    expand(before .. GLOBSTAR)
  else
    expand(before .. GLOBSTAR .. after)
  end

  return variants
end

--- Translate one globstar-free glob into an anchored Lua pattern.
---@param glob string may contain `GLOBSTAR`
---@param separator string the path separator a single `*` must not cross
---@return string|nil pattern
---@return string|nil reason set only when `pattern` is nil
local function glob_pattern(glob, separator)
  local segment = '[^' .. escape(separator) .. ']'
  local out = {}
  local index = 1

  while index <= #glob do
    local char = glob:sub(index, index)
    if char == GLOBSTAR then
      out[#out + 1] = '.*'
      index = index + 1
    elseif char == '*' then
      out[#out + 1] = segment .. '*'
      index = index + 1
    elseif char == '?' then
      out[#out + 1] = segment
      index = index + 1
    elseif char == '[' then
      local text, rest = bracket(glob, index)
      if text == nil then return nil, tostring(rest) end
      out[#out + 1] = text
      ---@cast rest integer
      index = rest
    elseif char == '{' or char == '}' then
      return nil, 'brace alternation is not supported in a glob'
    elseif char == '\\' then
      local escaped = glob:sub(index + 1, index + 1)
      if escaped == '' then return nil, 'glob ends in a backslash' end
      out[#out + 1] = escape(escaped)
      index = index + 2
    else
      out[#out + 1] = escape(char)
      index = index + 1
    end
  end

  return '^' .. table.concat(out) .. '$'
end

--- Translate a glob into the Lua patterns that together mean the same thing.
--
-- Returns a list rather than one pattern because `**` is optional next to a
-- separator and Lua patterns cannot say "optional" about anything longer than a
-- single character. `patterns.any` is what callers ask the list a question with.
---@param glob string
---@param separator string the separator a single `*` must not cross
---@return string[]|nil compiled
---@return string|nil reason set only when `compiled` is nil
local function from_glob(glob, separator)
  if type(glob) ~= 'string' then return nil, 'glob must be a string' end
  if glob:find(GLOBSTAR, 1, true) then return nil, 'glob contains a control character' end

  local expanded = expand_globstar(glob, separator)
  local compiled = {}
  for i = 1, #expanded do
    local pattern, reason = glob_pattern(expanded[i], separator)
    if pattern == nil then return nil, reason end
    compiled[#compiled + 1] = pattern
  end

  return compiled
end

--- Translate a dotted module glob, as `modules[].path` writes them.
--
-- The only glob syntax a `tach.lua` actually reaches this module with; the
-- separator stays a parameter one level down because `**` means "cross the
-- separator" and that has to be a decision, not a constant buried in the loop.
---@param glob string
---@return string[]|nil compiled
---@return string|nil reason set only when `compiled` is nil
function patterns.from_module_glob(glob)
  return from_glob(glob, '.')
end

--- True when any of `compiled` matches the whole of `text`.
---@param compiled string[] Lua patterns, already anchored
---@param text string|nil nothing matches a name that could not be derived
---@return boolean
function patterns.any(compiled, text)
  if text == nil then return false end
  for i = 1, #compiled do
    if text:find(compiled[i]) then return true end
  end
  return false
end

return patterns
