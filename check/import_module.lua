--!noscript
-- smoke test: the installed xmake's core.tools.cl.has_flags must parse, load,
-- and actually contain the patched filter. run after check/apply_fix.lua.
--
-- the ubuntu/macos jobs never touch MSVC, so this is the only thing they can
-- prove about the patch: the module tree they patched is the one xmake loads,
-- and it is syntactically intact. the behavioral proof lives in the windows
-- job, which runs the five flag checks against the real cl.exe.

import("core.tools.cl.has_flags")

local src = io.readfile(path.join(os.programdir(), "modules", "core", "tools", "cl", "has_flags.lua"))

-- the literal text of the fix, built without pattern escapes:
--   line:find("D%d%d%d%d")
local needle = 'line:find("D' .. string.rep("%d", 4) .. '")'
assert(src:find(needle, 1, true),
    "installed core/tools/cl/has_flags.lua does not contain the D9xxx filter -- apply_fix did not stick?")

-- and the old, buggy oracle must be gone
assert(not src:find("if #line > 0 and not line:endswith(filename) then", 1, true),
    "installed core/tools/cl/has_flags.lua still carries the stock any-line-is-an-answer filter")

-- and so must the falsified v1 fix: matching the plain word "error" flags the C5072
-- message itself, which ends with "...for better ASAN error reporting"
assert(not src:find('line:find("error"', 1, true),
    "installed core/tools/cl/has_flags.lua still matches message text -- the C5072 warning would be flagged again")

print("import smoke ok: core.tools.cl.has_flags loads, patched _get_output is live in " .. os.programdir())
