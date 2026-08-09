-- Tokeniser for Lua source.
--
-- Accepts the union of Lua 5.1 - 5.4 and LuaJIT syntax, so that this tool can
-- analyse modern code even though it runs on 5.1 itself. Unknown-but-harmless
-- constructs are tokenised rather than rejected; the parser decides what is
-- structurally valid.
--
-- Returns plain arrays of token tables. Positions are 1-based `line` and `col`
-- measured in bytes. Only start positions are recorded: this tool reports
-- findings, it never rewrites source, so no node ever needs an end position.

local Lexer = {}

local byte, sub, find, gsub = string.byte, string.sub, string.find, string.gsub

local KEYWORDS = {}
for word in
  (
    'and break do else elseif end false for function goto if in '
    .. 'local nil not or repeat return then true until while'
  ):gmatch('%S+')
do
  KEYWORDS[word] = true
end

-- Longest-first so that `..` wins over `.`, `//` over `/`, and so on.
local OPERATORS = {
  '...',
  '..',
  '==',
  '~=',
  '<=',
  '>=',
  '//',
  '<<',
  '>>',
  '::',
  '+',
  '-',
  '*',
  '/',
  '%',
  '^',
  '#',
  '&',
  '~',
  '|',
  '<',
  '>',
  '=',
  '(',
  ')',
  '{',
  '}',
  '[',
  ']',
  ';',
  ':',
  ',',
  '.',
}

local LF, CR = 10, 13
local SPACE, TAB, VTAB, FF = 32, 9, 11, 12

local function is_space(b)
  return b == SPACE or b == TAB or b == VTAB or b == FF
end

local function is_digit(b)
  return b and b >= 48 and b <= 57
end

local function is_hex(b)
  return b
    and (
      is_digit(b)
      or (b >= 97 and b <= 102) -- a-f
      or (b >= 65 and b <= 70)
    ) -- A-F
end

local function is_name_start(b)
  return b and ((b >= 97 and b <= 122) or (b >= 65 and b <= 90) or b == 95)
end

local function is_name_part(b)
  return is_name_start(b) or is_digit(b)
end

local Scanner = {}
Scanner.__index = Scanner

local function new_scanner(src, chunkname)
  return setmetatable({
    src = src,
    len = #src,
    pos = 1,
    line = 1,
    line_start = 1,
    chunkname = chunkname or '?',
    tokens = {},
    comments = {},
  }, Scanner)
end

function Scanner:col()
  return self.pos - self.line_start + 1
end

function Scanner:error(msg, line)
  error({ deadcode_lex = true, msg = msg, line = line or self.line, chunkname = self.chunkname }, 0)
end

-- Consumes a newline in any of the four accepted forms and bumps the counter.
function Scanner:newline()
  local b = byte(self.src, self.pos)
  local nxt = byte(self.src, self.pos + 1)
  self.pos = self.pos + 1
  if (nxt == LF or nxt == CR) and nxt ~= b then self.pos = self.pos + 1 end
  self.line = self.line + 1
  self.line_start = self.pos
end

-- Matches `[`, `=`*n, `[` at the current position. Returns the level or nil.
function Scanner:long_bracket_level()
  if byte(self.src, self.pos) ~= 91 then return nil end -- '['
  local p = self.pos + 1
  local level = 0
  while byte(self.src, p) == 61 do -- '='
    level = level + 1
    p = p + 1
  end
  if byte(self.src, p) == 91 then return level, p + 1 end
  return nil
end

-- Reads the body of a long string/comment. `start_pos` is just past the opener.
function Scanner:read_long_body(level, start_pos, opener_line)
  self.pos = start_pos
  -- A newline immediately after the opening bracket is not part of the content.
  local b = byte(self.src, self.pos)
  if b == LF or b == CR then self:newline() end

  local content_start = self.pos
  local closer = ']' .. string.rep('=', level) .. ']'
  while true do
    if self.pos > self.len then self:error('unterminated long string or comment', opener_line) end
    local c = byte(self.src, self.pos)
    if c == 93 then -- ']'
      if sub(self.src, self.pos, self.pos + level + 1) == closer then
        local content = sub(self.src, content_start, self.pos - 1)
        self.pos = self.pos + level + 2
        return content
      end
      self.pos = self.pos + 1
    elseif c == LF or c == CR then
      self:newline()
    else
      self.pos = self.pos + 1
    end
  end
