-- @noindex
--[[
  juno_MIDIExportHelper - analysis and track creation.

  Original tracks are only read. The one exception is REAPER's track spacer (I_SPACER), which is a property of
  the track *below* it, so the spacer between the export and the project is set on the first original track.

  Every track this script creates carries the P_EXT tag below, so later runs can recognise (and skip, or
  replace) it: "src:<GUID of the original track>". ("separator" marks the black separator track that early
  versions created; it is removed and replaced by a spacer.)
--]]

local M = {}

M.TAG    = "P_EXT:juno_MIDIExport"
M.PREFIX = "MIDI: "

-- MIDI split modes. AUTO = Drums if the track looks like drums, else Voice leading.
M.MIDI_AUTO, M.MIDI_SPLIT_VL, M.MIDI_SPLIT_TOP, M.MIDI_SPLIT_FIRST, M.MIDI_NO_SPLIT, M.MIDI_SPLIT_DRUMS = 0, 1, 2, 3, 4, 5
M.GM_DRUM_CHANNEL = 9 -- MIDI channel 10, 0-based
M.SAMPLE_AUTO, M.SAMPLE_ONE, M.SAMPLE_SPLIT = 1, 2, 3

local BEND_STEP = 0.01 -- seconds between pitch bend samples of a slide
local EPS = 1e-9

local floor, max, min, abs, log = math.floor, math.max, math.min, math.abs, math.log
local function round(x) return floor(x + 0.5) end

-----------------------------------------------------------------------------------------------------------------------
-- Small helpers
-----------------------------------------------------------------------------------------------------------------------

function M.GetTag(track)
	local _, v = reaper.GetSetMediaTrackInfo_String(track, M.TAG, "", false)
	return v or ""
end

local function trackName(track)
	local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
	return name or ""
end

local function baseName(path)
	return (path:match("[^\\/]+$") or path)
end

local function stripExt(name)
	return name:match("^(.*)%.[^.]+$") or name
end

local function rootSource(src)
	while true do
		local parent = reaper.GetMediaSourceParent(src)
		if not parent then return src end
		src = parent
	end
end

function M.FormatTime(t)
	return reaper.format_timestr_pos(t, "", 0) -- minutes:seconds, whatever the project's time format
end

--- Export range: =START / =END markers, else the whole project.
function M.Range()
	local s, e
	local i = 0
	while true do
		local ret, isRgn, pos, _, name = reaper.EnumProjectMarkers(i)
		if not ret or ret == 0 then break end
		if not isRgn then
			if name == "=START" then s = pos elseif name == "=END" then e = pos end
		end
		i = i + 1
	end
	local projLen = reaper.GetProjectLength(0)
	local r = { s = s or 0, e = e or projLen, hasStart = s ~= nil, hasEnd = e ~= nil }
	if r.e <= r.s then r.e, r.hasEnd = max(projLen, r.s), false end
	return r
end

local function clipToRange(t0, t1, range)
	t0, t1 = max(t0, range.s), min(t1, range.e)
	if t1 - t0 > EPS then return t0, t1 end
end

