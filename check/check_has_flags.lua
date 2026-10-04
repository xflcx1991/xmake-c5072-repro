-- Drives xmake's REAL flag detection (lib.detect.has_flags ->
-- core.tools.cl.has_flags) against stub/stub_cl.c, which behaves like a cl.exe
-- running on a machine with no Address Sanitizer runtime component installed.
--
-- Nothing here is mocked except the compiler: the detection code, the caching
-- and the output filtering are all xmake's own.
--
-- `xmake l` does not forward arguments to the script, so everything is
-- configured through the environment:
--
--   STUB_CL        absolute path of the stub cl
--   STUB_CLANG_CL  absolute path of the stub clang-cl (same binary)
--   EXPECT_MODE    "bug"   -> assert the stock xmake 3.1.1 results
--                  "fixed" -> assert the results with patches/ applied

import("lib.detect.has_flags")

local stub_cl = os.getenv("STUB_CL")
local stub_clang_cl = os.getenv("STUB_CLANG_CL")
local mode = os.getenv("EXPECT_MODE") or "bug"

if not stub_cl or not stub_clang_cl then
    os.raise("STUB_CL and STUB_CLANG_CL must point at the compiled stub")
end
if mode ~= "bug" and mode ~= "fixed" then
    os.raise("EXPECT_MODE must be 'bug' or 'fixed', got '%s'", mode)
end

local asan = {"-fsanitize=address"}

-- expected[i] = {bug = <stock 3.1.1>, fixed = <with the patch>}
local cases = {
    {
        tool = "cl", program = stub_cl, flags = {"-fsanitize=address"},
        expected = {bug = false, fixed = true},
        why = "cl does support /fsanitize; C5072 only says the runtime component is missing",
    },
    {
        tool = "clang-cl", program = stub_clang_cl, flags = {"-fsanitize=address"},
        expected = {bug = true, fixed = true},
        why = "core/tools/clang_cl/has_flags.lua only looks at the exit code, so it was never affected",
    },
    {
        tool = "cl", program = stub_cl, flags = {"-std:c++17"}, sysflags = asan,
        expected = {bug = false, fixed = true},
        why = "this is the one that breaks real builds: set_languages() probes leak the asan sysflag",
    },
    {
        tool = "cl", program = stub_cl, flags = {"-FS"}, sysflags = asan,
        expected = {bug = true, fixed = true},
        why = "-FS is hardcoded in core/tools/cl/check_knownargs.lua, so it never reaches the probe",
    },
    {
        tool = "cl", program = stub_cl, flags = {"-xx"},
        expected = {bug = false, fixed = false},
        why = "genuinely unknown option: D9002 must still be reported, the fix may not swallow it",
    },
}

print("")
print(string.format("xmake %s, programdir %s", xmake.version(), os.programdir()))
print(string.format("stub cl: %s", stub_cl))
print(string.format("expecting the '%s' results", mode))
print("")

local failed = 0
for _, c in ipairs(cases) do
    local want = c.expected[mode]
    local errors = nil
    local opt = {
        program = c.program,
        toolkind = "cc",
        flagkind = "cxflags",   -- what core/tools/cl.lua nf_language() passes
        force = true,     -- never trust a cached result across the two modes
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

    local ok = (got == want)
    if not ok then
        failed = failed + 1
    end
    print(string.format("  [%s] %-9s %-22s sysflags=%-20s -> %-5s (want %s)",
        ok and "PASS" or "FAIL",
        c.tool,
        table.concat(c.flags, " "),
        c.sysflags and table.concat(c.sysflags, " ") or "-",
        tostring(got),
        tostring(want)))
    print(string.format("         why: %s", c.why))
    if not ok and errors then
        print(string.format("         reported: %s", tostring(errors):trim():gsub("\n", "\n                     ")))
    end
end

print("")
if failed > 0 then
    os.raise("%d of %d checks did not match the '%s' expectations", failed, #cases, mode)
end
print(string.format("all %d checks match the '%s' expectations", #cases, mode))
