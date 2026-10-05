-- Drives xmake's REAL flag detection (lib.detect.has_flags ->
-- core.tools.cl.has_flags) against a cl-shaped compiler and compares the result
-- with what the original 3.1.1 vs. the fixed build produce.
--
-- Nothing here is mocked except the compiler choice: the detection code, the
-- caching and the output filtering are all xmake's own.
--
-- `xmake l` does not forward arguments to the script, so everything is
-- configured through the environment:
--
--   CL_PROGRAM        path of the cl to check against. on Windows CI this is
--                     the runner's REAL cl.exe -- its probe line
--                     (cl -c -nologo <flags> -Fo<o> <src>) has no debug-info
--                     flag, so with /fsanitize=address on it cl prints
--                     "warning C5072" and still exits 0. that is the bug's
--                     raw material, no stub needed.
--   CLANG_CL_PROGRAM  path of a clang-cl for the unaffected-baseline case
--                     (optional; the case is skipped when absent)
--   EXPECT_MODE       "original" -> assert the unpatched xmake 3.1.1 results
--                     "fixed"    -> assert the results of the fixed build
--   REPORT_ONLY       when set, print what has_flags returns but never fail.
--                     a manual-debugging affordance; no CI step uses it.

import("lib.detect.has_flags")

local cl_program = os.getenv("CL_PROGRAM")
local clang_cl_program = os.getenv("CLANG_CL_PROGRAM")
local mode = os.getenv("EXPECT_MODE") or "original"
local report_only = os.getenv("REPORT_ONLY") ~= nil

if not cl_program then
    os.raise("CL_PROGRAM must point at the cl to check against")
end
if mode ~= "original" and mode ~= "fixed" then
    os.raise("EXPECT_MODE must be 'original' or 'fixed', got '%s'", mode)
end

local asan = {"-fsanitize=address"}

-- expected[i] = {original = <unpatched 3.1.1>, fixed = <the fixed build>}
local cases = {
    {
        tool = "cl", flags = {"-fsanitize=address"},
        expected = {original = false, fixed = true},
        why = "cl supports /fsanitize; C5072 only says the probe line has no debug info (-Zi)",
    },
    {
        tool = "clang-cl", flags = {"-fsanitize=address"}, use_clang_cl = true,
        expected = {original = true, fixed = true},
        why = "core/tools/clang_cl/has_flags.lua only looks at the exit code, so it was never affected",
    },
    {
        tool = "cl", flags = {"-std:c++17"}, sysflags = asan,
        expected = {original = false, fixed = true},
        why = "the one that breaks real builds: package on_check flows pass the "
            .. "toolchain flags as sysflags, and every probe after the asan flag "
            .. "leaks in is answered with C5072",
    },
    {
        tool = "cl", flags = {"-FS"}, sysflags = asan,
        expected = {original = true, fixed = true},
        why = "-FS is hardcoded in core/tools/cl/check_knownargs.lua, so it never reaches the probe",
    },
    {
        tool = "cl", flags = {"-xx"},
        expected = {original = false, fixed = false},
        why = "genuinely unknown option: D9002 must still be reported, the fix may not swallow it",
    },
    {
        -- the two rows above decide the shape of the filter; these two say where its
        -- edges are. both outdata strings are measured, from vstool.iorunv against the
        -- runner's cl 14.51 (run 37328831477, job 111826370215), not guessed.
        tool = "cl", flags = {"-W5"},
        expected = {original = false, fixed = true},
        why = "D9014, a bad VALUE of an option the driver does have: cl assumes /W1, "
            .. "compiles the stub and exits 0. that is support -- matching every four-digit "
            .. "D-code is how the v2 fix was wrong",
    },
    {
        tool = "cl", flags = {"-std:c++23"},
        expected = {original = false, fixed = false},
        why = "a standard this compiler does not implement comes back as D9002, the same "
            .. "code as a typo'd option -- narrowing the filter to two codes must not start "
            .. "calling this supported",
    },
}

print("")
print(string.format("xmake %s, programdir %s", xmake.version(), os.programdir()))
print(string.format("cl:        %s", cl_program))
print(string.format("clang-cl:  %s", clang_cl_program or "(not set, that case will be skipped)"))
print(string.format("expecting the '%s' results%s", mode, report_only and " (report only, no assertions)" or ""))
print("")

local failed = 0
local checked = 0

local function run_case(c, program)
    checked = checked + 1
    local want = report_only and nil or c.expected[mode]
    local errors = nil
    local opt = {
        program = program,
        toolkind = "cc",
        flagkind = "cxflags",   -- what core/tools/cl.lua nf_language() passes
        force = true,     -- never trust a cached detect result
        -- lib.detect.has_flags only returns the boolean, so grab the
        -- diagnostic through the on_check hook instead
        on_check = function (ok, errs)
            errors = errs
            return ok, errs
        end,
    }
    if c.sysflags then
        opt.sysflags = c.sysflags
    end

    local got = has_flags(c.tool, c.flags, opt)
    got = got and true or false

    local ok
    if report_only then
        ok = true
    else
        ok = (got == want)
        if not ok then
            failed = failed + 1
        end
    end
    print(string.format("  [%s] %-9s %-22s sysflags=%-20s -> %-5s (want %s)",
        report_only and "REPORT" or (ok and "PASS" or "FAIL"),
        c.tool,
        table.concat(c.flags, " "),
        c.sysflags and table.concat(c.sysflags, " ") or "-",
        tostring(got),
        tostring(want)))
    print(string.format("         why: %s", c.why))
    if errors then
        print(string.format("         reported: %s", tostring(errors):trim():gsub("\n", "\n                     ")))
    end
end

for _, c in ipairs(cases) do
    local program = c.use_clang_cl and clang_cl_program or cl_program
    if not os.isfile(program) then
        print(string.format("  [SKIP] %-9s %-22s (%s not found)", c.tool, table.concat(c.flags, " "), c.tool))
    else
        run_case(c, program)
    end
end

print("")
if checked == 0 then
    os.raise("nothing was checked -- every case was skipped, so this run proves nothing")
end
if failed > 0 then
    os.raise("%d of %d checks did not match the '%s' expectations", failed, checked, mode)
end
if report_only then
    print("report only -- no assertions were made")
else
    print(string.format("all %d checks match the '%s' expectations", checked, mode))
end
