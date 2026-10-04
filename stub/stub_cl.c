// A minimal stand-in for Microsoft's cl.exe.
//
// xmake decides whether a flag is supported by READING CL'S STDOUT, not by
// looking at the exit code -- cl exits 0 even for an unknown option. This stub
// reproduces exactly the three invocations xmake's detection makes, so the
// logic can be exercised on any platform, with or without MSVC installed, and
// with a deterministic result:
//
//   cl                                  -> banner, exit 0
//   cl -?                               -> option list, exit 0
//   cl -c -nologo <flags> -Fo<o> <src>  -> basename(src), then one diagnostic
//                                          per flag, exit 0
//
// The diagnostics mirror real cl:
//
//   option cl does not know       -> "Command line warning D9002" (driver level)
//   /fsanitize without the asan   -> "Command line warning C5072" (frontend)
//   runtime component installed
//
// Both are warnings and both exit 0. C5072 is the one xmake 3.1.1 mistakes for
// a real failure: _get_output() in modules/core/tools/cl/has_flags.lua treats
// every stdout line that is not the filename echo as an unsupported flag.
//
// On Windows xmake spawns cl through private/tools/vstool.lua, which sets
// VS_UNICODE_OUTPUT=<fd of the capture file> and decodes that file as UTF-16LE.
// So when that variable is present we must emit UTF-16LE, otherwise xmake reads
// garbage and every check fails for the wrong reason.
//
// Two modes:
//
//   STUB_REAL_CL unset  -> fully synthetic. Enough for check/check_has_flags.lua,
//                          runs anywhere, no MSVC required.
//   STUB_REAL_CL set    -> passthrough. Injects the C5072 warning, then hands the
//                          unchanged argv to the real cl.exe and returns its exit
//                          code. This is what makes the end-to-end build in
//                          repro/ reproduce deterministically on a CI runner whose
//                          MSVC *does* ship the asan component (GitHub's does, so
//                          the real cl would stay silent and hide the bug).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <io.h>
#include <fcntl.h>
#include <process.h>
#else
#include <unistd.h>
#include <sys/wait.h>
#endif

static int g_unicode = 0;

static void emit(const char *text)
{
    const unsigned char *p = (const unsigned char *)text;
    if (g_unicode)
    {
        for (; *p; ++p)
        {
            fputc(*p, stdout);
            fputc(0, stdout);
        }
        fputc('\r', stdout); fputc(0, stdout);
        fputc('\n', stdout); fputc(0, stdout);
    }
    else
    {
        fputs(text, stdout);
        fputs("\n", stdout);
    }
    fflush(stdout);
}

// the option list printed by `cl -?`, consumed by _check_from_arglist() with
// the pattern (/[%%-%%a%%d]+)%%s+ -- note it needs whitespace right after the
// option, which is why `/std:<...>` and `/fsanitize[=...]` are never captured:
// the ':' and '[' stop the match. That is what pushes those flags on to
// _check_try_running(), where C5072 then breaks them.
static void emit_help(void)
{
    static const char *const lines[] = {
        "Microsoft (R) Optimizing Compiler Version 19.44.35207 for x64",
        "Copyright (C) Microsoft Corporation.  All rights reserved.",
        "",
        "usage: cl [ option... ] filename... [ /link linkoption... ]",
        "",
        "                          -OPTIMIZATION-",
        "",
        "/O1 (minimize space)  /O2 (maximize speed)  /Od (disable)  /Ox (maximize)",
        "/Os (favor small code)  /Ot (favor fast code)",
        "",
        "                          -CODE GENERATION-",
        "",
        "/FS (force synchronous PDB writes)  /EHsc (C++ exception handling)",
        "/permissive- (disable permissive mode)  /utf-8 (set both charsets)",
        "/std:<c++14|c++17|c++20|c++latest> (C++ standard version)",
        "/fsanitize[={address|thread}] (enable the sanitizers)",
        "/Zc:<feature>[-] (enable or disable a conformance feature)",
        "",
        "                          -OUTPUT FILES-",
        "",
        "/Fo<file> (name the .OBJ file)  /Fe<file> (name the executable)",
        "/Fd<file> (name the .PDB file)  /FR<file> (name the .SBR file)",
        NULL
    };
    int i;
    for (i = 0; lines[i]; ++i) emit(lines[i]);
}

