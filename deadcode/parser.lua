-- Recursive-descent parser for Lua, producing an AST for dead-code analysis.
--
-- Accepts Lua 5.1 - 5.4 and LuaJIT syntax. Nodes carry a `tag`, plus `line` and
-- `col` of where they start. Nothing carries an end position: this tool only
-- reports findings, so a definition's extent is never needed.
--
-- Binding occurrences (a `local` name, a parameter, a loop variable) are
-- represented as NameDef nodes and are kept distinct from Name reference nodes.
-- The resolver relies on that distinction to tell a declaration from a use.

local Lexer = require('deadcode.lexer')

--- Every tag a node can carry. `NameDef` is the odd one out: it is a binding
--- occurrence rather than an expression, and the resolver depends on never
--- confusing one with a `Name` reference.
---@alias deadcode.NodeTag
---| '"Chunk"'
---| '"Block"'
---| '"NameDef"'
---| '"Name"'
---| '"Index"'
---| '"Paren"'
---| '"Vararg"'
---| '"Nil"'
---| '"True"'
---| '"False"'
---| '"Number"'
---| '"String"'
---| '"Table"'
---| '"Function"'
---| '"Call"'
---| '"MethodCall"'
---| '"UnOp"'
---| '"BinOp"'
---| '"LocalStat"'
---| '"LocalFunc"'
---| '"FuncStat"'
---| '"Assign"'
---| '"CallStat"'
---| '"Do"'
---| '"While"'
---| '"Repeat"'
---| '"If"'
---| '"NumericFor"'
---| '"GenericFor"'
---| '"Return"'
---| '"Break"'
---| '"Goto"'
---| '"Label"'

--- What a binding occurrence was written as. The resolver reports each kind
--- under its own code, so the distinction has to survive parsing.
---@alias deadcode.BindingKind '"local"' | '"param"' | '"loop"' | '"localfunc"'

--- One entry in a table constructor.
---@class deadcode.TableField
---@field kind '"bracket"' | '"named"' | '"item"'
---@field key deadcode.Node|nil the expression, for the `bracket` form
---@field name string|nil the literal key, for the `named` form
---@field line integer|nil position of `name`, for the `named` form
---@field col integer|nil
---@field value deadcode.Node

--- One `if`/`elseif` arm. `line` and `col` point at the keyword that opened it,
--- which is what a dead-branch finding is reported against.
---@class deadcode.IfClause
---@field cond deadcode.Node
---@field body deadcode.Node the arm's `Block`
---@field line integer
---@field col integer

--- An AST node.
---
--- The shape is deliberately loose: one table with a `tag` and whichever fields
--- that tag needs, rather than a class per variant. The resolver dispatches on
--- `tag`, and nothing reads a field that its tag does not populate, so a class
--- per variant would buy only casts. Each field below names the tags that carry
--- it; on any other tag it is absent, which is why `node` builds a bare table
--- and casts. The handful of fields marked optional are optional *within* their
--- own tag - `step` on a `NumericFor`, `orelse` on an `If` - and the code tests
--- for them.
---@class deadcode.Node
---@field tag deadcode.NodeTag
---@field line integer 1-based line the construct starts on
---@field col integer 1-based column, in bytes
---@field name string NameDef, Name, Label
---@field def deadcode.Node LocalFunc; the NameDef for the bound name
---@field kind deadcode.BindingKind NameDef
---@field implicit? boolean NameDef; true for a method's unwritten `self`
---@field value string Number, String
---@field body deadcode.Node Chunk, Function, Do, While, Repeat, NumericFor, GenericFor
---@field stats deadcode.Node[] Block
---@field fields deadcode.TableField[] Table
---@field params deadcode.Node[] Function; each a NameDef
---@field is_method boolean Function, FuncStat
---@field obj deadcode.Node Index, MethodCall
---@field key deadcode.Node Index
---@field dot boolean Index; false for the `[expr]` form
---@field key_line? integer Index, dotted form only
---@field key_col? integer Index, dotted form only
---@field method string MethodCall
---@field args deadcode.Node[] Call, MethodCall
---@field func deadcode.Node Call (the callee), LocalFunc and FuncStat (the body)
---@field expr deadcode.Node Paren
---@field op string UnOp, BinOp
---@field operand deadcode.Node UnOp
---@field left deadcode.Node BinOp
---@field right deadcode.Node BinOp
---@field exprs deadcode.Node[] Return, LocalStat, GenericFor, Assign
---@field names deadcode.Node[] LocalStat, GenericFor; each a NameDef
---@field target deadcode.Node FuncStat
---@field targets deadcode.Node[] Assign
---@field call deadcode.Node CallStat
---@field cond deadcode.Node While, Repeat
---@field clauses deadcode.IfClause[] If
---@field orelse? deadcode.Node If; the `else` Block
---@field orelse_line integer If, set whenever `orelse` is
---@field orelse_col integer If
---@field var deadcode.Node NumericFor; a NameDef
---@field start deadcode.Node NumericFor
---@field stop deadcode.Node NumericFor
---@field step? deadcode.Node NumericFor
---@field label string Goto

