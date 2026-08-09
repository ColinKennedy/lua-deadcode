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
-- A field is only *defined* when the table it is written to is one this file
-- built. `vim.opt_local.number = false` writes into an API we cannot see, and
-- nothing here can prove the host does not read it back, so it is a use of
-- someone else's table rather than a definition of ours. See `owns_table`.
--
-- Direct recursion is not counted as use: a function whose only caller is
-- itself is still dead. Mutual recursion is not detected.

--- A table that fields get defined on, tracked only so that the definitions can
--- be withdrawn once the table stops being ours to reason about. Either a
--- binding (`local M = {}`) or the stand-in for every table reached as
--- `<anything>.name`, since fields are matched by name and no more can be known.
---@class deadcode.TableOwner
---@field opaque boolean true once the table left this codebase's sight - it was
--- handed to a call, stored in a table we do not own, or read with a computed
--- key - after which none of its fields can be proven dead

--- A binding resolved exactly, by lexical scope.
---@class deadcode.Symbol : deadcode.TableOwner
---@field name string
---@field file string
---@field line integer
---@field col integer
---@field type deadcode.FindingType
---@field reads integer reads from outside the function this symbol binds
---@field self_reads integer reads from inside it; recursion is not use
---@field writes integer assignments after the declaration
---@field implicit boolean true for a method's unwritten `self`
---@field defining_function deadcode.Node|nil the Function node this symbol
--- binds, when it binds one; what `self_reads` is measured against
---@field table_value boolean true when the binding holds a table this file
--- constructs, which is what makes `name.field = ...` a definition

--- A finding before suppression, ignore rules and formatting are applied. It
--- is exactly what `CodeItem.new` wants, so collecting is a straight handover.
---@class deadcode.RawFinding : deadcode.CodeItem.Opts
---@field line integer
---@field col integer
---@field implicit boolean|nil set only for findings that came from a symbol

--- Where a global or field was defined. Globals and fields are matched by name
--- across the program, so a site is all that survives of the definition - and
--- if nothing reads the name, the site is reported as it stands.
---@class deadcode.DefinitionSite : deadcode.RawFinding
---@field owners deadcode.TableOwner[]|nil every table this field had to be
--- reached through; the site is withdrawn once any of them turns opaque

--- Everything learned about the program, accumulated across every file so that
--- cross-file questions can be answered once the whole run has been walked.
---@class deadcode.Program
---@field symbols deadcode.Symbol[] exact, lexically resolved bindings
---@field globals_defined table<string, deadcode.DefinitionSite[]>
---@field globals_used table<string, integer> name -> total read count
---@field globals_self table<string, integer> reads inside the definition itself
---@field fields_defined table<string, deadcode.DefinitionSite[]>
---@field fields_used table<string, integer>
---@field fields_self table<string, integer>
---@field findings deadcode.RawFinding[] findings needing no cross-file context
---@field seen_definition table<string, boolean> de-dupes repeat definitions
---@field field_owners table<string, deadcode.TableOwner> one shared record per
--- field name, standing in for every table ever reached as `<anything>.name`

--- Walks a parsed chunk and records definitions and uses.
---@class deadcode.Resolver
local Resolver = {}

-- --------------------------------------------------------------- program

--- Shared accumulator across all analysed files.
---@return deadcode.Program
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
    field_owners = {}, -- name -> the opacity shared by every `X.name` table
  }
end

-- --------------------------------------------------------------- helpers

--- True when `expr` is a direct `require(...)`, which is reported under its own
--- code rather than as an ordinary unused variable.
---@param expr deadcode.Node|nil
---@return boolean|nil
local function is_require_call(expr)
  return expr
    and expr.tag == 'Call'
    and expr.func
    and expr.func.tag == 'Name'
    and expr.func.name == 'require'
end

--- The literal field name an Index node reads, or nil when it is dynamic.
---@param node deadcode.Node an Index node
---@return string|nil
local function static_key(node)
  if node.dot then return node.key.value end
  if node.key and node.key.tag == 'String' then return node.key.value end
  return nil
end

--- True when `expr` evaluates to a table built right here, rather than to
-- something handed over by a `require`, a call, or the host environment.
-- `setmetatable({...}, mt)` counts: the table is still one this file made, and
-- the class idiom that spells it that way is far too common to lose.
---@param expr deadcode.Node|nil
---@return boolean
local function constructs_table(expr)
  if not expr then return false end
  if expr.tag == 'Table' then return true end
  if expr.tag == 'Paren' then return constructs_table(expr.expr) end
  if
    expr.tag == 'Call'
    and expr.func.tag == 'Name'
    and expr.func.name == 'setmetatable'
    and expr.args[1]
  then
    return constructs_table(expr.args[1])
  end
  return false
