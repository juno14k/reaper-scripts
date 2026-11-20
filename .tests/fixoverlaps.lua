-- @noindex
-- juno_FixOverlaps with a mocked MIDI editor.
local H = dofile((debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or "") .. "helpers.lua")

local s = { take = { name = "Piano", notes = {} }, ext = {} }
reaper = H.midiEditorReaper(s)
local ui = H.imgui()
local function N(a, b, p, sel, ch) return { s = a, e = b, p = p, sel = sel or false, ch = ch or 0 } end
local get = function() return s.deferred end

local function load(notes, settings)
	s.take.notes, s.ext = notes, { juno_FixOverlaps_version = "1" }
	for k, v in pairs(settings or {}) do s.ext["juno_FixOverlaps" .. k] = tostring(v) end
	dofile(H.REPO .. "MIDI/juno_FixOverlaps.lua")
	return H.frame(ui, get)
end
local function notes()
	local o = {}
	for i, n in ipairs(s.take.notes) do o[i] = n.s .. "-" .. n.e .. ":" .. n.p end
	return table.concat(o, " ")
end
local function check(input, settings, want, msg)
	load(input, settings)
	H.frame(ui, get, "Fix"); H.frame(ui, get)
	local got = notes()
	assert(got == want, msg .. "\n got  " .. got .. "\n want " .. want)
	H.ok(msg)
end

check({ N(0, 500, 60), N(5, 900, 60), N(800, 1200, 60), N(0, 300, 64) }, nil, "5-800:60 800-1200:60 0-300:64", "duplicates (longest kept) + trim")
check({ N(0, 500, 60), N(400, 900, 60), N(800, 1200, 60) }, { overlapMode = 2 }, "0-1200:60", "merge overlaps")
check({ N(0, 30, 60), N(100, 100, 62), N(200, 400, 64) }, { short = 1 }, "200-400:64", "short and zero-length notes")
check({ N(0, 500, 60), N(300, 700, 62), N(300, 600, 65) }, { mono = 1 }, "0-300:60 300-700:62 300-600:65", "monophonic, chords kept")
check({ N(0, 500, 60, false, 0), N(0, 500, 60, false, 1) }, nil, "0-500:60 0-500:60", "channels separate")
check({ N(0, 500, 60, false, 0), N(0, 400, 60, false, 1) }, { separateChans = 0 }, "0-500:60", "channels together")
check({ N(0, 500, 60, true), N(400, 900, 60, true), N(1000, 1500, 62), N(1200, 1600, 62) }, nil,
	"0-400:60 400-900:60 1000-1500:62 1200-1600:62", "selected notes only")

-- "Select affected" selects both notes of a conflict, so fixing the selection still finds it
load({ N(0, 500, 60), N(400, 900, 60), N(1000, 1100, 64) })
H.frame(ui, get, "Select affected")
local t = s.take.notes
assert(t[1].sel and t[2].sel and not t[3].sel, "both partners selected")
H.frame(ui, get, "Fix")
assert(notes() == "0-400:60 400-900:60 1000-1100:64")
H.ok("select affected notes, then fix")

-- The summary lists every kind found, even when an earlier kind has none (was: "nothing to fix")
local text = load({ N(0, 500, 60), N(400, 900, 60) })
assert(text:find("same%-pitch overlaps") and not text:find("nothing to fix"), "summary:\n" .. text)
H.ok("summary shows overlaps when there are no duplicates")

local src = io.open(H.REPO .. "MIDI/juno_FixOverlaps.lua"):read("a")
assert(not src:find("SetNextItemWidth%(ctx, %-"), "relative widths in an auto-resizing window")
H.ok("no relative widths in the auto-resizing window")
