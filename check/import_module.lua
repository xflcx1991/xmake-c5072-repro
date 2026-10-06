--!noscript
-- Asserts WHICH xmake is running and WHAT its core.tools.cl.has_flags says.
--
-- The ubuntu/macos jobs never touch MSVC, so this is the only thing they can
-- prove about the fix: the module tree in os.programdir() loads, and it carries
-- the oracle the job claims. The behavioral proof lives in the windows jobs,
-- which run the seven flag checks against the real cl.exe.
--
-- `xmake l` does not forward arguments to the script, so everything is
-- configured through the environment:
--
--   EXPECT_MODE       "original" -> assert the unpatched 3.1.1 oracle is present
--                     "fixed"    -> assert the two-code oracle is present, and the
--                                   unpatched, v1 (message text), v2 (any Dxxxx)
--                                   and strict-gate shapes are all gone (default)
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

-- the literal text of the fix: only the two codes that mean "this driver does not
-- have that option" are read as an answer about support.
--   line:find("D9002", 1, true) or line:find("D8043", 1, true)
-- built without pattern escapes, so a reformat of the patch cannot make this pass
-- by accident -- but neither can a rewrite that keeps the behavior. the behavioral
-- proof is the flag check, not this file.
--
-- the needles carry their quotes and their plain-flag argument on purpose:
-- unpatched 3.1.1 already writes D9002 twice in prose above _get_output, so a bare
-- "D9002" would be found in the ORIGINAL build too and the check would say the
-- fixed code is present when it is not.
local needle_d9002 = '"D9002", 1, true)'
local needle_d8043 = '"D8043", 1, true)'

-- the /options:strict capability gate, measured redundant and then dropped: it
-- changed which channel carried the answer, never the answer (identical verdicts
-- with it live and with it off), and it only opens when the detect-cache entry was
-- written by a gate-aware xmake -- which an upgraded user's is not. asserted
-- ABSENT, because the same is true of any code that injects the option, and its
-- comment says why it must stay out.
--
-- the quoted dash form is the argv insertion; the prose in the module spells the
-- option /options:strict, so this cannot hit a comment.
local needle_strict_gate = '"-options:strict"'
local needle_strict_field = "_options_strict"

-- the falsified v2 fix: matching ANY four-digit D-code also catches D9014, cl's
-- "invalid value '5' for '/W'; assuming '1'", and calls a supported option with a
-- bad value unsupported
local v2_needle = 'line:find("D' .. string.rep("%d", 4) .. '")'

-- the falsified v1 fix: matching the plain word "error" flags the C5072 message
-- itself, which ends with "...for better ASAN error reporting"
local v1_needle = 'line:find("error"'

-- the unpatched 3.1.1 oracle: any stdout line that is not the filename echo is
-- read as "this flag is unsupported"
local original_needle = "if #line > 0 and not line:endswith(filename) then"

if mode == "fixed" then
    assert(src:find(needle_d9002, 1, true),
        srcfile .. " does not read D9002 -- this is not the fixed build")
    assert(src:find(needle_d8043, 1, true),
        srcfile .. " does not read D8043 -- this is not the fixed build")
    assert(not src:find(needle_strict_gate, 1, true),
        srcfile .. " injects /options:strict again -- measured redundant, and it never opens on an upgraded cache")
    assert(not src:find(needle_strict_field, 1, true),
        srcfile .. " records a driver capability field again -- the gate that read it was measured away")
    assert(not src:find(v2_needle, 1, true),
        srcfile .. " still matches every Dxxxx code -- D9014 would be flagged again")
    assert(not src:find(original_needle, 1, true),
        srcfile .. " still carries the unpatched any-line-is-an-answer filter")
    assert(not src:find(v1_needle, 1, true),
        srcfile .. " still matches message text -- the C5072 warning would be flagged again")
else
    assert(src:find(original_needle, 1, true),
        srcfile .. " does not carry the unpatched filter -- this is not the original build")
    assert(not src:find(needle_d9002, 1, true),
        srcfile .. " already reads D9002 -- the original job is running a fixed xmake")
    assert(not src:find(needle_d8043, 1, true),
        srcfile .. " already reads D8043 -- the original job is running a fixed xmake")
    assert(not src:find(v2_needle, 1, true),
        srcfile .. " already contains the Dxxxx filter -- the original job is running a fixed xmake")
end

print(string.format("%s: core.tools.cl.has_flags loads and carries the %s oracle, xmake %s in %s",
    mode, mode, xmake.version(), programdir))
