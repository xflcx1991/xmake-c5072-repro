# xmake 3.1.1: C5072 breaks MSVC flag detection

A minimal reproduction of an xmake 3.1.1 regression, the one-file fix, and a
CI setup that proves both halves against a real Windows runner — by driving
xmake's own flag detection into the runner's real `cl.exe` and asserting what
it answers. Nothing is stubbed or mocked.

## The bug

xmake decides whether `cl.exe` supports a flag by **reading cl's stdout**, not
by looking at the exit code — because cl exits `0` even for an unknown option.
That much is legitimate; there is no exit code to trust.

The problem is the oracle it uses. `_get_output()` in
`modules/core/tools/cl/has_flags.lua`:

```lua
if #line > 0 and not line:endswith(filename) then
    table.insert(output, line)     -- anything that is not the filename echo
end                                -- is treated as "this flag is unsupported"
```

That says: *any* stdout line that is not the filename echo means rejection. But
a compiler routinely prints benign warnings to stdout **while accepting the
flag and exiting 0**. The oracle is unsound, and any such warning silently
turns a supported flag into an "unsupported" one.

`-fsanitize=address` is the concrete trigger that got reported. Measured on
GitHub `windows-latest` (MSVC 19.51, ASan runtime **installed**), cl answers a
probe like `cl /nologo /c /fsanitize=address /Fo<o> <src>` with:

```
<src> : warning C5072: ASAN enabled without debug information emission. Enable debug info for better ASAN error reporting
```

and still exits `0`. The warning fires whenever `/fsanitize=address` is on the
command line **without a debug-info flag** (`/Zi`, `/ZI`, `/Z7`) — it does not
mean "ASan is not installed". Because xmake's own probe line
(`cl -c -nologo <flags> -Fo<o> <src>`) carries no debug-info flag, stock 3.1.1
reads the warning as "cl does not support `/fsanitize`" on any stock machine.

Note the two kinds of command-line diagnostic are genuinely different, and only
one of them means "unsupported":

| diagnostic | level | meaning |
|---|---|---|
| `Command line warning D9002 : ignoring unknown option '-xx'` | driver | the option does not exist |
| `warning C5072: ASAN enabled without debug information emission ...` | frontend | the option **is** understood; the probe line has no debug info |

### xmake does not need to know anything about ASan

Worth stating plainly, because it is the natural objection: the fix does not
interpret C5072 at all — it does not try to distinguish "ASan installed" from
"debug info missing" from anything else. There is exactly one condition that
matters: did cl print a *driver-level* option diagnostic (`D9xxx`) or an error?
A frontend warning is not an answer to "is this flag supported", whatever it
says.

The fix is not "teach xmake about sanitizers". It is "stop treating a frontend
warning as an answer to a different question".

### Why that breaks unrelated things

`lib/detect/has_flags.lua` builds the probe command line as:

```lua
local checkflags = table.join(flags, opt.sysflags)
```

So once `-fsanitize=address` rides along as a **sysflag** — which is exactly
what package installs and `on_check` flows do, passing the toolchain's flags
into every subsequent capability probe — each probe is answered with C5072
and judged "unsupported".

`set_languages("c++20")` then probes `/std:c++20` and `/std:c++latest`, each
one accompanied by `-fsanitize=address`, each one answered with the same
warning, each one judged unsupported. `nf_language()` in `core/tools/cl.lua`
runs out of candidates and **returns nil**. The language flag is silently
dropped, the source is compiled in MSVC's default C++14 mode, and a C++20
project fails to build with errors that point nowhere near the real cause.
Check case 3 in `check/check_has_flags.lua` reproduces exactly this shape
(flag under test + asan sysflag) against the real cl.

A measured caveat: a *plain* project build (`set_policy("build.sanitizer.address", true)`
+ `set_languages("c++20")`, no packages) does **not** reproduce — the CI job
records that the `set_languages` probe in that flow carries no asan sysflag,
so C5072 never fires and the language flag survives in both release and debug
mode. The breakage needs the sysflag leak, which is why the five flag checks —
not the plain E2E build — are the proof.

