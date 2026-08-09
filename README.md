# lua-deadcode

Finds Lua code that is never used, and reports it. It never edits your files.

```
$ deadcode src
src/parser.lua:41:7:   DC01 Variable `depth` is never used
src/parser.lua:88:16:  DC02 Function `normalise` is never used
src/format.lua:12:12:  DC05 Field `legacy_mode` is never used
src/format.lua:57:1:   DC10 Branch is never taken (`if` is constant)
```

Requires Lua 5.1 or newer, or LuaJIT. No runtime dependencies — not even
LuaFileSystem. Parses the full Lua 5.1–5.4 and LuaJIT grammar, so it can analyse
modern code whatever it runs on itself.

## Install

```sh
luarocks install deadcode
```

That puts a `deadcode` command on your `PATH`:

```sh
deadcode path/to/your/project
```

Or run it straight from a clone — there is nothing to build, since the only
dependency is Lua itself:

```sh
git clone https://github.com/ColinKennedy/lua-deadcode && cd lua-deadcode
./bin/deadcode path/to/your/project
```

Symlink `bin/deadcode` onto your `PATH` if you want that copy everywhere. It
resolves its own modules relative to the real script location.

## Usage

```sh
deadcode src                                  # check a directory
deadcode src spec                             # check several
deadcode src --exclude vendor,build           # skip paths entirely
deadcode src --ignore-names "on_*,handle_*"   # drop findings by name
deadcode src --count                          # just the number
deadcode . --only src/parser.lua              # report on one file
```

Exit status is `0` when clean, `1` when something was found, and `2` for a
usage error or an unreadable file — so it drops straight into CI or a
pre-commit hook.

> **Put paths before options.** List options consume every following word until
> the next `--flag`, so `deadcode --ignore-names foo src` reads `src` as a
> second name to ignore. Write `deadcode src --ignore-names foo`, or separate
> them with `--`. This wart is inherited from the tool this one is modelled on,
> and is pinned by a test so it cannot change silently.

## What it detects

| Code   | Name                  | Detects |
|--------|-----------------------|---------|
| `DC01` | unused-variable       | `local x` that is never read |
| `DC02` | unused-function       | `local function f` that is never called |
| `DC03` | unused-global         | a global this codebase assigns but never reads |
| `DC04` | unused-method         | `function T:m()` never invoked |
| `DC05` | unused-field          | `function T.f()`, `T.f = ...`, `local T = { f = ... }`, where `T` is a table this codebase owns |
| `DC06` | unused-parameter      | a parameter never read (opt-in, `--check-params`) |
| `DC07` | unused-require        | `local m = require "x"` where `m` is never used |
| `DC08` | unused-loop-variable  | a `for` control variable never read |
| `DC09` | unreachable-code      | statements after `break` or `goto` in the same block |
| `DC10` | unreachable-branch    | `if false`, `while false`, a branch after `if true` |
| `DC11` | empty-file            | a file with no statements |
| `DC12` | unused-label          | `::label::` that no `goto` targets |
| `DC13` | unused-ignore         | a `deadcode: ignore` comment that suppresses nothing |

Assignment is not use: `local x; x = 5` still reports `x`. Neither is
self-recursion — a function whose only caller is itself is dead, and saying so
is much of the point.

## How it decides

Two strategies, picked per construct by what Lua can actually guarantee.

**Locals are resolved exactly.** Lua's scoping is fully static, so locals,
parameters, loop variables and labels get a real lexical symbol table.
Shadowing, redeclaration and declaration order all behave as Lua does — a
finding about a local is never a name collision:

```lua
local x = 1     -- DC01: reported
do
  local x = x   -- reads the OUTER x, which is therefore live...
  print(x)      -- ...and this reads the inner one
end
```

**Globals and fields are matched by name, program-wide.** `t.foo` cannot be
resolved without type inference, so every `foo` field in the codebase shares one
bucket and a use of any marks all of them used. That under-reports; it never
over-reports. Analysis is whole-program, so a field defined in one module and
only read from another is correctly live.

**A field finding is only ever made about a table this codebase owns.** Writing
`t.k = v` says nothing about `k` unless `t` is a table built here and still kept
here — otherwise the reader lives somewhere this tool cannot look, and calling
the field dead is a claim about *their* code:

```lua
local M = {}
M.helper = function() end        -- ours: reported if nothing calls it

vim.opt_local.number = false     -- the editor reads these back
vim.bo[buffer].bufhidden = "wipe"
local other = require("other")
other.extra = 1                  -- not our table to reason about

local opts = { silent = true }   -- ours, until it is handed over...
vim.keymap.set("n", "x", print, opts)   -- ...and now the callee reads it

local STEPS = { next = 1 }
return STEPS[direction]          -- a computed key can name any field
```

A table stops being provable the moment it is passed to a call, stored in a
table we do not own, or read with a computed key. `setmetatable(M, mt)` is
excluded: it hands the table to the VM, not to a reader, and the class idiom
depends on it. *Writing through* a global counts as foreign, because nothing
distinguishes a global table of yours from `vim` or `string` — though a
constructor you can see (`config = { verbose = true }`) is still yours.

Truthiness follows Lua, not intuition borrowed from other languages: only `nil`
and `false` are falsy, so `if 0 then` and `if "" then` are live branches.

## Suppression

`-- deadcode: ignore` silences an individual finding. Name codes after it to
silence only those; with none listed, every finding on the line goes quiet. Two
spellings you may already type are accepted as exact equivalents:

```lua
local x = 1   -- deadcode: ignore
local y = 2   -- deadcode: ignore DC01
local z = 3   -- deadcode: ignore DC01, DC02
local w = 4   -- luacheck: ignore
local v = 5   -- noqa: DC01
```

A trailing comment governs its own line; a comment on a line of its own governs
the next line of code. A directive must start the comment, so ordinary prose
mentioning "noqa" is not a directive.

To mute a whole file while still letting it count as a *user* of other code:

```lua
-- deadcode: ignore-file
```

Names starting with `_` are never reported, and neither is the implicit `self`
of a method. Metamethods (`__index`, `__tostring`, …) are never reported: the
VM calls them, so no static reader can ever see them used.

### Ignores that stopped mattering (`DC13`)

A suppression comment outlives the code it was written for. Rename the variable,
delete the branch, finally use the field — and the comment stays, silencing a
finding that no longer exists. Nothing else in a codebase ever prompts you to
remove one.

So the check runs both ways: a `deadcode: ignore` that suppressed nothing is
itself reported.

```
$ deadcode src
src/parser.lua:41:16: DC13 Ignore comment suppresses nothing; remove it
src/format.lua:12:22: DC13 Ignore of `DC05` suppresses nothing; remove it
```

The finding points at the comment — the line you would delete — not at the code
it was governing. Listing several codes reports each one separately, so
`-- deadcode: ignore DC01, DC07` on a line that only ever had a `DC01` names the
`DC07` and leaves the rest of the comment alone.

Three deliberate limits:

- **Only this tool's own spelling is reported.** A `luacheck: ignore` or a bare
  `noqa:` may well be earning its keep in a linter this one cannot see, so
  advising you to delete it would be a claim about someone else's tool.
- **A directive cannot excuse itself.** `-- deadcode: ignore` on a line whose
  only finding is that very comment is still reported; otherwise every stale
  directive would justify its own existence. A *neighbouring* directive can
  excuse it, which is the escape hatch for a comment you want to keep through a
  change that has not landed yet:

  ```lua
  -- deadcode: ignore DC13
  print(value)  -- deadcode: ignore DC01
  ```

  The inner directive is suppressing nothing — that is the point — and the
  outer one says to leave it be. Neither is reported.

- **A muted file is left alone.** `-- deadcode: ignore-file` already said
  nothing in the file is being listened to.

Turn the check off with `--ignore-codes DC13`, or `ignore_codes = { 'DC13' }` in
`.deadcoderc`.

### `--exclude` versus `--ignore-names-in-files`

The difference matters and is easy to get wrong:

- `--exclude` **does not read** the path. Fast, but excluded code contributes no
  usages — exclude the directory that calls your API and the API looks dead.
- `--ignore-names-in-files` **reads** the path and suppresses findings *in* it.
  Slower, correct.
- `-- deadcode: ignore-file` behaves like the latter.

Reach for `--exclude` on vendored or generated code that never calls yours, and
`--ignore-names-in-files` on everything else.

## Configuration

Optional `.deadcoderc` in the working directory — a Lua file returning a table.
A Lua tool reading a Lua config needs no extra parser, and matches what the
ecosystem already does with `.luacheckrc`.

