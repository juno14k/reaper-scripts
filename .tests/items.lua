-- @noindex
-- Item mode of juno_ExtendNotes and juno_FixOverlaps (audio/video items on the timeline), and that MIDI items
-- are always handled as notes.
local H = dofile((debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or "") .. "helpers.lua")
local approx = H.approx

local s = { tracks = {}, ext = {} }
reaper = H.itemsReaper(s)
local ui = H.imgui()
local get = function() return s.deferred end

local function run(script, press, settings, version)
	s.ext = {}
	if version then s.ext[script .. "_version"] = version end
	for k, v in pairs(settings or {}) do s.ext[script .. k] = tostring(v) end
	dofile(H.REPO .. "MIDI/" .. script .. ".lua")
	local text = H.frame(ui, get)
	if press then H.frame(ui, get, press); H.frame(ui, get) end
	return text
end
local function extend(settings) return run("juno_ExtendNotes", "Extend", settings) end
local function fixItems(settings) return run("juno_FixOverlaps", "Fix", settings, "1") end

---------------------------------------------------------------------------------------------------------------------
-- ExtendNotes
---------------------------------------------------------------------------------------------------------------------
local tr = {}
s.tracks = { tr }
local A = H.audioItem(tr, 0, 1)
local B = H.audioItem(tr, 2, 1)
local C = H.audioItem(tr, 5, 1)
local text = extend()
assert(text:find("3 audio/video items"), text)
approx(A.len, 2, "A up to B"); approx(B.len, 3, "B up to C"); approx(C.len, 1, "last item left alone")
H.ok("ExtendNotes: items extended to the next item on the track")

tr = {}; s.tracks = { tr }
A = H.audioItem(tr, 0, 1); B = H.audioItem(tr, 2, 1)
extend({ gap = 100 })
approx(A.len, 1.9, "gap 100 ms")
A.len = 1
extend({ gap = 240, gapUnit = 2 }) -- 240 ticks = 1/4 beat = 0.125 s at 120 bpm
approx(A.len, 1.875, "gap in ticks")
H.ok("ExtendNotes: gap in ms and ticks")

tr = {}; s.tracks = { tr }
A = H.audioItem(tr, 0, 2.5); B = H.audioItem(tr, 2, 1)
extend({ overlap = 2 })
approx(A.len, 2.5, "keep overlaps")
extend()
approx(A.len, 2, "trim overlaps")
H.ok("ExtendNotes: overlapping items trimmed or kept")

tr = {}; s.tracks = { tr }
A = H.audioItem(tr, 0, 1, { file = "x.wav" })
local L1 = H.audioItem(tr, 1.5, 1, { lane = 1 }) -- another lane: not the next item
B = H.audioItem(tr, 3, 1, { file = "y.wav" })
C = H.audioItem(tr, 4, 1, { file = "x.wav" })
L1.sel = false
extend()
approx(A.len, 3, "items in another lane don't count")
A.len, B.len = 1, 1
extend({ itemNext = 2 })
approx(A.len, 4, "next item from the same source file")
H.ok("ExtendNotes: lanes, same source file")

-- MIDI items: their notes are extended, the items themselves never
tr = {}; s.tracks = { tr }
local M = H.midiItem(tr, 0, 2, { { s = 0, e = 100, p = 60 }, { s = 960, e = 1000, p = 62 } })
local M2 = H.midiItem(tr, 4, 1, { { s = 0, e = 100, p = 60 } })
text = extend()
assert(text:find("Notes in 2 MIDI items"), text)
approx(M.len, 2, "MIDI item not extended as an item"); approx(M2.len, 1)
assert(M.take.notes[1].e == 960, "its notes are")
-- the MIDI editor wins when nothing (or its own item) is selected; selected audio items win otherwise
s.editorTake = M.take
M.sel, M2.sel = false, false
text = extend()
assert(text:find("MIDI editor: midi"), text)
local X = H.audioItem(tr, 6, 1); local Y = H.audioItem(tr, 8, 1)
text = extend()
assert(text:find("2 audio/video items") and not text:find("MIDI editor"), "selected audio items win over the open editor")
approx(X.len, 2)
s.editorTake = nil
H.ok("ExtendNotes: MIDI items always as notes; MIDI editor vs selected items")

