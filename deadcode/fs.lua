-- Filesystem access, isolated behind one small table.
--
-- Every read the analyser performs goes through here, so the test suite can
-- swap in a virtual file tree and never touch disk. That is the single most
-- useful thing the Python original's test harness does, and it is worth more
-- here than an `lfs` dependency would be: no LuaRocks install is required to
-- run this tool or its tests.

--- The filesystem interface the analyser is given. The real implementation is
--- this module; the test suite passes a table of the same shape backed by an
--- in-memory tree, so anything typed as `deadcode.FS` must accept either.
---@class deadcode.FS
local fs = {}

--- Single-quote a path for /bin/sh.
---@param path string
---@return string the quoted path, safe to interpolate into a command
local function shell_quote(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

--- Strip the `./` prefix so reported paths match what the user typed.
---@param path string
---@return string
function fs.normalise(path)
  local normalised = tostring(path):gsub('\\', '/')
  while normalised:sub(1, 2) == './' do
    normalised = normalised:sub(3)
  end
  return normalised
end

--- Read a whole file.
---@param path string
---@return string|nil content nil when the file could not be read
---@return string|nil err the reason, set only when `content` is nil
function fs.read_file(path)
  local handle, err = io.open(path, 'rb')
  if not handle then return nil, err or ('could not open ' .. tostring(path)) end
  local content = handle:read('*a')
  handle:close()
  if not content then return nil, 'could not read ' .. tostring(path) end
  return content
end

--- Recursively list `.lua` files under `path`, or `path` itself if it is one.
--
-- Uses `find` rather than LuaFileSystem to stay dependency-free. Returns
-- `files, err`; a nil `files` means the path could not be inspected at all.
---@param path string
---@return string[]|nil files nil when `path` could not be inspected
---@return string|nil err the reason, set only when `files` is nil
function fs.list_lua_files(path)
  if not io.popen then return nil, 'io.popen is unavailable; cannot walk directories' end

  local command =
    string.format("find %s -type f -name '*.lua' -print 2>/dev/null", shell_quote(path))
  local pipe = io.popen(command)
  if not pipe then return nil, 'could not run find on ' .. tostring(path) end

  local files = {}
  for line in pipe:lines() do
    if line ~= '' then files[#files + 1] = fs.normalise(line) end
  end
  pipe:close()

  if #files == 0 and not fs.exists(path) then
    return nil, string.format('%s could not be found', path)
  end

  return files
end

--- Whether `path` names an existing file or directory.
---@param path string
---@return boolean
function fs.exists(path)
  local handle = io.open(path, 'r')
  if handle then
    handle:close()
    return true
  end
  if not io.popen then return false end
  -- Directories cannot always be opened, so fall back to a stat via find.
  local pipe = io.popen(string.format('find %s -maxdepth 0 -print 2>/dev/null', shell_quote(path)))
  if not pipe then return false end
  local found = pipe:read('*l')
  pipe:close()
  return found ~= nil and found ~= ''
end

return fs
