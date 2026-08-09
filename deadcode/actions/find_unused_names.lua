-- Parse every file, resolve names across the whole program, and turn what is
-- left unused into filtered, sorted findings.
--
-- Analysis is whole-program on purpose: a field defined in one module and only
-- read from another is live, and no per-file pass can know that.

local Parser = require('deadcode.parser')
local Resolver = require('deadcode.resolver')
local CodeItem = require('deadcode.code_item')
local constants = require('deadcode.constants')
local ignore = require('deadcode.ignore')
local noqa = require('deadcode.noqa')
local tach = require('deadcode.tach')

--- Read the project's `tach.lua`, if it has one and was not told not to.
--
-- A missing file at the default location is not a problem: most projects have
-- no `tach.lua`. A missing file at a location the user named is, because they
-- asked for it by name.
---@param args deadcode.Args
---@param fs deadcode.FS
---@return deadcode.Surface surface empty when there is nothing to read
---@return string|nil path the file that was read, so it is not itself reported
---@return string[] diagnostics
local function read_tach(args, fs)
  if args.no_tach then return tach.empty(), nil, {} end

  -- Normalised, because the path is compared against the discovered file list
  -- later to keep the configuration out of its own report.
  local path = fs.normalise(args.tach or tach.FILENAME)
  local source = fs.read_file(path)

  if not source then
    if args.tach then
      return tach.empty(), nil, { string.format('Error: %s could not be found', path) }
    end
    return tach.empty(), nil, {}
  end

  local surface, problems = tach.load(source, path)
  if not surface then
    ---@cast problems string[] set exactly when the surface is not
    local diagnostics = {}
    for i = 1, #problems do
      diagnostics[i] = 'Error: ' .. problems[i]
    end
    return tach.empty(), path, diagnostics
  end

  if args.verbose then
    return surface, path, { string.format('Reading declared interfaces from %s', path) }
  end
  return surface, path, {}
end

--- Analyse every file and return what is left unused.
---@param filenames string[]
---@param args deadcode.Args
---@param fs deadcode.FS
---@return deadcode.CodeItem[] items sorted by `CodeItem.compare`
---@return string[] diagnostics messages for the user; `Error:` prefixed ones
--- are fatal to the exit status but never to the run
---@return string|nil tach_path the declaration file that was read, so the
--- reporter knows whether the project has one yet
-- One module, one verb, one exported function - so there is no module table to
-- read fields off, and nothing here to narrow.
return function(filenames, args, fs)
  local program = Resolver.new_program()
  local directives_by_file = {}
  local muted_files = {}
  local module_names = {}

  local surface, tach_path, diagnostics = read_tach(args, fs)

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

        local module_name = tach.module_name(file, surface.source_roots)
        module_names[file] = module_name

        -- `ignore-file` mutes reporting but the file is still analysed, so the
        -- names it uses keep the rest of the codebase honest. This is the
        -- deliberate difference from `--exclude`, which skips reading entirely.
        if directives.ignore_file then
          muted_files[file] = true
          if args.verbose then
            diagnostics[#diagnostics + 1] =
              string.format('Muted by ignore-file directive: %s', file)
          end
        elseif tach.is_unchecked(surface, module_name) then
          -- The same treatment, for the same reason, asked for in tach's words.
          muted_files[file] = true
          if args.verbose then
            diagnostics[#diagnostics + 1] =
              string.format('Muted by an unchecked tach module: %s', file)
          end
        elseif file == tach_path then
          -- The configuration is not part of the program it configures, and
          -- reporting on the file that was just read would be absurd. Muted
          -- rather than skipped, so a name it mentions still counts as used.
          muted_files[file] = true
        end

        Resolver.analyse(program, chunk, file, args)
      end
    end
  end

  local ignored_codes = {}
  for _, code in ipairs(args.ignore_codes) do
    ignored_codes[code] = true
  end
  for code in pairs(surface.disabled_codes) do
    ignored_codes[code] = true
  end

  local items = {}
  for _, raw in ipairs(Resolver.collect(program, args)) do
    -- The resolver works in paths; a declaration works in module names. The
    -- raw finding is this pass's own table, so it is where the two are joined.
    raw.module = module_names[raw.file]
    local item = CodeItem.new(raw)

    local skip = muted_files[item.file]
      or ignored_codes[item.code]
      or ignore.by_kind(item, raw)
      or ignore.by_config(item, args)
      or tach.exposes(surface, item, item.module)
      or noqa.is_ignored(directives_by_file[item.file], item.line, item.code)

    if not skip and #args.only > 0 then skip = not ignore.matches_path(item.file, args.only) end

    if not skip then items[#items + 1] = item end
  end

  -- Only now, with every finding filtered, is it known which directives did any
  -- work. One that did none is reported in its turn, so suppression comments do
  -- not quietly outlive the code they were written for.
  --
  -- Iteration order over files is arbitrary; the sort below is what makes the
  -- report deterministic, exactly as it does for everything above.
  for file, directives in pairs(directives_by_file) do
    if not muted_files[file] then
      for _, unused in ipairs(noqa.unused(directives)) do
        local item = CodeItem.new({
          name = unused.code or '',
          type = 'unused_ignore',
          file = file,
          module = module_names[file],
          line = unused.line,
          col = unused.col,
          message = not unused.code and constants.UNUSED_IGNORE_MESSAGE or nil,
        })

        -- `by_kind` has nothing to say about a directive, and the file is known
        -- not to be muted, so this is the rest of the same chain. The directive
        -- under complaint is excluded from suppressing its own complaint.
        local skip = ignored_codes[item.code]
          or ignore.by_config(item, args)
          or noqa.is_ignored(directives, item.line, item.code, unused.directive)

        if not skip and #args.only > 0 then skip = not ignore.matches_path(item.file, args.only) end

        if not skip then items[#items + 1] = item end
      end
    end
  end

  table.sort(items, CodeItem.compare)
  return items, diagnostics, tach_path
end
