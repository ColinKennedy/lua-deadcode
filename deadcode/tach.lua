-- Read a `tach.lua`, and act on the part of it this tool has an answer for.
--
-- tach (https://github.com/gauge-sh/tach) checks that a project's modules
-- import each other the way the project says they should, and its `tach.toml`
-- already answers a question this tool has to ask as well: which names a module
-- publishes on purpose.
--
-- That question matters here because reachability is inferred from what the
-- checkout itself uses, which is exactly right for an application and exactly
-- wrong for a library. A library's callers are somewhere else by definition, so
-- its whole API looks dead. The answer is a declaration, and tach already has
-- the vocabulary for one, so this reads the same table rather than inventing a
-- third spelling of the same idea.
--
-- `tach.lua` is `tach.toml`'s schema written as a Lua table: the same keys, the
-- same values, the same defaults. Every key tach accepts is accepted here and
-- an unknown one is refused, so a file shared with tach loads unchanged. Most
-- of those keys describe an import graph, which this tool does not check; they
-- are validated and then ignored. What is acted on is listed on `tach.compile`.

local Args = require('deadcode.args')
local patterns = require('deadcode.patterns')

--- Read a `tach.lua`, and act on the part of it this tool has an answer for.
---@class deadcode.tach
local tach = {}

tach.FILENAME = 'tach.lua'

--- Every top-level key `tach.toml` accepts, and how each is checked here.
--
-- "opaque" means the type is validated and nothing more: `cache`, `external`,
-- `map` and `plugins` configure work this tool does not do, and type-checking
-- their innards would mean asserting a schema it has no stake in and would have
-- to keep in step with tach forever.
local KEYS = {
  modules = 'entries',
  interfaces = 'entries',
  layers = 'layers',
  exclude = 'strings',
  source_roots = 'strings',
  exact = 'boolean',
  ignore_type_checking_imports = 'boolean',
  include_string_imports = 'boolean',
  forbid_circular_dependencies = 'boolean',
  layers_explicit_depends_on = 'boolean',
  respect_gitignore = 'respect_gitignore',
  root_module = 'root_module',
  rules = 'rules',
  cache = 'opaque',
  external = 'opaque',
  map = 'opaque',
  plugins = 'opaque',
}

--- Keys an `interfaces` entry may carry, and how each is checked.
--
-- The whole tach shape rather than the two fields that are read, so a config
-- shared with tach loads here unchanged. Anything outside this set is refused,
-- which is what tach does too: a misspelled key is a rule that silently is not
-- applied, and both tools exist to argue against exactly that.
local INTERFACE_KEYS = {
  expose = 'regexes',
  from = 'regexes',
  visibility = 'strings',
  data_types = 'data_types',
  exclusive = 'boolean',
}

--- Keys a `modules` entry may carry.
local MODULE_KEYS = {
  path = 'module_glob',
  paths = 'module_globs',
  depends_on = 'dependencies',
  cannot_depend_on = 'dependencies',
  depends_on_external = 'strings',
  cannot_depend_on_external = 'strings',
  layer = 'string',
  visibility = 'strings',
  utility = 'boolean',
  unchecked = 'boolean',
}

local ROOT_MODULE_TREATMENTS = {
  ignore = true,
  allow = true,
  dependenciesonly = true,
  forbid = true,
}

local RULE_LEVELS = { error = true, warn = true, off = true }

--- The rules tach names, all of which are accepted. `unused_ignore_directives`
--- is the one with an equivalent here; see `tach.compile`.
local RULES = {
  unused_ignore_directives = true,
  require_ignore_directive_reasons = true,
  unused_external_dependencies = true,
  local_imports = true,
}

local DATA_TYPES = { all = true, primitive = true }

--- What an interface with no `from` applies to, matching tach: every module.
local DEFAULT_FROM = { '.*' }

--- Where module names are resolved from when the file does not say, matching
--- tach: the directory the configuration itself lives in.
local DEFAULT_SOURCE_ROOTS = { '.' }

--- Finding kinds a declaration can vouch for.
--
-- An interface says "code outside this checkout reaches this name", which is a
-- statement only a name another file could reach can carry. It cannot make a
-- parameter, a loop variable, a label, an unreachable branch or an empty file
-- live, so those stay reported however the declaration is written - a
-- declaration that could silence them would be a way to switch the tool off by
-- accident.
local EXPOSABLE = {
  ['function'] = true,
  global = true,
  method = true,
  field = true,
}

--- The declared surface of one run, in the form the checks ask questions of.
---@class deadcode.Surface
---@field interfaces { expose: string[], from: string[] }[] compiled patterns
---@field modules { paths: string[], unchecked: boolean }[] compiled patterns
---@field source_roots string[] as written, for deriving module names
---@field disabled_codes table<string, boolean> `DCxx` codes the rules switch off

--- True for a dense array of strings and nothing else.
---@param value any
---@return boolean
local function is_string_list(value)
  if type(value) ~= 'table' then return false end
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  if count ~= #value then return false end
  for i = 1, #value do
    if type(value[i]) ~= 'string' then return false end
  end
  return true
end

--- Check one field of one `interfaces` or `modules` entry.
-- Collects problems rather than stopping at the first: someone fixing a config
-- file wants the list.
---@param kind string a value of `INTERFACE_KEYS` or `MODULE_KEYS`
---@param label string how a problem should name this field
---@param value any
---@param problems string[] appended to in place
local function check_field(kind, label, value, problems)
  if kind == 'boolean' then
    if type(value) ~= 'boolean' then problems[#problems + 1] = label .. ' must be true or false' end
  elseif kind == 'string' then
    if type(value) ~= 'string' then problems[#problems + 1] = label .. ' must be a string' end
  elseif kind == 'strings' then
    if not is_string_list(value) then
      problems[#problems + 1] = label .. ' must be a list of strings'
    end
  elseif kind == 'data_types' then
    if not DATA_TYPES[value] then
      problems[#problems + 1] = label .. " must be 'all' or 'primitive'"
    end
  elseif kind == 'regexes' then
    if not is_string_list(value) then
      problems[#problems + 1] = label .. ' must be a list of patterns'
    else
      for i = 1, #value do
        local _, reason = patterns.from_regex(value[i])
        if reason then problems[#problems + 1] = label .. " '" .. value[i] .. "': " .. reason end
      end
    end
  elseif kind == 'module_glob' or kind == 'module_globs' then
    if kind == 'module_globs' and not is_string_list(value) then
      problems[#problems + 1] = label .. ' must be a list of module paths'
      return
    end
    if kind == 'module_glob' and type(value) ~= 'string' then
      problems[#problems + 1] = label .. ' must be a module path'
      return
    end
    local list = kind == 'module_glob' and { value } or value
    for i = 1, #list do
      local _, reason = patterns.from_module_glob(list[i])
      if reason then problems[#problems + 1] = label .. " '" .. list[i] .. "': " .. reason end
    end
  elseif kind == 'dependencies' then
    -- tach lets a dependency be a bare path or `{ path = ..., deprecated = ... }`.
    -- Neither is ever read here, but a config this refuses to load is a config
    -- that cannot be shared with tach.
    if type(value) ~= 'table' then
      problems[#problems + 1] = label .. ' must be a list'
      return
    end
    for i = 1, #value do
      local entry = value[i]
      if type(entry) == 'table' then
        if type(entry.path) ~= 'string' then
          problems[#problems + 1] = label .. ' entries need a string `path`'
        end
      elseif type(entry) ~= 'string' then
        problems[#problems + 1] = label .. ' entries must be strings or tables'
      end
    end
  end
end

--- Validate a list of entries against one key table.
---@param entries any the raw `interfaces` or `modules` value
---@param keys table<string, string>
---@param name string `'interfaces'` or `'modules'`, for the problem text
---@param problems string[] appended to in place
local function check_entries(entries, keys, name, problems)
  if entries == nil then return end
  if type(entries) ~= 'table' or (next(entries) ~= nil and #entries == 0) then
    problems[#problems + 1] = name .. ' must be a list of tables'
    return
  end

  for index = 1, #entries do
    local entry = entries[index]
    local label = string.format('%s[%d]', name, index)
    if type(entry) ~= 'table' then
      problems[#problems + 1] = label .. ' must be a table'
    else
      for key, value in pairs(entry) do
        local kind = keys[key]
        if kind == nil then
          problems[#problems + 1] = label .. ": unknown setting '" .. tostring(key) .. "'"
        else
          check_field(kind, label .. '.' .. key, value, problems)
        end
      end
    end
  end
end

--- Check one top-level key.
---@param key string
---@param value any
---@param problems string[] appended to in place
local function check_key(key, value, problems)
  local kind = KEYS[key]

  if kind == nil then
    problems[#problems + 1] = "unknown tach setting '" .. tostring(key) .. "'"
  elseif kind == 'boolean' then
    if type(value) ~= 'boolean' then problems[#problems + 1] = key .. ' must be true or false' end
  elseif kind == 'strings' then
    if not is_string_list(value) then
      problems[#problems + 1] = key .. ' must be a list of strings'
    end
  elseif kind == 'layers' then
    -- tach writes a layer as a bare name or as `{ name = ..., closed = ... }`.
    if type(value) ~= 'table' then
      problems[#problems + 1] = 'layers must be a list'
    else
      for i = 1, #value do
        local entry = value[i]
        if type(entry) == 'table' then
          if type(entry.name) ~= 'string' then
            problems[#problems + 1] = 'layers entries need a string `name`'
          end
        elseif type(entry) ~= 'string' then
          problems[#problems + 1] = 'layers entries must be strings or tables'
        end
      end
    end
  elseif kind == 'respect_gitignore' then
    if value ~= true and value ~= false and value ~= 'if_git_repo' then
      problems[#problems + 1] = "respect_gitignore must be true, false or 'if_git_repo'"
    end
  elseif kind == 'root_module' then
    if not ROOT_MODULE_TREATMENTS[value] then
      problems[#problems + 1] =
        "root_module must be 'ignore', 'allow', 'dependenciesonly' or 'forbid'"
    end
  elseif kind == 'rules' then
    if type(value) ~= 'table' then
      problems[#problems + 1] = 'rules must be a table'
    else
      for rule, level in pairs(value) do
        if not RULES[rule] then
          problems[#problems + 1] = "unknown rule '" .. tostring(rule) .. "'"
        elseif not RULE_LEVELS[level] then
          problems[#problems + 1] = rule .. " must be 'error', 'warn' or 'off'"
        end
      end
    end
  elseif kind == 'opaque' then
    if type(value) ~= 'table' then problems[#problems + 1] = key .. ' must be a table' end
  end
end

--- Everything wrong with a tach configuration, as a sorted list.
---@param data table
---@return string[] empty when the table is usable
local function problems_with(data)
  local problems = {}

  for key, value in pairs(data) do
    check_key(key, value, problems)
  end

  check_entries(data.interfaces, INTERFACE_KEYS, 'interfaces', problems)
  for index = 1, #(data.interfaces or {}) do
    local entry = data.interfaces[index]
    if type(entry) == 'table' and entry.expose == nil then
      problems[#problems + 1] = string.format('interfaces[%d] needs an `expose` list', index)
    end
  end

  check_entries(data.modules, MODULE_KEYS, 'modules', problems)
  for index = 1, #(data.modules or {}) do
    local entry = data.modules[index]
    if type(entry) == 'table' and entry.path == nil and entry.paths == nil then
      problems[#problems + 1] = string.format('modules[%d] needs a `path` or `paths`', index)
    end
  end

  table.sort(problems)
  return problems
end

--- Translate a list of regexes, dropping any that will not compile.
--
-- Compiling twice - once to validate, once here - is deliberate: this runs
-- against a config already accepted, so a failure at this point cannot be
-- reported to anyone, and silently keeping a pattern that does not mean what it
-- says would be worse than dropping it.
---@param sources string[]
---@return string[] Lua patterns
local function compile_regexes(sources)
  local out = {}
  for i = 1, #sources do
    local pattern = patterns.from_regex(sources[i])
    if pattern then out[#out + 1] = pattern end
  end
  return out
end

--- Turn a validated tach table into the surface the checks consult.
--
-- What is acted on, and why:
--
--   `interfaces`    the declared public surface. `expose` names symbols and
--                   `from` names the modules that publish them; both halves
--                   have to match the same entry
--   `modules`       read for `unchecked`, which tach means as "do not check
--                   this module's imports" and which reads here as "do not
--                   report anything in this module"
--   `source_roots`  the same question, the same answer: what a file's module
--                   name is relative to
--   `rules.unused_ignore_directives`
--                   tach's name for a suppression comment that suppresses
--                   nothing, which is DC13 exactly
--
-- Everything else describes which module may import which. That is tach's
-- question and tach answers it.
--
-- `exclude` is the one key deliberately left alone despite having an obvious
-- counterpart. `--exclude` here means "do not read", which withdraws every
-- usage in the excluded path and can make live code look dead - the failure
-- mode the README warns about. Inheriting a list written for a tool that only
-- ever reads imports would spring that trap silently, so it is validated and
-- ignored. Pass `--exclude` yourself if that is what you want.
---@param data table a validated tach configuration
---@return deadcode.Surface
local function compile(data)
  local surface = {
    interfaces = {},
    modules = {},
    source_roots = data.source_roots or DEFAULT_SOURCE_ROOTS,
    disabled_codes = {},
  }

  for index = 1, #(data.interfaces or {}) do
    local entry = data.interfaces[index]
    surface.interfaces[#surface.interfaces + 1] = {
      expose = compile_regexes(entry.expose or {}),
      from = compile_regexes(entry.from or DEFAULT_FROM),
    }
  end

  for index = 1, #(data.modules or {}) do
    local entry = data.modules[index]
    local declared = entry.paths or { entry.path }
    local paths = {}
    for i = 1, #declared do
      -- Already validated, so a failure here cannot be reported to anyone; the
      -- same trade `compile_regexes` makes, for the same reason.
      local compiled = patterns.from_module_glob(declared[i]) or {}
      for j = 1, #compiled do
        paths[#paths + 1] = compiled[j]
      end
    end
    surface.modules[#surface.modules + 1] = {
      paths = paths,
      unchecked = entry.unchecked == true,
    }
  end

  -- Only `off` is acted on. This tool has one severity - a finding is printed
  -- and fails the run - so `warn` and `error` both mean the check stays on, and
  -- pretending otherwise would be inventing a level it does not have.
  if data.rules and data.rules.unused_ignore_directives == 'off' then
    surface.disabled_codes.DC13 = true
  end

  return surface
end

--- An empty surface: what a run with no `tach.lua` consults.
---@return deadcode.Surface
function tach.empty()
  return {
    interfaces = {},
    modules = {},
    source_roots = DEFAULT_SOURCE_ROOTS,
    disabled_codes = {},
  }
end

--- Read a `tach.lua` source into a surface.
---@param source string the file's contents
---@param path string used only in problem messages
---@return deadcode.Surface|nil surface nil when the file could not be used
---@return string[]|nil problems set only when `surface` is nil
function tach.load(source, path)
  -- The same loader `.deadcoderc` goes through, so both configuration files
  -- behave the same way and both are Lua rather than a second data language.
  local data, err = Args.load_table(source, path)
  if not data then return nil, { string.format('%s: %s', path, err) } end

  local problems = problems_with(data)
  if #problems > 0 then
    local labelled = {}
    for i = 1, #problems do
      labelled[i] = string.format('%s: %s', path, problems[i])
    end
    return nil, labelled
  end

  return compile(data)
end

--- The dotted module name a file path denotes, relative to the source roots.
--
-- `deadcode/cli.lua` under a root of `.` is `deadcode.cli`, and
-- `lua/mylib/init.lua` under a root of `lua` is `mylib`, which is what `require`
-- would call them. A file under no declared root keeps its whole path, so it
-- still has a name for `from` to match rather than dropping out of the config's
-- reach entirely.
---@param path string
---@param source_roots string[]
---@return string
function tach.module_name(path, source_roots)
  local normalised = path:gsub('\\', '/'):gsub('^%./', '')

  local best
  for i = 1, #source_roots do
    local root = source_roots[i]:gsub('\\', '/'):gsub('^%./', ''):gsub('/+$', '')
    if root == '' or root == '.' then
      best = best or normalised
    elseif normalised:sub(1, #root + 1) == root .. '/' then
      local rest = normalised:sub(#root + 2)
      -- The deepest root that contains the file is the most specific
      -- description of it, and so the one that names it.
      if not best or #rest < #best then best = rest end
    end
  end

  local name = (best or normalised):gsub('%.lua$', ''):gsub('/init$', '')
  return (name:gsub('/', '.'))
end

--- Could a declaration ever vouch for this finding?
--
-- Asked by the reporter as well as by `tach.exposes`, because a suggestion to
-- declare an unused local public would be advice that cannot work.
---@param item deadcode.CodeItem
---@return boolean
function tach.can_expose(item)
  return EXPOSABLE[item.type] == true
end

--- Does a declared interface publish `item`'s name out of `module_name`?
--
-- Both halves have to match the same entry: `{ expose = { 'setup' } }` says
-- every module's `setup` is public and says nothing about anything else, while
-- `{ expose = { '.*' }, from = { 'mylib' } }` says all of `mylib` is.
---@param surface deadcode.Surface
---@param item deadcode.CodeItem
---@param module_name string
---@return boolean
function tach.exposes(surface, item, module_name)
  if not tach.can_expose(item) then return false end

  for i = 1, #surface.interfaces do
    local entry = surface.interfaces[i]
    if patterns.any(entry.from, module_name) and patterns.any(entry.expose, item.name) then
      return true
    end
  end

  return false
end

--- Is this module one the configuration declares `unchecked`?
--
-- tach's `unchecked` means "do not check this module's imports"; the same
-- sentence here is "do not report anything inside this module". What it does
-- not mean is that the file stops being read: what it uses still keeps the rest
-- of the codebase honest, exactly as `ignore-file` does.
---@param surface deadcode.Surface
---@param module_name string
---@return boolean
function tach.is_unchecked(surface, module_name)
  for i = 1, #surface.modules do
    local entry = surface.modules[i]
    if entry.unchecked and patterns.any(entry.paths, module_name) then return true end
  end
  return false
end

return tach
