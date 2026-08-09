-- Finding kinds and their DC error codes.
--
-- The DCxx numbering is inherited from the Python `deadcode` tool this port is
-- modelled on, but the kinds are Lua's, not Python's. Codes are stable: they
-- appear in user configuration and in `-- deadcode: ignore DCxx` comments.
--
-- One array is the source of truth and every lookup table is derived from it.
-- That is not only tidier than maintaining parallel tables keyed by literal
-- name - it is what this tool's own analysis asks for. A table written with
-- literal keys and read by dynamic lookup looks exactly like dead code from
-- the outside, because that is all a static reader can see.

local constants = {}

constants.VERSION = '0.1.0'

-- `exact = true` marks kinds resolved by lexical scoping rather than by
-- matching bare names, which cannot be confused by a name collision.
constants.CODES = {
  {
    type = 'variable',
    code = 'DC01',
    name = 'unused-variable',
    exact = true,
    message = 'Variable `%s` is never used',
  },
  {
    type = 'function',
    code = 'DC02',
    name = 'unused-function',
    exact = true,
    message = 'Function `%s` is never used',
  },
  {
    type = 'global',
    code = 'DC03',
    name = 'unused-global',
    message = 'Global `%s` is never used',
  },
  {
    type = 'method',
    code = 'DC04',
    name = 'unused-method',
    message = 'Method `%s` is never used',
  },
  {
    type = 'field',
    code = 'DC05',
    name = 'unused-field',
    message = 'Field `%s` is never used',
  },
  {
    type = 'parameter',
    code = 'DC06',
    name = 'unused-parameter',
    exact = true,
    message = 'Parameter `%s` is never used',
  },
  {
    type = 'require',
    code = 'DC07',
    name = 'unused-require',
    exact = true,
    message = 'Require `%s` is never used',
  },
  {
    type = 'loop_variable',
    code = 'DC08',
    name = 'unused-loop-variable',
    exact = true,
    message = 'Loop variable `%s` is never used',
  },
  {
    type = 'unreachable',
    code = 'DC09',
    name = 'unreachable-code',
    exact = true,
    message = 'Unreachable code after `%s`',
  },
  {
    type = 'dead_branch',
    code = 'DC10',
    name = 'unreachable-branch',
    exact = true,
    message = 'Branch is never taken (`%s` is constant)',
  },
  {
    type = 'empty_file',
    code = 'DC11',
    name = 'empty-file',
    exact = true,
    message = 'Empty Lua file',
  },
  {
    type = 'label',
    code = 'DC12',
    name = 'unused-label',
    exact = true,
    message = 'Label `%s` is never used',
  },
}

constants.TYPE_TO_CODE = {}
constants.MESSAGE_FOR_TYPE = {}
constants.EXACT_TYPES = {}

for _, entry in ipairs(constants.CODES) do
  constants.TYPE_TO_CODE[entry.type] = entry.code
  constants.MESSAGE_FOR_TYPE[entry.type] = entry.message
  if entry.exact then constants.EXACT_TYPES[entry.type] = true end
end

return constants
