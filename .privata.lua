-- examples/ is deliberately dead code the demo target points at, so every
-- name in it looks private to privata. Findings there are the point of the
-- directory, not a defect, and they would drown the real ones.
return {
  source_roots = { '.' },
  test_roots = { 'tests' },
  exclude = { 'examples' },

  -- `bin/deadcode` is run by the shell and has no extension, so privata never
  -- parses it and never sees the `cli.run(arg)` inside it. The module it drives
  -- is the interface, so name the module rather than chase the caller.
  entrypoint_modules = { 'deadcode.cli' },
}
