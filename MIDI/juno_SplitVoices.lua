-- @description juno: Split MIDI voices into tracks
-- @author juno
-- @version 1.0.0
-- @changelog
--   Initial release.
-- @provides
--   [nomain] juno_SplitVoices/core.lua
-- @about
--   # juno: Split Voices
--
--   Splits polyphonic MIDI (chords, piano parts, choir writing...) into one track per voice.
--
--   Select one or more MIDI items and run the script. Notes from all selected items on the
--   same track are analysed together, so a voice stays on the same track across items.
--
--   ## Modes
--   - **First Available**: as many tracks as the max number of simultaneous notes; each note
--     goes to the first free track.
--   - **Top to Bottom**: notes of every chord are ranked by pitch (highest -> top track).
--   - **Voice Leading**: follows melodic lines, assigning each note to the free voice whose
--     recent pitch is closest, while avoiding voice crossings.
--   - **Pitch Ranges**: split by keyboard split points (e.g. C4 for left/right hand).
--   - **Drums**: one track per note pitch (kick, snare, hi-hat... each on its own track).
--
--   ## Features
--   - Chord and legato-overlap tolerances for humanized/played-in MIDI.
--   - Fixed or automatic voice count, with overflow handling.
--   - Live piano-roll preview coloured by voice.
--   - Output tracks named, coloured, grouped in a folder, with the source FX chain copied.
--   - CC / pitch bend / sustain can go to all voices, the first voice only, or be removed.
--
--   Requires ReaImGui (ReaTeam Extensions repository).
--
--   Limitation: looped MIDI items are analysed using their first loop iteration only.

local SCRIPT_NAME = "juno: Split Voices"
local EXT_SECTION = "juno_SplitVoices"

-----------------------------------------------------------------------------------------------------------------------
-- Dependencies
-----------------------------------------------------------------------------------------------------------------------

if not reaper.ImGui_GetBuiltinPath then
	reaper.MB("This script requires ReaImGui.\n\nAfter closing this message ReaPack will open on it: "
		.. "install it, restart REAPER and run the script again.", SCRIPT_NAME, 0)
	if reaper.ReaPack_BrowsePackages then reaper.ReaPack_BrowsePackages("ReaImGui") end
	return
end

package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ok_imgui, ImGui = pcall(function() return require("imgui")("0.9") end)
if not ok_imgui then
	reaper.MB("This script requires ReaImGui 0.9 or newer.\nPlease update it through ReaPack.", SCRIPT_NAME, 0)
	if reaper.ReaPack_BrowsePackages then reaper.ReaPack_BrowsePackages("ReaImGui") end
	return
end

local SCRIPT_DIR = debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or ""
local Core = dofile(SCRIPT_DIR .. "juno_SplitVoices/core.lua")

