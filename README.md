# xmake 3.1.1: C5072 breaks MSVC flag detection

A minimal, self-contained reproduction of an xmake 3.1.1 regression, plus the
one-file fix and a CI setup that proves both halves on a real Windows runner.

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

Once `-fsanitize=address` is in the target's flags — which is exactly what a
package's `configs = {asan = true}`, or `set_policy("build.sanitizer.address", true)`,
does (see `private/utils/toolchain.lua:get_sanitizer_flags`, which adds it
unconditionally for cl, with no capability check) — it leaks into **every
subsequent probe** as a sysflag.

`set_languages("c++20")` then probes `/std:c++20` and `/std:c++latest`, each one
accompanied by `-fsanitize=address`, each one answered with the same warning,
each one judged unsupported. `nf_language()` in `core/tools/cl.lua` runs out of
candidates and **returns nil**. The language flag is silently dropped, the
source is compiled in MSVC's default C++14 mode, and a C++20 project fails to
build with errors that point nowhere near the real cause.

Corollary, verified by the CI job: a **debug-mode** build (`xmake f -m debug`)
does not reproduce — the target's own `-Zi` suppresses C5072. **Release mode
does**, because nothing puts a debug-info flag on the probe line.

Regression window: introduced with the stdout-filtering change for
[xmake-io/xmake#7610](https://github.com/xmake-io/xmake/issues/7610),
present in 3.1.1.

### What is measured

The `windows-msvc` job's ground-truth step runs the runner's **real** cl.exe
with three probe shapes and prints stdout, stderr and exit code for each:

* A: `/fsanitize=address`, no debug info — xmake's probe shape. Expected: C5072
  on stdout, exit `0`.
* B: same plus `/Zi` — a debug-mode target's shape. Expected: clean stdout.
* C: unknown option `/xx`. Expected: D9002 on stdout, exit `0`.

It also records whether `clang_rt.asan_dynamic-x86_64.lib` is present in the
MSVC lib path — on GitHub runners it is, and C5072 fires anyway.

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
stub/stub_cl.c              a synthetic stand-in for cl.exe (used by the POSIX
                            jobs, which are commented out for now)
check/check_has_flags.lua   drives xmake's REAL detection against CL_PROGRAM
                            (the real cl.exe on Windows, the stub on POSIX),
                            5 cases, asserts either the buggy or the fixed
                            results; REPORT_ONLY=1 prints without asserting
check/apply_fix.lua         copies patches/cl_has_flags.fixed.lua over the
                            installed xmake's own module tree
patches/                    the fix, as a full file and as a diff
repro/                      an actual xmake project whose build breaks on stock
                            3.1.1 (release mode) and succeeds with the fix
.github/workflows/ci.yml    windows-msvc (against the real cl.exe); the two
                            ubuntu jobs are commented out for now
```

Nothing is mocked except the compiler. The detection code, the caching and the
output filtering are all xmake's own.

### The stub

`stub_cl.c` reproduces the three invocations xmake's detection makes:

```
cl                                  -> banner, exit 0        (find_cl.lua probe)
cl -?                               -> option list, exit 0   (_check_from_arglist)
cl -c -nologo <flags> -Fo<o> <src>  -> basename(src), then one diagnostic per
                                       flag, exit 0          (_check_try_running)
```

The diagnostics mirror the measured real-cl behaviour:

* unknown option → `cl : Command line warning D9002 : ignoring unknown option '<opt>'`
* `/fsanitize=address` with no debug-info flag on the line →
  `<src> : warning C5072: ASAN enabled without debug information emission. Enable debug info for better ASAN error reporting`

Two details that are easy to get wrong and are handled here:

* On Windows, xmake spawns cl through `private/tools/vstool.lua`, which sets
  `VS_UNICODE_OUTPUT` and decodes the captured stdout as **UTF-16LE**. When that
  variable is present the stub emits UTF-16LE too, otherwise xmake reads garbage
  and every check fails for the wrong reason. (The POSIX jobs run the stub
  directly, in plain text.)
* cl echoes the source filename to stdout even on success (`-nologo` only
  suppresses the banner). `_get_output()` skips lines ending with that filename,
  so the stub must emit it or the filter has nothing to filter.

## The five checks

| # | tool | flags | sysflags | stock 3.1.1 | fixed | why |
|---|---|---|---|---|---|---|
| 1 | `cl` | `-fsanitize=address` | — | `false` | `true` | cl does support `/fsanitize`; C5072 only says the probe line has no debug info |
| 2 | `clang-cl` | `-fsanitize=address` | — | `true` | `true` | `core/tools/clang_cl/has_flags.lua` only looks at the exit code, so it was never affected (skipped if clang-cl is absent) |
| 3 | `cl` | `-std:c++17` | `-fsanitize=address` | `false` | `true` | **the one that breaks real builds** — `set_languages()` probes leak the asan sysflag |
| 4 | `cl` | `-FS` | `-fsanitize=address` | `true` | `true` | `-FS` is hardcoded in `core/tools/cl/check_knownargs.lua`, so it never reaches a probe |
| 5 | `cl` | `-xx` | — | `false` | `false` | genuinely unknown option: D9002 must still be reported, the fix may not swallow it |

Case 5 is the guard against an over-broad fix.

## Running it locally

`xmake l` **does not forward arguments to the script**, and `xmake l "print(1)"`
does **not** accept inline code — everything is configured through environment
variables.

Linux or macOS, no MSVC required:

```sh
mkdir -p /tmp/stub
cc -O0 -Wall -o /tmp/stub/cl stub/stub_cl.c
cp /tmp/stub/cl /tmp/stub/clang-cl

export CL_PROGRAM=/tmp/stub/cl
export CLANG_CL_PROGRAM=/tmp/stub/clang-cl

# against a stock 3.1.1 install: asserts the buggy results
EXPECT_MODE=bug xmake l check/check_has_flags.lua

# overwrite the installed module with the fix (keeps a .orig backup)
FIXED_LUA=$PWD/patches/cl_has_flags.fixed.lua xmake l check/apply_fix.lua

# now asserts the fixed results
EXPECT_MODE=fixed xmake l check/check_has_flags.lua
```

On a Windows machine with Visual Studio installed you can point
`CL_PROGRAM` at the real `cl.exe` — its probe shape alone triggers C5072, no
stub needed (that is exactly what the CI job does).

Or apply the diff to a source checkout instead:

```sh
cd /path/to/xmake
git apply /path/to/patches/fix-cl-has-flags-c5072.patch
```

`check/apply_fix.lua` refuses to run if `<os.programdir()>/modules/core/tools/cl/has_flags.lua`
does not exist, so a wrong `programdir` fails loudly instead of silently testing
the stock module. Single-file `xmake-bundle-*` builds unpack their modules to a
tmpdir and `os.programdir()` points there, so it works for those too.

The end-to-end project:

```sh
cd repro
xmake f -c -p windows -a x64 -m release   # release: stock 3.1.1 drops /std:c++20
xmake -v                                  # look for /std:c++20 in the cl command line
```

(`-m debug` builds keep the flag even on stock 3.1.1 — the target's `-Zi`
hides C5072 — which is exactly why this bug is easy to miss locally.)

Note that `xmake f -c` is required when switching xmake versions: the detect
cache key does not include the version, so a stale result survives otherwise.

## CI

* **windows-msvc** — `psget.text -version 3.1.1 -installdir ...`, then, against
  the runner's **real** cl.exe (no stub, no PATH tricks — xmake resolves cl via
  the cached VS environment to an absolute path, so shadowing cannot work):
  ground-truth probes, the five flag checks in both modes, and the end-to-end
  repro in release mode (stock: expects the c++20 flag dropped; fixed: expects
  it kept and a clean build), plus a debug-mode measurement showing the target
  `-Zi` masking the bug.
* **ubuntu-stock** / **ubuntu-fork-fix** — currently commented out in
  `ci.yml`; they drive the same checks through the synthetic stub on POSIX.
  Delete the `# ` prefixes to re-enable.

Two gotchas worth knowing:

* `scripts/get.ps1` parses the version with `[version]::Parse()`, so pass
  `-version 3.1.1`, **not** `-version v3.1.1`. It also only mutates `$env:Path`
  for its own session, so the directory has to be re-exported via
  `$GITHUB_PATH`.
* `scripts/get.sh` **always builds from source** (~3-5 min) and its `gitrepo` is
  hardcoded to `xmake-io/xmake.git` — it cannot install a fork, hence the
  fork-fix job builds the branch manually.
