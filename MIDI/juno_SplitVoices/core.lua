-- @noindex
--[[
  juno_SplitVoices - core algorithms.

  Pure Lua (no REAPER API calls) so it can be unit tested outside REAPER.

  Input:  an array of notes { start = seconds, finish = seconds, pitch = 0..127 }
  Output: Core.Split() returns
    {
      voiceOf    = { [noteIndex] = voice (1 = top track), 0 = dropped },
      numVoices  = number of output voices (empty voices are removed),
      voices     = { [voice] = { count, low, high, avg, overflow } },
      maxPoly    = max simultaneous notes (after tolerances),
      groupCount = number of onset groups (chords),
    }
--]]

local Core = {}

-- Other scripts load this file (juno_MIDIExportHelper). Bump when the way Core.Split is called or what it
-- returns changes, and update those scripts.
Core.API_VERSION = 1

Core.MODE_FIRST_AVAILABLE = 1
Core.MODE_TOP_TO_BOTTOM   = 2
Core.MODE_VOICE_LEADING   = 3
Core.MODE_PITCH_RANGES    = 4
Core.MODE_DRUMS           = 5 -- one voice per pitch

Core.MODE_NAMES = {
	"First Available",
	"Top to Bottom",
	"Voice Leading",
	"Pitch Ranges",
	"Drums (one track per note)",
}

Core.FILL_SPREAD = 1
Core.FILL_TOP    = 2
Core.FILL_BOTTOM = 3
Core.FILL_NAMES  = { "Spread (melody & bass outside)", "Fill from top", "Fill from bottom" }

Core.OVERFLOW_NEAREST = 1
Core.OVERFLOW_TRACK   = 2
Core.OVERFLOW_DROP    = 3
Core.OVERFLOW_NAMES   = { "Stack on nearest voice", "Put on an extra 'Overflow' track", "Drop the notes" }

Core.DEFAULTS = {
	mode          = Core.MODE_VOICE_LEADING,
	voiceCount    = 0,      -- 0 = auto (max polyphony)
	chordTolMs    = 30,     -- onsets closer than this are one chord
	overlapTolMs  = 40,     -- legato overlaps shorter than this don't add polyphony
	fill          = Core.FILL_SPREAD,
	allowCrossing = false,
	memorySec     = 2.0,    -- how long a voice "remembers" its last pitch while resting
	overflow      = Core.OVERFLOW_NEAREST,
	splits        = { 60 }, -- pitch ranges split points (note >= split goes to the upper voice)
	orderByPitch  = true,   -- order output voices from highest to lowest average pitch
}

local MIN_LEN    = 1e-6
local CROSS_COST = 24
local NEW_VOICE_COST = 2

local abs, max, min, exp, floor = math.abs, math.max, math.min, math.exp, math.floor

-----------------------------------------------------------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------------------------------------------------------

local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

