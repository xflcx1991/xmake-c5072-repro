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
(`cl -c -nologo <flags> -Fo<o> <src>`) carries no debug-info flag, the original
3.1.1 reads the warning as "cl does not support `/fsanitize`" on any machine.

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

The `windows-msvc-original` job's ground-truth step runs the runner's **real**
cl.exe with three probe shapes and prints stdout, stderr and exit code for each:

* A: `/fsanitize=address`, no debug info — xmake's probe shape. Measured: C5072
  on stdout, exit `0`.
* B: same plus `/Zi` — a debug-mode target's shape. Measured: clean stdout.
* C: unknown option `/xx`. Measured: D9002, exit `0` — on **stderr** when cl
  runs directly; through xmake's `vstool` wrapper (`VS_UNICODE_OUTPUT`) the
  diagnostics land in the captured output xmake parses, which is why check
  case 5 still correctly answers "unsupported" with the real cl.

It also records whether `clang_rt.asan_dynamic-x86_64.lib` is present in the
MSVC lib path — on GitHub runners it is, and C5072 fires anyway.

The original job's E2E step is likewise a measurement, not an assertion: it
builds `repro/` in release and debug mode and records whether the c++20 flag
reaches the compiler (see the caveat above).

## The fix

The fix lives on the branch `xflcx1991/xmake@fix-cl-c5072` — v3.1.1 with no
upstream commits missing, plus two commits whose net diff touches exactly one
file, `modules/core/tools/cl/has_flags.lua`. Only fail on driver-level
diagnostics, matched by their **Dxxxx code**:

```lua
if #line > 0 and not line:endswith(filename)
    and line:find("D%d%d%d%d") then
```

Matching the plain word "error" does not work — that was the first version of
this fix, and CI falsified it: the C5072 message itself ends with "...for
better ASAN **error** reporting", so the benign warning was still counted as a
diagnostic and every asan-flagged probe still answered "unsupported". Hard
errors are a non-issue here anyway: they exit non-zero and are raised by
`vstool.iorunv` before the filter runs. Matching the Dxxxx code is also
locale-stable, unlike localized message words.

There is deliberately no copy of the fix in this repository. Every `*-fixed`
job builds xmake from the branch itself, so the code under test and the code
proposed upstream cannot drift apart.

## Layout

```
check/check_has_flags.lua   drives xmake's REAL detection against CL_PROGRAM
                            (the real cl.exe on the Windows runner), 5 cases,
                            asserts either the original or the fixed results;
                            REPORT_ONLY=1 prints without asserting
check/import_module.lua     asserts WHICH xmake is running: loads
                            core.tools.cl.has_flags and checks the oracle in
                            os.programdir() is the one EXPECT_MODE claims
repro/                      an actual xmake project (c++20 + asan policy) used
                            for the E2E measurements and the control builds
.github/workflows/ci.yml    six jobs: windows-msvc, ubuntu, macos-arm64,
                            each x {original, fixed}
```

`check/import_module.lua` is what makes the job names trustworthy. The POSIX
jobs never invoke cl, so the only thing they can prove about the fix is that the
module tree they are running really carries it; the Windows jobs prove the rest
behaviourally. It also takes an optional `EXPECT_PROGRAMDIR` substring, because
the Windows `fixed` job has two xmakes installed at once — the release used as a
build bootstrap and the one built from the branch.

## The five checks

Run on the Windows runner against the **real** cl.exe, through xmake's own
`lib.detect.has_flags` → `core.tools.cl.has_flags` path. `windows-msvc-original`
asserts the left column, `windows-msvc-fixed` the right one — same script, same
runner image, two xmakes:

| # | tool | flags | sysflags | original 3.1.1 | fixed | why |
|---|---|---|---|---|---|---|
| 1 | `cl` | `-fsanitize=address` | — | `false` | `true` | cl does support `/fsanitize`; C5072 only says the probe line has no debug info |
| 2 | `clang-cl` | `-fsanitize=address` | — | `true` | `true` | `core/tools/clang_cl/has_flags.lua` only looks at the exit code, so it was never affected (skipped if clang-cl is absent) |
| 3 | `cl` | `-std:c++17` | `-fsanitize=address` | `false` | `true` | **the one that breaks real builds** — the sysflag shape package/on_check flows produce |
| 4 | `cl` | `-FS` | `-fsanitize=address` | `true` | `true` | `-FS` is hardcoded in `core/tools/cl/check_knownargs.lua`, so it never reaches the probe |
| 5 | `cl` | `-xx` | — | `false` | `false` | genuinely unknown option: D9002 must still be reported, the fix may not swallow it |

Case 5 is the guard against an over-broad fix. The script also refuses to pass
when every case was skipped, so a missing `cl.exe` cannot be mistaken for five
green checks.

## Running it locally

`xmake l` **does not forward arguments to the script**, and `xmake l "print(1)"`
does **not** accept inline code — everything is configured through environment
variables.

