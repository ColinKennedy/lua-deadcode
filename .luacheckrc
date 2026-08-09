-- Rerun checks only if a file's modification time changed.
cache = true

-- The runtime code has to keep working under Lua 5.1 and LuaJIT, so check
-- against the smaller standard library rather than whatever `lua` happens to
-- be on PATH.
std = 'lua51'
codes = true

self = false

-- Reference: https://luacheck.readthedocs.io/en/stable/warnings.html
ignore = {}

exclude_files = {}
