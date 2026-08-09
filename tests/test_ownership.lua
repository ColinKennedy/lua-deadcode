-- Which tables a field finding may be made about.
--
-- `t.k = v` is only a definition when `t` is a table this codebase built and
-- still has to itself. Writing into someone else's table, or into one we have
-- already handed over, reaches a reader this tool cannot see - and a finding
-- there claims something about that reader's code, not about ours.

local support = require('tests.support')
local run, findings = support.run, support.findings
local assert_list_equal = support.assert_list_equal

return {

  -- ------------------------------------------------- tables we do not own

  ['a field written through a foreign table is not a definition'] = function()
    -- The host reads these back on every buffer switch; nothing here can see
    -- that happen, so nothing here may call them dead.
    support.assert_clean({
      ['a.lua'] = [[
vim.opt_local.relativenumber = false
vim.opt_local.number = false
vim.opt_local.signcolumn = "no"
]],
    })
  end,

  ['a field written through a dynamically indexed foreign table is not a definition'] = function()
    support.assert_clean({
      ['a.lua'] = [[
local buffer = vim.api.nvim_create_buf(false, true)
vim.bo[buffer].bufhidden = "wipe"
vim.bo[buffer].swapfile = false
]],
    })
  end,

  ['extending a required module is not a definition'] = function()
    support.assert_clean({ ['a.lua'] = [[
local m = require("other")
m.extra = 1
]] })
  end,

  ['a global table is foreign, because nothing tells it apart from `vim`'] = function()
    support.assert_clean({ ['a.lua'] = 'shared = {}\nshared.thing = 1\nprint(shared)\n' })
  end,

  ['a constructor assigned to a global still defines its fields'] = function()
    -- The other half of the rule above: writing *through* a global name proves
    -- nothing, but a table literal is written here whatever it is bound to.
    local output = run({ ['a.lua'] = 'shared = { dead = 1 }\nprint(shared)\n' })
    assert_list_equal(findings(output), { 'DC05 dead' })
  end,

  -- ------------------------------------------------- tables we do own

  ['a field on a local table is still reported'] = function()
    local output = run({ ['a.lua'] = [[
local M = {}
M.dead = 1
return M
]] })
    assert_list_equal(findings(output), { 'DC05 dead' }, 'the module idiom must keep working')
  end,

  ['a table built one statement late is still ours'] = function()
    local output = run({ ['a.lua'] = [[
local M
M = {}
M.dead = 1
return M
]] })
    assert_list_equal(findings(output), { 'DC05 dead' })
  end,

  ['a table built by setmetatable is still ours'] = function()
    local output = run({
      ['a.lua'] = [[
local Point = setmetatable({}, {})
function Point.dead() return 1 end
return Point
]],
    })
    assert_list_equal(findings(output), { 'DC05 dead' })
  end,

  ['a field assigned through the implicit self is still reported'] = function()
    -- A method writes to an instance of the very class being analysed, which
    -- is the OOP spelling of the module-table idiom.
    local output = run({
      ['a.lua'] = [[
local M = {}
function M.init(self) return self end
function M:configure() self.dead = 0 end
print(M.init, M.configure)
return M
]],
    })
    assert_list_equal(findings(output), { 'DC05 dead' })
  end,

  -- ------------------------------------------------- tables we hand over

  ['a table passed to a call can be read by the callee'] = function()
    -- `vim.keymap.set(..., opts)` reads `silent`; the definition is here but
    -- the use never will be.
    support.assert_clean({
      ['a.lua'] = [[
local opts = { noremap = true, silent = true }
vim.keymap.set("n", "<CR>", print, opts)
]],
    })
  end,

  ['a table stored in a foreign table can be read by its owner'] = function()
    support.assert_clean({
      ['a.lua'] = [[
local state = {}
state.count = 0
vim.g.my_state = state
]],
    })
  end,

  ['setmetatable is not handing the table over'] = function()
    local output = run({ ['a.lua'] = [[
local M = {}
M.dead = 1
setmetatable(M, {})
return M
]] })
    assert_list_equal(findings(output), { 'DC05 dead' }, 'the class idiom is not an escape')
  end,

  ['handing over one field does not hand over the table'] = function()
    local output = run({
      ['a.lua'] = [[
local M = {}
M.live = { inner = 1 }
M.dead = 2
configure(M.live)
return M
]],
    })
    assert_list_equal(
      findings(output),
      { 'DC05 dead' },
      'only `inner` travelled; `dead` stayed home'
    )
  end,

  -- ------------------------------------------------- tables read dynamically

  ['a table read with a computed key hides every field it has'] = function()
    support.assert_clean({
      ['a.lua'] = [[
local STEPS = { next = 1, previous = -1 }
local function step(direction) return STEPS[direction] end
print(step("next"))
]],
    })
  end,

  ['a lookup table behind a field is hidden the same way'] = function()
    support.assert_clean({
      ['a.lua'] = [[
local M = {}
M.BY_FILETYPE = { python = "python" }
function M.language_of(filetype) return M.BY_FILETYPE[filetype] end
print(M.language_of("lua"))
]],
    })
  end,

  -- ------------------------------------------------- uses still count

  ['a use through a foreign table still counts'] = function()
    support.assert_clean({
      ['mod.lua'] = 'local M = {}\nfunction M.handler() return 1 end\nreturn M\n',
      ['main.lua'] = 'local M = require("mod")\nvim.keymap.set("n", "x", M.handler)\n',
    })
  end,

  ['the value of a write we ignore is still walked'] = function()
    local output = run({ ['a.lua'] = [[
local unused = 1
local used = 2
vim.g.thing = used
]] })
    assert_list_equal(findings(output), { 'DC01 unused' })
  end,
}