--- 60 -> "C4"
function Core.PitchName(p)
	p = floor(p + 0.5)
	return NOTE_NAMES[p % 12 + 1] .. tostring(p // 12 - 1)
end

local NOTE_OFFSETS = { c = 0, d = 2, e = 4, f = 5, g = 7, a = 9, b = 11 }

-- General MIDI drum names (channel 10).
Core.GM_DRUMS = {
	[35] = "Acoustic Kick", [36] = "Kick", [37] = "Side Stick", [38] = "Snare", [39] = "Clap", [40] = "Electric Snare",
	[41] = "Low Floor Tom", [42] = "Closed Hi-Hat", [43] = "High Floor Tom", [44] = "Pedal Hi-Hat", [45] = "Low Tom",
	[46] = "Open Hi-Hat", [47] = "Low-Mid Tom", [48] = "Hi-Mid Tom", [49] = "Crash", [50] = "High Tom", [51] = "Ride",
	[52] = "China", [53] = "Ride Bell", [54] = "Tambourine", [55] = "Splash", [56] = "Cowbell", [57] = "Crash 2",
	[58] = "Vibraslap", [59] = "Ride 2", [60] = "Hi Bongo", [61] = "Low Bongo", [62] = "Mute Hi Conga",
	[63] = "Open Hi Conga", [64] = "Low Conga", [65] = "High Timbale", [66] = "Low Timbale", [67] = "High Agogo",
	[68] = "Low Agogo", [69] = "Cabasa", [70] = "Maracas", [71] = "Short Whistle", [72] = "Long Whistle",
	[73] = "Short Guiro", [74] = "Long Guiro", [75] = "Claves", [76] = "Hi Wood Block", [77] = "Low Wood Block",
	[78] = "Mute Cuica", [79] = "Open Cuica", [80] = "Mute Triangle", [81] = "Open Triangle",
}

--- "C4, G#5, 72" -> { 60, 80, 72 } (sorted ascending, duplicates removed). Invalid tokens are ignored.
function Core.ParseSplits(str)
	local out, seen = {}, {}
	for token in tostring(str or ""):gmatch("[^,;%s]+") do
		local p = tonumber(token)
		if not p then
			local letter, acc, oct = token:match("^([A-Ga-g])([#bs]?)(-?%d+)$")
			if letter then
				p = NOTE_OFFSETS[letter:lower()] + (oct + 1) * 12
				if acc == "#" or acc == "s" then p = p + 1 elseif acc == "b" then p = p - 1 end
			end
		end
		if p then
			p = floor(p)
			if p >= 0 and p <= 127 and not seen[p] then
				seen[p] = true
				out[#out + 1] = p
			end
		end
	end
	table.sort(out)
	return out
end

function Core.FormatSplits(list)
	local parts = {}
	for i, p in ipairs(list) do parts[i] = Core.PitchName(p) end
	return table.concat(parts, ", ")
end

local function withDefaults(opts)
	local o = {}
	for k, v in pairs(Core.DEFAULTS) do o[k] = v end
	if opts then for k, v in pairs(opts) do o[k] = v end end
	return o
end

-----------------------------------------------------------------------------------------------------------------------
-- Preprocessing
-----------------------------------------------------------------------------------------------------------------------

--- Groups notes into onset groups ("chords"). Each group: { t = onset, notes = {indices, highest pitch first} }
function Core.BuildGroups(notes, chordTol)
	local order = {}
	for i = 1, #notes do order[i] = i end
	table.sort(order, function(a, b)
		local na, nb = notes[a], notes[b]
		if na.start ~= nb.start then return na.start < nb.start end
		if na.pitch ~= nb.pitch then return na.pitch > nb.pitch end
		return a < b
	end)

	local groups, cur = {}, nil
	for _, i in ipairs(order) do
		local s = notes[i].start
		if cur and s - cur.t <= chordTol then
			cur.notes[#cur.notes + 1] = i
		else
			cur = { t = s, notes = { i } }
			groups[#groups + 1] = cur
		end
	end

	for _, g in ipairs(groups) do
		table.sort(g.notes, function(a, b)
			if notes[a].pitch ~= notes[b].pitch then return notes[a].pitch > notes[b].pitch end
			return a < b
		end)
	end
	return groups
end

--- Effective end of every note: the overlap tolerance is subtracted (but never more than half the note).
local function effectiveEnds(notes, groups, overlapTol)
	local eff = {}
	for _, g in ipairs(groups) do
		for _, i in ipairs(g.notes) do
			local n = notes[i]
			local len = n.finish - n.start
			local cut = min(overlapTol, max(0, len) * 0.5)
			eff[i] = max(g.t + MIN_LEN, n.finish - cut)
		end
	end
	return eff
end

--- Max polyphony = number of voices greedy "first available" needs (optimal for interval graphs).
local function countPolyphony(groups, eff)
	local busy = {}
	for _, g in ipairs(groups) do
		for _, i in ipairs(g.notes) do
			local placed = false
			for v = 1, #busy do
				if busy[v] <= g.t then
					busy[v] = eff[i]
					placed = true
					break
				end
			end
			if not placed then busy[#busy + 1] = eff[i] end
		end
	end
	return #busy
end

-----------------------------------------------------------------------------------------------------------------------
-- Matching helpers
-----------------------------------------------------------------------------------------------------------------------

--- Order preserving assignment of k items to m slots (k <= m), minimizing the sum of cost(a, b).
--- On ties the earliest slot wins. Returns map[a] = b.
local function orderedMatch(k, m, cost)
	local INF = math.huge
	local dp, took = {}, {}
	for a = 0, k do
		dp[a], took[a] = {}, {}
		for b = 0, m do dp[a][b] = (a == 0) and 0 or INF end
	end
	for a = 1, k do
		for b = a, m do
			local skip = dp[a][b - 1]
			local take = dp[a - 1][b - 1] + cost(a, b)
			if take < skip then
				dp[a][b], took[a][b] = take, true
			else
				dp[a][b] = skip
			end
		end
	end
	local map, a, b = {}, k, m
	while a > 0 do
		if took[a][b] then
			map[a] = b
			a = a - 1
		end
		b = b - 1
	end
	return map
end

--- Hungarian algorithm for an n x m cost matrix (n <= m). Returns map[row] = col.
local function hungarian(n, m, cost)
	local INF = math.huge
	local u, v, p, way = {}, {}, {}, {}
	for i = 0, n do u[i] = 0 end
	for j = 0, m do v[j], p[j], way[j] = 0, 0, 0 end

	for i = 1, n do
		p[0] = i
		local j0 = 0
		local minv, used = {}, {}
		for j = 0, m do minv[j], used[j] = INF, false end
		repeat
			used[j0] = true
			local i0, delta, j1 = p[j0], INF, 0
			for j = 1, m do
				if not used[j] then
					local cur = cost(i0, j) - u[i0] - v[j]
					if cur < minv[j] then minv[j], way[j] = cur, j0 end
					if minv[j] < delta then delta, j1 = minv[j], j end
				end
			end
			for j = 0, m do
				if used[j] then
					u[p[j]] = u[p[j]] + delta
					v[j] = v[j] - delta
				else
					minv[j] = minv[j] - delta
				end
			end
			j0 = j1
		until p[j0] == 0
		repeat
			local j1 = way[j0]
			p[j0] = p[j1]
			j0 = j1
		until j0 == 0
	end

	local map = {}
	for j = 1, m do
		if p[j] ~= 0 then map[p[j]] = j end
	end
	return map
end

--- If a chord has more notes than free voices, keep the outer notes first (melody and bass matter most).
--- Both returned lists stay sorted highest pitch first.
local function selectNotes(list, m)
	if #list <= m then return list, {} end
	local keep = {}
	local lo, hi, n = 1, #list, 0
	while n < m do
		keep[lo] = true; n = n + 1
		if n < m and hi ~= lo then keep[hi] = true; n = n + 1 end
		lo, hi = lo + 1, hi - 1
	end
	local chosen, leftover = {}, {}
	for idx, i in ipairs(list) do
		if keep[idx] then chosen[#chosen + 1] = i else leftover[#leftover + 1] = i end
	end
	return chosen, leftover
end

-----------------------------------------------------------------------------------------------------------------------
-- Polyphonic modes (First Available, Top to Bottom, Voice Leading)
-----------------------------------------------------------------------------------------------------------------------

local function assignPolyphonic(notes, groups, eff, N, o, voiceOf)
	-- Prior "home" pitch of each voice: quantiles of the whole pitch distribution (voice 1 = top).
	local pitches = {}
	for i = 1, #notes do pitches[i] = notes[i].pitch end
	table.sort(pitches, function(a, b) return a > b end)

	local V = {}
	for v = 1, N do
		local q = floor((v - 0.5) / N * #pitches) + 1
		V[v] = { busy = -math.huge, last = nil, lastEnd = -math.huge, center = pitches[min(q, #pitches)] }
	end

	local overflowVoice = nil
	local memory = max(0.01, o.memorySec or 2)

	local function place(i, v)
		local st, n = V[v], notes[i]
		voiceOf[i] = v
		st.busy = max(st.busy, eff[i])
		st.last = n.pitch
		st.lastEnd = max(st.lastEnd, n.finish)
		st.center = st.center + 0.15 * (n.pitch - st.center)
	end

	for _, g in ipairs(groups) do
		local t = g.t
		local free, held = {}, {}
		for v = 1, N do
			if V[v].busy <= t then free[#free + 1] = v else held[#held + 1] = v end
		end

		local chosen, leftover = selectNotes(g.notes, #free)
		local k, m = #chosen, #free

		if k > 0 then
			local map -- map[a] = position in `free`
			if o.mode == Core.MODE_FIRST_AVAILABLE then
				map = {}
				for a = 1, k do map[a] = a end

			elseif o.mode == Core.MODE_TOP_TO_BOTTOM then
				map = {}
				if o.fill == Core.FILL_TOP then
					for a = 1, k do map[a] = a end
				elseif o.fill == Core.FILL_BOTTOM then
					for a = 1, k do map[a] = m - k + a end
				elseif k == 1 then
					-- Single note: go to the free voice whose home pitch is closest.
					local p, best, bestD = notes[chosen[1]].pitch, 1, math.huge
					for b = 1, m do
						local d = abs(p - V[free[b]].center)
						if d < bestD then best, bestD = b, d end
					end
					map[1] = best
				else
					for a = 1, k do map[a] = 1 + floor((a - 1) * (m - 1) / (k - 1) + 0.5) end
				end

			else -- Voice Leading
				local crossing = o.allowCrossing
				local function cost(a, b)
					local v = free[b]
					local st, p = V[v], notes[chosen[a]].pitch
					local c
					if st.last then
						local w = exp(-max(0, t - st.lastEnd) / memory)
						c = abs(p - (w * st.last + (1 - w) * st.center))
						local leap = abs(p - st.last)
						if leap > 12 then c = c + (leap - 12) * w end
					else
						c = abs(p - st.center) + NEW_VOICE_COST
					end
					if not crossing then
						for _, h in ipairs(held) do
							local hp = V[h].last
							if (h < v and p > hp) or (h > v and p < hp) then
								c = c + CROSS_COST + abs(p - hp)
							end
						end
					end
					return c
				end
				if crossing then
					map = hungarian(k, m, cost)
				else
					map = orderedMatch(k, m, cost)
				end
			end

			for a = 1, k do place(chosen[a], free[map[a]]) end
		end

		for _, i in ipairs(leftover) do
			if o.overflow == Core.OVERFLOW_DROP then
				voiceOf[i] = 0
			elseif o.overflow == Core.OVERFLOW_TRACK then
				overflowVoice = N + 1
				voiceOf[i] = overflowVoice
			else
				local p, best, bestD = notes[i].pitch, 1, math.huge
				for v = 1, N do
					local d = abs(p - (V[v].last or V[v].center))
					if d < bestD then best, bestD = v, d end
				end
				voiceOf[i] = best
				V[best].busy = max(V[best].busy, eff[i])
			end
		end
	end

	return overflowVoice
end

-----------------------------------------------------------------------------------------------------------------------
-- Pitch ranges mode
-----------------------------------------------------------------------------------------------------------------------

local function assignRanges(notes, splits, voiceOf)
	for i, n in ipairs(notes) do
		local v = 1
		for _, s in ipairs(splits) do
			if n.pitch < s then v = v + 1 end
		end
		voiceOf[i] = v
	end
end

-----------------------------------------------------------------------------------------------------------------------
-- Main entry point
-----------------------------------------------------------------------------------------------------------------------

function Core.Split(notes, opts)
	local o = withDefaults(opts)
	local chordTol   = max(0, o.chordTolMs or 0) / 1000
	local overlapTol = max(0, o.overlapTolMs or 0) / 1000

	local groups = Core.BuildGroups(notes, chordTol)
	local eff    = effectiveEnds(notes, groups, overlapTol)
	local res    = {
		voiceOf    = {},
		maxPoly    = countPolyphony(groups, eff),
		groupCount = #groups,
		voices     = {},
		numVoices  = 0,
	}
	if #notes == 0 then return res end

	local raw = res.voiceOf
	local overflowVoice
	if o.mode == Core.MODE_DRUMS then
		for i, n in ipairs(notes) do raw[i] = floor(n.pitch) + 1 end
		res.drums = true
	elseif o.mode == Core.MODE_PITCH_RANGES then
		local splits = {}
		for i, s in ipairs(o.splits or {}) do splits[i] = s end
		table.sort(splits)
		assignRanges(notes, splits, raw)
	else
		local N = (o.voiceCount and o.voiceCount > 0) and floor(o.voiceCount) or res.maxPoly
		overflowVoice = assignPolyphonic(notes, groups, eff, N, o, raw)
	end

	-- Stats per raw voice
	local stats = {}
	for i, v in pairs(raw) do
		if v > 0 then
			local s = stats[v]
			if not s then
				s = { raw = v, count = 0, sum = 0, low = 127, high = 0, overflow = (v == overflowVoice) }
				stats[v] = s
			end
			local p = notes[i].pitch
			s.count, s.sum = s.count + 1, s.sum + p
			s.low, s.high = min(s.low, p), max(s.high, p)
		end
	end

	-- Drop empty voices, optionally order by average pitch, overflow always last.
	local list, overflowStat = {}, nil
	for _, s in pairs(stats) do
		s.avg = s.sum / s.count
		if s.overflow then overflowStat = s else list[#list + 1] = s end
	end
	local byPitch = o.orderByPitch and o.mode ~= Core.MODE_PITCH_RANGES and o.mode ~= Core.MODE_DRUMS
	table.sort(list, function(a, b)
		if byPitch and a.avg ~= b.avg then return a.avg > b.avg end
		if o.mode == Core.MODE_DRUMS then return a.raw < b.raw end -- drums: lowest note (kick) first
		return a.raw < b.raw
	end)
	if overflowStat then list[#list + 1] = overflowStat end

	local remap = {}
	for idx, s in ipairs(list) do
		remap[s.raw] = idx
		res.voices[idx] = { count = s.count, low = s.low, high = s.high, avg = s.avg, overflow = s.overflow,
			pitch = res.drums and s.low or nil }
	end
	for i, v in pairs(raw) do
		raw[i] = (v > 0) and remap[v] or 0
	end
	res.numVoices = #list

	return res
end

return Core
