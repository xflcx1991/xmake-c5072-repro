-- Overwrites the cl flag-detection module inside the INSTALLED xmake with the
-- patched copy from this repo.
--
-- os.programdir() is where xmake keeps its Lua modules, whatever the install
-- method:
--
--   curl -fsSL https://xmake.io/shget.text | bash -s v3.1.1  -> ~/.local/share/xmake
--   psget.text -version 3.1.1                                -> <installdir>
--
-- Both are plain, non-embedded installs, so the .lua sources are sitting right
-- there and can be replaced in place. (The single-file `xmake-bundle-*` builds
-- embed them and unpack to a tmpdir instead -- os.programdir() still points at
-- the unpacked tree, so this works there too.)

local src = os.getenv("FIXED_LUA")
if not src then
    os.raise("FIXED_LUA must point at patches/cl_has_flags.fixed.lua")
end
if not os.isfile(src) then
    os.raise("FIXED_LUA does not exist: %s", src)
end

local programdir = os.programdir()
local dst = path.join(programdir, "modules", "core", "tools", "cl", "has_flags.lua")
local backup = dst .. ".orig"

print("programdir: " .. programdir)
print("source:     " .. src)
print("patching:   " .. dst)

-- Refuse to copy blindly: if os.programdir() is not the tree we think it is, the
-- cp below would happily create a stray directory and the later "fixed" checks
-- would silently be testing the STOCK module.
if not os.isfile(dst) then
    os.raise("no cl/has_flags.lua under %s -- is os.programdir() the installed xmake?", programdir)
end

if not os.isfile(backup) then
    os.cp(dst, backup)
    print("kept the stock copy as " .. path.filename(backup))
end
os.cp(src, dst)
print("done")
