-- @noindex
-- Plain Lua 5.4 tests for MIDI/juno_SplitVoices/core.lua

local H = dofile((debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or "") .. "helpers.lua")
local Core = dofile(H.REPO .. "MIDI/juno_SplitVoices/core.lua")

local passed, failed = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL: " .. name .. "\n      " .. tostring(err))
	end
end

local function eq(a, b, msg)
	if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function ok(c, msg) if not c then error(msg or "assertion failed", 2) end end

-- n(startBeat, lenBeats, pitch, [offsetSeconds]) with 120 bpm (0.5 s per beat)
local function n(b, len, pitch, off)
	local s = b * 0.5 + (off or 0)
	return { start = s, finish = s + len * 0.5, pitch = pitch }
end

local POLY_MODES = { Core.MODE_FIRST_AVAILABLE, Core.MODE_TOP_TO_BOTTOM, Core.MODE_VOICE_LEADING }

local function checkInvariants(notes, res, opts)
	local tol = (opts.overlapTolMs or Core.DEFAULTS.overlapTolMs) / 1000
	local byVoice = {}
	for i = 1, #notes do
		local v = res.voiceOf[i]
		ok(v and v >= 1 and v <= res.numVoices, "note " .. i .. " has invalid voice " .. tostring(v))
		byVoice[v] = byVoice[v] or {}
		table.insert(byVoice[v], notes[i])
	end
	for v, list in pairs(byVoice) do
		table.sort(list, function(a, b) return a.start < b.start end)
		for k = 2, #list do
			local prev, cur = list[k - 1], list[k]
			local cut = math.min(tol, (prev.finish - prev.start) * 0.5)
			ok(prev.finish - cut <= cur.start + 1e-9,
				("voice %d overlaps: %.3f-%.3f then %.3f"):format(v, prev.start, prev.finish, cur.start))
		end
	end
	ok(res.numVoices <= res.maxPoly, "more voices than max polyphony")
end

-----------------------------------------------------------------------------------------------------------------------