-----------------------------------------------------------------------------------------------------------------------
-- Settings (persisted in REAPER's ExtState)
-----------------------------------------------------------------------------------------------------------------------

local SETTINGS_VERSION = "2" -- bump when defaults change, so stale saved settings are ignored

local CC_MODES     = { "Copy to every voice", "First voice only", "Remove" }
local SOURCE_MODES = { "Keep source items", "Mute source items", "Delete source items" }

local MODE_HELP = {
	[Core.MODE_FIRST_AVAILABLE] = "Creates as many tracks as the maximum number of notes playing at once. "
		.. "Each note goes to the first free track, top track first. Simple and predictable, "
		.. "but a voice can jump between registers.",
	[Core.MODE_TOP_TO_BOTTOM] = "At every chord the notes are ranked by pitch: the highest goes to the top "
		.. "track, the lowest to the bottom one. Best for block chords and choir-style writing.",
	[Core.MODE_VOICE_LEADING] = "Follows each melodic line: a new note goes to the free voice whose recent "
		.. "pitch is closest, avoiding voice crossings and big leaps. Best for real polyphony, "
		.. "counterpoint, piano and guitar parts.",
	[Core.MODE_DRUMS] = "One track per note pitch: every kick on one track, every snare on another... "
		.. "Best for drum and percussion parts.",
	[Core.MODE_PITCH_RANGES] = "Splits by pitch. Each split point starts a new track below it "
		.. "(notes at or above the split point go to the upper track). 'C4' = left/right hand.",
}

local DEFAULT_SETTINGS = {
	mode          = Core.DEFAULTS.mode,
	autoVoices    = true,
	voiceCount    = 4,
	overflow      = Core.DEFAULTS.overflow,
	fill          = Core.DEFAULTS.fill,
	allowCrossing = Core.DEFAULTS.allowCrossing,
	memorySec     = Core.DEFAULTS.memorySec,
	chordTolMs    = Core.DEFAULTS.chordTolMs,
	overlapTolMs  = Core.DEFAULTS.overlapTolMs,
	splitsText    = "C4",
	orderByPitch  = Core.DEFAULTS.orderByPitch,
	folder        = false,
	copyFX        = false,
	ccMode        = 1,
	sourceMode    = 1,
}

local S = {}

local function loadSettings()
	local useSaved = reaper.GetExtState(EXT_SECTION, "_version") == SETTINGS_VERSION
	for k, def in pairs(DEFAULT_SETTINGS) do
		local raw = useSaved and reaper.GetExtState(EXT_SECTION, k) or ""
		local val = def
		if raw ~= "" then
			if type(def) == "boolean" then val = (raw == "1")
			elseif type(def) == "number" then val = tonumber(raw) or def
			else val = raw end
		end
		S[k] = val
	end
end

local function saveSettings()
	for k, v in pairs(S) do
		local raw = (type(v) == "boolean") and (v and "1" or "0") or tostring(v)
		reaper.SetExtState(EXT_SECTION, k, raw, true)
	end
	reaper.SetExtState(EXT_SECTION, "_version", SETTINGS_VERSION, true)
end

local function settingsKey()
	local keys = {}
	for k in pairs(S) do keys[#keys + 1] = k end
	table.sort(keys)
	local parts = {}
	for i, k in ipairs(keys) do parts[i] = k .. "=" .. tostring(S[k]) end
	return table.concat(parts, ";")
end

local function coreOptions()
	return {
		mode          = S.mode,
		voiceCount    = S.autoVoices and 0 or S.voiceCount,
		overflow      = S.overflow,
		fill          = S.fill,
		allowCrossing = S.allowCrossing,
		memorySec     = S.memorySec,
		chordTolMs    = S.chordTolMs,
		overlapTolMs  = S.overlapTolMs,
		splits        = Core.ParseSplits(S.splitsText),
		orderByPitch  = S.orderByPitch,
	}
end

-----------------------------------------------------------------------------------------------------------------------
-- Colours / names
-----------------------------------------------------------------------------------------------------------------------

local function hsv2rgb(h, s, v)
	h = (h % 360) / 60
	local c = v * s
	local x = c * (1 - math.abs(h % 2 - 1))
	local m = v - c
	local r, g, b
	if     h < 1 then r, g, b = c, x, 0
	elseif h < 2 then r, g, b = x, c, 0
	elseif h < 3 then r, g, b = 0, c, x
	elseif h < 4 then r, g, b = 0, x, c
	elseif h < 5 then r, g, b = x, 0, c
	else              r, g, b = c, 0, x end
	return math.floor((r + m) * 255 + 0.5), math.floor((g + m) * 255 + 0.5), math.floor((b + m) * 255 + 0.5)
end

local function rgb2hsv(r, g, b)
	r, g, b = r / 255, g / 255, b / 255
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local d = mx - mn
	local h = 0
	if d > 0 then
		if mx == r then h = 60 * (((g - b) / d) % 6)
		elseif mx == g then h = 60 * ((b - r) / d + 2)
		else h = 60 * ((r - g) / d + 4) end
	end
	return h, (mx > 0) and d / mx or 0, mx
end

local function imguiColor(r, g, b, a)
	return (r << 24) | (g << 16) | (b << 8) | (a or 0xFF)
end

--- Gradient from the source track colour. Returns two arrays: ImGui RGBA colours and REAPER native colours.
local function voiceColors(track, res)
	local h, s, v = 205, 0.55, 0.9
	local native = track and reaper.GetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR") or 0
	local hasColor = (math.floor(native) & 0x1000000) ~= 0
	if hasColor then
		h, s, v = rgb2hsv(reaper.ColorFromNative(math.floor(native) & 0xFFFFFF))
		s, v = math.max(s, 0.35), math.max(v, 0.55)
	end

	local imgui, reaperCols = {}, {}
	local mains = 0
	for _, vo in ipairs(res.voices) do if not vo.overflow then mains = mains + 1 end end

	for idx, vo in ipairs(res.voices) do
		local r, g, b
		if vo.overflow then
			r, g, b = 128, 128, 128
		else
			local tpos = (mains > 1) and (idx - 1) / (mains - 1) or 0
			r, g, b = hsv2rgb(h + tpos * 140 - 20, s, v - tpos * 0.15)
		end
		imgui[idx] = imguiColor(r, g, b)
		reaperCols[idx] = reaper.ColorToNative(r, g, b) | 0x1000000
	end
	return imgui, reaperCols
end

--- "<Track> - Voice N" (and "<Track> - Overflow"); in Drums mode "<Track> - C1".
local function voiceNames(srcName, res)
	local names = {}
	for idx, vo in ipairs(res.voices) do
		local label = vo.overflow and "Overflow" or (vo.pitch and Core.PitchName(vo.pitch)) or ("Voice " .. idx)
		names[idx] = srcName .. " - " .. label
	end
	return names
end

-----------------------------------------------------------------------------------------------------------------------
-- Reading the selection
-----------------------------------------------------------------------------------------------------------------------

local function trackName(track)
	local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
	if name == "" then
		name = "Track " .. math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
	end
	return name
end

local function noteKey(sp, ep, chan, pitch)
	return ("%.4f:%.4f:%d:%d"):format(sp, ep, chan, pitch)
end

--- Collects selected MIDI items grouped by track.
--- Each source: { track, name, items = { {item, take, keys = {noteIdx -> key}, noteRef = {noteIdx -> srcNoteIdx}} }, notes }
local function gatherSources()
	local byTrack, list = {}, {}
	for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
		local item = reaper.GetSelectedMediaItem(0, i)
		local take = reaper.GetActiveTake(item)
		if take and reaper.TakeIsMIDI(take) then
			local track = reaper.GetMediaItem_Track(item)
			local src = byTrack[track]
			if not src then
				src = { track = track, name = trackName(track), items = {}, notes = {} }
				byTrack[track] = src
				list[#list + 1] = src
			end
			local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
			local itemEnd = itemStart + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
			local _, noteCount = reaper.MIDI_CountEvts(take)
			local entry = { item = item, take = take, noteCount = noteCount, keys = {}, noteRef = {} }
			src.items[#src.items + 1] = entry

			for n = 0, noteCount - 1 do
				local _, _, _, sp, ep, chan, pitch = reaper.MIDI_GetNote(take, n)
				entry.keys[n] = noteKey(sp, ep, chan, pitch)
				local s = reaper.MIDI_GetProjTimeFromPPQPos(take, sp)
				local e = reaper.MIDI_GetProjTimeFromPPQPos(take, ep)
				if e > itemStart and s < itemEnd then -- ignore notes hidden outside the item bounds
					src.notes[#src.notes + 1] = { start = math.max(s, itemStart), finish = math.min(e, itemEnd), pitch = pitch }
					entry.noteRef[n] = #src.notes
				end
			end
		end
	end
	table.sort(list, function(a, b)
		return reaper.GetMediaTrackInfo_Value(a.track, "IP_TRACKNUMBER") < reaper.GetMediaTrackInfo_Value(b.track, "IP_TRACKNUMBER")
	end)
	return list
end

local function selectionSignature()
	local parts = { tostring(reaper.GetProjectStateChangeCount(0)) }
	for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
		parts[#parts + 1] = tostring(reaper.GetSelectedMediaItem(0, i))
	end
	return table.concat(parts, ",")
end

-----------------------------------------------------------------------------------------------------------------------
-- Writing the result
-----------------------------------------------------------------------------------------------------------------------

local GUID_PATTERN = "{%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x}"

--- Copies an item to another track. All GUIDs are regenerated, which also un-pools pooled MIDI.
local function copyItemToTrack(item, track)
	local _, chunk = reaper.GetItemStateChunk(item, "", false)
	chunk = chunk:gsub(GUID_PATTERN, function() return reaper.genGuid("") end)
	local new = reaper.AddMediaItemToTrack(track)
	reaper.SetItemStateChunk(new, chunk, false)
	reaper.SetMediaItemSelected(new, false)
	return new
end

local function deleteAllCCs(take)
	local _, _, ccCount = reaper.MIDI_CountEvts(take)
	for c = ccCount - 1, 0, -1 do reaper.MIDI_DeleteCC(take, c) end
end

--- Builds { key -> queue of voices } for one source item (handles duplicated identical notes).
local function voiceQueues(entry, res)
	local queues = {}
	for n = 0, entry.noteCount - 1 do
		local key = entry.keys[n]
		if key then
			local ref = entry.noteRef[n]
			local v = ref and res.voiceOf[ref] or 0
			local q = queues[key]
			if not q then q = { pos = 1 }; queues[key] = q end
			q[#q + 1] = v
		end
	end
	return queues
end

--- Inserts `count` tracks right after `track`, with folder structure fixed up. Returns the new tracks.
local function insertVoiceTracks(track, count, asFolder)
	local srcIdx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) -- 1-based
	local srcDepth = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH"))
	local tracks = {}
	for v = 1, count do
		reaper.InsertTrackAtIndex(srcIdx + v - 1, true)
		tracks[v] = reaper.GetTrack(0, srcIdx + v - 1)
		reaper.SetMediaTrackInfo_Value(tracks[v], "I_FOLDERDEPTH", 0)
	end
	if srcDepth == 1 then
		-- Source already is a folder parent: the new tracks become its first children.
	elseif asFolder then
		reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", 1)
		reaper.SetMediaTrackInfo_Value(tracks[count], "I_FOLDERDEPTH", srcDepth - 1)
	else
		reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", 0)
		reaper.SetMediaTrackInfo_Value(tracks[count], "I_FOLDERDEPTH", srcDepth)
	end
	return tracks
end

local function splitSource(src, res)
	local N = res.numVoices
	if N == 0 then return 0 end

	local tracks = insertVoiceTracks(src.track, N, S.folder)
	local names = voiceNames(src.name, res)
	local _, nativeCols = voiceColors(src.track, res)

	for v, tr in ipairs(tracks) do
		reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", names[v], true)
		reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", nativeCols[v])
		if S.copyFX then
			for fx = 0, reaper.TrackFX_GetCount(src.track) - 1 do
				reaper.TrackFX_CopyToTrack(src.track, fx, tr, fx, false)
			end
		end
	end

	for _, entry in ipairs(src.items) do
		-- Which voices actually have notes in this item?
		local used = {}
		for _, ref in pairs(entry.noteRef) do
			local v = res.voiceOf[ref]
			if v and v > 0 then used[v] = true end
		end

		for v = 1, N do
			if used[v] then
				local newItem = copyItemToTrack(entry.item, tracks[v])
				local take = reaper.GetActiveTake(newItem)
				local queues = voiceQueues(entry, res)
				reaper.MIDI_DisableSort(take)
				local _, noteCount = reaper.MIDI_CountEvts(take)
				local toDelete = {}
				for n = 0, noteCount - 1 do
					local _, _, _, sp, ep, chan, pitch = reaper.MIDI_GetNote(take, n)
					local q = queues[noteKey(sp, ep, chan, pitch)]
					local nv = 0
					if q and q[q.pos] then nv = q[q.pos]; q.pos = q.pos + 1 end
					if nv ~= v then toDelete[#toDelete + 1] = n end
				end
				for k = #toDelete, 1, -1 do reaper.MIDI_DeleteNote(take, toDelete[k]) end
				if S.ccMode == 3 or (S.ccMode == 2 and v ~= 1) then deleteAllCCs(take) end
				reaper.MIDI_Sort(take)
			end
		end

		if S.sourceMode == 2 then
			reaper.SetMediaItemInfo_Value(entry.item, "B_MUTE", 1)
		end
	end

	if S.sourceMode == 3 then
		for _, entry in ipairs(src.items) do
			reaper.DeleteTrackMediaItem(src.track, entry.item)
		end
	end
	return N
end

local function runSplit()
	local sources = gatherSources()
	local opts = coreOptions()
	local tracksMade, srcCount = 0, 0

	reaper.Undo_BeginBlock()
	reaper.PreventUIRefresh(1)
	local okRun, err = pcall(function()
		for _, src in ipairs(sources) do
			local res = Core.Split(src.notes, opts)
			local made = splitSource(src, res)
			if made > 0 then
				tracksMade = tracksMade + made
				srcCount = srcCount + 1
			end
		end
	end)
	reaper.PreventUIRefresh(-1)
	reaper.TrackList_AdjustWindows(false)
	reaper.UpdateArrange()
	reaper.Undo_EndBlock("juno: Split MIDI voices into tracks", -1)

	if not okRun then return false, "Error: " .. tostring(err) .. " (use Undo to revert partial changes)" end
	return true, ("Created %d track%s from %d source track%s."):format(
		tracksMade, tracksMade == 1 and "" or "s", srcCount, srcCount == 1 and "" or "s")
end

-----------------------------------------------------------------------------------------------------------------------
-- UI
-----------------------------------------------------------------------------------------------------------------------

local ctx = ImGui.CreateContext(SCRIPT_NAME)

local state = {
	sources     = {},
	srcIndex    = 1,
	selSig      = nil,
	resKey      = nil,
	result      = nil,
	status      = nil,
	statusColor = 0x9BE29BFF,
	closeAfter  = false,
}

local function comboItems(list) return table.concat(list, "\0") .. "\0" end

local function infoMarker(desc)
	ImGui.SameLine(ctx)
	ImGui.TextDisabled(ctx, "(?)")
	if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_DelayShort) and ImGui.BeginTooltip(ctx) then
		ImGui.PushTextWrapPos(ctx, ImGui.GetFontSize(ctx) * 30)
		ImGui.Text(ctx, desc)
		ImGui.PopTextWrapPos(ctx)
		ImGui.EndTooltip(ctx)
	end
end

local function combo(label, key, list, help)
	local changed, idx = ImGui.Combo(ctx, label, S[key] - 1, comboItems(list))
	if changed then S[key] = idx + 1 end
	if help then infoMarker(help) end
end

local function checkbox(label, key, help)
	local changed, v = ImGui.Checkbox(ctx, label, S[key])
	if changed then S[key] = v end
	if help then infoMarker(help) end
end

local function sliderInt(label, key, lo, hi, fmt, help)
	local changed, v = ImGui.SliderInt(ctx, label, S[key], lo, hi, fmt, ImGui.SliderFlags_AlwaysClamp)
	if changed then S[key] = v end
	if help then infoMarker(help) end
end

local function refresh()
	local sig = selectionSignature()
	if sig ~= state.selSig then
		state.selSig = sig
		state.sources = gatherSources()
		state.resKey = nil
		if state.srcIndex > #state.sources then state.srcIndex = 1 end
	end
	local src = state.sources[state.srcIndex]
	local key = settingsKey() .. "|" .. state.srcIndex .. "|" .. sig
	if key ~= state.resKey then
		state.resKey = key
		state.result = src and Core.Split(src.notes, coreOptions()) or nil
	end
end

local function drawPreview(src, res, colors)
	local avail = ImGui.GetContentRegionAvail(ctx)
	local w, h = math.max(avail, 50), 200
	local x0, y0 = ImGui.GetCursorScreenPos(ctx)
	ImGui.InvisibleButton(ctx, "##preview", w, h)
	local hovered = ImGui.IsItemHovered(ctx)
	local dl = ImGui.GetWindowDrawList(ctx)

	ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, 0x161616FF, 4)

	local notes = src.notes
	if #notes == 0 then return end
	local t0, t1, lo, hi = math.huge, -math.huge, 127, 0
	for _, n in ipairs(notes) do
		t0, t1 = math.min(t0, n.start), math.max(t1, n.finish)
		lo, hi = math.min(lo, n.pitch), math.max(hi, n.pitch)
	end
	lo, hi = math.max(0, lo - 2), math.min(127, hi + 2)
	local span = math.max(t1 - t0, 1e-3)
	local rowH = h / (hi - lo + 1)

	ImGui.DrawList_PushClipRect(dl, x0, y0, x0 + w, y0 + h, true)
	for p = lo, hi do
		if p % 12 == 0 then
			local y = y0 + (hi - p + 1) * rowH
			ImGui.DrawList_AddLine(dl, x0, y, x0 + w, y, 0x2E2E2EFF)
			ImGui.DrawList_AddText(dl, x0 + 3, y - 13, 0x6A6A6AFF, Core.PitchName(p))
		end
	end

	local mx, my = ImGui.GetMousePos(ctx)
	local hoverNote
	for i, n in ipairs(notes) do
		local v = res.voiceOf[i] or 0
		local nx1 = x0 + (n.start - t0) / span * w
		local nx2 = math.max(nx1 + 2, x0 + (n.finish - t0) / span * w - 1)
		local ny1 = y0 + (hi - n.pitch) * rowH
		local ny2 = ny1 + math.max(rowH - 1, 2)
		if v > 0 then
			ImGui.DrawList_AddRectFilled(dl, nx1, ny1, nx2, ny2, colors[v], 1)
		else
			ImGui.DrawList_AddRect(dl, nx1, ny1, nx2, ny2, 0xFF5555FF, 1)
		end
		if hovered and mx >= nx1 and mx <= nx2 and my >= ny1 - 1 and my <= ny2 + 1 then hoverNote = i end
	end
	ImGui.DrawList_PopClipRect(dl)

	if hoverNote then
		local v = res.voiceOf[hoverNote] or 0
		local names = voiceNames(src.name, res)
		ImGui.SetTooltip(ctx, Core.PitchName(notes[hoverNote].pitch) .. "  ->  " .. (v > 0 and names[v] or "dropped"))
	end
end

local function drawVoiceTable(src, res, colors)
	local names = voiceNames(src.name, res)
	local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg | ImGui.TableFlags_SizingFixedFit
	if ImGui.BeginTable(ctx, "voices", 4, flags) then
		ImGui.TableSetupColumn(ctx, "Track", ImGui.TableColumnFlags_WidthStretch)
		ImGui.TableSetupColumn(ctx, "Notes")
		ImGui.TableSetupColumn(ctx, "Range")
		ImGui.TableSetupColumn(ctx, "Average")
		ImGui.TableHeadersRow(ctx)
		for v, vo in ipairs(res.voices) do
			ImGui.TableNextRow(ctx)
			ImGui.TableNextColumn(ctx)
			ImGui.ColorButton(ctx, "##col" .. v, colors[v], ImGui.ColorEditFlags_NoTooltip | ImGui.ColorEditFlags_NoBorder, 12, 12)
			ImGui.SameLine(ctx)
			ImGui.Text(ctx, names[v])
			ImGui.TableNextColumn(ctx)
			ImGui.Text(ctx, tostring(vo.count))
			ImGui.TableNextColumn(ctx)
			ImGui.Text(ctx, Core.PitchName(vo.low) .. " - " .. Core.PitchName(vo.high))
			ImGui.TableNextColumn(ctx)
			ImGui.Text(ctx, Core.PitchName(vo.avg))
		end
		ImGui.EndTable(ctx)
	end
end

local function drawUI()
	refresh()
	local sources = state.sources
	local src = sources[state.srcIndex]
	local res = state.result

	-- Source -----------------------------------------------------------------------------------------------------
	if #sources == 0 then
		ImGui.TextColored(ctx, 0xFFC857FF, "Select one or more MIDI items to split.")
	elseif #sources == 1 then
		ImGui.Text(ctx, ("Source: %s  (%d item%s, %d notes)"):format(
			src.name, #src.items, #src.items == 1 and "" or "s", #src.notes))
	else
		local names = {}
		for i, s in ipairs(sources) do names[i] = ("%s (%d notes)"):format(s.name, #s.notes) end
		local changed, idx = ImGui.Combo(ctx, "Preview track", state.srcIndex - 1, comboItems(names))
		if changed then state.srcIndex = idx + 1 end
		infoMarker(("%d tracks selected. Each one is split on its own; this only picks which one is previewed."):format(#sources))
	end

	-- Algorithm --------------------------------------------------------------------------------------------------
	ImGui.SeparatorText(ctx, "Algorithm")
	combo("Mode", "mode", Core.MODE_NAMES)
	ImGui.PushTextWrapPos(ctx, 0)
	ImGui.TextDisabled(ctx, MODE_HELP[S.mode] or "")
	ImGui.PopTextWrapPos(ctx)

	if S.mode == Core.MODE_TOP_TO_BOTTOM then
		combo("Small chords", "fill", Core.FILL_NAMES,
			"What to do when a chord has fewer notes than there are voices.\n"
			.. "Spread: highest note on the top voice, lowest on the bottom voice, the rest in between.")
	elseif S.mode == Core.MODE_VOICE_LEADING then
		checkbox("Allow voice crossing", "allowCrossing",
			"When off, a voice is discouraged from going above the voice over it (or below the one under it).")
		local changed, v = ImGui.SliderDouble(ctx, "Voice memory", S.memorySec, 0.1, 10, "%.1f s", ImGui.SliderFlags_AlwaysClamp)
		if changed then S.memorySec = v end
		infoMarker("How long a resting voice keeps 'its' last pitch.\n"
			.. "Short: after a rest, voices are re-chosen by register. Long: lines are followed across rests.")
	elseif S.mode == Core.MODE_PITCH_RANGES then
		local changed, txt = ImGui.InputText(ctx, "Split points", S.splitsText)
		if changed then S.splitsText = txt end
		infoMarker("Comma separated note names or MIDI numbers, e.g. 'C4' or 'C3, C5' or '60'.\nMiddle C = C4 = 60.")
		local parsed = Core.ParseSplits(S.splitsText)
		ImGui.TextDisabled(ctx, #parsed > 0 and ("Splits at: " .. Core.FormatSplits(parsed)) or "No valid split point: everything stays on one track.")
	end

	if S.mode ~= Core.MODE_PITCH_RANGES and S.mode ~= Core.MODE_DRUMS then
		checkbox("Automatic voice count", "autoVoices",
			"Uses the maximum number of notes playing at the same time, so no note ever has to share a track.")
		if not S.autoVoices then
			sliderInt("Voices", "voiceCount", 1, 16, "%d")
			combo("Extra notes", "overflow", Core.OVERFLOW_NAMES,
				"When more notes play at once than there are voices. The highest and lowest notes of a chord always keep their voice.")
		end
		checkbox("Order tracks by pitch", "orderByPitch", "Sorts output tracks from the highest to the lowest average pitch.")
	end

	-- Detection --------------------------------------------------------------------------------------------------
	ImGui.SeparatorText(ctx, "Detection")
	sliderInt("Chord tolerance", "chordTolMs", 0, 120, "%d ms",
		"Notes starting within this time count as one chord. Raise it for humanized or strummed MIDI.")
	sliderInt("Overlap tolerance", "overlapTolMs", 0, 250, "%d ms",
		"A note overlapping the next one by less than this doesn't count as an extra voice (legato playing).")

	-- Output -----------------------------------------------------------------------------------------------------
	ImGui.SeparatorText(ctx, "Output")
	combo("CC / pitch bend", "ccMode", CC_MODES, "Controllers, pitch bend, sustain pedal... on the new items.")
	combo("Source", "sourceMode", SOURCE_MODES)
	checkbox("Put voices in a folder", "folder", "The source track becomes the folder parent of the voice tracks.")
	ImGui.SameLine(ctx)
	checkbox("Copy FX chain", "copyFX", "Copies the source track's FX (e.g. the instrument) to every voice track.")

	-- Preview ----------------------------------------------------------------------------------------------------
	ImGui.SeparatorText(ctx, "Preview")
	if src and res then
		local colors = voiceColors(src.track, res)
		local dropped = 0
		for i = 1, #src.notes do if (res.voiceOf[i] or 0) == 0 then dropped = dropped + 1 end end
		ImGui.Text(ctx, ("Max polyphony: %d   Chords: %d   ->  %d track%s"):format(
			res.maxPoly, res.groupCount, res.numVoices, res.numVoices == 1 and "" or "s"))
		if dropped > 0 then
			ImGui.SameLine(ctx)
			ImGui.TextColored(ctx, 0xFF7070FF, ("(%d notes dropped)"):format(dropped))
		end
		drawPreview(src, res, colors)
		drawVoiceTable(src, res, colors)
	else
		ImGui.TextDisabled(ctx, "Nothing to preview.")
	end

	-- Action -----------------------------------------------------------------------------------------------------
	ImGui.Spacing(ctx)
	local canSplit = res and res.numVoices > 0
	ImGui.BeginDisabled(ctx, not canSplit)
	if ImGui.Button(ctx, "Split", 120, 0) then
		local okRun, msg = runSplit()
		state.status, state.statusColor = msg, okRun and 0x9BE29BFF or 0xFF7070FF
	end
	ImGui.EndDisabled(ctx)
	ImGui.SameLine(ctx)
	if ImGui.Button(ctx, "Close", 80, 0) then state.closeAfter = true end
	if state.status then
		ImGui.SameLine(ctx)
		ImGui.TextColored(ctx, state.statusColor, state.status)
	end
end

local function loop()
	ImGui.SetNextWindowSize(ctx, 560, 780, ImGui.Cond_FirstUseEver)
	local visible, open = ImGui.Begin(ctx, SCRIPT_NAME, true, ImGui.WindowFlags_NoCollapse)
	if visible then
		drawUI()
		if ImGui.IsWindowFocused(ctx) and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then state.closeAfter = true end
		ImGui.End(ctx)
	end
	if open and not state.closeAfter then
		reaper.defer(loop)
	end
end

loadSettings()
reaper.atexit(saveSettings)
reaper.defer(loop)