end

--- Static truthiness of an expression, or nil when unknown.
-- Only `nil` and `false` are falsy in Lua: 0 and "" are both true. Getting
-- this wrong is the classic way to produce bogus dead-branch findings.
---@param expr deadcode.Node|nil
---@return boolean|nil nil when the value cannot be decided statically
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

--- One lexical scope. `parent` is nil for the outermost one.
---@class deadcode.Scope
---@field parent deadcode.Scope|nil
---@field names table<string, deadcode.Symbol>

--- A label definition site, kept until its enclosing function is finished.
---@class deadcode.LabelSite
---@field name string
---@field line integer
---@field col integer

--- Label bookkeeping for one function. `goto` cannot cross a function
--- boundary, so this is saved and restored around every function body.
---@class deadcode.LabelState
---@field defined deadcode.LabelSite[]
---@field used table<string, boolean>

--- The name of a field or global whose definition is currently being walked,
--- so that reads inside it can be told apart from reads by anyone else.
---@class deadcode.DefiningEntry
---@field kind '"global"'|'"field"'
---@field name string

--- Per-file walk state.
---@class deadcode.Analyser
---@field program deadcode.Program shared across every file in the run
---@field file string the file being walked
---@field args deadcode.Args
---@field scope deadcode.Scope|nil nil outside any push/pop pair
---@field func_stack deadcode.Node[] Function nodes currently being walked
---@field defining deadcode.DefiningEntry[]
---@field labels deadcode.LabelState|nil nil outside any function body
local Analyser = {}
Analyser.__index = Analyser

---@param program deadcode.Program
---@param file string
---@param args deadcode.Args|nil
---@return deadcode.Analyser
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

--- Open a scope. Every `push_scope` is paired with a `pop_scope`, which is why
--- the code below may treat `self.scope` as present.
function Analyser:push_scope()
  self.scope = { parent = self.scope, names = {} }
end

function Analyser:pop_scope()
  self.scope = assert(self.scope).parent
end

--- Find the innermost binding of `name`.
---@param name string
---@return deadcode.Symbol|nil nil when the name is not a local, i.e. a global
function Analyser:resolve(name)
  local scope = self.scope
  while scope do
    local sym = scope.names[name]
    if sym then return sym end
    scope = scope.parent
  end
  return nil
end

