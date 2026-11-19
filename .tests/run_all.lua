-- @noindex
-- Runs every test with a mocked REAPER. Needs only Lua 5.4:  lua .tests/run_all.lua
local dir = debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or "./"

local FILES = {
	"splitvoices_core.lua",
	"extendnotes.lua",
	"fixoverlaps.lua",
	"frameshift.lua",
	"bakevolume.lua",
	"exporthelper.lua",
}

local failed = 0
for _, f in ipairs(FILES) do
	print(f)
	package.loaded.imgui = nil
	local ok, err = pcall(dofile, dir .. f)
	if not ok then
		failed = failed + 1
		print("  FAIL " .. tostring(err))
	end
end
print(failed == 0 and "ALL PASSED" or (failed .. " test file(s) FAILED"))
if failed > 0 then os.exit(1) end
