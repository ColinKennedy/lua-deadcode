-- examples/ is deliberately dead code the demo target points at, so every
-- name in it looks private to privata. Findings there are the point of the
-- directory, not a defect, and they would drown the real ones.
return {
  source_roots = { '.' },
  test_roots = { 'tests' },
  exclude = { 'examples' },

  -- The CLI wrapper is run by the shell, not required by any module.
  entrypoint_globs = { 'bin/*' },
}
