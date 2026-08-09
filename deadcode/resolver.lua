-- Walks a parsed chunk and records definitions and uses.
--
-- Two resolution strategies, chosen per construct by what Lua can actually
-- guarantee statically:
--
--   * Locals, parameters, loop variables and labels are resolved EXACTLY, by
--     lexical scope. Lua's scoping rules are fully static, so a finding about
--     one of these cannot be a name collision. This is the main accuracy win
--     over the Python original, which matches every kind of name by string.
--
--   * Globals and table fields/methods are matched by NAME across the whole
--     program, because `t.foo` cannot be resolved without type inference.
--     Two unrelated tables with a `foo` field share one bucket, so a use of
--     either marks both used. That under-reports; it never over-reports.
--
-- Direct recursion is not counted as use: a function whose only caller is
-- itself is still dead. Mutual recursion is not detected.

local Resolver = {}

-- --------------------------------------------------------------- program

--- Shared accumulator across all analysed files.
function Resolver.new_program()
  return {
    symbols = {}, -- exact, lexically resolved bindings
    globals_defined = {}, -- name -> ordered list of definition sites
    globals_used = {}, -- name -> total read count
    globals_self = {}, -- name -> reads occurring inside its own definition
    fields_defined = {}, -- name -> ordered list of definition sites
    fields_used = {}, -- name -> total read count
    fields_self = {}, -- name -> reads inside its own definition
    findings = {}, -- findings that need no cross-file information
    seen_definition = {}, -- de-dupes repeated definitions of one name per file
  }
end

-- --------------------------------------------------------------- helpers

local function is_require_call(expr)
  return expr
    and expr.tag == 'Call'
    and expr.func
    and expr.func.tag == 'Name'
    and expr.func.name == 'require'
end

--- Static truthiness of an expression, or nil when unknown.
-- Only `nil` and `false` are falsy in Lua: 0 and "" are both true. Getting
-- this wrong is the classic way to produce bogus dead-branch findings.
local function truthiness(expr)
  if not expr then return nil end
  local tag = expr.tag

  if tag == 'Nil' or tag == 'False' then return false end
  if tag == 'True' or tag == 'Number' or tag == 'String' or tag == 'Table' or tag == 'Function' then
    return true
  end
  if tag == 'Paren' then return truthiness(expr.expr) end

  if tag == 'UnOp' then
    if expr.op == 'not' then
      local inner = truthiness(expr.operand)
      if inner == nil then return nil end
      return not inner
    end
    return nil
  end

  if tag == 'BinOp' then
    if expr.op == 'and' then
      local l = truthiness(expr.left)
      if l == false then return false end
      if l == true then return truthiness(expr.right) end
      return nil
    elseif expr.op == 'or' then
      local l = truthiness(expr.left)
      if l == true then return true end
      if l == false then return truthiness(expr.right) end
      return nil
    end
    return nil
  end

  return nil
end

-- --------------------------------------------------------------- analyser

local Analyser = {}
Analyser.__index = Analyser

local function new_analyser(program, file, args)
  return setmetatable({
    program = program,
    file = file,
    args = args or {},
    scope = nil,
    func_stack = {}, -- Function nodes currently being walked
    defining = {}, -- {kind, name} of the field/global being defined
    labels = nil, -- per-function label bookkeeping
  }, Analyser)
end

function Analyser:push_scope()
  self.scope = { parent = self.scope, names = {} }
end

function Analyser:pop_scope()
  self.scope = self.scope.parent
end

function Analyser:resolve(name)
  local scope = self.scope
  while scope do
    local sym = scope.names[name]
    if sym then return sym end
    scope = scope.parent
  end
  return nil
end