end

function Scanner:read_short_string(quote, line)
  local start = self.pos
  self.pos = self.pos + 1
  local pieces = {}
  while true do
    if self.pos > self.len then self:error('unterminated string', line) end
    local c = byte(self.src, self.pos)
    if c == quote then
      self.pos = self.pos + 1
      break
    elseif c == LF or c == CR then
      self:error('unterminated string', line)
    elseif c == 92 then -- backslash
      -- The precise decoded value is irrelevant for dead-code analysis; we only
      -- need well-formed bounds and correct line counting. `\<newline>` and
      -- `\z` are the two escapes that affect either.
      self.pos = self.pos + 1
      local e = byte(self.src, self.pos)
      if e == LF or e == CR then
        self:newline()
      elseif e == 122 then -- 'z': skip following whitespace incl. newlines
        self.pos = self.pos + 1
        while self.pos <= self.len do
          local w = byte(self.src, self.pos)
          if w == LF or w == CR then
            self:newline()
          elseif is_space(w) then
            self.pos = self.pos + 1
          else
            break
          end
        end
      else
        self.pos = self.pos + 1
      end
    else
      self.pos = self.pos + 1
    end
  end
  local raw = sub(self.src, start, self.pos - 1)
  -- Best-effort decode of the common escapes, enough for directive/name
  -- matching against string literals (e.g. require "mod", t["field"]).
  local body = sub(raw, 2, -2)
  body = gsub(body, '\\(.)', function(ch)
    if ch == 'n' then
      return '\n'
    elseif ch == 't' then
      return '\t'
    elseif ch == 'r' then
      return '\r'
    elseif ch == 'a' then
      return '\a'
    elseif ch == 'b' then
      return '\b'
    elseif ch == 'f' then
      return '\f'
    elseif ch == 'v' then
      return '\v'
    else
      return ch
    end
  end)
  table.insert(pieces, body)
  return table.concat(pieces)
end

function Scanner:read_number()
  local start = self.pos
  local src = self.src
  if
    byte(src, self.pos) == 48 -- '0'
    and (byte(src, self.pos + 1) == 120 or byte(src, self.pos + 1) == 88)
  then -- x/X
    self.pos = self.pos + 2
    while is_hex(byte(src, self.pos)) or byte(src, self.pos) == 46 do -- '.'
      self.pos = self.pos + 1
    end
    local e = byte(src, self.pos)
    if e == 112 or e == 80 then -- hex float exponent p/P
      self.pos = self.pos + 1
      local s = byte(src, self.pos)
      if s == 43 or s == 45 then self.pos = self.pos + 1 end
      while is_digit(byte(src, self.pos)) do
        self.pos = self.pos + 1
      end
    end
  else
    while is_digit(byte(src, self.pos)) or byte(src, self.pos) == 46 do
      self.pos = self.pos + 1
    end
    local e = byte(src, self.pos)
    if e == 101 or e == 69 then -- e/E
      self.pos = self.pos + 1
      local s = byte(src, self.pos)
      if s == 43 or s == 45 then self.pos = self.pos + 1 end
      while is_digit(byte(src, self.pos)) do
        self.pos = self.pos + 1
      end
    end
  end
  -- LuaJIT numeric suffixes: 1LL, 1ULL, 1i
  local tail = sub(src, self.pos, self.pos + 2):upper()
  if tail:sub(1, 3) == 'ULL' then
    self.pos = self.pos + 3
  elseif tail:sub(1, 2) == 'LL' then
    self.pos = self.pos + 2
  elseif tail:sub(1, 1) == 'I' and not is_name_part(byte(src, self.pos + 1)) then
    self.pos = self.pos + 1
  end
  return sub(src, start, self.pos - 1)
end

