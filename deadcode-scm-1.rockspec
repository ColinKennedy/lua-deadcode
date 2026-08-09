package = "deadcode"
version = "scm-1"

source = {
  url = "git+https://github.com/ColinKennedy/lua-deadcode.git",
}

description = {
  summary = "Find Lua code that is never used, and report it.",
  detailed = [[
    deadcode is a static checker that reports code nothing reaches: unused
    locals and parameters, functions and module fields no one calls, requires
    nothing uses, unreachable statements, and branches that can never be
    taken. It never edits your files.

    Parses the full Lua 5.1-5.4 and LuaJIT grammar, so it can analyse modern
    code whatever interpreter it runs on itself.

    Zero runtime dependencies, not even LuaFileSystem.
  ]],
  homepage = "https://github.com/ColinKennedy/lua-deadcode",
  -- TODO: no licence has been chosen for this repository yet. Add `license`
  -- here (and a LICENSE file) before the first upload; a rock on luarocks.org
  -- with no stated terms is one nobody can safely depend on.
}

dependencies = {
  "lua >= 5.1",
}

build = {
  type = "builtin",
  modules = {
    ["deadcode.actions.find_lua_files"] = "deadcode/actions/find_lua_files.lua",
    ["deadcode.actions.find_unused_names"] = "deadcode/actions/find_unused_names.lua",
    ["deadcode.actions.report"] = "deadcode/actions/report.lua",
    ["deadcode.args"] = "deadcode/args.lua",
    ["deadcode.cli"] = "deadcode/cli.lua",
    ["deadcode.code_item"] = "deadcode/code_item.lua",
    ["deadcode.constants"] = "deadcode/constants.lua",
    ["deadcode.fs"] = "deadcode/fs.lua",
    ["deadcode.ignore"] = "deadcode/ignore.lua",
    ["deadcode.lexer"] = "deadcode/lexer.lua",
    ["deadcode.noqa"] = "deadcode/noqa.lua",
    ["deadcode.parser"] = "deadcode/parser.lua",
    ["deadcode.resolver"] = "deadcode/resolver.lua",
  },
  install = {
    bin = {
      deadcode = "bin/deadcode",
    },
  },
}