--- The table thrown by `P:error` and caught in `Parser.parse`.
---@class deadcode.ParseError
---@field deadcode_parse true marks the table as ours rather than a runtime error
---@field msg string
---@field line integer
---@field chunkname string

--- Recursive-descent parser for Lua.
---@class deadcode.Parser
local Parser = {}

-- Binary operator priorities, matching lparser.c. Bitwise operators are
-- accepted on every target version; the analyser does not care whether the
-- host Lua could run them.
local BINARY_PRIORITY = {
  ['or'] = { 1, 1 },
  ['and'] = { 2, 2 },
  ['<'] = { 3, 3 },
  ['>'] = { 3, 3 },
  ['<='] = { 3, 3 },
  ['>='] = { 3, 3 },
  ['~='] = { 3, 3 },
  ['=='] = { 3, 3 },
  ['|'] = { 4, 4 },
  ['~'] = { 5, 5 },
  ['&'] = { 6, 6 },
  ['<<'] = { 7, 7 },
  ['>>'] = { 7, 7 },
  ['..'] = { 9, 8 }, -- right associative
  ['+'] = { 10, 10 },
  ['-'] = { 10, 10 },
  ['*'] = { 11, 11 },
  ['/'] = { 11, 11 },
  ['//'] = { 11, 11 },
  ['%'] = { 11, 11 },
  ['^'] = { 14, 13 }, -- right associative
}

local UNARY_PRIORITY = 12

local BLOCK_ENDERS = {
  ['end'] = true,
  ['else'] = true,
  ['elseif'] = true,
  ['until'] = true,
}

--- Mutable parse state: a token cursor and the name to blame in errors.
---@class deadcode.P
---@field tokens deadcode.Token[]
---@field pos integer index of the token about to be read
---@field chunkname string
local P = {}
P.__index = P

---@param tokens deadcode.Token[]
---@param chunkname string|nil defaults to `'?'`
---@return deadcode.P
local function new_parser(tokens, chunkname)
  return setmetatable({
    tokens = tokens,
    pos = 1,
    chunkname = chunkname or '?',
  }, P)
end

--- The token `offset` places ahead, without consuming anything.
---@param offset integer|nil defaults to 0, the current token
---@return deadcode.Token|nil nil past the end of the stream
function P:peek(offset)
  return self.tokens[self.pos + (offset or 0)]
end

--- Consume and return the current token.
---
--- Every caller has already established that a token is there, either through
--- `check` or through `expect`, and no caller consumes the trailing `EOF`, so
--- the result is never nil in practice.
---@return deadcode.Token
function P:next()
  local tok = self.tokens[self.pos]
  self.pos = self.pos + 1
  ---@cast tok deadcode.Token
  return tok
end

--- Abandon the parse.
---
--- This never returns, but the declared type is `any` so that callers can
--- write `return self:error(...)` in a function that owes a value. Doing so is
--- also what tells the analyser that the branch is terminal.
---@param msg string
---@param tok deadcode.Token|deadcode.Node|nil what to blame; defaults to the
--- current token
---@return any
function P:error(msg, tok)
  tok = tok or self:peek()
  error({
    deadcode_parse = true,
    msg = msg,
    line = tok and tok.line or 0,
    chunkname = self.chunkname,
  }, 0)