--- Bind a name in the current scope and register it with the program.
---@param def deadcode.Node a NameDef node
---@param type_ deadcode.FindingType how an unused binding should be reported
---@param defining_function deadcode.Node|nil the Function this name binds
---@return deadcode.Symbol
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
    table_value = false,
    opaque = false,
  }
  assert(self.scope).names[def.name] = sym
  local symbols = self.program.symbols
  symbols[#symbols + 1] = sym
  return sym
end

--- True when a read of `sym` occurs inside the function `sym` itself binds.
---@param sym deadcode.Symbol
---@return boolean
function Analyser:is_self_reference(sym)
  if not sym.defining_function then return false end
  for i = #self.func_stack, 1, -1 do
    if self.func_stack[i] == sym.defining_function then return true end
  end
  return false
end

--- True when `obj` names a table this file built, which is the only case where
--- `obj.key = value` may be read as *defining* a field.
---
--- Assigning through anything else reaches a table we did not make - `vim.bo[b]`,
--- `os`, a module a `require` returned - and the receiver is free to read the
--- value back at any point we cannot see. Calling that a definition and then
--- reporting it unused says something about the host's code that this tool is
--- in no position to say.
---
--- A global is deliberately excluded: nothing distinguishes a global table of
--- ours from `vim` or `string`, and guessing wrong is precisely the mistake
--- above. The implicit `self` of a method is included, because a method
--- assigning `self.x` is writing to an instance of the very class being
--- analysed - the OOP spelling of the module-table idiom.
---@param obj deadcode.Node the table being written through
---@return boolean
function Analyser:owns_table(obj)
  if obj.tag ~= 'Name' then return false end
  local sym = self:resolve(obj.name)
  if not sym then return false end
  return sym.table_value or sym.implicit
end

--- The opacity record shared by every table ever reached as `<anything>.name`.
--- Fields are matched by name program-wide, so their contents can only be
--- tracked by name too.
---@param name string
---@return deadcode.TableOwner
function Analyser:field_owner(name)
  local owners = self.program.field_owners
  local owner = owners[name]
  if not owner then
    owner = { opaque = false }
    owners[name] = owner
  end
  return owner
end

--- Give up on proving anything about the table `expr` denotes.
---
--- Called wherever a table we built reaches code this tool cannot follow: an
--- argument to a call, a slot in a table we do not own, an index with a
--- computed key. Any of those can read any field, so the fields defined on it
--- stop being reportable. Anything else - a literal, a global, a computed
--- expression - has no definitions recorded against it to withdraw.
---@param expr deadcode.Node|nil the expression handing the table over
function Analyser:mark_opaque(expr)
  if not expr then return end
  if expr.tag == 'Paren' then
    self:mark_opaque(expr.expr)
    return
  end

  if expr.tag == 'Name' then
    local sym = self:resolve(expr.name)
    if sym and sym.table_value then sym.opaque = true end
    return
  end

  if expr.tag == 'Index' then
    local key = static_key(expr)
    if key then self:field_owner(key).opaque = true end
  end
end

--- True for a call to `setmetatable`, which hands the table to the VM rather
--- than to a reader: `local M = setmetatable({}, mt)` is the class idiom, and
--- treating it as an escape would give up on every class in the codebase.
---@param node deadcode.Node a Call node
---@return boolean
local function is_setmetatable_call(node)
  return node.func.tag == 'Name' and node.func.name == 'setmetatable'
end

--- Is the field/global currently being defined the one now being read?
---@param kind '"global"'|'"field"'
---@param name string
---@return boolean
function Analyser:is_defining(kind, name)
  for i = #self.defining, 1, -1 do
    local entry = self.defining[i]
    if entry.kind == kind and entry.name == name then return true end
  end
  return false
end

--- Count a read of `name`, against its binding if it has one and against the
--- program-wide global tally if it does not.
---@param name string
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

--- Count a read of a field or method name, program-wide.
---@param name string
function Analyser:use_field(name)
  local program = self.program
  program.fields_used[name] = (program.fields_used[name] or 0) + 1
  if self:is_defining('field', name) then
    program.fields_self[name] = (program.fields_self[name] or 0) + 1
  end
end

--- Records a definition site, keeping only the first per (file, kind, name)
-- so that repeated assignment does not multiply findings.
---@param bucket table<string, deadcode.DefinitionSite[]>
---@param kind '"global"'|'"field"'
---@param name string
---@param line integer
---@param col integer
---@param type_ deadcode.FindingType
---@param owners deadcode.TableOwner[]|nil the tables the name was defined on
function Analyser:record_definition(bucket, kind, name, line, col, type_, owners)
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
    owners = owners,
  }
end

--- Record an assignment to an unbound name as a global definition.
---@param name string
---@param line integer
---@param col integer
function Analyser:define_global(name, line, col)
  self:record_definition(self.program.globals_defined, 'global', name, line, col, 'global')
end

--- Record a definition of a table field or method.
---@param name string
---@param line integer
---@param col integer
---@param type_ deadcode.FindingType `'field'` or `'method'`
---@param owners deadcode.TableOwner[]|nil the tables it was defined on
function Analyser:define_field(name, line, col, type_, owners)
  self:record_definition(self.program.fields_defined, 'field', name, line, col, type_, owners)
end

--- Record a finding that needs no cross-file information to decide.
---@param type_ deadcode.FindingType
---@param name string
---@param line integer
---@param col integer
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

-- --------------------------------------------------------------- expressions

--- Walk an expression, counting every name and field it reads.
---@param node deadcode.Node|nil nil is accepted so that optional children
--- (`NumericFor.step`, an absent assignment value) need no guard at the call
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
      -- `t[k]` with a computed key can name any field in `t`, so no field of
      -- `t` is provably dead from here on.
      self:mark_opaque(node.obj)
      self:expr(node.key)
    end
  elseif tag == 'Call' then
    self:expr(node.func)
    local hands_over = not is_setmetatable_call(node)
    for _, arg in ipairs(node.args) do
      if hands_over then self:mark_opaque(arg) end
      self:expr(arg)
    end
  elseif tag == 'MethodCall' then
    self:expr(node.obj)
    self:use_field(node.method)
    for _, arg in ipairs(node.args) do
      self:mark_opaque(arg)
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

--- Walk a function: its parameters bind in a scope of their own, and its
--- labels are tracked separately because `goto` cannot leave a function.
---@param node deadcode.Node a Function node
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

