--!noscript
-- What does xmake's own child-process wrapper actually receive from cl?
--
-- Every other step in this repo talks to cl through PowerShell and sees cl's
-- real stdout and stderr as two separate files. core.tools.cl.has_flags does not
-- use those streams: it calls private.tools.vstool.iorunv(), which sets
-- VS_UNICODE_OUTPUT to a raw file descriptor and returns a single `outdata`.
-- The claim that has to be measured here is that D9002 -- the diagnostic for an
-- unsupported flag, which cl emits with exit code 0 -- lands inside `outdata`,
-- because _get_output() only ever looks at outdata. Nothing else in this repo
-- tests that, and PowerShell cannot answer it: whether the text reaches the
-- stream depends on the redirection mechanism, not on cl.
--
-- This is why `exit != 0` cannot carry the verdict on its own. On a toolset
-- without /options:strict, an unrecognized option is a warning at exit 0, so the
-- failure is only visible as text. Whether that text is where the parser looks
-- is the question below.
--
-- Measurement only: prints both streams, never asserts, always exits 0.
--
--   CL_PROGRAM   required, the cl.exe to probe
--   VSTOOL_CASES optional, ';' separated flag sets, each passed verbatim after
--                -c -nologo (defaults to the interesting ones)

import("private.tools.vstool")

local program = os.getenv("CL_PROGRAM")
if not program then
    print("CL_PROGRAM is not set -- nothing to measure, and this script cannot guess the toolchain")
    return
end

-- the stub has to be a .c file: _get_extension() picks the suffix from the tool
-- kind, and a C source is what a cc probe compiles
local sourcefile = path.join(os.tmpdir(), "vstool_dump_probe.c")
io.writefile(sourcefile, "int main(void){return 0;}\n")

-- each case is a flag string; "" is the baseline
local cases = os.getenv("VSTOOL_CASES")
if cases then
    local split = {}
    for item in cases:gmatch("[^;]+") do
        table.insert(split, item:trim())
    end
    cases = split
else
    cases = {
        "",
        "-fsanitize=address",
        "-xx",
        "-options:strict",
        "-options:strict -fsanitize=address",
        "-options:strict -xx",
        "-W5",
        "-std:c++23",
        "-analyze",
        "-?",
    }
end

-- is it a Dxxxx (driver-level option diagnostic, what should decide support) or a
-- Cxxxx (frontend warning/error, which the fix must not read as "unsupported")?
local function codes(text)
    local found = {}
    for code in (text or ""):gmatch("([DC]%d%d%d%d)") do
        table.insert(found, code)
    end
    return #found > 0 and table.concat(found, ",") or "none"
end

-- one text, printed with its length so nil and "" stay distinguishable: a stream
-- that is present but empty is a different answer from one that was never
-- redirected into
local function show(label, text)
    if text == nil then
        print(("  %s: <nil>"):format(label))
        return
    end
    if type(text) ~= "string" then
        print(("  %s: a %s, not a string -- its fields follow"):format(label, type(text)))
        for key, value in pairs(text or {}) do
            if type(value) == "string" then
                show(("  %s.%s"):format(label, key), value)
            else
                print(("  %s.%s: %s"):format(label, key, tostring(value)))
            end
        end
        return
    end
    print(("  %s: %d bytes, D/C codes: %s"):format(label, #text, codes(text)))
    for line in text:gmatch("[^\r\n]+") do
        print(("    |%s"):format(line))
    end
end

-- the whole point: outdata is what _get_output() parses, and a non-zero exit never
-- reaches it at all -- vstool raises first, so the raised text is all we get back
for _, flags in ipairs(cases) do

    -- -? is _check_from_arglist()'s own call shape; everything else is
    -- _check_try_running()'s, including the -Fo<nul> output it redirects to
    local arglist = flags == "-?"
    local argv = arglist and { "-?" } or { "-c", "-nologo" }
    if not arglist then
        for flag in flags:gmatch("%S+") do
            table.insert(argv, flag)
        end
        table.insert(argv, "-Fo" .. os.nuldev())
        table.insert(argv, sourcefile)
    end
    print("=== case: vstool.iorunv(cl, " .. table.concat(argv, " ") .. " ...)")
    local raised = nil
    local outdata, errdata = try { function ()
        -- {curdir = ...} and no envs, the way core/tools/cl/has_flags.lua calls it
        return vstool.iorunv(program, argv, {curdir = os.tmpdir()})
    end, catch { function (errs) raised = errs end } }
    if raised then
        print("  RAISED (vstool.iorunv does not return for a non-zero exit, so this text is")
        print("  the only thing has_flags can read on that path):")
        show("raised", raised)
    else
        print("  returned (exit 0 -- the verdict can only come from the text below):")
    end
    show("outdata", outdata)
    show("errdata", errdata)
    print("")
end

print("done. nothing asserted; the numbers above are the answer.")