end

--- True when the current token is the given operator or keyword.
---@param type_ deadcode.TokenType
---@param value string|nil when omitted, any token of `type_` matches
---@return boolean|nil
function P:check(type_, value)
  local tok = self:peek()
  return tok and tok.type == type_ and (value == nil or tok.value == value)
end

---@param value string
---@return boolean|nil
function P:check_op(value)
  return self:check('Op', value)
end

---@param value string
---@return boolean|nil
function P:check_kw(value)
  return self:check('Keyword', value)
end

--- Consumes the token if it matches, returning it, else nil.
---@param type_ deadcode.TokenType
---@param value string|nil
---@return deadcode.Token|nil
function P:accept(type_, value)
  if self:check(type_, value) then return self:next() end
  return nil
end

---@param value string
---@return deadcode.Token|nil
function P:accept_op(value)
  return self:accept('Op', value)
end

--- Consume the token, or abandon the parse if it is not there.
---@param type_ deadcode.TokenType
---@param value string|nil
---@param what string|nil what to name in the message; defaults to `value`
---@return deadcode.Token
function P:expect(type_, value, what)
  local tok = self:peek()
  if not self:check(type_, value) then
    self:error(
      string.format(
        "'%s' expected near '%s'",
        what or value or type_,
        tok and tostring(tok.value) or '<eof>'
      )
    )
  end
  return self:next()
end

---@param value string
---@return deadcode.Token
function P:expect_op(value)
  return self:expect('Op', value)
end

---@param value string
---@return deadcode.Token
function P:expect_kw(value)
  return self:expect('Keyword', value)
end

--- `goto` is a keyword from 5.2 on, but a perfectly ordinary identifier in 5.1.
-- Accepting it in name position keeps older code parseable.
---@return deadcode.Token
function P:expect_name()
  local tok = self:peek()
  if not (tok and (tok.type == 'Name' or (tok.type == 'Keyword' and tok.value == 'goto'))) then
    return self:error(
      string.format("<name> expected near '%s'", tok and tostring(tok.value) or '<eof>')
    )
  end
  return self:next()
end

--- A bare node. The caller fills in whatever else its tag needs, which is why
--- the result is cast rather than built complete: no tag uses more than a
--- handful of the fields `deadcode.Node` declares.
---@param tag deadcode.NodeTag
---@param line integer
---@param col integer
---@return deadcode.Node
local function node(tag, line, col)
  local n = { tag = tag, line = line, col = col }
  ---@cast n deadcode.Node
  return n
end

--- A binding occurrence, taking its name and position from the token.
---@param tok deadcode.Token
---@param kind deadcode.BindingKind
---@return deadcode.Node a NameDef node
local function name_def(tok, kind)
  local n = node('NameDef', tok.line, tok.col)
  n.name = tok.value
  n.kind = kind
  return n
end

--- A String node for a name used as a literal: a dotted key, or the argument
--- of the `f"str"` call form.
---@param tok deadcode.Token
---@return deadcode.Node a String node
local function string_node(tok)
  local n = node('String', tok.line, tok.col)
  n.value = tok.value
  return n
end

-- ---------------------------------------------------------------- expressions