-- Trims same-pitch overlaps (same channel) so the MIDI stays valid. Chords are untouched.
local function trimSamePitch(notes)
	table.sort(notes, function(a, b)
		if a.t0 ~= b.t0 then return a.t0 < b.t0 end
		return a.pitch > b.pitch
	end)
	local last = {}
	local out = {}
	for _, n in ipairs(notes) do
		local k = n.chan * 128 + n.pitch
		local p = last[k]
		if p and abs(p.t0 - n.t0) < EPS then
			p.t1 = max(p.t1, n.t1); p.vel = max(p.vel, n.vel) -- exact duplicate: keep one
		else
			if p and p.t1 > n.t0 then p.t1 = n.t0 end
			last[k] = n
			out[#out + 1] = n
		end
	end
	return out
end

-----------------------------------------------------------------------------------------------------------------------
-- Scanning
-----------------------------------------------------------------------------------------------------------------------

local function trackColor(tr)
	local col = reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR")
	if col and (floor(col) & 0x1000000) ~= 0 then return floor(col) & 0xFFFFFF end
end

--- Original tracks that hold MIDI or sample items (never the ones this script made), in project order, plus
--- the folder tracks above them (kind = "parent", shown for context only).
--- Exportable rows: { kind = "track", track, guid, index, name, level, color (native rgb or nil), midi, samples }
function M.Scan()
	local list = {}
	local level = 0
	local stack = {} -- ancestors of the current track: { row, emitted }
	for ti = 0, reaper.CountTracks(0) - 1 do
		local tr = reaper.GetTrack(0, ti)
		local depth = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
		local here
		if M.GetTag(tr) == "" then
			local info = {
				kind = "track", track = tr, guid = reaper.GetTrackGUID(tr), index = ti, name = trackName(tr), level = level,
				midi = {}, samples = {}, color = trackColor(tr),
			}
			for ii = 0, reaper.CountTrackMediaItems(tr) - 1 do
				local item = reaper.GetTrackMediaItem(tr, ii)
				local take = reaper.GetActiveTake(item)
				if take and reaper.GetMediaItemInfo_Value(item, "B_MUTE") < 0.5 then
					if reaper.TakeIsMIDI(take) then
						table.insert(info.midi, item)
					else
						local src = rootSource(reaper.GetMediaItemTake_Source(take))
						if reaper.GetMediaSourceFileName(src, "") ~= "" then table.insert(info.samples, item) end
					end
				end
			end
			here = { row = info, emitted = false }
			if #info.midi > 0 or #info.samples > 0 then
				for _, anc in ipairs(stack) do -- show the folders this track is in
					if not anc.emitted then
						anc.emitted = true
						list[#list + 1] = anc.row
					end
				end
				list[#list + 1] = info
				here.emitted = true
			end
		end
		if depth > 0 then
			if here and not here.emitted then here.row.kind = "parent" end
			stack[#stack + 1] = here or { row = { kind = "parent", track = tr, name = trackName(tr), index = ti, level = level, color = trackColor(tr) }, emitted = false }
		elseif depth < 0 then
			for _ = 1, -depth do stack[#stack] = nil end
		end
		level = max(0, level + depth)
	end
	return list
end

--- Cheap fingerprint of everything Plan() reads from a track, to avoid recomputing unchanged tracks.
function M.ContentKey(info)
	local parts = { trackName(info.track) }
	for _, item in ipairs(info.midi) do
		local take = reaper.GetActiveTake(item)
		parts[#parts + 1] = ("%.9f,%.9f,%d"):format(reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
			reaper.GetMediaItemInfo_Value(item, "D_LENGTH"), reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC"))
		local _, hash = reaper.MIDI_GetHash(take, false, "")
		parts[#parts + 1] = hash
	end
	for _, item in ipairs(info.samples) do
		local take = reaper.GetActiveTake(item)
		local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
		parts[#parts + 1] = ("%.9f,%.9f,%.6f|%.6f,%.6f,%.6f,%.6f,%d"):format(
			reaper.GetMediaItemInfo_Value(item, "D_POSITION"), reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
			reaper.GetMediaItemInfo_Value(item, "D_VOL"), reaper.GetMediaItemTakeInfo_Value(take, "D_VOL"),
			reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH"), reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
			reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"), reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH"))
		parts[#parts + 1] = reaper.GetMediaSourceFileName(rootSource(reaper.GetMediaItemTake_Source(take)), "")
		if env then
			for pt = 0, reaper.CountEnvelopePoints(env) - 1 do
				local _, t, v = reaper.GetEnvelopePoint(env, pt)
				parts[#parts + 1] = ("%.6f:%.6f"):format(t, v)
			end
		end
	end
	return table.concat(parts, ";")
end

--- Tracks made by earlier runs: guid of original -> { track names }.
function M.Existing()
	local bySrc = {}
	for ti = 0, reaper.CountTracks(0) - 1 do
		local tr = reaper.GetTrack(0, ti)
		local guid = M.GetTag(tr):match("^src:(.+)$")
		if guid then
			bySrc[guid] = bySrc[guid] or {}
			table.insert(bySrc[guid], trackName(tr))
		end
	end
	return bySrc
end

--- Drums: the name says so, or most notes are on MIDI channel 10.
function M.LooksLikeDrums(name, notes)
	local lower = (name or ""):lower()
	for _, w in ipairs({ "drum", "kit", "perc", "batteria" }) do
		if lower:find(w, 1, true) then return true end
	end
	if #notes == 0 then return false end
	local ch10 = 0
	for _, n in ipairs(notes) do if n.chan == M.GM_DRUM_CHANNEL then ch10 = ch10 + 1 end end
	return ch10 * 2 >= #notes
end

-----------------------------------------------------------------------------------------------------------------------
-- MIDI tracks: merge every MIDI item into one note list (project time)
-----------------------------------------------------------------------------------------------------------------------

-- Length of one loop of the take's MIDI source, in ticks (nil if unknown).
local function loopTicks(take)
	if reaper.BR_GetMidiSourceLenPPQ then
		local len = reaper.BR_GetMidiSourceLenPPQ(take)
		if len and len > 0 then return len end
	end
	local len, isQN = reaper.GetMediaSourceLength(reaper.GetMediaItemTake_Source(take))
	if not isQN or not len or len <= 0 then return nil end
	local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
	local perQN = (reaper.MIDI_GetPPQPosFromProjQN(take, 1) - reaper.MIDI_GetPPQPosFromProjQN(take, 0)) / max(rate, EPS)
	return len * perQN
end

--- { notes = { {t0, t1, pitch, vel, chan} }, ccs = { {t, chanmsg, chan, msg2, msg3} } }
function M.MergeMIDI(info, range)
	local notes, ccs, lastBefore = {}, {}, {}
	for _, item in ipairs(info.midi) do
		local take = reaper.GetActiveTake(item)
		local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
		local iEnd = pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
		local loop = reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC") > 0.5 and loopTicks(take) or nil
		local _, noteCount, ccCount = reaper.MIDI_CountEvts(take)
		local function time(ppq) return reaper.MIDI_GetProjTimeFromPPQPos(take, ppq) end

		local k = 0
		while true do
			local off = loop and k * loop or 0
			if k > 0 and time(off) >= iEnd - EPS then break end
			for i = 0, noteCount - 1 do
				local _, _, muted, sp, ep, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
				if not muted then
					local t0, t1 = time(sp + off), time(ep + off)
					if t0 >= pos - EPS and t0 < iEnd - EPS then
						local c0, c1 = clipToRange(t0, min(t1, iEnd), range)
						if c0 then notes[#notes + 1] = { t0 = c0, t1 = c1, pitch = pitch, vel = vel, chan = chan } end
					end
				end
			end
			for i = 0, ccCount - 1 do
				local _, _, muted, ppq, chanmsg, chan, msg2, msg3 = reaper.MIDI_GetCC(take, i)
				if not muted then
					local t = time(ppq + off)
					if t >= pos - EPS and t < iEnd - EPS and t < range.e then
						local ev = { t = t, chanmsg = chanmsg, chan = chan, msg2 = msg2, msg3 = msg3 }
						if t >= range.s then
							ccs[#ccs + 1] = ev
						else
							-- remember the last value before the range, so it is still in effect at the start
							local key = chanmsg * 4096 + chan * 256 + ((chanmsg == 0xB0) and msg2 or 0)
							local p = lastBefore[key]
							if not p or p.t <= t then lastBefore[key] = ev end
						end
					end
				end
			end
			if not loop then break end
			k = k + 1
			if k > 100000 then break end
		end
	end
	for _, ev in pairs(lastBefore) do ev.t = range.s; ccs[#ccs + 1] = ev end
	table.sort(ccs, function(a, b) return a.t < b.t end)
	return { notes = trimSamePitch(notes), ccs = ccs }
end

-----------------------------------------------------------------------------------------------------------------------
-- Sample tracks
-----------------------------------------------------------------------------------------------------------------------

local function pitchEnvelope(take)
	local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
	if not env or reaper.CountEnvelopePoints(env) == 0 then return nil end
	local ok, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
	if ok and chunk:find("\nACT 0") then return nil end
	return env
end

local function envValue(env, t)
	local _, v = reaper.Envelope_Evaluate(env, t, 44100, 1)
	local mode = reaper.GetEnvelopeScalingMode(env)
	if mode and mode ~= 0 then v = reaper.ScaleFromEnvelopeMode(mode, v) end
	return v
end

--- Sample items grouped by source file + start position in the file (within `tol` seconds).
--- Each group: { file, offs, items = { {item, take, t0, t1, pitch, db, env} } }. Also returns min/max dB.
function M.SampleGroups(info, range, tol)
	local byFile, files = {}, {}
	local minDB, maxDB
	for _, item in ipairs(info.samples) do
		local take = reaper.GetActiveTake(item)
		local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
		local t0, t1 = clipToRange(pos, pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH"), range)
		if t0 then
			local src = rootSource(reaper.GetMediaItemTake_Source(take))
			local file = reaper.GetMediaSourceFileName(src, "")
			local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
			local pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
			if reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH") < 0.5 and rate > 0 then
				pitch = pitch + 12 * log(rate, 2) -- playrate changes the pitch too
			end
			local vol = reaper.GetMediaItemInfo_Value(item, "D_VOL") * reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")
			local db = vol > 0 and 20 * log(vol, 10) or -150
			minDB, maxDB = min(minDB or db, db), max(maxDB or db, db)
			if not byFile[file] then byFile[file] = {}; files[#files + 1] = file end
			table.insert(byFile[file], {
				item = item, take = take, pos = pos, t0 = t0, t1 = t1, pitch = pitch, db = db,
				offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"), env = pitchEnvelope(take),
			})
		end
	end
	local groups = {}
	for _, file in ipairs(files) do
		local list = byFile[file]
		table.sort(list, function(a, b) if a.offs ~= b.offs then return a.offs < b.offs end return a.t0 < b.t0 end)
		local g
		for _, e in ipairs(list) do
			if not g or e.offs - g.offs > tol then
				g = { file = file, offs = e.offs, items = {} }
				groups[#groups + 1] = g
			end
			table.insert(g.items, e)
		end
	end
	return groups, minDB, maxDB
end

--- Largest slide (semitones, absolute) among the items of the groups, from the envelope points.
function M.MaxSlide(groups)
	local m = 0
	for _, g in ipairs(groups) do
		for _, e in ipairs(g.items) do
			if e.env then
				for p = 0, reaper.CountEnvelopePoints(e.env) - 1 do
					local _, _, v = reaper.GetEnvelopePoint(e.env, p)
					local mode = reaper.GetEnvelopeScalingMode(e.env)
					if mode and mode ~= 0 then v = reaper.ScaleFromEnvelopeMode(mode, v) end
					m = max(m, abs(v))
				end
			end
		end
	end
	return m
end

--- Pitch bend range for a slide: 12, or the next whole octave above the largest slide.
function M.BendRange(maxSlide)
	if maxSlide <= 12 + EPS then return 12 end
	return 12 * math.ceil(maxSlide / 12 - EPS)
end

local function velocity(db, minDB, maxDB)
	if not minDB or maxDB - minDB < 0.01 then return 127 end
	return max(1, min(127, 1 + round((db - minDB) / (maxDB - minDB) * 126)))
end

-- Notes (and pitch bends of slides) for the given groups.
local function sampleNotes(groups, baseNote, minDB, maxDB)
	local notes, bends, maxSlide = {}, {}, 0
	for _, g in ipairs(groups) do
		for _, e in ipairs(g.items) do
			local pitch = max(0, min(127, baseNote + round(e.pitch)))
			notes[#notes + 1] = { t0 = e.t0, t1 = e.t1, pitch = pitch, vel = velocity(e.db, minDB, maxDB), chan = 0 }
			if e.env then
				local last = 0
				local t = e.t0
				while t < e.t1 - EPS do
					local v = envValue(e.env, t - e.pos)
					if abs(v - last) > 0.001 then
						bends[#bends + 1] = { t = t, semis = v }
						last = v
					end
					maxSlide = max(maxSlide, abs(v))
					t = t + BEND_STEP
				end
				if last ~= 0 then bends[#bends + 1] = { t = e.t1, semis = 0 } end
			end
		end
	end
	return trimSamePitch(notes), bends, maxSlide
end

-----------------------------------------------------------------------------------------------------------------------
-- Planning: what will be created for a track
-----------------------------------------------------------------------------------------------------------------------

local SPLIT_MODE_OF = { } -- filled lazily (needs Core)

--- Display name for an original track (falls back to the sample file names, then "Track N").
local function displayName(info, groups)
	if info.name ~= "" then return info.name end
	if groups and #groups > 0 then
		local seen, names = {}, {}
		for _, g in ipairs(groups) do
			local n = stripExt(baseName(g.file))
			if not seen[n] then seen[n] = true; names[#names + 1] = n end
		end
		if #names > 3 then return table.concat(names, " + ", 1, 3) .. " + ..." end
		return table.concat(names, " + ")
	end
	return "Track " .. (info.index + 1)
end

local function groupLabel(g, sameFileCount)
	local label = baseName(g.file)
	if sameFileCount > 1 then label = label .. " @ " .. M.FormatTime(g.offs):gsub("^0:0?", "") end
	return label
end

--- The tracks to create for one original track.
--- opts: { range, tol, baseNote, midiMode, sampleMode, Core }
--- Returns { outputs = { {name, depth, level, notes, ccs, bends, bendRange} }, summary = {...} }
function M.Plan(info, opts)
	local Core = opts.Core
	SPLIT_MODE_OF[M.MIDI_SPLIT_VL] = Core.MODE_VOICE_LEADING
	SPLIT_MODE_OF[M.MIDI_SPLIT_TOP] = Core.MODE_TOP_TO_BOTTOM
	SPLIT_MODE_OF[M.MIDI_SPLIT_FIRST] = Core.MODE_FIRST_AVAILABLE
	SPLIT_MODE_OF[M.MIDI_SPLIT_DRUMS] = Core.MODE_DRUMS

	local outputs, summary = {}, {}
	local both = #info.midi > 0 and #info.samples > 0
	local groups, minDB, maxDB
	if #info.samples > 0 then groups, minDB, maxDB = M.SampleGroups(info, opts.range, opts.tol) end
	local name = displayName(info, groups)

	-- MIDI part
	if #info.midi > 0 then
		local merged = M.MergeMIDI(info, opts.range)
		summary.drumLike = M.LooksLikeDrums(info.name, merged.notes)
		local midiMode = opts.midiMode
		if not midiMode or midiMode == M.MIDI_AUTO then
			midiMode = summary.drumLike and M.MIDI_SPLIT_DRUMS or M.MIDI_SPLIT_VL
		end
		summary.midiMode = midiMode
		local voices
		local mode = SPLIT_MODE_OF[midiMode]
		if mode and #merged.notes > 1 then
			local input = {}
			for i, n in ipairs(merged.notes) do input[i] = { start = n.t0, finish = n.t1, pitch = n.pitch } end
			local splitOpts = {}
			for k, v in pairs(opts.split or {}) do splitOpts[k] = v end
			splitOpts.mode = mode
			local res = Core.Split(input, splitOpts)
			if res.numVoices > 1 then voices = res end
		end
		local title = M.PREFIX .. name
		summary.midiNotes = #merged.notes
		if voices then
			summary.midi = voices.drums and ("folder: full MIDI + %d drum notes"):format(voices.numVoices)
				or ("folder: full MIDI + %d voices"):format(voices.numVoices)
			outputs[#outputs + 1] = { name = title, depth = 1, notes = merged.notes, ccs = merged.ccs }
			local per = {}
			for v = 1, voices.numVoices do per[v] = {} end
			for i, n in ipairs(merged.notes) do
				local v = voices.voiceOf[i]
				if v and v > 0 then table.insert(per[v], n) end
			end
			for v = 1, voices.numVoices do
				local label = ("%s %d"):format(title, v)
				local pitch = voices.voices[v].pitch
				if pitch then -- drums: "MIDI: Drums 1 (C2 Kick)", GM name only for channel 10 notes
					local gm = per[v][1] and per[v][1].chan == M.GM_DRUM_CHANNEL and Core.GM_DRUMS[pitch]
					label = ("%s (%s%s)"):format(label, Core.PitchName(pitch), gm and (" " .. gm) or "")
				end
				outputs[#outputs + 1] = { name = label, depth = 0, child = v, notes = per[v], ccs = merged.ccs }
			end
			outputs[#outputs].depth = -1
		else
			summary.midi = #merged.notes > 0 and "1 track" or "1 track (no notes in range)"
			outputs[#outputs + 1] = { name = title, depth = 0, notes = merged.notes, ccs = merged.ccs }
		end
	end

	-- Sample part
	if groups then
		local title = M.PREFIX .. name .. (both and " (samples)" or "")
		local split = opts.sampleMode == M.SAMPLE_SPLIT or (opts.sampleMode == M.SAMPLE_AUTO and #groups > 1)
		summary.groups = #groups
		summary.autoSplit = #groups > 1
		local perFile = {}
		for _, g in ipairs(groups) do perFile[g.file] = (perFile[g.file] or 0) + 1 end
		local function out(o, gs)
			local notes, bends, slide = sampleNotes(gs, opts.baseNote, minDB, maxDB)
			o.notes, o.bends = notes, bends
			if #bends > 0 then
				o.bendRange = M.BendRange(slide)
				summary.bendRange = max(summary.bendRange or 0, o.bendRange)
			end
			return o
		end
		if split and #groups > 0 then
			summary.samples = ("folder: %d sample%s"):format(#groups, #groups == 1 and "" or "s")
			outputs[#outputs + 1] = { name = title, depth = 1, notes = {} } -- the samples share a centre note: parent stays empty
			for i, g in ipairs(groups) do
				outputs[#outputs + 1] = out({ name = ("%s %d (%s)"):format(title, i, groupLabel(g, perFile[g.file])), depth = 0, child = i }, { g })
			end
			outputs[#outputs].depth = -1
		else
			summary.samples = #groups > 0 and "1 track" or "1 track (no items in range)"
			outputs[#outputs + 1] = out({ name = title, depth = 0 }, groups)
		end
	end

	-- Preview: every note once, tagged with the output track it ends up on (folder parents with children are
	-- skipped, since they only repeat the children's notes).
	local roll = { notes = {}, lanes = 0, low = 127, high = 0, t0 = opts.range.s, t1 = opts.range.e }
	for k, o in ipairs(outputs) do
		o.notes = o.notes or {}
		local parentWithKids = o.depth == 1 and outputs[k + 1] ~= nil and outputs[k + 1].child ~= nil
		if not parentWithKids then
			roll.lanes = roll.lanes + 1
			for _, n in ipairs(o.notes) do
				roll.notes[#roll.notes + 1] = { t0 = n.t0, t1 = n.t1, pitch = n.pitch, child = o.child }
				roll.low, roll.high = min(roll.low, n.pitch), max(roll.high, n.pitch)
			end
		end
	end
	return { outputs = outputs, summary = summary, name = name, roll = roll }
end

-----------------------------------------------------------------------------------------------------------------------
-- Building
-----------------------------------------------------------------------------------------------------------------------

local PALETTE = {
	{ 230, 110, 100 }, { 240, 170, 80 }, { 220, 210, 90 }, { 120, 200, 110 }, { 90, 190, 200 },
	{ 100, 140, 230 }, { 160, 120, 220 }, { 220, 120, 190 },
}

--- { r, g, b } colour of an original track (its own colour, else one from the palette).
function M.BaseColor(info, n)
	if info.color then return { reaper.ColorFromNative(info.color) } end
	return PALETTE[((n or 1) - 1) % #PALETTE + 1]
end

function M.Shade(rgb, i)
	if not i then return rgb end
	local f = 0.12 * ((i - 1) % 5 + 1) -- children: progressively lighter
	return { round(rgb[1] + (255 - rgb[1]) * f), round(rgb[2] + (255 - rgb[2]) * f), round(rgb[3] + (255 - rgb[3]) * f) }
end

local function insertEvents(take, o, range)
	local function ppq(t) return reaper.MIDI_GetPPQPosFromProjTime(take, t) end
	for _, n in ipairs(o.notes) do
		reaper.MIDI_InsertNote(take, false, false, ppq(n.t0), ppq(n.t1), n.chan, n.pitch, n.vel, true)
	end
	for _, c in ipairs(o.ccs or {}) do
		reaper.MIDI_InsertCC(take, false, false, ppq(c.t), c.chanmsg, c.chan, c.msg2, c.msg3, true)
	end
	if o.bends and #o.bends > 0 then
		-- RPN 0 (pitch bend sensitivity) at the start, so a sampler following it gets the right range
		local p0 = ppq(range.s)
		for _, cc in ipairs({ { 101, 0 }, { 100, 0 }, { 6, o.bendRange }, { 38, 0 }, { 101, 127 }, { 100, 127 } }) do
			reaper.MIDI_InsertCC(take, false, false, p0, 0xB0, 0, cc[1], cc[2], true)
		end
		for _, b in ipairs(o.bends) do
			local v = max(0, min(16383, 8192 + round(b.semis / o.bendRange * 8192)))
			reaper.MIDI_InsertCC(take, false, false, ppq(b.t), 0xE0, 0, v & 0x7F, v >> 7, true)
		end
	end
	reaper.MIDI_Sort(take)
end

--- Creates the planned tracks at the top of the project.
--- jobs: { {info, plan} } in project order. replace: delete earlier exports of these originals first.
function M.Build(jobs, replace, range)
	reaper.Undo_BeginBlock()
	reaper.PreventUIRefresh(1)

	if replace then
		local guids = {}
		for _, j in ipairs(jobs) do guids[j.info.guid] = true end
		for ti = reaper.CountTracks(0) - 1, 0, -1 do
			local tr = reaper.GetTrack(0, ti)
			local guid = M.GetTag(tr):match("^src:(.+)$")
			if guid and guids[guid] then reaper.DeleteTrack(tr) end
		end
	end
	-- early versions made a black separator track: replace it by a spacer
	for ti = reaper.CountTracks(0) - 1, 0, -1 do
		local tr = reaper.GetTrack(0, ti)
		if M.GetTag(tr) == "separator" then reaper.DeleteTrack(tr) end
	end

	local idx, created = 0, 0
	for ji, j in ipairs(jobs) do
		local base = M.BaseColor(j.info, ji)
		for _, o in ipairs(j.plan.outputs) do
			reaper.InsertTrackAtIndex(idx, false)
			local tr = reaper.GetTrack(0, idx)
			idx = idx + 1
			created = created + 1
			reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", o.name, true)
			reaper.GetSetMediaTrackInfo_String(tr, M.TAG, "src:" .. j.info.guid, true)
			local c = M.Shade(base, o.child)
			reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", reaper.ColorToNative(c[1], c[2], c[3]) | 0x1000000)
			reaper.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", o.depth)
			if #o.notes > 0 or (o.ccs and #o.ccs > 0) then
				local item = reaper.CreateNewMIDIItemInProj(tr, range.s, range.e, false)
				local take = item and reaper.GetActiveTake(item)
				if take then
					reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", o.name, true)
					insertEvents(take, o, range)
				end
			end
		end
	end

	-- spacer above the first original track (REAPER 7: a spacer belongs to the track below it)
	if created > 0 then
		for ti = 0, reaper.CountTracks(0) - 1 do
			local tr = reaper.GetTrack(0, ti)
			if M.GetTag(tr) == "" then
				if reaper.GetMediaTrackInfo_Value(tr, "I_SPACER") ~= 1 then
					reaper.SetMediaTrackInfo_Value(tr, "I_SPACER", 1)
				end
				break
			end
		end
	end

	reaper.PreventUIRefresh(-1)
	reaper.TrackList_AdjustWindows(false)
	reaper.UpdateArrange()
	reaper.Undo_EndBlock("juno: MIDI export helper", -1)
	return created
end

return M
