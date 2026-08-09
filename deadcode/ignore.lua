-- Suppression: every reason a finding might not be reported.
--
-- Deliberately the single place where that decision is made, so the layers
-- compose in one predicate rather than being scattered through the collectors:
--
--   1. naming conventions baked into the language's culture (`_`, `_unused`)
--   2. per-kind heuristics (test files, implicit `self`)
--   3. user globs: --ignore-names / --ignore-names-in-files
--   4. inline directives (see noqa.lua)
--
-- Layer 4 is applied by the reporter, which has the comment table; layers 1-3
-- live here.

--- Suppression: every reason a finding might not be reported.
---@class deadcode.ignore
local ignore = {}

---@type table<string, string> glob -> compiled Lua pattern
local pattern_cache = {}

--- Translate a shell-style glob into a Lua pattern anchored at both ends.
-- `*` matches any run of characters including `/`, matching the fnmatch
-- semantics the Python original relies on. `?` matches one character.
---@param glob string
---@return string a Lua pattern
function ignore.glob_to_pattern(glob)
  local cached = pattern_cache[glob]
  if cached then return cached end

  local escaped = glob:gsub('[%^%$%(%)%%%.%[%]%+%-]', '%%%1')
  escaped = escaped:gsub('%*', '\1')
  escaped = escaped:gsub('%?', '\2')
  escaped = escaped:gsub('\1', '.*')
  escaped = escaped:gsub('\2', '.')

  local pattern = '^' .. escaped .. '$'
  pattern_cache[glob] = pattern
  return pattern
end

--- True when `value` matches any glob in `patterns`.
---@param value string|nil
---@param patterns string[]|nil
---@return boolean
function ignore.matches(value, patterns)
  if not patterns or #patterns == 0 or value == nil then return false end
  value = tostring(value)
  for i = 1, #patterns do
    if value:find(ignore.glob_to_pattern(patterns[i])) then return true end
  end
  return false
end

--- A bare `*Mixin`-style pattern should also match a dotted path's last
-- segment, so users can write `--ignore-names=setup` rather than a full path.
---@param name string|nil
---@param patterns string[]|nil
---@return boolean
function ignore.matches_name(name, patterns)
  if ignore.matches(name, patterns) then return true end
  local tail = name and name:match('([^%.]+)$')
  if tail and tail ~= name then return ignore.matches(tail, patterns) end
  return false
end

-- Metamethods are called by the VM, never by name from Lua code, so
-- `Foo.__index = Foo` can never look used to a static reader. Deliberately an
-- explicit list rather than "anything starting with __": a field called
-- `__private` is ordinary code and should still be checked.
local METAMETHODS = {
  __index = true,
  __newindex = true,
  __call = true,
  __tostring = true,
  __len = true,
  __eq = true,
  __lt = true,
  __le = true,
  __concat = true,
  __unm = true,
  __add = true,
  __sub = true,
  __mul = true,
  __div = true,
  __mod = true,
  __pow = true,
  __idiv = true,
  __band = true,
  __bor = true,
  __bxor = true,
  __bnot = true,
  __shl = true,
  __shr = true,
  __gc = true,
  __close = true,
  __mode = true,
  __metatable = true,
  __pairs = true,
  __ipairs = true,
  __name = true,
}

local TEST_PATH_PATTERNS = {
  '^spec/',
  '/spec/',
  '^test/',
  '/test/',
  '^tests/',
  '/tests/',
  '_spec%.lua$',
  '_test%.lua$',
  '^test_[^/]*%.lua$',
  '/test_[^/]*%.lua$',
}

--- Test files get looser treatment for names a framework reaches dynamically.
---@param path string|nil
---@return boolean
function ignore.is_test_file(path)
  if not path then return false end
  local normalised = path:gsub('\\', '/'):gsub('^%./', '')
  for i = 1, #TEST_PATH_PATTERNS do
    if normalised:find(TEST_PATH_PATTERNS[i]) then return true end
  end
  return false
end

--- `_` is the universal Lua placeholder and `_name` the conventional marker for
-- a binding that exists only for its position. Neither is ever a finding.
---@param name string
---@return boolean
function ignore.is_placeholder_name(name)
  return name == '_' or name:sub(1, 1) == '_'
end

--- Per-kind heuristics, mirroring the shape of the Python original's
-- `_ignore_variable` / `_ignore_import` / ... callbacks.
-- Returns true when the finding should be dropped before user config applies.
---@param item deadcode.CodeItem
---@param context deadcode.RawFinding|nil the raw finding `item` was built from,
--- which is where `implicit` survives
---@return boolean
function ignore.by_kind(item, context)
  local type_, name = item.type, item.name

  if
    type_ == 'variable'
    or type_ == 'parameter'
    or type_ == 'loop_variable'
    or type_ == 'require'
  then
    if ignore.is_placeholder_name(name) then return true end
  end

  if type_ == 'parameter' and context and context.implicit then
    return true -- the `self` that `function T:m()` inserts for you
  end

  if (type_ == 'field' or type_ == 'method') and METAMETHODS[name] then return true end

  -- Test frameworks reach globals and table fields by name at runtime
  -- (busted's `describe`/`it`, love2d callbacks, luaunit's `TestFoo.testBar`),
  -- so static reachability says nothing useful about them there.
  if
    (type_ == 'global' or type_ == 'field' or type_ == 'method')
    and ignore.is_test_file(item.file)
  then
    return true
  end

  return false
end

--- The user-configurable layer: --ignore-names and --ignore-names-in-files.
--- Path matching that behaves the way people expect from `--exclude vendor`.
-- A pattern matches if it matches the whole path, any ancestor directory, or
-- any single path segment. Without this, an anchored glob would only ever
-- match a full path and every exclusion would need a `*` on each end.
---@param path string|nil
---@param patterns string[]|nil
---@return boolean
function ignore.matches_path(path, patterns)
  if not patterns or #patterns == 0 or path == nil then return false end
  if ignore.matches(path, patterns) then return true end

  local prefix
  for segment in tostring(path):gmatch('[^/]+') do
    prefix = prefix and (prefix .. '/' .. segment) or segment
    if ignore.matches(segment, patterns) then return true end
    if ignore.matches(prefix, patterns) then return true end
  end
  return false
end

--- The user-configurable layer proper: does this finding match a name or path
--- the user asked to be left alone?
---@param item deadcode.CodeItem
---@param args deadcode.Args
---@return boolean
function ignore.by_config(item, args)
  if ignore.matches_name(item.name, args.ignore_names) then return true end
  if ignore.matches_path(item.file, args.ignore_names_in_files) then return true end
  return false
end

return ignore