--- Parse a `{ ... }` constructor.
---@return deadcode.Node a Table node
function P:parse_table()
  local open = self:expect_op('{')
  local n = node('Table', open.line, open.col)
  n.fields = {}

  while not self:check_op('}') do
    if self:check_op('[') then
      self:next()
      local key = self:parse_expr()
      self:expect_op(']')
      self:expect_op('=')
      local value = self:parse_expr()
      n.fields[#n.fields + 1] = { kind = 'bracket', key = key, value = value }
    elseif
      (self:check('Name') or self:check_kw('goto'))
      and self:peek(1)
      and self:peek(1).type == 'Op'
      and self:peek(1).value == '='
    then
      local key = self:next()
      self:next() -- '='
      local value = self:parse_expr()
      n.fields[#n.fields + 1] = {
        kind = 'named',
        name = key.value,
        line = key.line,
        col = key.col,
        value = value,
      }
    else
      n.fields[#n.fields + 1] = { kind = 'item', value = self:parse_expr() }
    end

    if not (self:accept_op(',') or self:accept_op(';')) then break end
  end

  self:expect_op('}')
  return n
end

--- Parse a parameter list and body, up to and including the closing `end`.
---@param line integer position of the construct that introduced the function,
--- not of the `(` - that is what a finding should point at
---@param col integer
---@param is_method boolean|nil true to add the implicit `self` parameter
---@return deadcode.Node a Function node
function P:parse_func_body(line, col, is_method)
  local n = node('Function', line, col)
  n.params = {}
  n.is_method = is_method or false

  if is_method then
    -- The implicit `self` is a real binding, but one the author did not write.
    -- Flagging it as unused would be nonsense, so it is marked implicit and the
    -- suppression layer always exempts it.
    local implicit_self = node('NameDef', line, col)
    implicit_self.name = 'self'
    implicit_self.kind = 'param'
    implicit_self.implicit = true
    n.params[1] = implicit_self
  end

  self:expect_op('(')
  if not self:check_op(')') then
    repeat
      -- `...` binds no name, so nothing to record; it just ends the list.
      if self:accept_op('...') then break end
      n.params[#n.params + 1] = name_def(self:expect_name(), 'param')
    until not self:accept_op(',')
  end
  self:expect_op(')')

  n.body = self:parse_block()
  self:expect_kw('end')
  return n
end

--- Suffixes shared by prefixexp: `.name`, `[expr]`, `:name(args)`, `(args)`,
-- `"str"` and `{table}` call sugar.
---@param base deadcode.Node the expression the suffixes apply to
---@return deadcode.Node base itself when no suffix follows
function P:parse_suffixed(base)
  while true do
    if self:check_op('.') then
      self:next()
      local key = self:expect_name()
      local n = node('Index', base.line, base.col)
      n.obj = base
      n.key = string_node(key)
      n.dot = true
      n.key_line, n.key_col = key.line, key.col
      base = n
    elseif self:check_op('[') then
      self:next()
      local n = node('Index', base.line, base.col)
      n.obj = base
      n.key = self:parse_expr()
      n.dot = false
      self:expect_op(']')
      base = n
    elseif self:check_op(':') then
      self:next()
      local method = self:expect_name()
      local n = node('MethodCall', base.line, base.col)
      n.obj = base
      n.method = method.value
      n.args = self:parse_call_args()
      base = n
    elseif self:check_op('(') or self:check('String') or self:check_op('{') then
      local n = node('Call', base.line, base.col)
      n.func = base
      n.args = self:parse_call_args()
      base = n
    else
      return base
    end
  end
end

--- Parse a call's arguments in any of the three spellings Lua allows.
---@return deadcode.Node[]
function P:parse_call_args()
  if self:check('String') then
    local tok = self:next()
    return { string_node(tok) }
  end
  if self:check_op('{') then return { self:parse_table() } end

  self:expect_op('(')
  local args = {}
  if not self:check_op(')') then
    repeat
      args[#args + 1] = self:parse_expr()
    until not self:accept_op(',')
  end
  self:expect_op(')')
  return args
end

--- Parse the head of a prefixexp: a bare name or a parenthesised expression.
---@return deadcode.Node a Name or Paren node
function P:parse_primary()
  local tok = self:peek()
  if not tok then return self:error('unexpected <eof>') end

  if tok.type == 'Name' or (tok.type == 'Keyword' and tok.value == 'goto') then
    self:next()
    local n = node('Name', tok.line, tok.col)
    n.name = tok.value
    return n
  end

  if tok.type == 'Op' and tok.value == '(' then
    self:next()
    local inner = self:parse_expr()
    self:expect_op(')')
    local n = node('Paren', tok.line, tok.col)
    n.expr = inner
    return n
  end

  return self:error(string.format("unexpected symbol near '%s'", tostring(tok.value)))
end

--- Parse an expression with no operators in it.
---@return deadcode.Node
function P:parse_simple()
  local tok = self:peek()
  if not tok then return self:error('unexpected <eof>') end

  if tok.type == 'Number' then
    self:next()
    local n = node('Number', tok.line, tok.col)
    n.value = tok.value
    return n
  end
  if tok.type == 'String' then
    self:next()
    local n = node('String', tok.line, tok.col)
    n.value = tok.value
    return n
  end
  if tok.type == 'Keyword' then
    if tok.value == 'nil' then
      self:next()
      return node('Nil', tok.line, tok.col)
    end
    if tok.value == 'true' then
      self:next()
      return node('True', tok.line, tok.col)
    end
    if tok.value == 'false' then
      self:next()
      return node('False', tok.line, tok.col)
    end
    if tok.value == 'function' then
      self:next()
      return self:parse_func_body(tok.line, tok.col, false)
    end
  end
  if tok.type == 'Op' then
    if tok.value == '...' then
      self:next()
      return node('Vararg', tok.line, tok.col)
    end
    if tok.value == '{' then return self:parse_table() end
  end

  return self:parse_suffixed(self:parse_primary())
end

--- Parse an expression by precedence climbing.
---@param limit integer|nil stop before any operator binding this loosely;
--- defaults to 0, which consumes the whole expression
---@return deadcode.Node
function P:parse_expr(limit)
  limit = limit or 0
  local left
  local tok = self:peek()

  local is_unary = tok
    and (
      (tok.type == 'Op' and (tok.value == '-' or tok.value == '#' or tok.value == '~'))
      or (tok.type == 'Keyword' and tok.value == 'not')
    )

  if is_unary then
    ---@cast tok -nil `is_unary` is only ever true for a token that is there.
    self:next()
    local operand = self:parse_expr(UNARY_PRIORITY)
    left = node('UnOp', tok.line, tok.col)
    left.op = tok.value
    left.operand = operand
  else
    left = self:parse_simple()
  end

  while true do
    local op = self:peek()
    if not op then break end
    local name = (op.type == 'Op' or op.type == 'Keyword') and op.value or nil
    local prio = name and BINARY_PRIORITY[name]
    if not prio or prio[1] <= limit then break end
    ---@cast name -nil a priority was only looked up if there was a name.

    self:next()
    local right = self:parse_expr(prio[2])
    local n = node('BinOp', left.line, left.col)
    n.op = name
    n.left = left
    n.right = right
    left = n
  end

  return left
end

-- ---------------------------------------------------------------- statements

--- Parse statements up to whatever closes the enclosing construct. The closing
--- token is left for the caller to consume.
---@return deadcode.Node a Block node
function P:parse_block()
  local first = self:peek()
  local block = node('Block', first and first.line or 0, first and first.col or 0)
  block.stats = {}

  while true do
    local tok = self:peek()
    if not tok or tok.type == 'EOF' then break end
    if tok.type == 'Keyword' and BLOCK_ENDERS[tok.value] then break end

    if tok.type == 'Keyword' and tok.value == 'return' then
      block.stats[#block.stats + 1] = self:parse_return()
      break -- `return` must be the last statement in its block
    end

    local stat = self:parse_statement()
    if stat then block.stats[#block.stats + 1] = stat end
  end

  return block
end

--- Parse a `return`, including the optional trailing `;`.
---@return deadcode.Node a Return node
function P:parse_return()
  local kw = self:expect_kw('return')
  local n = node('Return', kw.line, kw.col)
  n.exprs = {}

  local tok = self:peek()
  local ends_block = not tok
    or tok.type == 'EOF'
    or (tok.type == 'Keyword' and BLOCK_ENDERS[tok.value])
    or (tok.type == 'Op' and tok.value == ';')

  if not ends_block then
    repeat
      n.exprs[#n.exprs + 1] = self:parse_expr()
    until not self:accept_op(',')
  end
  self:accept_op(';')
  return n
end

--- Parses `funcname := Name {'.' Name} [':' Name]`.
---@return deadcode.Node target a Name, or an Index chain for a dotted name
---@return boolean is_method true when the final separator was `:`
function P:parse_func_name()
  local first = self:expect_name()
  local target = node('Name', first.line, first.col)
  target.name = first.value

  --- Wrap `target` in an Index node keyed by `key`.
  ---@param key deadcode.Token
  local function extend(key)
    local n = node('Index', target.line, target.col)
    n.obj = target
    n.key = string_node(key)
    n.dot = true
    n.key_line, n.key_col = key.line, key.col
    target = n
  end

  while self:check_op('.') do
    self:next()
    extend(self:expect_name())
  end

  if self:check_op(':') then
    self:next()
    extend(self:expect_name())
    return target, true
  end

  return target, false
end

--- Parse one statement.
---@return deadcode.Node|nil nil for a bare `;`, which binds nothing
function P:parse_statement()
  local tok = self:peek()
  ---@cast tok -nil `parse_block` is the only caller and it stops at `EOF`, so
  --- a statement is only ever started when there is a token to start it with.

  if tok.type == 'Op' and tok.value == ';' then
    self:next()
    return nil
  end

  if tok.type == 'Op' and tok.value == '::' then
    self:next()
    local name = self:expect_name()
    self:expect_op('::')
    local n = node('Label', tok.line, tok.col)
    n.name = name.value
    return n
  end

  if tok.type == 'Keyword' then
    local kw = tok.value

    if kw == 'break' then
      self:next()
      return node('Break', tok.line, tok.col)
    end

    if kw == 'goto' and self:peek(1) and self:peek(1).type == 'Name' then
      self:next()
      local name = self:expect_name()
      local n = node('Goto', tok.line, tok.col)
      n.label = name.value
      return n
    end

    if kw == 'do' then
      self:next()
      local n = node('Do', tok.line, tok.col)
      n.body = self:parse_block()
      self:expect_kw('end')
      return n
    end

    if kw == 'while' then
      self:next()
      local n = node('While', tok.line, tok.col)
      n.cond = self:parse_expr()
      self:expect_kw('do')
      n.body = self:parse_block()
      self:expect_kw('end')
      return n
    end

    if kw == 'repeat' then
      self:next()
      local n = node('Repeat', tok.line, tok.col)
      n.body = self:parse_block()
      self:expect_kw('until')
      -- The condition is evaluated inside the body's scope; the resolver
      -- relies on this node shape to keep that scope open.
      n.cond = self:parse_expr()
      return n
    end

    if kw == 'if' then
      self:next()
      local n = node('If', tok.line, tok.col)
      n.clauses = {}
      local cond = self:parse_expr()
      self:expect_kw('then')
      n.clauses[1] = { cond = cond, body = self:parse_block(), line = tok.line, col = tok.col }
      while self:check_kw('elseif') do
        local ei = self:next()
        local c = self:parse_expr()
        self:expect_kw('then')
        n.clauses[#n.clauses + 1] =
          { cond = c, body = self:parse_block(), line = ei.line, col = ei.col }
      end
      if self:check_kw('else') then
        local e = self:next()
        n.orelse = self:parse_block()
        n.orelse_line, n.orelse_col = e.line, e.col
      end
      self:expect_kw('end')
      return n
    end

    if kw == 'for' then
      self:next()
      local first = self:expect_name()

      if self:check_op('=') then
        self:next()
        local n = node('NumericFor', tok.line, tok.col)
        n.var = name_def(first, 'loop')
        n.start = self:parse_expr()
        self:expect_op(',')
        n.stop = self:parse_expr()
        if self:accept_op(',') then n.step = self:parse_expr() end
        self:expect_kw('do')
        n.body = self:parse_block()
        self:expect_kw('end')
        return n
      end

      local n = node('GenericFor', tok.line, tok.col)
      n.names = { name_def(first, 'loop') }
      while self:accept_op(',') do
        n.names[#n.names + 1] = name_def(self:expect_name(), 'loop')
      end
      self:expect_kw('in')
      n.exprs = {}
      repeat
        n.exprs[#n.exprs + 1] = self:parse_expr()
      until not self:accept_op(',')
      self:expect_kw('do')
      n.body = self:parse_block()
      self:expect_kw('end')
      return n
    end

    if kw == 'function' then
      self:next()
      local n = node('FuncStat', tok.line, tok.col)
      local target, is_method = self:parse_func_name()
      n.target = target
      n.is_method = is_method
      n.func = self:parse_func_body(tok.line, tok.col, is_method)
      return n
    end

    if kw == 'local' then
      self:next()

      if self:check_kw('function') then
        local fkw = self:next()
        local name = self:expect_name()
        local n = node('LocalFunc', tok.line, tok.col)
        -- The binding is in scope inside its own body, which is what makes
        -- `local function` recursive. The resolver adds it before descending.
        n.def = name_def(name, 'localfunc')
        n.func = self:parse_func_body(fkw.line, fkw.col, false)
        return n
      end

      local n = node('LocalStat', tok.line, tok.col)
      n.names = {}
      n.exprs = {}
      repeat
        local name = self:expect_name()
        local def = name_def(name, 'local')
        -- Lua 5.4 attributes: `local x <const>`, `local f <close>`. They are
        -- consumed so the file parses; neither affects reachability.
        if self:check_op('<') then
          self:next()
          self:expect_name()
          self:expect_op('>')
        end
        n.names[#n.names + 1] = def
      until not self:accept_op(',')

      if self:accept_op('=') then
        repeat
          n.exprs[#n.exprs + 1] = self:parse_expr()
        until not self:accept_op(',')
      end
      return n
    end
  end

  -- Everything else is either an assignment or an expression statement.
  local first = self:parse_suffixed(self:parse_primary())

  if self:check_op('=') or self:check_op(',') then
    local n = node('Assign', first.line, first.col)
    n.targets = { first }
    while self:accept_op(',') do
      n.targets[#n.targets + 1] = self:parse_suffixed(self:parse_primary())
    end
    self:expect_op('=')
    n.exprs = {}
    repeat
      n.exprs[#n.exprs + 1] = self:parse_expr()
    until not self:accept_op(',')

    for _, target in ipairs(n.targets) do
      if target.tag ~= 'Name' and target.tag ~= 'Index' then
        self:error('cannot assign to this expression', target)
      end
    end
    return n
  end

  if first.tag ~= 'Call' and first.tag ~= 'MethodCall' then
    self:error('syntax error near unexpected expression')
  end

  local n = node('CallStat', first.line, first.col)
  n.call = first
  return n
end

--- Parse Lua source into a Chunk node.
-- Returns `chunk, comments` on success, or `nil, message` on any lexical or
-- syntax error. Callers report and skip the file: a broken file must never
-- abort a whole run.
---@param src string
---@param chunkname string|nil name used in error messages; defaults to `'?'`
---@return deadcode.Node|nil chunk nil when `src` could not be parsed
---@return deadcode.Comment[]|string comments the comment list on success, the
--- error message when `chunk` is nil
function Parser.parse(src, chunkname)
  local tokens, comments = Lexer.tokenize(src, chunkname)
  if not tokens then
    return nil, comments -- second value is the error message
  end

  local parser = new_parser(tokens, chunkname)
  local ok, result = pcall(function()
    local body = parser:parse_block()
    if not parser:check('EOF') then
      parser:error(
        string.format("'<eof>' expected near '%s'", tostring(parser:peek() and parser:peek().value))
      )
    end
    local chunk = node('Chunk', 1, 1)
    chunk.body = body
    return chunk
  end)

  if not ok then
    -- On failure pcall puts the thrown value where the first return would be.
    ---@type any
    local err = result
    if type(err) == 'table' and err.deadcode_parse then
      ---@cast err deadcode.ParseError
      return nil, string.format('%s:%d: %s', err.chunkname, err.line, err.msg)
    end
    return nil, tostring(err)
  end

  return result, comments
end

return Parser
