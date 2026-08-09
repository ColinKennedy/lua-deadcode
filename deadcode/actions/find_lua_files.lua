-- Expand the paths the user gave into a sorted list of `.lua` files.
--
-- `--exclude` prunes here, before anything is read. That makes it fast, but it
-- also means excluded code contributes no *usages* - exclude a directory that
-- calls into your code and that code starts looking dead. When you want a path
-- read but not reported on, use `--ignore-names-in-files` instead.

local ignore = require('deadcode.ignore')

--- Expand `args.paths` into the files to analyse.
---@param args deadcode.Args
---@param fs deadcode.FS
---@return string[] files sorted and de-duplicated
---@return string[] diagnostics messages for the user; `Error:` prefixed ones
--- are fatal to the exit status but never to the run
-- One module, one verb, one exported function - so there is no module table to
-- read fields off, and nothing here to narrow.
return function(args, fs)
  local files, diagnostics, seen = {}, {}, {}

  for _, raw_path in ipairs(args.paths) do
    local path = fs.normalise(raw_path)

    if ignore.matches_path(path, args.exclude) then
      if args.verbose then
        diagnostics[#diagnostics + 1] = string.format('Skipping excluded path: %s', path)
      end
    else
      local found, err = fs.list_lua_files(path)
      if not found then
        diagnostics[#diagnostics + 1] = string.format('Error: %s', err)
      else
        for _, file in ipairs(found) do
          -- A file already seen was collected via another path argument.
          if not seen[file] then
            if ignore.matches_path(file, args.exclude) then
              if args.verbose then
                diagnostics[#diagnostics + 1] = string.format('Skipping excluded file: %s', file)
              end
            else
              seen[file] = true
              files[#files + 1] = file
            end
          end
        end
      end
    end
  end

  table.sort(files)

  if args.verbose and #files > 0 then
    diagnostics[#diagnostics + 1] =
      string.format('Checking %d file%s for dead code', #files, #files == 1 and '' or 's')
  end

  return files, diagnostics
end
