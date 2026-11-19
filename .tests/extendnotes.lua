-- @noindex
-- juno_ExtendNotes with a mocked MIDI editor.
local H = dofile((debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or "") .. "helpers.lua")

local s = { take = { name = "Piano", notes = {} }, ext = {} }
reaper = H.midiEditorReaper(s)
local ui = H.imgui()
local function N(a, b, p, sel) return { s = a, e = b, p = p, sel = sel or false } end

local function run(notes, settings)
	s.take.notes, s.ext = notes, {}
	for k, v in pairs(settings or {}) do s.ext["juno_ExtendNotes" .. k] = tostring(v) end
	dofile(H.REPO .. "MIDI/juno_ExtendNotes.lua")
	local get = function() return s.deferred end
	H.frame(ui, get); H.frame(ui, get, "Extend"); H.frame(ui, get)
	local o = {}
	for i, n in ipairs(s.take.notes) do o[i] = math.floor(n.e + 0.5) end
	return o
end
local function eq(got, want, msg)
	assert(#got == #want, msg)
	for i = 1, #want do assert(got[i] == want[i], ("%s #%d: %s vs %s"):format(msg, i, got[i], want[i])) end
	H.ok(msg)
end

eq(run({ N(0, 100, 60), N(5, 100, 64), N(960, 2500, 62), N(1920, 2000, 65) }), { 960, 960, 1920, 2000 }, "legato + chord + trim overlap")
eq(run({ N(0, 100, 60), N(960, 2500, 62), N(1920, 2000, 65) }, { overlap = 2 }), { 960, 2500, 2000 }, "keep overlaps")
eq(run({ N(0, 100, 60), N(960, 1000, 62) }, { gap = 10, last = 2 }), { 941, 7680 }, "gap in ms + last note to item end")
eq(run({ N(0, 100, 60), N(1000, 1100, 62) }, { gap = 50, gapUnit = 2 }), { 950, 1100 }, "gap in ticks")
eq(run({ N(0, 100, 60), N(1000, 1100, 62) }, { gap = 10, gapUnit = 3 }), { 900, 1100 }, "gap in percent")
eq(run({ N(0, 100, 60), N(500, 600, 64), N(1000, 1100, 60) }, { next = 2 }), { 1000, 600, 1100 }, "next note of the same pitch")
eq(run({ N(0, 100, 60, true), N(500, 600, 64), N(1000, 1100, 60, true) }), { 500, 600, 1100 }, "selection, unselected notes count")
eq(run({ N(0, 100, 60, true), N(500, 600, 64), N(1000, 1100, 60, true) }, { countUnselected = 0 }), { 1000, 600, 1100 }, "selection only")
eq(run({ N(0, 100, 60), N(10, 200, 62) }, { gap = 100, gapUnit = 2, tolMs = 0 }), { 1, 200 }, "never shorter than 1 tick")

-- the window must not use widths relative to its own size (it auto-resizes: that made it shrink forever)
local src = io.open(H.REPO .. "MIDI/juno_ExtendNotes.lua"):read("a")
assert(not src:find("SetNextItemWidth%(ctx, %-"), "relative widths in an auto-resizing window")
H.ok("no relative widths in the auto-resizing window")
