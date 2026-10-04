add_rules("mode.debug", "mode.release")

-- What a package's `configs = {asan = true}` boils down to:
--
--   rules/c++/config/sanitizer.lua -> private/utils/toolchain.get_sanitizer_flags()
--   -> target:add("cxxflags", "-fsanitize=address")
--
-- so from here on EVERY has_flags() probe xmake runs for this project compiles
-- with -fsanitize=address on the command line. On a machine whose MSVC has no
-- Address Sanitizer runtime component, cl answers each of those probes with
-- "Command line warning C5072" and still exits 0.
set_policy("build.sanitizer.address", true)

target("hello")
    set_kind("binary")
    add_files("src/main.cpp")

    -- c++20 on msvc needs `/std:c++20`. That flag is
    --   * not in core/tools/cl/check_knownargs.lua, and
    --   * not parseable out of `cl -?` (the regex (/[%%-%%a%%d]+)%%s+ stops at the ':'),
    -- so it is settled by _check_try_running(), which reads cl's stdout.
    --
    -- With stock 3.1.1 the C5072 line is mistaken for a failure, nf_language()
    -- in core/tools/cl.lua then returns nil for every candidate, the language
    -- flag is silently dropped, and src/main.cpp is compiled in the default
    -- c++14 mode -> the build breaks on the `concept` below.
    set_languages("c++20")