test("helpers: PitchName / ParseSplits", function()
	eq(Core.PitchName(60), "C4")
	eq(Core.PitchName(61), "C#4")
	eq(Core.PitchName(0), "C-1")
	local s = Core.ParseSplits("C4, g#5; 72 bad 60 Bb3")
	eq(#s, 4); eq(s[1], 58); eq(s[2], 60); eq(s[3], 72); eq(s[4], 80)
	eq(Core.FormatSplits({ 60, 72 }), "C4, C5")
end)

test("empty input", function()
	local res = Core.Split({}, {})
	eq(res.numVoices, 0); eq(res.maxPoly, 0)
end)

test("block SATB chords: voice 1 is always the top note, in every mode", function()
	local chords = { { 72, 67, 64, 60 }, { 74, 67, 65, 59 }, { 76, 72, 67, 48 }, { 72, 67, 64, 60 } }
	local notes = {}
	for b, c in ipairs(chords) do
		for _, p in ipairs(c) do notes[#notes + 1] = n(b - 1, 1, p) end
	end
	for _, mode in ipairs(POLY_MODES) do
		local res = Core.Split(notes, { mode = mode })
		eq(res.numVoices, 4, "mode " .. mode)
		for i = 1, #notes do
			eq(res.voiceOf[i], (i - 1) % 4 + 1, "mode " .. mode .. " note " .. i)
		end
		checkInvariants(notes, res, {})
	end
end)

test("legato overlap tolerance", function()
	local notes = { n(0, 1, 60), n(1, 1, 62), n(2, 1, 64) }
	notes[1].finish = notes[1].finish + 0.02 -- 20 ms overlap
	notes[2].finish = notes[2].finish + 0.02
	eq(Core.Split(notes, { overlapTolMs = 40 }).maxPoly, 1)
	eq(Core.Split(notes, { overlapTolMs = 0 }).maxPoly, 2)
	eq(Core.Split(notes, { overlapTolMs = 40 }).numVoices, 1)
end)

test("chord tolerance groups humanized chords", function()
	local notes = { n(0, 1, 60, 0.012), n(0, 1, 72, 0.0), n(0, 1, 67, 0.021),
	                n(1, 1, 59, 0.0), n(1, 1, 74, 0.018), n(1, 1, 65, 0.007) }
	local res = Core.Split(notes, { chordTolMs = 30 })
	eq(res.groupCount, 2)
	eq(res.voiceOf[2], 1); eq(res.voiceOf[3], 2); eq(res.voiceOf[1], 3)
	eq(res.voiceOf[5], 1); eq(res.voiceOf[6], 2); eq(res.voiceOf[4], 3)
	eq(Core.Split(notes, { chordTolMs = 0 }).groupCount, 6)
end)

test("voice leading keeps lines when the upper voice rests (first available does not)", function()
	-- upper: 72 . 74 76     lower: 60 62 64 65
	local notes = { n(0, 1, 72), n(0, 1, 60), n(1, 1, 62), n(2, 1, 74), n(2, 1, 64), n(3, 1, 76), n(3, 1, 65) }
	local vl = Core.Split(notes, { mode = Core.MODE_VOICE_LEADING })
	eq(vl.numVoices, 2)
	for i, note in ipairs(notes) do
		eq(vl.voiceOf[i], note.pitch >= 70 and 1 or 2, "VL note " .. i)
	end
	local fa = Core.Split(notes, { mode = Core.MODE_FIRST_AVAILABLE })
	eq(fa.voiceOf[1], fa.voiceOf[3], "first available should reuse the free top voice for 62")
end)

test("voice leading follows an inner voice moving under a held melody", function()
	-- Melody holds 79 for 4 beats; alto and bass move. Alto must stay voice 2.
	local notes = { n(0, 4, 79),
	                n(0, 1, 67), n(1, 1, 69), n(2, 1, 71), n(3, 1, 72),
	                n(0, 2, 48), n(2, 2, 43) }
	local res = Core.Split(notes, { mode = Core.MODE_VOICE_LEADING })
	eq(res.numVoices, 3)
	eq(res.voiceOf[1], 1)
	for i = 2, 5 do eq(res.voiceOf[i], 2, "alto note " .. i) end
	eq(res.voiceOf[6], 3); eq(res.voiceOf[7], 3)
end)

test("top to bottom spread puts melody and bass in the outer voices", function()
	local notes = { n(0, 1, 72), n(0, 1, 67), n(0, 1, 64), n(0, 1, 60),
	                n(1, 1, 74), n(1, 1, 59) }
	local res = Core.Split(notes, { mode = Core.MODE_TOP_TO_BOTTOM, fill = Core.FILL_SPREAD })
	eq(res.voiceOf[5], 1); eq(res.voiceOf[6], 4)
	-- (orderByPitch off: it would legitimately re-sort voices by their average pitch)
	local top = Core.Split(notes, { mode = Core.MODE_TOP_TO_BOTTOM, fill = Core.FILL_TOP, orderByPitch = false })
	eq(top.voiceOf[5], 1); eq(top.voiceOf[6], 2)
	local bot = Core.Split(notes, { mode = Core.MODE_TOP_TO_BOTTOM, fill = Core.FILL_BOTTOM, orderByPitch = false })
	eq(bot.voiceOf[5], 3); eq(bot.voiceOf[6], 4)
end)

test("fixed voice count + overflow policies", function()
	local notes = { n(0, 1, 72), n(0, 1, 66), n(0, 1, 60), n(1, 1, 74), n(1, 1, 67), n(1, 1, 59) }
	for _, mode in ipairs(POLY_MODES) do
		local drop = Core.Split(notes, { mode = mode, voiceCount = 2, overflow = Core.OVERFLOW_DROP })
		eq(drop.numVoices, 2)
		eq(drop.voiceOf[2], 0, "middle note dropped"); eq(drop.voiceOf[5], 0)
		eq(drop.voiceOf[1], 1); eq(drop.voiceOf[3], 2)

		local track = Core.Split(notes, { mode = mode, voiceCount = 2, overflow = Core.OVERFLOW_TRACK })
		eq(track.numVoices, 3)
		ok(track.voices[3].overflow, "last voice is the overflow")
		eq(track.voiceOf[2], 3); eq(track.voiceOf[5], 3)

		local near = Core.Split(notes, { mode = mode, voiceCount = 2, overflow = Core.OVERFLOW_NEAREST })
		eq(near.numVoices, 2)
		for i = 1, #notes do ok(near.voiceOf[i] >= 1, "nearest keeps every note") end
	end
end)

test("pitch ranges", function()
	local notes = { n(0, 1, 72), n(0, 1, 48), n(0, 1, 60), n(1, 1, 36) }
	local res = Core.Split(notes, { mode = Core.MODE_PITCH_RANGES, splits = { 60 } })
	eq(res.numVoices, 2)
	eq(res.voiceOf[1], 1); eq(res.voiceOf[3], 1); eq(res.voiceOf[2], 2); eq(res.voiceOf[4], 2)
	local three = Core.Split(notes, { mode = Core.MODE_PITCH_RANGES, splits = { 72, 40 } })
	eq(three.numVoices, 3)
	eq(three.voiceOf[1], 1); eq(three.voiceOf[3], 2); eq(three.voiceOf[4], 3)
	-- empty ranges are removed
	local gap = Core.Split(notes, { mode = Core.MODE_PITCH_RANGES, splits = { 100, 60 } })
	eq(gap.numVoices, 2)
end)

test("randomized invariants (all modes, crossing on/off)", function()
	math.randomseed(1234)
	for _ = 1, 200 do
		local notes = {}
		local count = math.random(1, 60)
		for _ = 1, count do
			local s = math.random(0, 40) * 0.25 + (math.random() < 0.3 and math.random() * 0.02 or 0)
			local len = math.random(1, 8) * 0.125
			notes[#notes + 1] = { start = s, finish = s + len, pitch = math.random(30, 96) }
		end
		for _, mode in ipairs(POLY_MODES) do
			for _, crossing in ipairs({ false, true }) do
				local opts = { mode = mode, allowCrossing = crossing,
				               chordTolMs = math.random(0, 40), overlapTolMs = math.random(0, 60) }
				local res = Core.Split(notes, opts)
				checkInvariants(notes, res, opts)
				eq(res.numVoices, res.maxPoly, "auto voice count uses every voice")
			end
		end
	end
end)

test("drums mode: one voice per pitch, lowest first", function()
	local notes = {
		{ start = 0, finish = 0.1, pitch = 42 }, { start = 0, finish = 0.1, pitch = 36 },
		{ start = 0.5, finish = 0.6, pitch = 38 }, { start = 1, finish = 1.1, pitch = 36 },
	}
	local res = Core.Split(notes, { mode = Core.MODE_DRUMS })
	eq(res.numVoices, 3)
	eq(res.voiceOf[2], 1, "kick first"); eq(res.voiceOf[4], 1); eq(res.voiceOf[3], 2); eq(res.voiceOf[1], 3)
	eq(res.voices[1].pitch, 36)
end)

-----------------------------------------------------------------------------------------------------------------------

print(("  ok  %d core tests passed"):format(passed))
if failed > 0 then error(("%d core tests failed"):format(failed)) end