On a Windows machine with Visual Studio and an unpatched xmake 3.1.1:

```pwsh
$env:CL_PROGRAM = (Get-Command cl.exe).Source
$env:CLANG_CL_PROGRAM = (Get-Command clang-cl.exe).Source   # optional

# asserts the original (buggy) results
$env:EXPECT_MODE = 'original'
xmake l check/check_has_flags.lua
```

Then build the fix branch and aim the same five checks at it:

```pwsh
git clone --recurse-submodules -b fix-cl-c5072 https://github.com/xflcx1991/xmake.git xmake-src

# xmake's C core can only be built by an existing xmake
cd xmake-src/core
xmake f -c -y -a x64
xmake
Copy-Item build/xmake.exe ../xmake/xmake.exe   # engine.c looks for the modules
cd ../..                                       # next to the exe

$env:EXPECT_MODE = 'fixed'
$env:EXPECT_PROGRAMDIR = 'xmake-src'
& "$PWD\xmake-src\xmake\xmake.exe" l check/check_has_flags.lua
```

The probe shape alone triggers C5072 — no stub is involved anywhere; the same
cl.exe GitHub's runners ship is enough.

`check/import_module.lua` is the cheap half of the same verification and needs
no compiler at all, which is why it is the only check the POSIX jobs can run:

```sh
EXPECT_MODE=original xmake l check/import_module.lua   # an unpatched 3.1.1
EXPECT_MODE=fixed    xmake l check/import_module.lua   # a built fix branch
```

Do not build the checkout with `--embed=y` if you want to inspect it: an
embedded binary unpacks its modules into a tmpdir and `os.programdir()` points
there, so the assertions would be checking a throwaway copy.

To point an existing xmake binary at a source checkout's module tree without
building anything, set `XMAKE_PROGRAM_DIR=<checkout>/xmake` — handy for checking
a working copy that has not been installed.

The end-to-end project:

```sh
cd repro
xmake f -c -p windows -a x64 -m release
xmake -v          # watch for /std:c++20 in the cl command line
```

Note that `xmake f -c` is required when switching xmake versions: the detect
cache key does not include the version, so a stale result survives otherwise.

## CI

Six jobs: three platforms x {original, fixed}. Nothing patches an installed
xmake in place any more, so each job tests exactly one xmake and the job name
says which one — `check/import_module.lua` asserts it before any build runs.

| job | xmake under test | what it proves |
|---|---|---|
| `windows-msvc-original` | the 3.1.1 release, via setup-xmake | the bug, against the runner's **real** cl.exe: ground-truth probes, the five flag checks in `original` mode, the E2E measurement |
| `windows-msvc-fixed` | built from `fix-cl-c5072` | the same five checks in `fixed` mode, plus a release build asserting the c++20 flag reaches cl and no `error C`/`error LNK` appears |
| `ubuntu-original` | the 3.1.1 release, via setup-xmake | control build through gcc: `-std=c++` and `-fsanitize=address` both reach the compiler, so the project itself is healthy |
| `ubuntu-fixed` | built from `fix-cl-c5072` | the same control build, unchanged by the fix |
| `macos-arm64-original` | the 3.1.1 release, via setup-xmake | the control build on AppleClang / arm64 |
| `macos-arm64-fixed` | built from `fix-cl-c5072` | the same control build on AppleClang / arm64 |

Only Windows differs between the two halves, because that is where the bug lives.
The ubuntu and macos pairs are regression controls: **both are expected to pass,
before and after**. They show the fix does not disturb toolchains that never had
the problem, and they are the only place `import_module.lua` can check the
patched oracle, since a gcc build never loads `core/tools/cl/has_flags.lua`.

No stub, no PATH tricks anywhere — xmake resolves cl through the cached VS
environment to an absolute path, so shadowing could never work, and it is not
needed: the probe shape alone triggers C5072.

Three gotchas worth knowing:

* `setup-xmake`'s `getInstallerUrl` only `core.warning()`s when a release asset
  404s and then **silently downgrades to the previous version**, so every
  `original` job hard-asserts that `xmake --version` really contains
  `$XMAKE_VERSION` instead of trusting the action.
* On Linux and macOS `setup-xmake` **always builds from source** — its
  unix-install path runs `./configure && make && make install` even for a tag —
  so the `original` jobs there are as slow as the `fixed` ones. That was equally
  true of the `shget.text` script this workflow used before.
* The Windows `fixed` job has two xmakes installed at once, because xmake's C
  core can only be compiled by an existing xmake. The release is a bootstrap
  only: every later step invokes `$env:FIXED_XMAKE` by absolute path, and
  `EXPECT_PROGRAMDIR=xmake-src` pins which tree `os.programdir()` resolved to.
  For the same reason the branch build must not use `--embed=y` — an embedded
  binary unpacks its modules into a tmpdir, so the oracle assertion would be
  reading a throwaway copy.