```lua
return {
  exclude = { 'vendor', 'build' },
  ignore_names = { 'on_*', '*_handler' },
  ignore_names_in_files = { 'spec/**' },
  ignore_codes = { 'DC08' },
  check_params = false,
}
```

List options in the config are **appended** to anything given on the command
line. Boolean options apply only where the command line stayed silent, so an
explicit flag always wins. `--no-config` skips the file; `--config <path>` picks
a different one.

## Declaring a public interface: `tach.lua`

Reachability is inferred from what the checkout itself uses. That is exactly
right for an application and exactly wrong for a library: its callers are
somewhere else by definition, so its whole API looks dead.

The answer is to declare the API, and
[tach](https://github.com/gauge-sh/tach) already has the vocabulary for one. If
a `tach.lua` sits in the working directory it is read, and anything it exposes
is not dead code.

A report that turns up names a declaration could cover says so, with those
names already filled in — paste it and the run is clean:

```
$ deadcode lua
lua/mylib/init.lua:2:12: DC05 Field `setup` is never used
lua/mylib/init.lua:3:12: DC05 Field `teardown` is never used
lua/other.lua:2:12: DC05 Field `render` is never used

Some of these may be public API this scan cannot see a caller for. To declare
them public rather than delete them, add a tach.lua beside your source:

  -- tach.lua
  return {
    interfaces = {
      { expose = { 'setup', 'teardown' }, from = { 'lua\\.mylib' } },
      { expose = { 'render' }, from = { 'lua\\.other' } },
    },
  }

`expose` names the symbols and `from` names the modules that publish them.
Both are regular expressions matching the whole name, and leaving `from` out
means every module. Anything a declaration covers is never reported again.
```

The suggestion is capped at a few entries, and says how many names it left out
rather than looking complete when it is not. It stops once the project has a
`tach.lua`, and `--no-tach` silences it outright.

The full shape, hand-written:

```lua
-- tach.lua
return {
  source_roots = { 'lua' },

  interfaces = {
    { expose = { 'setup', 'on_.*' }, from = { 'mylib' } },
  },

  modules = {
    { path = 'mylib.vendored', unchecked = true },
  },
}
```

`tach.lua` is `tach.toml`'s schema written as a Lua table — the same keys, the
same values, the same defaults — so a project already using tach can convert
its config once and both tools read it. Every key tach accepts is accepted
here, and an unknown one is refused, because a misspelled key is a rule that
silently is not applied.

What is acted on:

| Key | What it does here |
|-----|-------------------|
| `interfaces[].expose` | regexes naming symbols that are public, so never dead |
| `interfaces[].from` | regexes naming the modules that publish them; omitted means every module |
| `modules[].unchecked` | nothing in the module is reported, though it is still read |
| `source_roots` | what a file's module name is relative to; defaults to `{ '.' }` |
| `rules.unused_ignore_directives = 'off'` | disables `DC13` — tach's name for the same check |

`expose` and `from` are **regular expressions**, anchored at both ends, and both
halves of an entry must match: `{ expose = { 'setup' } }` says every module's
`setup` is public, while `{ expose = { '.*' }, from = { 'mylib' } }` says all of
`mylib` is. Constructs Lua patterns cannot express — alternation, groups,
repetition counts — are refused rather than approximated, because a pattern that
quietly matches something other than what it says is worse than one that will
not load. `modules[].path` is a dotted glob instead, where `**` crosses the
separator: `vendor.**` covers `vendor` and everything under it.

> **Double your backslashes.** These patterns live in a Lua file, so a regex
> `\.` has to be written `'\\.'` — Lua 5.2 and newer reject `'\.'` outright as
> an invalid escape, and Lua 5.1 silently reads it as a bare `.`, which matches
> any character. `'libs\\..*'` is the whole of `libs.anything`.

A declaration only ever vouches for names another file could reach: functions,
methods, fields and globals. It cannot make a local, a parameter, a loop
variable, a label or an unreachable branch live, since nothing outside the file
can reach those — and a declaration that could silence them would be a way to
switch the tool off by accident.

`--no-tach` skips the file; `--tach <path>` picks a different one.

Everything else in the schema describes which module may import which. That is
tach's question, and it is validated and then ignored here — with one deliberate
exception. **`exclude` is not honoured.** `--exclude` in this tool means "do not
read", which withdraws every usage in the excluded path and can make live code
look dead; inheriting a list written for a tool that only ever reads imports
would spring that trap silently. Pass `--exclude` yourself if that is what you
want.

## Known limitations

Stated plainly, because a linter you cannot calibrate is a linter you will
eventually ignore.

- **Field and global names are matched, not resolved.** Two unrelated tables
  with a `render` field share a bucket; using either marks both live.
- **Mutual recursion is invisible.** `a` calls `b`, `b` calls `a`, nothing calls
  either — both look used. Direct self-recursion *is* caught.
- **Dynamic access defeats it in both directions.** `t[key]` with a computed key
  is neither a use nor a definition — and it retires every finding about `t`,
  since a computed key could name any of them. `_G`, `setmetatable` trickery and
  `load()` are equally invisible. A literal `t["name"]` *is* understood.
- **A table you hand over is a table you stop hearing about.** Passing it to a
  call or storing it in a table you do not own withdraws its field findings, and
  no attempt is made to see whether the callee actually reads anything. Dead
  fields on your options tables will not be found.
- **A table only ever written to looks live**, because writing `t.a.b = 1` reads
  `t.a` on the way.
- **Removing dead code can reveal more.** Nothing chases that cascade; run the
  tool again after a cleanup.
- **Code inside a dead branch still counts as using things.** `DC10` reports the
  branch; it does not discount what the branch references.
- Test files (`spec/`, `test/`, `*_spec.lua`, `*_test.lua`, `test_*.lua`) have
  globals, fields and methods exempted, since frameworks reach those by name at
  runtime. Locals there are still checked.

## Development

```sh
make check      # test suite + self-check
make test       # 200 tests, no dependencies
make test-jit   # the same suite under LuaJIT
make deadcode   # run the tool against its own source

lua tests/run.lua suppression    # one file's worth
```

Tests declare a whole virtual project inline and assert on what `main` returns:

```lua
['unused local is reported'] = function()
  local output = run({ ['a.lua'] = 'local x = 1\n' })
  assert_list_equal(findings(output), { 'DC01 x' })
end,
```

Nothing touches the disk and nothing captures stdout, because `cli.main` returns
`output, exit_code` rather than printing. That single choice is what keeps the
suite readable.

### Layout

```
bin/deadcode              CLI wrapper
deadcode/lexer.lua        tokeniser (Lua 5.1-5.4, LuaJIT)
deadcode/parser.lua       recursive-descent parser -> AST
deadcode/resolver.lua     scope resolution and use collection
deadcode/ignore.lua       every reason a finding is dropped, in one predicate
deadcode/noqa.lua         inline directive parsing, and whether each one worked
deadcode/constants.lua    codes and messages, one source of truth
deadcode/code_item.lua    a single finding
deadcode/args.lua         CLI and .deadcoderc
deadcode/tach.lua         tach.lua: the declared public interface
deadcode/patterns.lua     tach's regexes and globs, as Lua patterns
deadcode/fs.lua           the only module that touches disk
deadcode/actions/         one module per pipeline step
deadcode/cli.lua          main()
```

AST nodes carry a start position and no end position. Nothing here rewrites
source, so a definition's extent would be dead weight — which is also why there
is no equivalent of the span-merging and text-repair machinery the tool this one
is modelled on needs for its `--fix`.

## Relationship to `deadcode` (Python)

This borrows the architecture of [albertas/deadcode](https://github.com/albertas/deadcode):
the pipeline of single-purpose action modules, `main()` returning a string, the
layered suppression predicate, the `DCxx` code scheme, and the virtual-filesystem
test harness. See `SUMMARY.local.md` for the full architectural read-through.

It is an independent implementation rather than a translation, and it diverges
where Lua differs:

- **detection only** — no `--fix`, and therefore no span tracking, no text
  repair, and no cascade problem to solve;
- **exact lexical resolution for locals**, which the original does not attempt
  for any name kind — its own enhancement proposal DEP 1 describes wanting it;
- **Lua's truthiness, idioms and metamethods** in place of Python's;
- **config as a Lua file** rather than TOML.

> Note on licensing: the Python original is AGPLv3. No code was copied, but the
> code numbering and flag names are deliberately familiar. This repository is
> MIT licensed; see `LICENSE`.
