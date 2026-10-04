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

`-fsanitize=address` is the concrete trigger that got reported. MSVC answers it
with a warning (C5072) when the AddressSanitizer runtime libraries are not
present in that Visual Studio install — the option itself is understood, cl
still compiles, and it still exits `0`. Stock 3.1.1 reads the warning as
"cl does not support `/fsanitize`".

Note the two kinds of command-line diagnostic are genuinely different, and only
one of them means "unsupported":

| diagnostic | level | meaning |
|---|---|---|
| `Command line warning D9002 : ignoring unknown option '-xx'` | driver | the option does not exist |
| C5072 for `/fsanitize=address` | frontend | the option **is** understood; the runtime component is missing |

### xmake does not need to know anything about ASan

Worth stating plainly, because it is the natural objection: a build tool has no
business distinguishing "ASan installed" from "ASan enabled". **It doesn't, and
the fix doesn't make it.** There is exactly one condition that matters —
something put `/fsanitize=address` on the command line, and this MSVC answers
with a warning. Whether the user "enabled ASan" is not a separate axis: if
nothing passes the flag, nothing happens.

The fix is not "teach xmake about sanitizers". It is "stop treating a frontend
warning as an answer to a different question" — only driver-level option
diagnostics (`D9xxx`) and actual errors mean the flag was rejected.

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

Regression window: introduced with the stdout-filtering change for
[xmake-io/xmake#7610](https://github.com/xmake-io/xmake/issues/7610),
present in 3.1.1.

### What is assumed and what is measured

The `windows-msvc` job's first step prints what the runner's **real** cl.exe
actually does with `/fsanitize=address` — stdout, stderr and exit code captured
separately, plus whether `clang_rt.asan_dynamic-x86_64.lib` is present in the
MSVC lib directory. The exact wording of the stub's injected warning is a
stand-in; the assertion that follows does not depend on it, because xmake's
`_get_output()` reacts to *any* non-filename line. If the real wording turns out
to differ, the log will show it and the conclusion is unchanged.


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
stub/stub_cl.c              a stand-in for cl.exe that behaves like one running
                            without the asan runtime component
check/check_has_flags.lua   drives xmake's REAL detection against the stub,
                            5 cases, asserts either the buggy or the fixed results
check/apply_fix.lua         copies patches/cl_has_flags.fixed.lua over the
                            installed xmake's own module tree
patches/                    the fix, as a full file and as a diff
repro/                      an actual xmake project whose build breaks on stock
                            3.1.1 and succeeds with the fix
.github/workflows/ci.yml    windows-msvc, ubuntu-stock, ubuntu-fork-fix
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

Two details that are easy to get wrong and are handled here:

* On Windows, xmake spawns cl through `private/tools/vstool.lua`, which sets
  `VS_UNICODE_OUTPUT` and decodes the captured stdout as **UTF-16LE**. When that
  variable is present the stub emits UTF-16LE too, otherwise xmake reads garbage
  and every check fails for the wrong reason.
* cl echoes the source filename to stdout even on success (`-nologo` only
  suppresses the banner). `_get_output()` skips lines ending with that filename,
  so the stub must emit it or the filter has nothing to filter.

It has two modes:

* **synthetic** (default) — answers everything itself. Runs on Linux/macOS with
  no MSVC at all, which is how the Ubuntu jobs work.
* **passthrough** (`STUB_REAL_CL=/path/to/real/cl.exe`) — injects the C5072
  warning, then hands the unchanged argv to the real compiler and returns its
  exit code. GitHub's Windows runner ships MSVC *with* the asan component, so
  the real cl would stay silent and hide the bug; passthrough makes the
  end-to-end build deterministic while still doing the actual compiling with the
  runner's MSVC.

## The five checks

| # | tool | flags | sysflags | stock 3.1.1 | fixed | why |
|---|---|---|---|---|---|---|
| 1 | `cl` | `-fsanitize=address` | — | `false` | `true` | cl does support `/fsanitize`; C5072 only reports a missing runtime component |
| 2 | `clang-cl` | `-fsanitize=address` | — | `true` | `true` | `core/tools/clang_cl/has_flags.lua` only looks at the exit code, so it was never affected |
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

export STUB_CL=/tmp/stub/cl
export STUB_CLANG_CL=/tmp/stub/clang-cl

# against a stock 3.1.1 install: asserts the buggy results
EXPECT_MODE=bug xmake l check/check_has_flags.lua

# overwrite the installed module with the fix (keeps a .orig backup)
FIXED_LUA=$PWD/patches/cl_has_flags.fixed.lua xmake l check/apply_fix.lua

# now asserts the fixed results
EXPECT_MODE=fixed xmake l check/check_has_flags.lua
```

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
xmake f -c -p windows -a x64 -m debug
xmake -v          # look for /std:c++20 in the cl command line
```

Note that `xmake f -c` is required when switching xmake versions: the detect
cache key does not include the version, so a stale result survives otherwise.

## CI

Three jobs, all using the official install scripts:

* **windows-msvc** — `psget.text -version 3.1.1 -installdir ...`, builds the stub
  with the runner's MSVC, runs the end-to-end repro before and after the fix, and
  the five flag checks in both modes.
* **ubuntu-stock** — `shget.text | bash -s v3.1.1`, same five flag checks in both
  modes.
* **ubuntu-fork-fix** — builds `xflcx1991/xmake@fix-cl-c5072` from source per the
  development guide (`./configure && make && make install PREFIX=`), so the
  branch and the patch file cannot drift apart.

Two gotchas worth knowing:

* `scripts/get.ps1` parses the version with `[version]::Parse()`, so pass
  `-version 3.1.1`, **not** `-version v3.1.1`. It also only mutates `$env:Path`
  for its own session, so the directory has to be re-exported via
  `$GITHUB_PATH`.
* `scripts/get.sh` **always builds from source** (~3-5 min) and its `gitrepo` is
  hardcoded to `xmake-io/xmake.git` — it cannot install a fork, hence the third
  job.