function Scanner:push(type_, value, line, col)
  local t = self.tokens
  t[#t + 1] = { type = type_, value = value, line = line, col = col }
end

function Scanner:run()
  local src, len = self.src, self.len

  -- A leading `#!` line is legal in Lua chunks.
  if byte(src, 1) == 35 then -- '#'
    local nl = find(src, '[\r\n]') or (len + 1)
    self.pos = nl
  end

  while self.pos <= len do
    local b = byte(src, self.pos)

    if b == LF or b == CR then
      self:newline()
    elseif is_space(b) then
      self.pos = self.pos + 1
    elseif b == 45 and byte(src, self.pos + 1) == 45 then -- '--'
      local line, col = self.line, self:col()
      self.pos = self.pos + 2
      -- Whether the comment is alone on its line decides what a directive
      -- inside it governs: a trailing comment annotates its own line, a
      -- standalone one annotates the code that follows.
      local last = self.tokens[#self.tokens]
      local own_line = (last == nil) or (last.line ~= line)

      local level, body_start = self:long_bracket_level()
      if level then
        local text = self:read_long_body(level, body_start, line)
        self.comments[#self.comments + 1] = {
          text = text,
          line = line,
          col = col,
          long = true,
          end_line = self.line,
          own_line = own_line,
        }
      else
        local nl = find(src, '[\r\n]', self.pos) or (len + 1)
        local text = sub(src, self.pos, nl - 1)
        self.pos = nl
        self.comments[#self.comments + 1] = {
          text = text,
          line = line,
          col = col,
          long = false,
          end_line = line,
          own_line = own_line,
        }
      end
    elseif is_name_start(b) then
      local line, col = self.line, self:col()
      local start = self.pos
      repeat
        self.pos = self.pos + 1
      until not is_name_part(byte(src, self.pos))
      local word = sub(src, start, self.pos - 1)
      self:push(KEYWORDS[word] and 'Keyword' or 'Name', word, line, col)
    elseif is_digit(b) or (b == 46 and is_digit(byte(src, self.pos + 1))) then
      local line, col = self.line, self:col()
      self:push('Number', self:read_number(), line, col)
    elseif b == 34 or b == 39 then -- " or '
      local line, col = self.line, self:col()
      self:push('String', self:read_short_string(b, line), line, col)
    else
      local line, col = self.line, self:col()
      local level, body_start = self:long_bracket_level()
      if level then
        self:push('String', self:read_long_body(level, body_start, line), line, col)
      else
        local matched
        for i = 1, #OPERATORS do
          local op = OPERATORS[i]
          if sub(src, self.pos, self.pos + #op - 1) == op then
            matched = op
            break
          end
        end
        if not matched then
          self:error(string.format("unexpected symbol near '%s'", sub(src, self.pos, self.pos)))
        end
        self.pos = self.pos + #matched
        self:push('Op', matched, line, col)
      end
    end
  end

  self:push('EOF', '<eof>', self.line, self:col())
  self:resolve_comment_targets()
  return self.tokens, self.comments
end

--- Give every comment the source line its directives govern.
-- Both token and comment lists are in source order, so one linear pass over
-- the tokens is enough.
function Scanner:resolve_comment_targets()
  local tokens = self.tokens
  local index = 1
  for _, comment in ipairs(self.comments) do
    if not comment.own_line then
      comment.applies_to = comment.line
    else
      while index <= #tokens and tokens[index].line <= comment.end_line do
        index = index + 1
      end
      local next_token = tokens[index]
      -- A trailing standalone comment governs nothing; point it at itself so
      -- the directive is simply inert rather than leaking onto earlier code.
      comment.applies_to = (next_token and next_token.type ~= 'EOF') and next_token.line
        or comment.line
    end
  end
end

--- Tokenise `src`.
-- On success returns `tokens, comments`. On a lexical error returns
-- `nil, message` - callers skip the file rather than aborting the run.
function Lexer.tokenize(src, chunkname)
  local scanner = new_scanner(src, chunkname)
  local ok, tokens, comments = pcall(scanner.run, scanner)
  if not ok then
    local err = tokens
    if type(err) == 'table' and err.deadcode_lex then
      return nil, string.format('%s:%d: %s', err.chunkname, err.line, err.msg)
    end
    return nil, tostring(err)
  end
  return tokens, comments
end

return Lexer
