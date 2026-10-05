--!noscript
-- Asserts WHICH xmake is running and WHAT its core.tools.cl.has_flags says.
--
-- The ubuntu/macos jobs never touch MSVC, so this is the only thing they can
-- prove about the fix: the module tree in os.programdir() loads, and it carries
-- the oracle the job claims. The behavioral proof lives in the windows jobs,
-- which run the five flag checks against the real cl.exe.
--
-- `xmake l` does not forward arguments to the script, so everything is
-- configured through the environment:
--
--   EXPECT_MODE       "original" -> assert the unpatched 3.1.1 oracle is present
--                     "fixed"    -> assert the Dxxxx oracle is present and both
--                                   the unpatched and the falsified v1 oracle
--                                   are gone (default)
--   EXPECT_PROGRAMDIR optional substring that os.programdir() must contain.
--                     the windows `fixed` job installs a bootstrap xmake too, so
--                     without this a wrong PATH would silently check the wrong
--                     tree.

import("core.tools.cl.has_flags")

local mode = os.getenv("EXPECT_MODE") or "fixed"
if mode ~= "original" and mode ~= "fixed" then
    os.raise("EXPECT_MODE must be 'original' or 'fixed', got '%s'", mode)
end

local programdir = os.programdir()
local expect_programdir = os.getenv("EXPECT_PROGRAMDIR")
if expect_programdir and not programdir:find(expect_programdir, 1, true) then
    os.raise("os.programdir() is '%s', which does not contain '%s' -- the wrong xmake is on PATH",
        programdir, expect_programdir)
end

local srcfile = path.join(programdir, "modules", "core", "tools", "cl", "has_flags.lua")
local src = io.readfile(srcfile)
if not src then
    os.raise("cannot read %s", srcfile)
end

-- the literal text of the fix, built without pattern escapes:
--   line:find("D%d%d%d%d")
local dcode_needle = 'line:find("D' .. string.rep("%d", 4) .. '")'

-- the unpatched 3.1.1 oracle: any stdout line that is not the filename echo is
-- read as "this flag is unsupported"
local original_needle = "if #line > 0 and not line:endswith(filename) then"

-- the falsified v1 fix: matching the plain word "error" flags the C5072 message
-- itself, which ends with "...for better ASAN error reporting"
local v1_needle = 'line:find("error"'

if mode == "fixed" then
    assert(src:find(dcode_needle, 1, true),
        srcfile .. " does not contain the Dxxxx filter -- this is not the fixed build")
    assert(not src:find(original_needle, 1, true),
        srcfile .. " still carries the unpatched any-line-is-an-answer filter")
    assert(not src:find(v1_needle, 1, true),
        srcfile .. " still matches message text -- the C5072 warning would be flagged again")
else
    assert(src:find(original_needle, 1, true),
        srcfile .. " does not carry the unpatched filter -- this is not the original build")
    assert(not src:find(dcode_needle, 1, true),
        srcfile .. " already contains the Dxxxx filter -- the original job is running a fixed xmake")
end

print(string.format("%s: core.tools.cl.has_flags loads and carries the %s oracle, xmake %s in %s",
    mode, mode, xmake.version(), programdir))