--- Report every label in the function just walked that no `goto` reached.
function Analyser:finish_labels()
  for _, label in ipairs(assert(self.labels).defined) do
    if not assert(self.labels).used[label.name] then
      self:add_finding('label', label.name, label.line, label.col)
    end
  end
end

-- --------------------------------------------------------------- statements

--- A table constructor counts as defining fields only when it is bound to a
-- name (`local M = { foo = ... }`), which is how modules are built. An inline
-- constructor passed as an argument (`f{ verbose = true }`) is configuration,
-- not definition, and treating it as one is a reliable false-positive factory.
---@param expr deadcode.Node|nil the value being bound; ignored unless a Table
---@param owners deadcode.TableOwner[]|nil the tables it is reached through
function Analyser:define_table_fields(expr, owners)
  if not expr or expr.tag ~= 'Table' then return end
  for _, field in ipairs(expr.fields) do
    if field.kind == 'named' then
      self:define_field(field.name, field.line, field.col, 'field', owners)
    end
  end
end

--- Walk one assignment target, and the value bound to it.
---@param target deadcode.Node a Name or Index node
---@param value deadcode.Node|nil nil when there is no matching value
---@param field_type deadcode.FindingType|nil `'field'` or `'method'`, used when
--- the target is `t.k`; defaults to `'field'`
function Analyser:assign_target(target, value, field_type)
  if target.tag == 'Name' then
    local sym = self:resolve(target.name)
    if sym then
      sym.writes = sym.writes + 1
      -- `local M; M = {}` builds the module table one statement late; the
      -- binding owns a table of ours from here on, exactly as if it had been
      -- written `local M = {}`.
      if constructs_table(value) then sym.table_value = true end
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
    local owned = self:owns_table(target.obj)

    -- Storing into a table we did not build puts whatever we stored within
    -- reach of code this tool cannot see.
    if not owned then self:mark_opaque(value) end

    if not key then
      self:expr(target.key)
    elseif owned then
      local owner = self:resolve(target.obj.name)
      self:define_field(
        key,
        target.key_line or target.line,
        target.key_col or target.col,
        field_type or 'field',
        { owner }
      )
      -- `M.MAP = { a = 1 }` puts `a` behind two tables: reading `M` or `M.MAP`
      -- dynamically hides `a` just as thoroughly, so it answers to both.
      self:define_table_fields(value, { owner, self:field_owner(key) })
      if value and value.tag == 'Function' then
        self.defining[#self.defining + 1] = { kind = 'field', name = key }
        self:expr(value)
        self.defining[#self.defining] = nil
        return
      end
    end
    -- A static key written through a table we do not own defines nothing. The
    -- value is still walked below, so whatever it reads still counts.
  end

  if value then self:expr(value) end
end

--- Walk a block in a scope of its own.
---@param block_node deadcode.Node a Block node
function Analyser:block(block_node)
  self:push_scope()
  self:block_stats(block_node)
  self:pop_scope()
end

--- Walks statements without opening a scope; used where the caller needs the
-- scope to outlive the statement list (`repeat ... until <cond>`).
---@param block_node deadcode.Node a Block node
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

--- Walk one statement.
---@param node deadcode.Node
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
      local sym = self:declare(def, type_, defining_function)
      sym.table_value = constructs_table(value)
      self:define_table_fields(value, { sym })
    end
  elseif tag == 'LocalFunc' then
    -- The name is in scope inside its own body: that is what makes
    -- `local function` recursive.
    local sym = self:declare(node.def, 'function', node.func)
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

--- True when any table this definition sits behind has stopped being provable.
---@param site deadcode.DefinitionSite
---@return boolean
local function is_opaque(site)
  if not site.owners then return false end
  for _, owner in ipairs(site.owners) do
    if owner.opaque then return true end
  end
  return false
end

-- --------------------------------------------------------------- entrypoint

--- Analyse one parsed chunk into `program`.
---@param program deadcode.Program mutated in place
---@param chunk deadcode.Node a Chunk node
---@param file string the path to report findings against
---@param args deadcode.Args|nil
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
---@param program deadcode.Program
---@param args deadcode.Args
---@return deadcode.RawFinding[] in no particular order; the report sorts them
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
        -- Decided here rather than at the definition, because a table usually
        -- escapes further down the file than the field was written on it.
        if not is_opaque(site) then raw[#raw + 1] = site end
      end
    end
  end

  for _, finding in ipairs(program.findings) do
    raw[#raw + 1] = finding
  end

  return raw
end

return Resolver
