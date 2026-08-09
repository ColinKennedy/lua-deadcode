-- Parse every file, resolve names across the whole program, and turn what is
-- left unused into filtered, sorted findings.
--
-- Analysis is whole-program on purpose: a field defined in one module and only
-- read from another is live, and no per-file pass can know that.

local Parser = require('deadcode.parser')
local Resolver = require('deadcode.resolver')
local CodeItem = require('deadcode.code_item')
local ignore = require('deadcode.ignore')
local noqa = require('deadcode.noqa')

--- Analyse every file and return what is left unused.
---@param filenames string[]
---@param args deadcode.Args
---@param fs deadcode.FS
---@return deadcode.CodeItem[] items sorted by `CodeItem.compare`
---@return string[] diagnostics messages for the user; `Error:` prefixed ones
--- are fatal to the exit status but never to the run
return function(filenames, args, fs)
  local program = Resolver.new_program()
  local directives_by_file = {}
  local muted_files = {}
  local diagnostics = {}

  for _, file in ipairs(filenames) do
    local content, read_err = fs.read_file(file)

    if not content then
      diagnostics[#diagnostics + 1] = string.format('Error: %s', read_err)
    else
      local chunk, comments = Parser.parse(content, file)

      if not chunk then
        -- A file we cannot parse is skipped, never fatal. `comments` holds the
        -- error message in this branch.
        diagnostics[#diagnostics + 1] =
          string.format('Error: failed to parse %s, ignoring it (%s)', file, tostring(comments))
      else
        ---@cast comments deadcode.Comment[] the error message is the other case
        local directives = noqa.parse(comments)
        directives_by_file[file] = directives

        -- `ignore-file` mutes reporting but the file is still analysed, so the
        -- names it uses keep the rest of the codebase honest. This is the
        -- deliberate difference from `--exclude`, which skips reading entirely.
        if directives.ignore_file then
          muted_files[file] = true
          if args.verbose then
            diagnostics[#diagnostics + 1] =
              string.format('Muted by ignore-file directive: %s', file)
          end
        end

        Resolver.analyse(program, chunk, file, args)
      end
    end
  end

  local ignored_codes = {}
  for _, code in ipairs(args.ignore_codes) do
    ignored_codes[code] = true
  end

  local items = {}
  for _, raw in ipairs(Resolver.collect(program, args)) do
    local item = CodeItem.new(raw)

    local skip = muted_files[item.file]
      or ignored_codes[item.code]
      or ignore.by_kind(item, raw)
      or ignore.by_config(item, args)
      or noqa.is_ignored(directives_by_file[item.file], item.line, item.code)

    if not skip and #args.only > 0 then skip = not ignore.matches_path(item.file, args.only) end

    if not skip then items[#items + 1] = item end
  end

  table.sort(items, CodeItem.compare)
  return items, diagnostics
end
