# lua-deadcode

Finds Lua code that is never used, and reports it. It never edits your files.

```
$ deadcode src
src/parser.lua:41:7:   DC01 Variable `depth` is never used
src/parser.lua:88:16:  DC02 Function `normalise` is never used
src/format.lua:12:12:  DC05 Field `legacy_mode` is never used
src/format.lua:57:1:   DC10 Branch is never taken (`if` is constant)
```

Requires Lua 5.1 or newer, or LuaJIT. No dependencies, no LuaRocks, no
LuaFileSystem. Parses the full Lua 5.1–5.4 and LuaJIT grammar, so it can analyse
modern code whatever it runs on itself.

## Install

Clone it and run the script; there is nothing to build.

```sh
git clone <this repo> && cd lua-deadcode
./bin/deadcode path/to/your/project
```

Symlink `bin/deadcode` onto your `PATH` if you want it everywhere. It resolves
its own modules relative to the real script location.

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
| `DC05` | unused-field          | `function T.f()`, `T.f = ...`, `local T = { f = ... }` |
| `DC06` | unused-parameter      | a parameter never read (opt-in, `--check-params`) |
| `DC07` | unused-require        | `local m = require "x"` where `m` is never used |
| `DC08` | unused-loop-variable  | a `for` control variable never read |
| `DC09` | unreachable-code      | statements after `break` or `goto` in the same block |
| `DC10` | unreachable-branch    | `if false`, `while false`, a branch after `if true` |
| `DC11` | empty-file            | a file with no statements |
| `DC12` | unused-label          | `::label::` that no `goto` targets |

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

Truthiness follows Lua, not intuition borrowed from other languages: only `nil`
and `false` are falsy, so `if 0 then` and `if "" then` are live branches.

## Suppression

Inline, using whichever spelling you already type:

```lua
local x = 1   -- deadcode: ignore
local y = 2   -- deadcode: ignore DC01, DC02
local z = 3   -- luacheck: ignore
local w = 4   -- noqa: DC01
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

## Known limitations

Stated plainly, because a linter you cannot calibrate is a linter you will
eventually ignore.

- **Field and global names are matched, not resolved.** Two unrelated tables
  with a `render` field share a bucket; using either marks both live.
- **Mutual recursion is invisible.** `a` calls `b`, `b` calls `a`, nothing calls
  either — both look used. Direct self-recursion *is* caught.
- **Dynamic access defeats it in both directions.** `t[key]` with a computed key
  is neither a use nor a definition. Dispatch tables, `_G`, `setmetatable`
  trickery and `load()` are all invisible. A literal `t["name"]` *is* understood.
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
make test       # 129 tests, no dependencies
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
deadcode/noqa.lua         inline directive parsing
deadcode/constants.lua    codes and messages, one source of truth
deadcode/code_item.lua    a single finding
deadcode/args.lua         CLI and .deadcoderc
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
> code numbering and flag names are deliberately familiar. No licence has been
> chosen for this repository yet — that is a decision for its owner.
