-- @description juno: MIDI export helper (MIDI and pitched samples to MIDI tracks)
-- @author juno
-- @version 1.0.0
-- @changelog
--   Initial release.
-- @provides
--   [nomain] juno_MIDIExportHelper/lib.lua
-- @about
--   # juno: MIDI Export Helper
--
--   Prepares a project for MIDI export: for every track you tick, it creates MIDI tracks at the top of the
--   project, above a track spacer. The original tracks are never changed (only the spacer is set on the
--   first original track, since REAPER attaches spacers to the track below them).
--
--   - **MIDI tracks**: all MIDI items are merged into one item (from =START to =END if those markers exist).
--     If notes play at the same time, the voices are also split, using juno_SplitVoices' logic, into a folder:
--     the folder track holds the full MIDI, the tracks inside it one voice each. Drum tracks (MIDI channel 10,
--     or "drum"/"kit"/"perc" in the name) are split one track per note instead. The split settings can be
--     changed per track.
--   - **Sample tracks** (audio/video items with pitch applied): one note per item, with the item's length,
--     its pitch (relative to a base note) and a velocity from its volume (quietest = 1, loudest = 127).
--     Pitch envelopes become pitch bend (range +/-12, or more octaves if a slide goes further).
--     Items from different files, or from different parts of the same file, become separate tracks in a
--     folder. You can override this per track.
--
--   Clicking a track in the list selects it in REAPER, and selecting a track in REAPER highlights it in the list.
--   Ticked tracks show a small preview of the notes, coloured by the track they will end up on.
--
--   Tracks made by the script are tagged, so they never show up for export again. Exporting a track again
--   asks whether to replace its earlier export or add new copies.
--
--   Requires ReaImGui (ReaTeam Extensions repository; 0.10 or newer to show non-Latin names, e.g. Japanese)
--   and juno_SplitVoices (this repository).

local SCRIPT_NAME = "juno: MIDI Export Helper"
local EXT_SECTION = "juno_MIDIExportHelper"
local SPLITVOICES_API = 1

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

local okCore, Core = pcall(dofile, SCRIPT_DIR .. "juno_SplitVoices/core.lua")
if not okCore or type(Core) ~= "table" then
	reaper.MB("This script needs juno_SplitVoices (from the same repository) to split voices.\n\n"
		.. "After closing this message ReaPack will open on it: install it and run this script again.", SCRIPT_NAME, 0)
	if reaper.ReaPack_BrowsePackages then reaper.ReaPack_BrowsePackages("juno_SplitVoices") end
	return
end
if (Core.API_VERSION or 0) < SPLITVOICES_API or not Core.MODE_DRUMS then
	reaper.MB("Your juno_SplitVoices is too old for this script.\nPlease update it through ReaPack.", SCRIPT_NAME, 0)
	if reaper.ReaPack_BrowsePackages then reaper.ReaPack_BrowsePackages("juno_SplitVoices") end
	return
end

local L = dofile(SCRIPT_DIR .. "juno_MIDIExportHelper/lib.lua")

-- ReaImGui before 0.10 can only draw U+0020..U+00FF (other characters show as '?').
local REAIMGUI_FULL_UNICODE = (function()
	local _, _, v = ImGui.GetVersion()
	local major, minor = tostring(v or ""):match("^(%d+)%.(%d+)")
	major, minor = tonumber(major) or 0, tonumber(minor) or 0
	return major > 0 or minor >= 10
end)()

local function hasWideChars(s) return s:find("[\xC4-\xF4]") ~= nil end -- UTF-8 lead bytes above U+00FF

-----------------------------------------------------------------------------------------------------------------------
-- Settings: global ones in ExtState, per-track ones in the project
-----------------------------------------------------------------------------------------------------------------------

local DEFAULTS = { baseNote = 60, tolMs = 20, settingsH = 170 } -- settingsH: voice settings panel height (px)
local S = {}

local function loadSettings()
	for k, def in pairs(DEFAULTS) do S[k] = tonumber(reaper.GetExtState(EXT_SECTION, k)) or def end
end

local function saveSettings()
	for k, v in pairs(S) do reaper.SetExtState(EXT_SECTION, k, tostring(v), true) end
end

local function trackSetting(guid, key)
	local _, v = reaper.GetProjExtState(0, EXT_SECTION, guid .. key)
	return v ~= "" and v or nil
end

local function setTrackSetting(guid, key, v)
	reaper.SetProjExtState(0, EXT_SECTION, guid .. key, tostring(v))