static int starts_with(const char *s, const char *prefix)
{
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

// options this stub pretends to understand; anything else is "unknown" and
// earns a D9002, exactly like the real driver
static int is_known(const char *arg)
{
    static const char *const exact[] = {
        "-c", "-nologo", "-FS", "-utf-8", "-permissive-", "-bigobj",
        "-EHsc", "-GR", "-GR-", "-Zi", "-Z7", "-Od", "-O1", "-O2", "-Ox",
        "-MD", "-MDd", "-MT", "-MTd", "-LD", "-LDd",
        "-W0", "-W1", "-W2", "-W3", "-W4", "-Wall", "-WX", "-TP", "-TC",
        "-Gm-", "-MP", "-FC", "-showIncludes",
        NULL
    };
    static const char *const prefixes[] = {
        "-Fo", "-Fe", "-Fd", "-Fp", "-Fa", "-FR", "-FI", "-I", "-D", "-U",
        "-std:", "-source-charset:", "-execution-charset:", "-external:I",
        "-external:W", "-Zc:", "-Yc", "-Yu", "-wd", "-we", "-wo",
        "-fsanitize=",   // a real option; whether it WORKS depends on the asan
                        // runtime component, which is what C5072 reports
        "-fsanitize:",
        NULL
    };
    char buf[256];
    const char *a = arg;
    int i;

    if (*a == '/')
    {
        buf[0] = '-';
        strncpy(buf + 1, a + 1, sizeof(buf) - 2);
        buf[sizeof(buf) - 1] = '\0';
        a = buf;
    }

    for (i = 0; exact[i]; ++i)
        if (strcmp(a, exact[i]) == 0) return 1;
    for (i = 0; prefixes[i]; ++i)
        if (starts_with(a, prefixes[i])) return 1;
    return 0;
}

static int is_asan(const char *arg)
{
    if (arg[0] != '-' && arg[0] != '/') return 0;
    return starts_with(arg + 1, "fsanitize=address") ||
           starts_with(arg + 1, "fsanitize:address");
}

// Source files cannot be recognised by "does not start with - or /": on POSIX a
// path like /tmp/.xmake1000/xxx/cl_has_flags_1.c starts with '/'. Match on the
// extension instead, which works on both platforms.
static int is_source(const char *arg)
{
    static const char *const exts[] = {
        ".c", ".C", ".i", ".ii", ".cc", ".cp", ".cpp", ".cxx", ".c++", ".inl",
        NULL
    };
    size_t len = strlen(arg);
    int i;

    for (i = 0; exts[i]; ++i)
    {
        size_t n = strlen(exts[i]);
        if (len > n && strcmp(arg + len - n, exts[i]) == 0) return 1;
    }
    return 0;
}

// last argument that is not an option, i.e. the source file
static const char *find_source(int argc, char **argv)
{
    int i;
    const char *src = NULL;
    for (i = 1; i < argc; ++i)
    {
        if (is_source(argv[i])) src = argv[i];
    }
    return src;
}

static const char *basename_of(const char *p)
{
    const char *base = p;
    for (; *p; ++p)
        if (*p == '/' || *p == '\\') base = p + 1;
    return base;
}

// run the real cl with this stub's own argv (argv[0] replaced by the real path)
static int passthrough(const char *real, int argc, char **argv)
{
    char **child_argv = malloc(sizeof(char *) * (argc + 1));
    int i, code;

    if (!child_argv) return 1;
    child_argv[0] = (char *)real;
    for (i = 1; i < argc; ++i) child_argv[i] = argv[i];
    child_argv[argc] = NULL;

    fflush(stdout);
#ifdef _WIN32
    code = _spawnv(_P_WAIT, real, (const char *const *)child_argv);
    if (code == -1)
    {
        fprintf(stderr, "stub_cl: cannot spawn %s\n", real);
        code = 1;
    }
#else
    {
        pid_t pid = fork();
        int status = 0;
        if (pid == 0)
        {
            execv(real, child_argv);
            _exit(127);
        }
        waitpid(pid, &status, 0);
        code = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    }
#endif
    free(child_argv);
    return code;
}

int main(int argc, char **argv)
{
    int i;
    const char *src;
    const char *real_cl = getenv("STUB_REAL_CL");
    char line[512];

#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    g_unicode = getenv("VS_UNICODE_OUTPUT") != NULL;

    // find_cl.lua runs a bare `cl` to verify the program exists
    if (argc <= 1)
    {
        emit("Microsoft (R) Optimizing Compiler Version 19.44.35207 for x64");
        emit("Copyright (C) Microsoft Corporation.  All rights reserved.");
        emit("");
        emit("usage: cl [ option... ] filename... [ /link linkoption... ]");
        return 0;
    }

    // _check_from_arglist() parses this. Kept synthetic in both modes so the set
    // of "known args" does not drift with the runner's MSVC version.
    if (argc == 2 && (strcmp(argv[1], "-?") == 0 || strcmp(argv[1], "/?") == 0))
    {
        emit_help();
        return 0;
    }

    if (real_cl && *real_cl)
    {
        // Passthrough: pretend the asan runtime component is missing, then let
        // the real compiler do the actual work and decide the exit code.
        for (i = 1; i < argc; ++i)
        {
            if (is_asan(argv[i]))
            {
                emit("cl : Command line warning C5072 : Address Sanitizer is not "
                     "installed. This configuration is unsupported.");
                break;
            }
        }
        return passthrough(real_cl, argc, argv);
    }

    // a compile invocation: cl echoes the source file name first, even when it
    // succeeds, because -nologo only suppresses the banner
    src = find_source(argc, argv);
    if (src) emit(basename_of(src));

    for (i = 1; i < argc; ++i)
    {
        if (argv[i][0] != '-' && argv[i][0] != '/') continue;
        if (is_source(argv[i])) continue;   // POSIX absolute path, not an option
        if (is_asan(argv[i]))
        {
            // the machine has no Address Sanitizer runtime component, so cl
            // warns -- but still compiles, and still exits 0
            emit("cl : Command line warning C5072 : Address Sanitizer is not "
                 "installed. This configuration is unsupported.");
        }
        else if (!is_known(argv[i]))
        {
            snprintf(line, sizeof(line),
                     "cl : Command line warning D9002 : ignoring unknown option '%s'",
                     argv[i]);
            emit(line);
        }
    }
    return 0;
}
