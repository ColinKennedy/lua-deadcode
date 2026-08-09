.PHONY: check check-stylua deadcode demo help lint llscheck luacheck privata stylua test test-jit

LUA     ?= lua
LUAJIT  ?= luajit
SOURCES  = deadcode bin tests

# bin/deadcode has no extension, so stylua will not find it by walking `bin`.
LUA_SOURCES = deadcode bin/deadcode tests

CONFIGURATION = .luarc.json
ARGUMENTS ?=

# The full gate: the suite must pass and the tool must find nothing in itself.
check: test deadcode

test:
	@$(LUA) tests/run.lua

# The runtime code is Lua 5.1-compatible; this proves it stays that way.
test-jit:
	@$(LUAJIT) tests/run.lua

# Dogfooding. A tool that cannot survive its own analysis is not finished.
deadcode:
	@$(LUA) bin/deadcode $(SOURCES)

# examples/ is dead code on purpose, so findings here are success, not failure.
demo:
	@$(LUA) bin/deadcode examples || true

lint: stylua luacheck privata llscheck

llscheck:
	llscheck --configpath $(CONFIGURATION) .

luacheck:
	luacheck $(ARGUMENTS) $(LUA_SOURCES)

check-stylua:
	stylua $(LUA_SOURCES) --color always --check

privata:
	privata . $(ARGUMENTS)

stylua:
	stylua $(LUA_SOURCES)

help:
	@echo 'check         run the test suite and the self-check'
	@echo 'test          run the test suite'
	@echo 'test-jit      run the test suite under LuaJIT'
	@echo 'deadcode      run this tool against its own source'
	@echo 'demo          run this tool against examples/'
	@echo
	@echo 'lint          stylua + luacheck + privata + llscheck'
	@echo 'stylua        reformat the sources in place'
	@echo 'check-stylua  report formatting drift without rewriting anything'
	@echo 'luacheck      lint the sources'
	@echo 'privata       report public names only used privately'
	@echo 'llscheck      run the LuaLS diagnostics'
	@echo
	@echo 'Run a subset of tests:  lua tests/run.lua <substring>'