end

-- Voice splitter settings (a subset of juno_SplitVoices' options), stored per track as "k=v,k=v".
local SPLIT_KEYS = { "chordTolMs", "overlapTolMs", "voiceCount", "fill", "allowCrossing", "memorySec", "overflow" }

local function defaultSplit()
	local o = {}
	for _, k in ipairs(SPLIT_KEYS) do o[k] = Core.DEFAULTS[k] end
	return o
end

local function parseSplit(str)
	local o = defaultSplit()
	for k, v in tostring(str or ""):gmatch("(%w+)=([^,]+)") do
		if o[k] ~= nil then
			if type(o[k]) == "boolean" then o[k] = v == "true" else o[k] = tonumber(v) or o[k] end
		end
	end
	return o
end

local function serializeSplit(o)
	local parts = {}
	for _, k in ipairs(SPLIT_KEYS) do parts[#parts + 1] = k .. "=" .. tostring(o[k]) end
	return table.concat(parts, ",")
end

-----------------------------------------------------------------------------------------------------------------------
-- State
-----------------------------------------------------------------------------------------------------------------------

local ctx = ImGui.CreateContext(SCRIPT_NAME)
local state = {
	key = nil, rows = {}, range = nil, cache = {}, wide = false,
	reaSel = nil, scrollPending = false,
	status = nil, statusColor = 0x7FD67FFF, closeAfter = false, confirm = nil,
}

local function planRow(row)
	local opts = {
		Core = Core, range = state.range, tol = S.tolMs / 1000, baseNote = S.baseNote,
		midiMode = row.midiMode, sampleMode = row.sampleMode, split = row.split,
	}
	local key = table.concat({ L.ContentKey(row.info), row.midiMode, row.sampleMode, serializeSplit(row.split),
		S.baseNote, S.tolMs, state.range.s, state.range.e }, "|")
	local c = state.cache[row.info.guid]
	if c and c.key == key then
		row.plan, row.err = c.plan, c.err
		return
	end
	local ok, plan = pcall(L.Plan, row.info, opts)
	row.plan, row.err = ok and plan or nil, not ok and tostring(plan) or nil
	state.cache[row.info.guid] = { key = key, plan = row.plan, err = row.err }
end

-- Re-scan when the project or the settings change (unchanged tracks reuse their cached plan).
local function refresh(force)
	local key = ("%d|%d|%g"):format(reaper.GetProjectStateChangeCount(0), S.baseNote, S.tolMs)
	if key == state.key and not force then return end
	state.key = key
	state.range = L.Range()
	state.rows = {}
	state.wide = false
	for _, info in ipairs(L.Scan()) do
		local row = { kind = info.kind, info = info }
		if info.kind == "track" then
			local g = info.guid
			row.selected = trackSetting(g, "_sel") == "1"
			row.midiMode = tonumber(trackSetting(g, "_midi")) or L.MIDI_AUTO
			row.sampleMode = tonumber(trackSetting(g, "_samp")) or L.SAMPLE_AUTO
			row.split = parseSplit(trackSetting(g, "_split"))
			planRow(row)
		end
		if hasWideChars(info.name or "") then state.wide = true end
		state.rows[#state.rows + 1] = row
	end
end

local function exportRows()
	local out = {}
	for _, r in ipairs(state.rows) do
		if r.kind == "track" and r.selected and r.plan then out[#out + 1] = r end
	end
	return out
end

local function runExport(replace)
	local jobs = {}
	for _, r in ipairs(exportRows()) do jobs[#jobs + 1] = { info = r.info, plan = r.plan } end
	local ok, res = pcall(L.Build, jobs, replace, state.range)
	if ok then
		state.status = ("Created %d track%s for %d original track%s."):format(res, res == 1 and "" or "s", #jobs, #jobs == 1 and "" or "s")
		state.statusColor = 0x7FD67FFF
	else
		reaper.PreventUIRefresh(-1)
		reaper.Undo_EndBlock("juno: MIDI export helper (failed)", -1)
		state.status, state.statusColor = "Export failed: " .. tostring(res), 0xFF7070FF
	end
	refresh(true)
end

local function startExport()
	local existing = L.Existing()
	local conflicts = {}
	for _, r in ipairs(exportRows()) do
		local names = existing[r.info.guid]
		if names then conflicts[#conflicts + 1] = { name = r.plan.name, tracks = names } end
	end
	if #conflicts == 0 then
		runExport(false)
	else
		state.confirm = conflicts
		ImGui.OpenPopup(ctx, "Already exported")
	end
end

-----------------------------------------------------------------------------------------------------------------------
-- Drawing helpers
-----------------------------------------------------------------------------------------------------------------------

local function rgba(r, g, b, a) return (r << 24) | (g << 16) | (b << 8) | (a or 255) end

local function rowColor(row, n)
	local c = L.BaseColor(row.info, n)
	return c[1], c[2], c[3]
end

local function help(text)
	ImGui.SameLine(ctx)
	ImGui.TextDisabled(ctx, "(?)")
	if ImGui.IsItemHovered(ctx) and ImGui.BeginTooltip(ctx) then
		ImGui.PushTextWrapPos(ctx, ImGui.GetFontSize(ctx) * 28)
		ImGui.Text(ctx, text)
		ImGui.PopTextWrapPos(ctx)
		ImGui.EndTooltip(ctx)
	end
end

-- Icons, drawn with lines and shapes (so they don't depend on fonts).
local ICON_W, ICON_H = 26, 20

local GLYPHS = {
	voiceLeading = function(dl, x, y, col) -- two melodic lines
		for _, dy in ipairs({ 6, 14 }) do
			ImGui.DrawList_AddLine(dl, x + 4, y + dy, x + 9, y + dy - 3, col, 1.5)
			ImGui.DrawList_AddLine(dl, x + 9, y + dy - 3, x + 15, y + dy + 1, col, 1.5)
			ImGui.DrawList_AddLine(dl, x + 15, y + dy + 1, x + 22, y + dy - 2, col, 1.5)
		end
	end,
	topToBottom = function(dl, x, y, col) -- chord notes going to stacked tracks
		for _, dy in ipairs({ 5, 10, 15 }) do
			ImGui.DrawList_AddCircleFilled(dl, x + 7, y + dy, 2, col)
			ImGui.DrawList_AddLine(dl, x + 11, y + dy, x + 22, y + dy, col, 2)
		end
	end,
	firstAvailable = function(dl, x, y, col) -- tracks filling up
		ImGui.DrawList_AddLine(dl, x + 4, y + 5, x + 22, y + 5, col, 2)
		ImGui.DrawList_AddLine(dl, x + 4, y + 10, x + 16, y + 10, col, 2)
		ImGui.DrawList_AddLine(dl, x + 4, y + 15, x + 10, y + 15, col, 2)
	end,
	drums = function(dl, x, y, col) -- drum pads
		for _, p in ipairs({ { 9, 6 }, { 17, 6 }, { 9, 14 }, { 17, 14 } }) do
			ImGui.DrawList_AddCircleFilled(dl, x + p[1], y + p[2], 3, col)
		end
	end,
	oneTrack = function(dl, x, y, col)
		ImGui.DrawList_AddRectFilled(dl, x + 5, y + 7, x + 21, y + 13, col, 2)
	end,
	perSample = function(dl, x, y, col)
		for _, dy in ipairs({ 3, 8, 13 }) do ImGui.DrawList_AddRectFilled(dl, x + 5, y + dy, x + 21, y + dy + 4, col, 1) end
	end,
}

-- One segment of a segmented control: buttons touch and only the outer corners are rounded. Coloured like
-- normal ImGui buttons; the chosen one uses the "pressed" button colour.
local function iconButton(id, glyph, active, tip, index, count)
	local x, y = ImGui.GetCursorScreenPos(ctx)
	local clicked = ImGui.InvisibleButton(ctx, id, ICON_W, ICON_H)
	local hovered = ImGui.IsItemHovered(ctx)
	local dl = ImGui.GetWindowDrawList(ctx)
	local corners = ImGui.DrawFlags_RoundCornersNone
	if count == 1 then corners = ImGui.DrawFlags_RoundCornersAll
	elseif index == 1 then corners = ImGui.DrawFlags_RoundCornersLeft
	elseif index == count then corners = ImGui.DrawFlags_RoundCornersRight end
	local pressed = ImGui.IsItemActive(ctx)
	local colIdx = (active or pressed) and ImGui.Col_ButtonActive or (hovered and ImGui.Col_ButtonHovered or ImGui.Col_Button)
	ImGui.DrawList_AddRectFilled(dl, x, y, x + ICON_W, y + ICON_H, ImGui.GetStyleColor(ctx, colIdx), 4, corners)
	GLYPHS[glyph](dl, x, y, ImGui.GetStyleColor(ctx, ImGui.Col_Text))
	if hovered then ImGui.SetTooltip(ctx, tip) end
	ImGui.SameLine(ctx, 0, 0)
	return clicked
end

local MIDI_ICONS = {
	{ mode = L.MIDI_SPLIT_VL, glyph = "voiceLeading", tip = "Split voices: Voice leading (follows each melodic line)" },
	{ mode = L.MIDI_SPLIT_TOP, glyph = "topToBottom", tip = "Split voices: Top to bottom (chord notes ranked by pitch)" },
	{ mode = L.MIDI_SPLIT_FIRST, glyph = "firstAvailable", tip = "Split voices: First available (each note on the first free track)" },
	{ mode = L.MIDI_SPLIT_DRUMS, glyph = "drums", tip = "Drums: one track per note (kick, snare, hi-hat...)" },
	{ mode = L.MIDI_NO_SPLIT, glyph = "oneTrack", tip = "Don't split: one track with all the MIDI" },
}

local SAMPLE_ICONS = {
	{ mode = L.SAMPLE_ONE, glyph = "oneTrack", tip = "One track for all the items" },
	{ mode = L.SAMPLE_SPLIT, glyph = "perSample", tip = "One track per sample (per file, or per part of the same file)" },
}

local MODE_NAME = {
	[L.MIDI_SPLIT_VL] = "Voice leading", [L.MIDI_SPLIT_TOP] = "Top to bottom",
	[L.MIDI_SPLIT_FIRST] = "First available", [L.MIDI_SPLIT_DRUMS] = "Drums", [L.MIDI_NO_SPLIT] = "Don't split",
}

-- Mini piano roll of a plan: notes coloured by the output track they end up on.
local ROLL_H = 38

local function drawRoll(row, x0, x1)
	local roll = row.plan and row.plan.roll
	local dl = ImGui.GetWindowDrawList(ctx)
	local _, y0 = ImGui.GetCursorScreenPos(ctx)
	local y1 = y0 + ROLL_H
	ImGui.DrawList_PushClipRect(dl, x0, y0, x1, y1, false)
	ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, 0x1A1A1AFF, 3)
	if roll and #roll.notes > 0 and roll.t1 > roll.t0 then
		local lo, hi = roll.low - 1, roll.high + 1
		local w, h = x1 - x0 - 4, ROLL_H - 4
		local rowH = math.max(1, h / (hi - lo + 1))
		local lanes = math.max(1, roll.lanes)
		local r, g, b = rowColor(row)
		local hBase = ImGui.ColorConvertRGBtoHSV and select(1, ImGui.ColorConvertRGBtoHSV(r / 255, g / 255, b / 255)) or 0
		local cols = {}
		for i, n in ipairs(roll.notes) do
			if i > 6000 then break end
			local lane = n.child or 1
			local col = cols[lane]
			if not col then
				if lanes == 1 then
					col = rgba(r, g, b, 230)
				else
					local hue = (hBase + (lane - 1) / lanes) % 1
					local cr, cg, cb = ImGui.ColorConvertHSVtoRGB(hue, 0.55, 0.95)
					col = ImGui.ColorConvertDouble4ToU32(cr, cg, cb, 0.9)
				end
				cols[lane] = col
			end
			local nx0 = x0 + 2 + (n.t0 - roll.t0) / (roll.t1 - roll.t0) * w
			local nx1 = math.max(nx0 + 1, x0 + 2 + (n.t1 - roll.t0) / (roll.t1 - roll.t0) * w)
			local ny = y0 + 2 + (hi - n.pitch) / (hi - lo + 1) * h
			ImGui.DrawList_AddRectFilled(dl, nx0, ny, nx1, ny + rowH, col)
		end
	else
		ImGui.DrawList_AddText(dl, x0 + 6, y0 + 12, 0x808080FF, "No notes in the export range")
	end
	ImGui.DrawList_PopClipRect(dl)
	ImGui.Dummy(ctx, 1, ROLL_H)
end

-----------------------------------------------------------------------------------------------------------------------
-- Track table
-----------------------------------------------------------------------------------------------------------------------

local function selectInReaper(track)
	reaper.SetOnlyTrackSelected(track)
	reaper.Main_OnCommand(40913, 0) -- Track: Vertical scroll selected tracks into view
	state.reaSel = track
end

local function rowType(info)
	if #info.midi > 0 and #info.samples > 0 then return "MIDI + samples" end
	return #info.midi > 0 and "MIDI" or "Samples"
end

local function drawRow(i, row)
	local info, plan = row.info, row.plan
	local isTrack = row.kind == "track"
	local selectedInReaper = info.track == state.reaSel
	ImGui.TableNextRow(ctx)
	ImGui.PushID(ctx, tostring(i))

	-- tint the row with the track colour
	if info.color then
		local r, g, b = reaper.ColorFromNative(info.color)
		ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_RowBg0, rgba(r, g, b, isTrack and 0x40 or 0x22))
	end

	-- Track name (submitted first so the checkbox, drawn after it, gets the clicks)
	ImGui.TableSetColumnIndex(ctx, 1)
	if selectedInReaper and state.scrollPending then
		ImGui.SetScrollHereY(ctx, 0.3)
		state.scrollPending = false
	end
	-- the row is as tall as its icon buttons (one line per kind of items): the highlight must cover all of it
	local fh = ImGui.GetTextLineHeight(ctx)
	local rowH = fh
	if isTrack then
		local lines = (#info.midi > 0 and 1 or 0) + (#info.samples > 0 and 1 or 0)
		local _, spY = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
		rowH = math.max(fh, lines * ICON_H + (lines - 1) * (spY or 4))
	end
	local x, y = ImGui.GetCursorScreenPos(ctx)
	local indent = 14 * (info.level or 0)
	local r, g, b = rowColor(row, i)
	local dl = ImGui.GetWindowDrawList(ctx)
	local sy = y + (rowH - fh * 0.6) / 2
	ImGui.DrawList_AddRectFilled(dl, x + indent, sy, x + indent + fh * 0.6, sy + fh * 0.6,
		info.color and rgba(r, g, b) or 0x606060FF, 2)
	ImGui.SetCursorScreenPos(ctx, x + indent + fh * 0.6 + 6, y)
	local label = (isTrack and plan and plan.name) or (info.name ~= "" and info.name) or ("Track " .. (info.index + 1))
	if not isTrack then label = label .. "   (folder)"
	elseif info.name == "" then label = label .. "   (unnamed)" end
	if not isTrack then ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x9A9A9AFF) end
	ImGui.PushStyleVar(ctx, ImGui.StyleVar_SelectableTextAlign, 0, 0.5)
	if ImGui.Selectable(ctx, label .. "##name", selectedInReaper,
			ImGui.SelectableFlags_SpanAllColumns | ImGui.SelectableFlags_AllowOverlap, 0, rowH) then
		selectInReaper(info.track)
	end
	ImGui.PopStyleVar(ctx)
	if not isTrack then ImGui.PopStyleColor(ctx) end

	-- Checkbox
	ImGui.TableSetColumnIndex(ctx, 0)
	if isTrack then
		local c, v = ImGui.Checkbox(ctx, "##sel", row.selected)
		if c then row.selected = v; setTrackSetting(info.guid, "_sel", v and 1 or 0) end
	end

	if isTrack then
		ImGui.TableSetColumnIndex(ctx, 2)
		ImGui.Text(ctx, rowType(info))

		ImGui.TableSetColumnIndex(ctx, 3)
		ImGui.Text(ctx, tostring(#info.midi + #info.samples))

		ImGui.TableSetColumnIndex(ctx, 4)
		if not plan then
			ImGui.TextColored(ctx, 0xFF7070FF, "Error")
			if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, row.err or "") end
		else
			local s = plan.summary
			if s.midi then
				ImGui.Text(ctx, (s.samples and "MIDI: " or "") .. s.midi)
				if row.midiMode == L.MIDI_AUTO and s.drumLike then
					ImGui.SameLine(ctx); ImGui.TextDisabled(ctx, "(drums detected)")
				end
			end
			if s.samples then
				ImGui.Text(ctx, (s.midi and "Samples: " or "") .. s.samples)
				if s.bendRange then
					ImGui.SameLine(ctx)
					ImGui.TextDisabled(ctx, ("bend +/-%d"):format(s.bendRange))
				end
			end
		end

		ImGui.TableSetColumnIndex(ctx, 5)
		local changed = false
		if #info.midi > 0 then
			-- Until you pick one, the mode is chosen for you (Drums for drum tracks, else Voice leading)
			local current = plan and plan.summary.midiMode or row.midiMode
			for k, ic in ipairs(MIDI_ICONS) do
				local tip = ic.tip
				if row.midiMode == L.MIDI_AUTO and current == ic.mode then
					tip = tip .. (plan and plan.summary.drumLike and "\n(picked because this looks like a drum track)"
						or "\n(picked automatically)")
				end
				if iconButton("m" .. ic.mode, ic.glyph, current == ic.mode, tip, k, #MIDI_ICONS) then
					row.midiMode = ic.mode; setTrackSetting(info.guid, "_midi", ic.mode); changed = true
				end
			end
			ImGui.NewLine(ctx)
		end
		if #info.samples > 0 then
			-- Until you pick one: one track per sample if there are several samples, else one track
			local current = row.sampleMode
			if current == L.SAMPLE_AUTO then
				current = (plan and plan.summary.autoSplit) and L.SAMPLE_SPLIT or L.SAMPLE_ONE
			end
			for k, ic in ipairs(SAMPLE_ICONS) do
				local tip = ic.tip
				if row.sampleMode == L.SAMPLE_AUTO and current == ic.mode then tip = tip .. "\n(picked automatically)" end
				if iconButton("s" .. ic.mode, ic.glyph, current == ic.mode, tip, k, #SAMPLE_ICONS) then
					row.sampleMode = ic.mode; setTrackSetting(info.guid, "_samp", ic.mode); changed = true
				end
			end
			ImGui.NewLine(ctx)
		end
		if changed then planRow(row) end
	end
	ImGui.PopID(ctx)

	-- Preview under ticked tracks
	if isTrack and row.selected and plan then
		ImGui.TableNextRow(ctx)
		ImGui.TableSetColumnIndex(ctx, 1)
		local rx = ImGui.GetCursorScreenPos(ctx)
		local wx = ImGui.GetWindowPos(ctx)
		drawRoll(row, rx, wx + ImGui.GetWindowWidth(ctx) - 16)
	end
end

local function focusedRow()
	for _, r in ipairs(state.rows) do
		if r.kind == "track" and r.info.track == state.reaSel then return r end
	end
end

-----------------------------------------------------------------------------------------------------------------------
-- Voice settings of the track selected in REAPER
-----------------------------------------------------------------------------------------------------------------------

local function drawVoiceSettings()
	local row = focusedRow()
	if not row then
		ImGui.TextDisabled(ctx, "Select a track (in this list or in REAPER) to see its voice settings.")
		return
	end
	local mode = row.plan and row.plan.summary.midiMode or row.midiMode
	if #row.info.midi == 0 then
		ImGui.TextDisabled(ctx, (row.plan and row.plan.name or row.info.name) .. ": samples only, nothing else to set.")
		return
	end
	ImGui.Text(ctx, (row.plan and row.plan.name or row.info.name) .. ": " .. (MODE_NAME[mode] or ""))
	if mode == L.MIDI_NO_SPLIT or mode == L.MIDI_SPLIT_DRUMS then
		ImGui.SameLine(ctx)
		ImGui.TextDisabled(ctx, mode == L.MIDI_SPLIT_DRUMS and "(one track per note, no settings)" or "(no settings)")
		return
	end

	local o, changed = row.split, false
	local function apply(c, key, v) if c then o[key] = v; changed = true end end
	ImGui.PushItemWidth(ctx, 160)
	local c, v = ImGui.SliderInt(ctx, "Chord tolerance", o.chordTolMs, 0, 120, "%d ms")
	apply(c, "chordTolMs", v)
	help("Notes starting within this time count as one chord. Raise it for humanized or strummed MIDI.")
	ImGui.SameLine(ctx, 0, 24)
	c, v = ImGui.SliderInt(ctx, "Overlap tolerance", o.overlapTolMs, 0, 250, "%d ms")
	apply(c, "overlapTolMs", v)
	help("A note overlapping the next one by less than this doesn't count as an extra voice (legato playing).")

	local auto = o.voiceCount == 0
	c, v = ImGui.Checkbox(ctx, "Automatic voice count", auto)
	if c then o.voiceCount = v and 0 or math.max(1, row.plan and row.plan.summary.voiceCount or 4); changed = true end
	if o.voiceCount > 0 then
		ImGui.SameLine(ctx, 0, 24)
		c, v = ImGui.SliderInt(ctx, "Voices", o.voiceCount, 1, 16)
		apply(c, "voiceCount", v)
		ImGui.SameLine(ctx, 0, 24)
		c, v = ImGui.Combo(ctx, "Extra notes", o.overflow - 1, table.concat(Core.OVERFLOW_NAMES, "\0") .. "\0")
		apply(c, "overflow", v + 1)
	end

	if mode == L.MIDI_SPLIT_TOP then
		c, v = ImGui.Combo(ctx, "Small chords", o.fill - 1, table.concat(Core.FILL_NAMES, "\0") .. "\0")
		apply(c, "fill", v + 1)
	elseif mode == L.MIDI_SPLIT_VL then
		c, v = ImGui.Checkbox(ctx, "Allow voice crossing", o.allowCrossing)
		apply(c, "allowCrossing", v)
		ImGui.SameLine(ctx, 0, 24)
		c, v = ImGui.SliderDouble(ctx, "Voice memory", o.memorySec, 0.1, 10, "%.1f s")
		apply(c, "memorySec", v)
		help("How long a resting voice keeps 'its' last pitch.")
	end
	ImGui.PopItemWidth(ctx)
	if ImGui.Button(ctx, "Reset voice settings") then row.split = defaultSplit(); changed = true end

	if changed then
		setTrackSetting(row.info.guid, "_split", serializeSplit(row.split))
		planRow(row)
	end
end

-----------------------------------------------------------------------------------------------------------------------
-- Window
-----------------------------------------------------------------------------------------------------------------------

local function drawConfirm()
	if not ImGui.BeginPopupModal(ctx, "Already exported", nil, ImGui.WindowFlags_AlwaysAutoResize) then return end
	ImGui.Text(ctx, "These tracks were exported before. Replacing deletes these earlier exported tracks:")
	ImGui.Spacing(ctx)
	for _, c in ipairs(state.confirm or {}) do
		ImGui.Text(ctx, c.name)
		ImGui.Indent(ctx)
		for _, n in ipairs(c.tracks) do ImGui.BulletText(ctx, n) end
		ImGui.Unindent(ctx)
	end
	ImGui.Spacing(ctx)
	ImGui.TextDisabled(ctx, "Original tracks are never touched either way.")
	ImGui.Spacing(ctx)
	if ImGui.Button(ctx, "Replace", 120, 0) then
		ImGui.CloseCurrentPopup(ctx); state.confirm = nil; runExport(true)
	end
	ImGui.SameLine(ctx)
	if ImGui.Button(ctx, "Create new copies", 150, 0) then
		ImGui.CloseCurrentPopup(ctx); state.confirm = nil; runExport(false)
	end
	ImGui.SameLine(ctx)
	if ImGui.Button(ctx, "Cancel", 80, 0) then
		ImGui.CloseCurrentPopup(ctx); state.confirm = nil
	end
	ImGui.EndPopup(ctx)
end

local SETTINGS_MIN, SETTINGS_MAX = 60, 600

-- Horizontal bar between the track list and the voice settings: drag it to resize the settings panel.
local function splitter()
	local w = ImGui.GetContentRegionAvail(ctx) or 1
	local x, y = ImGui.GetCursorScreenPos(ctx)
	ImGui.InvisibleButton(ctx, "##splitter", math.max(1, w), 8)
	local active, hovered = ImGui.IsItemActive(ctx), ImGui.IsItemHovered(ctx)
	if active or hovered then ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_ResizeNS) end
	if active then
		local _, dy = ImGui.GetMouseDelta(ctx)
		S.settingsH = math.max(SETTINGS_MIN, math.min(SETTINGS_MAX, S.settingsH - (dy or 0)))
	end
	local dl = ImGui.GetWindowDrawList(ctx)
	local col = active and 0x3D7DD8FF or (hovered and 0x707070FF or 0x404040FF)
	ImGui.DrawList_AddRectFilled(dl, x + w / 2 - 20, y + 3, x + w / 2 + 20, y + 5, col, 1)
end

local function drawUI()
	refresh()
	local sel = reaper.GetSelectedTrack(0, 0)
	if sel ~= state.reaSel then state.reaSel = sel; state.scrollPending = true end

	-- Range and global settings
	local r = state.range
	ImGui.Text(ctx, ("Export range: %s %s  ->  %s %s"):format(
		r.hasStart and "=START" or "project start", L.FormatTime(r.s),
		r.hasEnd and "=END" or "project end", L.FormatTime(r.e)))
	help("Add markers named =START and =END to export only part of the project.")

	ImGui.SetNextItemWidth(ctx, 110)
	local cb, base = ImGui.InputInt(ctx, "Base note", S.baseNote)
	if cb then S.baseNote = math.max(0, math.min(127, base)) end
	ImGui.SameLine(ctx)
	ImGui.TextDisabled(ctx, Core.PitchName(S.baseNote))
	help("The note an unpitched sample item gets. An item pitched +3 semitones gets the base note + 3.")
	ImGui.SameLine(ctx, 0, 30)
	ImGui.SetNextItemWidth(ctx, 90)
	local ct, tol = ImGui.InputInt(ctx, "Same sample tolerance (ms)", S.tolMs, 5, 20)
	if ct then S.tolMs = math.max(0, tol) end
	help("Items from the same file count as the same sample if they start within this time of each other "
		.. "inside the file. Further apart, they are treated as different samples (separate tracks).")

	if state.wide and not REAIMGUI_FULL_UNICODE then
		ImGui.TextColored(ctx, 0xFFC857FF, "Some names use characters this ReaImGui version can't draw (shown as ?). "
			.. "Update ReaImGui to 0.10 or newer through ReaPack.")
	end

	-- Track list
	ImGui.SeparatorText(ctx, "Tracks")
	local nTracks = 0
	for _, row in ipairs(state.rows) do if row.kind == "track" then nTracks = nTracks + 1 end end
	if nTracks == 0 then
		ImGui.TextColored(ctx, 0xFFC857FF, "No tracks with MIDI or sample items.")
	else
		if ImGui.Button(ctx, "Select all") then
			for _, row in ipairs(state.rows) do
				if row.kind == "track" then row.selected = true; setTrackSetting(row.info.guid, "_sel", 1) end
			end
		end
		ImGui.SameLine(ctx)
		if ImGui.Button(ctx, "Select none") then
			for _, row in ipairs(state.rows) do
				if row.kind == "track" then row.selected = false; setTrackSetting(row.info.guid, "_sel", 0) end
			end
		end

		local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerH | ImGui.TableFlags_ScrollY
			| ImGui.TableFlags_SizingFixedFit
		-- leave room for: splitter, "Voice settings" title, the settings panel, the buttons
		local h = -(S.settingsH + 12 + ImGui.GetFrameHeightWithSpacing(ctx) * 2.5)
		if ImGui.BeginTable(ctx, "tracks", 6, flags, 0, h) then
			ImGui.TableSetupScrollFreeze(ctx, 0, 1)
			ImGui.TableSetupColumn(ctx, "")
			ImGui.TableSetupColumn(ctx, "Track", ImGui.TableColumnFlags_WidthStretch)
			ImGui.TableSetupColumn(ctx, "Type")
			ImGui.TableSetupColumn(ctx, "Items")
			ImGui.TableSetupColumn(ctx, "Will create")
			ImGui.TableSetupColumn(ctx, "Split")
			ImGui.TableHeadersRow(ctx)
			for i, row in ipairs(state.rows) do drawRow(i, row) end
			ImGui.EndTable(ctx)
		end
	end

	-- Voice settings for the track selected in REAPER
	splitter()
	ImGui.SeparatorText(ctx, "Voice settings")
	if ImGui.BeginChild(ctx, "voice", 0, S.settingsH) then
		drawVoiceSettings()
		ImGui.EndChild(ctx)
	end

	-- Actions
	local n = #exportRows()
	ImGui.BeginDisabled(ctx, n == 0)
	if ImGui.Button(ctx, ("Export (%d)"):format(n), 120, 0) then startExport() end
	ImGui.EndDisabled(ctx)
	ImGui.SameLine(ctx)
	if ImGui.Button(ctx, "Close", 80, 0) then state.closeAfter = true end
	if state.status then
		ImGui.SameLine(ctx)
		ImGui.TextColored(ctx, state.statusColor, state.status)
	end

	drawConfirm()
end

local function loop()
	ImGui.SetNextWindowSize(ctx, 1000, 620, ImGui.Cond_FirstUseEver)
	local visible, open = ImGui.Begin(ctx, SCRIPT_NAME, true, ImGui.WindowFlags_NoCollapse)
	if visible then
		drawUI()
		if ImGui.IsWindowFocused(ctx) and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) and not state.confirm then
			state.closeAfter = true
		end
		ImGui.End(ctx)
	end
	if open and not state.closeAfter then reaper.defer(loop) end
end

loadSettings()
reaper.atexit(saveSettings)
reaper.defer(loop)