Regression window: introduced with the stdout-filtering change for
[xmake-io/xmake#7610](https://github.com/xmake-io/xmake/issues/7610),
present in 3.1.1.

### What is measured

The `windows-msvc` job's ground-truth step runs the runner's **real** cl.exe
with three probe shapes and prints stdout, stderr and exit code for each:

* A: `/fsanitize=address`, no debug info — xmake's probe shape. Measured: C5072
  on stdout, exit `0`.
* B: same plus `/Zi` — a debug-mode target's shape. Measured: clean stdout.
* C: unknown option `/xx`. Measured: D9002, exit `0` — on **stderr** when cl
  runs directly; through xmake's `vstool` wrapper (`VS_UNICODE_OUTPUT`) the
  diagnostics land in the captured output xmake parses, which is why check
  case 5 still correctly answers "unsupported" with the real cl.

It also records whether `clang_rt.asan_dynamic-x86_64.lib` is present in the
MSVC lib path — on GitHub runners it is, and C5072 fires anyway.

The stock-xmake E2E step is likewise a measurement, not an assertion: it
builds `repro/` in release and debug mode and records whether the c++20 flag
reaches the compiler (see the caveat above).

## The fix

`patches/cl_has_flags.fixed.lua` — only fail on driver-level diagnostics:

```lua
if #line > 0 and not line:endswith(filename)
    and (line:find("error", 1, true) or line:find("D%d%d%d%d")) then
```

`patches/fix-cl-has-flags-c5072.patch` is the same change as a `git apply`-able
diff against an xmake checkout.

## Layout

```
check/check_has_flags.lua   drives xmake's REAL detection against CL_PROGRAM
                            (the real cl.exe on the Windows runner), 5 cases,
                            asserts either the buggy or the fixed results;
                            REPORT_ONLY=1 prints without asserting
check/apply_fix.lua         copies patches/cl_has_flags.fixed.lua over the
                            installed xmake's own module tree
check/import_module.lua     smoke test that the patched module still parses,
                            loads and really carries the filter (used by the
                            POSIX jobs, which never invoke cl)
patches/                    the fix, as a full file and as a diff
repro/                      an actual xmake project (c++20 + asan policy) used
                            for the E2E measurements and the control builds
.github/workflows/ci.yml    windows-msvc, ubuntu-stock, ubuntu-fork-fix,
                            macos-arm64
```

## The five checks

Run on the Windows runner against the **real** cl.exe, through xmake's own
`lib.detect.has_flags` → `core.tools.cl.has_flags` path:

| # | tool | flags | sysflags | stock 3.1.1 | fixed | why |
|---|---|---|---|---|---|---|
| 1 | `cl` | `-fsanitize=address` | — | `false` | `true` | cl does support `/fsanitize`; C5072 only says the probe line has no debug info |
| 2 | `clang-cl` | `-fsanitize=address` | — | `true` | `true` | `core/tools/clang_cl/has_flags.lua` only looks at the exit code, so it was never affected (skipped if clang-cl is absent) |
| 3 | `cl` | `-std:c++17` | `-fsanitize=address` | `false` | `true` | **the one that breaks real builds** — the sysflag shape package/on_check flows produce |
| 4 | `cl` | `-FS` | `-fsanitize=address` | `true` | `true` | `-FS` is hardcoded in `core/tools/cl/check_knownargs.lua`, so it never reaches the probe |
| 5 | `cl` | `-xx` | — | `false` | `false` | genuinely unknown option: D9002 must still be reported, the fix may not swallow it |

Case 5 is the guard against an over-broad fix.

## Running it locally

`xmake l` **does not forward arguments to the script**, and `xmake l "print(1)"`
does **not** accept inline code — everything is configured through environment
variables.

On a Windows machine with Visual Studio and a stock xmake 3.1.1:

```pwsh
$env:CL_PROGRAM = (Get-Command cl.exe).Source
$env:CLANG_CL_PROGRAM = (Get-Command clang-cl.exe).Source   # optional

# asserts the buggy results
$env:EXPECT_MODE = 'bug'
xmake l check/check_has_flags.lua

# overwrite the installed module with the fix (keeps a .orig backup)
$env:FIXED_LUA = "$PWD\patches\cl_has_flags.fixed.lua"
xmake l check/apply_fix.lua

# now asserts the fixed results
$env:EXPECT_MODE = 'fixed'
xmake l check/check_has_flags.lua
```

The probe shape alone triggers C5072 — no stub is involved anywhere; the same
cl.exe GitHub's runners ship is enough.

Or apply the diff to a source checkout instead:

```sh
cd /path/to/xmake
git apply /path/to/patches/fix-cl-has-flags-c5072.patch
```

`check/apply_fix.lua` refuses to run if `<os.programdir()>/modules/core/tools/cl/has_flags.lua`
does not exist, so a wrong `programdir` fails loudly instead of silently testing
the stock module. Single-file `xmake-bundle-*` builds unpack their modules to a
tmpdir and `os.programdir()` points there, so it works for those too.

On Linux/macOS the same project builds cleanly through gcc/AppleClang (that is
the control build in the POSIX jobs), and `check/import_module.lua` verifies
the patched module loads there:

```sh
FIXED_LUA=$PWD/patches/cl_has_flags.fixed.lua xmake l check/apply_fix.lua
xmake l check/import_module.lua
```

The end-to-end project:

```sh
cd repro
xmake f -c -p windows -a x64 -m release
xmake -v          # watch for /std:c++20 in the cl command line
```

Note that `xmake f -c` is required when switching xmake versions: the detect
cache key does not include the version, so a stale result survives otherwise.

## CI

Four jobs, all using the official install scripts:

* **windows-msvc** — `psget.text -version 3.1.1 -installdir ...`, then, against
  the runner's **real** cl.exe (no stub, no PATH tricks — xmake resolves cl via
  the cached VS environment to an absolute path, so shadowing cannot work):
  ground-truth probes, the five flag checks in both modes, the E2E
  measurements, and — with the fix applied — the five checks again plus a
  release build asserting the c++20 flag is kept and the build is clean.
* **ubuntu-stock** — `shget.text | bash -s v3.1.1`. Control build through gcc
  (the project itself is healthy: both `-std=c++` and `-fsanitize=address`
  reach the compiler), then `apply_fix` + import smoke + rebuild, proving the
  patched module is loadable and normal builds are unaffected on POSIX.
* **ubuntu-fork-fix** — builds `xflcx1991/xmake@fix-cl-c5072` from source per
  the development guide (`./configure && make && make install PREFIX=`), so
  the branch and the patch file cannot drift apart.
* **macos-arm64** — same control build + fix safety as ubuntu-stock, on
  AppleClang, arm64 hardware.

Two gotchas worth knowing:

* `scripts/get.ps1` parses the version with `[version]::Parse()`, so pass
  `-version 3.1.1`, **not** `-version v3.1.1`. It also only mutates `$env:Path`
  for its own session, so the directory has to be re-exported via
  `$GITHUB_PATH`.
* `scripts/get.sh` **always builds from source** (~3-5 min) and its `gitrepo` is
  hardcoded to `xmake-io/xmake.git` — it cannot install a fork, hence the
  fork-fix job builds the branch manually.