function Analyser:declare(def, type_, defining_function)
  local sym = {
    name = def.name,
    file = self.file,
    line = def.line,
    col = def.col,
    type = type_,
    reads = 0,
    self_reads = 0,
    writes = 0,
    implicit = def.implicit or false,
    defining_function = defining_function,
  }
  self.scope.names[def.name] = sym
  local symbols = self.program.symbols
  symbols[#symbols + 1] = sym
  return sym
end

--- True when a read of `sym` occurs inside the function `sym` itself binds.
function Analyser:is_self_reference(sym)
  if not sym.defining_function then return false end
  for i = #self.func_stack, 1, -1 do
    if self.func_stack[i] == sym.defining_function then return true end
  end
  return false
end

--- Is the field/global currently being defined the one now being read?
function Analyser:is_defining(kind, name)
  for i = #self.defining, 1, -1 do
    local entry = self.defining[i]
    if entry.kind == kind and entry.name == name then return true end
  end
  return false
end

function Analyser:read_name(name)
  local sym = self:resolve(name)
  if sym then
    if self:is_self_reference(sym) then
      sym.self_reads = sym.self_reads + 1
    else
      sym.reads = sym.reads + 1
    end
    return
  end

  local program = self.program
  program.globals_used[name] = (program.globals_used[name] or 0) + 1
  if self:is_defining('global', name) then
    program.globals_self[name] = (program.globals_self[name] or 0) + 1
  end
end

function Analyser:use_field(name)
  local program = self.program
  program.fields_used[name] = (program.fields_used[name] or 0) + 1
  if self:is_defining('field', name) then
    program.fields_self[name] = (program.fields_self[name] or 0) + 1
  end
end

--- Records a definition site, keeping only the first per (file, kind, name)
-- so that repeated assignment does not multiply findings.
function Analyser:record_definition(bucket, kind, name, line, col, type_)
  local key = self.file .. '\0' .. kind .. '\0' .. name
  if self.program.seen_definition[key] then return end
  self.program.seen_definition[key] = true

  local list = bucket[name]
  if not list then
    list = {}
    bucket[name] = list
  end
  list[#list + 1] = {
    name = name,
    file = self.file,
    line = line,
    col = col,
    type = type_,
  }
end

function Analyser:define_global(name, line, col)
  self:record_definition(self.program.globals_defined, 'global', name, line, col, 'global')
end

function Analyser:define_field(name, line, col, type_)
  self:record_definition(self.program.fields_defined, 'field', name, line, col, type_)
end

function Analyser:add_finding(type_, name, line, col)
  local findings = self.program.findings
  findings[#findings + 1] = {
    name = name,
    file = self.file,
    line = line,
    col = col,
    type = type_,
  }
end

--- The literal field name an Index node reads, or nil when it is dynamic.
local function static_key(node)
  if node.dot then return node.key.value end
  if node.key and node.key.tag == 'String' then return node.key.value end
  return nil
end

-- --------------------------------------------------------------- expressions

function Analyser:expr(node)
  if not node then return end
  local tag = node.tag

  if tag == 'Name' then
    self:read_name(node.name)
  elseif tag == 'Index' then
    self:expr(node.obj)
    local key = static_key(node)
    if key then
      self:use_field(key)
    else
      self:expr(node.key)
    end
  elseif tag == 'Call' then
    self:expr(node.func)
    for _, arg in ipairs(node.args) do
      self:expr(arg)
    end
  elseif tag == 'MethodCall' then
    self:expr(node.obj)
    self:use_field(node.method)
    for _, arg in ipairs(node.args) do
      self:expr(arg)
    end
  elseif tag == 'Function' then
    self:function_body(node)
  elseif tag == 'Table' then
    for _, field in ipairs(node.fields) do
      if field.kind == 'bracket' then self:expr(field.key) end
      self:expr(field.value)
    end
  elseif tag == 'BinOp' then
    self:expr(node.left)
    self:expr(node.right)
  elseif tag == 'UnOp' then
    self:expr(node.operand)
  elseif tag == 'Paren' then
    self:expr(node.expr)
  end
  -- Nil / True / False / Number / String / Vararg bind nothing and use nothing.
end

function Analyser:function_body(node)
  self.func_stack[#self.func_stack + 1] = node

  local saved_labels = self.labels
  self.labels = { defined = {}, used = {} }

  self:push_scope()
  for _, param in ipairs(node.params) do
    self:declare(param, 'parameter')
  end
  self:block(node.body)
  self:pop_scope()

  self:finish_labels()
  self.labels = saved_labels

  self.func_stack[#self.func_stack] = nil
end

function Analyser:finish_labels()
  for _, label in ipairs(self.labels.defined) do
    if not self.labels.used[label.name] then
      self:add_finding('label', label.name, label.line, label.col)
    end
  end
end

-- --------------------------------------------------------------- statements

--- A table constructor counts as defining fields only when it is bound to a
-- name (`local M = { foo = ... }`), which is how modules are built. An inline
-- constructor passed as an argument (`f{ verbose = true }`) is configuration,
-- not definition, and treating it as one is a reliable false-positive factory.
function Analyser:define_table_fields(expr)
  if not expr or expr.tag ~= 'Table' then return end
  for _, field in ipairs(expr.fields) do
    if field.kind == 'named' then self:define_field(field.name, field.line, field.col, 'field') end
  end
end

--- @param field_type 'field' or 'method', used when the target is `t.k`
function Analyser:assign_target(target, value, field_type)
  if target.tag == 'Name' then
    local sym = self:resolve(target.name)
    if sym then
      sym.writes = sym.writes + 1
      -- `local f; f = function() ... end` makes `f` genuinely recursive, so
      -- remember which function body counts as "inside itself", and report it
      -- as a function rather than as a plain variable.
      if value and value.tag == 'Function' then
        if not sym.defining_function then sym.defining_function = value end
        if sym.type == 'variable' then sym.type = 'function' end
      end
    else
      self:define_global(target.name, target.line, target.col)
      self:define_table_fields(value)
      if value and value.tag == 'Function' then
        self.defining[#self.defining + 1] = { kind = 'global', name = target.name }
        self:expr(value)
        self.defining[#self.defining] = nil
        return
      end
    end
  elseif target.tag == 'Index' then
    self:expr(target.obj)
    local key = static_key(target)
    if key then
      self:define_field(
        key,
        target.key_line or target.line,
        target.key_col or target.col,
        field_type or 'field'
      )
      self:define_table_fields(value)
      if value and value.tag == 'Function' then
        self.defining[#self.defining + 1] = { kind = 'field', name = key }
        self:expr(value)
        self.defining[#self.defining] = nil
        return
      end
    else
      self:expr(target.key)
    end
  end

  if value then self:expr(value) end
end

function Analyser:block(block_node)
  self:push_scope()
  self:block_stats(block_node)
  self:pop_scope()
end

--- Walks statements without opening a scope; used where the caller needs the
-- scope to outlive the statement list (`repeat ... until <cond>`).
function Analyser:block_stats(block_node)
  local stats = block_node.stats
  for i = 1, #stats do
    local stat = stats[i]
    self:stat(stat)

    if (stat.tag == 'Break' or stat.tag == 'Goto') and stats[i + 1] then
      local next_stat = stats[i + 1]
      self:add_finding(
        'unreachable',
        stat.tag == 'Break' and 'break' or 'goto',
        next_stat.line,
        next_stat.col
      )
    end
  end
end

function Analyser:stat(node)
  local tag = node.tag

  if tag == 'LocalStat' then
    -- Initialisers are evaluated before the names come into scope, so
    -- `local x = x` reads the outer `x`. Visit values first.
    for _, value in ipairs(node.exprs) do
      self:expr(value)
    end
    for index, def in ipairs(node.names) do
      local value = node.exprs[index]
      local type_ = 'variable'
      local defining_function
      if is_require_call(value) then
        type_ = 'require'
      elseif value and value.tag == 'Function' then
        type_ = 'function'
        defining_function = value
      end
      self:declare(def, type_, defining_function)
      self:define_table_fields(value)
    end
  elseif tag == 'LocalFunc' then
    -- The name is in scope inside its own body: that is what makes
    -- `local function` recursive.
    local sym = self:declare(node.name, 'function', node.func)
    sym.defining_function = node.func
    self:expr(node.func)
  elseif tag == 'FuncStat' then
    -- `function T:m()` is a method, `function T.f()` a plain field.
    self:assign_target(node.target, node.func, node.is_method and 'method' or 'field')
  elseif tag == 'Assign' then
    for index, target in ipairs(node.targets) do
      self:assign_target(target, node.exprs[index])
    end
    -- Values with no matching target are still evaluated, so still count.
    for index = #node.targets + 1, #node.exprs do
      self:expr(node.exprs[index])
    end
  elseif tag == 'CallStat' then
    self:expr(node.call)
  elseif tag == 'Do' then
    self:block(node.body)
  elseif tag == 'While' then
    self:expr(node.cond)
    if truthiness(node.cond) == false then
      self:add_finding('dead_branch', 'while', node.line, node.col)
    end
    self:block(node.body)
  elseif tag == 'Repeat' then
    -- `until` sees the body's locals, so one scope spans both.
    self:push_scope()
    self:block_stats(node.body)
    self:expr(node.cond)
    self:pop_scope()
  elseif tag == 'If' then
    local taken_earlier = false
    for _, clause in ipairs(node.clauses) do
      self:expr(clause.cond)
      local value = truthiness(clause.cond)
      if taken_earlier then
        self:add_finding('dead_branch', 'if', clause.line, clause.col)
      elseif value == false then
        self:add_finding('dead_branch', 'if', clause.line, clause.col)
      end
      if value == true then taken_earlier = true end
      self:block(clause.body)
    end
    if node.orelse then
      if taken_earlier then
        self:add_finding('dead_branch', 'if', node.orelse_line, node.orelse_col)
      end
      self:block(node.orelse)
    end
  elseif tag == 'NumericFor' then
    self:expr(node.start)
    self:expr(node.stop)
    self:expr(node.step)
    self:push_scope()
    self:declare(node.var, 'loop_variable')
    self:block_stats(node.body)
    self:pop_scope()
  elseif tag == 'GenericFor' then
    for _, value in ipairs(node.exprs) do
      self:expr(value)
    end
    self:push_scope()
    for _, def in ipairs(node.names) do
      self:declare(def, 'loop_variable')
    end
    self:block_stats(node.body)
    self:pop_scope()
  elseif tag == 'Return' then
    for _, value in ipairs(node.exprs) do
      self:expr(value)
    end
  elseif tag == 'Label' then
    if self.labels then
      local defined = self.labels.defined
      defined[#defined + 1] = { name = node.name, line = node.line, col = node.col }
    end
  elseif tag == 'Goto' then
    if self.labels then self.labels.used[node.label] = true end
  end
  -- Break has no children.
end

-- --------------------------------------------------------------- entrypoint

--- Analyse one parsed chunk into `program`.
function Resolver.analyse(program, chunk, file, args)
  local analyser = new_analyser(program, file, args)

  if #chunk.body.stats == 0 then
    analyser:add_finding('empty_file', file, 1, 1)
    return
  end

  -- The top level of a chunk is the body of an implicit vararg function.
  local top = { tag = 'Function', params = {}, body = chunk.body, line = 1, col = 1 }
  analyser:function_body(top)
end

--- Turn accumulated state into a flat list of raw findings.
-- Cross-file questions ("is this global read anywhere?") are answered here,
-- once every file has been walked.
function Resolver.collect(program, args)
  local raw = {}

  for _, sym in ipairs(program.symbols) do
    if sym.reads == 0 then
      local report = true
      if sym.type == 'parameter' and not args.check_params then report = false end
      if report then
        raw[#raw + 1] = {
          name = sym.name,
          file = sym.file,
          line = sym.line,
          col = sym.col,
          type = sym.type,
          implicit = sym.implicit,
        }
      end
    end
  end

  for name, sites in pairs(program.globals_defined) do
    local used = program.globals_used[name] or 0
    local self_used = program.globals_self[name] or 0
    if used <= self_used then
      for _, site in ipairs(sites) do
        raw[#raw + 1] = site
      end
    end
  end

  for name, sites in pairs(program.fields_defined) do
    local used = program.fields_used[name] or 0
    local self_used = program.fields_self[name] or 0
    if used <= self_used then
      for _, site in ipairs(sites) do
        raw[#raw + 1] = site
      end
    end
  end

  for _, finding in ipairs(program.findings) do
    raw[#raw + 1] = finding
  end

  return raw
end

return Resolver