---------------------------------------------------------------------------------------------------------------------
-- FixOverlaps
---------------------------------------------------------------------------------------------------------------------
tr = {}; s.tracks = { tr }
A = H.audioItem(tr, 0, 1, { file = "x.wav" })
local A2 = H.audioItem(tr, 0.005, 0.8, { file = "x.wav" }) -- duplicate of A (same file and part, starts together)
local D = H.audioItem(tr, 0.003, 0.5, { file = "x.wav", offs = 3 }) -- same file, another part: not a duplicate
text = fixItems()
assert(text:find("1 duplicate items"), text)
assert(#tr == 2 and tr[1] == A and tr[2] == D, "A2 removed, D kept")
H.ok("FixOverlaps: duplicate items (same file and part)")

tr = {}; s.tracks = { tr }
A = H.audioItem(tr, 0, 2.5); B = H.audioItem(tr, 2, 1)
fixItems()
approx(A.len, 2, "overlap trimmed"); approx(A.fadeout, 0, "no crossfade by default")
A.len = 2.5
fixItems({ xfadeMs = 50 })
approx(A.len, 2.05, "crossfade kept"); approx(A.fadeout, 0.05); approx(B.fadein, 0.05)
H.ok("FixOverlaps: overlapping items trimmed, optional crossfade")

-- Existing fades of the two items: kept by default, removed when "keep the fades" is off
local function withFades()
	tr = {}; s.tracks = { tr }
	A = H.audioItem(tr, 0, 2.5); B = H.audioItem(tr, 2, 1)
	A.fadeout, A.fadeoutManual, B.fadein, B.fadeinManual = 0.5, 0.2, 0.5, 0.2
end
withFades()
fixItems()
approx(A.len, 2); approx(A.fadeout, 0.5, "auto fade kept"); approx(A.fadeoutManual, 0.2, "manual fade kept"); approx(B.fadein, 0.5)
withFades()
fixItems({ keepFades = 0 })
approx(A.len, 2); approx(A.fadeout, 0); approx(A.fadeoutManual, 0); approx(B.fadein, 0); approx(B.fadeinManual, 0)
withFades()
fixItems({ keepFades = 0, xfadeMs = 50 })
approx(A.fadeout, 0.05, "only the new crossfade left"); approx(A.fadeoutManual, 0); approx(B.fadein, 0.05)
H.ok("FixOverlaps: keep or remove the fades of overlapping items")

-- Where an overlap is cut (A 0..2.5 and B 2..3 overlap from 2 to 2.5), with and without a crossfade
local function overlap()
	tr = {}; s.tracks = { tr }
	A = H.audioItem(tr, 0, 2.5); B = H.audioItem(tr, 2, 1, { offs = 1 })
end
overlap(); fixItems({ cutPos = 1 })
approx(A.len, 2, "start: A trimmed back to B"); approx(B.pos, 2); approx(B.take.offs, 1)
overlap(); fixItems({ cutPos = 2 })
approx(A.len, 2.25, "middle: A ends halfway"); approx(B.pos, 2.25, "B starts halfway")
approx(B.len, 0.75); approx(B.take.offs, 1.25, "B's audio stays in place")
overlap(); fixItems({ cutPos = 3 })
approx(A.len, 2.5, "end: A untouched"); approx(B.pos, 2.5); approx(B.len, 0.5); approx(B.take.offs, 1.5)
overlap(); fixItems({ cutPos = 2, xfadeMs = 100 })
approx(A.len, 2.3, "middle + 100 ms crossfade"); approx(B.pos, 2.2); approx(A.fadeout, 0.1); approx(B.fadein, 0.1)
overlap(); fixItems({ cutPos = 3, xfadeMs = 100 })
approx(A.len, 2.5); approx(B.pos, 2.4, "end + crossfade: inside the overlap"); approx(B.take.offs, 1.4)
overlap(); fixItems({ cutPos = 1, xfadeMs = 1000 })
approx(A.len, 2.5, "crossfade never longer than the overlap"); approx(B.pos, 2); approx(A.fadeout, 0.5)
H.ok("FixOverlaps: cut overlaps at their start, middle or end, with or without a crossfade")

tr = {}; s.tracks = { tr }
A = H.audioItem(tr, 0, 0.01); B = H.audioItem(tr, 1, 1)
fixItems({ short = 1, minLenMs = 20 })
assert(#tr == 1 and tr[1] == B, "short item removed")
H.ok("FixOverlaps: short items")

tr = {}; s.tracks = { tr }
A = H.audioItem(tr, 0, 2.5); B = H.audioItem(tr, 2, 1); C = H.audioItem(tr, 5, 1)
run("juno_FixOverlaps", "Select affected", nil, "1")
assert(A.sel and B.sel and not C.sel, "both items of the overlap selected")
H.ok("FixOverlaps: select affected items")

-- MIDI items: fixed as notes, never as items (a short MIDI item is not removed)
tr = {}; s.tracks = { tr }
M = H.midiItem(tr, 0, 0.01, { { s = 0, e = 500, p = 60 }, { s = 400, e = 900, p = 60 } })
fixItems({ short = 1, minLenMs = 20 })
assert(#tr == 1, "MIDI item not removed as an item")
assert(M.take.notes[1].e == 400, "its overlapping notes are fixed")
H.ok("FixOverlaps: MIDI items always as notes")
