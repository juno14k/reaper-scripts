-- @description juno: Extend notes to the next note
-- @author juno
-- @version 1.0.0
-- @changelog
--   Initial release.
-- @provides
--   [main=main,midi_editor] .
--   [nomain] juno_ExtendNotes/core.lua
-- @about
--   # juno: Extend Notes
--
--   Extends every note so it ends where the next note starts (legato).
--
--   Run it from the MIDI editor to work on the take being edited, or from the arrange view to
--   work on the selected MIDI items. Only the selected notes are changed (all notes if none is
--   selected).
--
--   - The next note can be the next note of any pitch, of the same pitch or of the same channel.
--   - Notes that already overlap the next note can be trimmed or kept.
--   - An optional gap (ms, ticks or % of the distance) leaves some space before the next note.
--   - The last notes can be left alone or extended to the item end.
--
--   Requires ReaImGui (ReaTeam Extensions repository).

local SCRIPT_NAME = "juno: Extend Notes"
local EXT_SECTION = "juno_ExtendNotes"

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
local Core = dofile(SCRIPT_DIR .. "juno_ExtendNotes/core.lua")

-----------------------------------------------------------------------------------------------------------------------
-- Settings
-----------------------------------------------------------------------------------------------------------------------

local SCOPES    = { "Selected notes (all if none is selected)", "All notes" }
local NEXTS     = { "Next note of any pitch (legato)", "Next note of the same pitch", "Next note on the same channel" }
local OVERLAPS  = { "Trim them to the next note", "Keep them (only lengthen notes)" }
local GAP_UNITS = { "ms", "ticks", "% of the distance" }
local LASTS     = { "Leave as they are", "Extend to the item end" }

local GAP_MS, GAP_TICKS, GAP_PERCENT = 1, 2, 3

local DEFAULTS = {
	scope = 1, countUnselected = true, next = Core.NEXT_ANY, tolMs = 10,
	overlap = Core.OVERLAP_TRIM, gap = 0, gapUnit = GAP_MS, last = Core.LAST_LEAVE,
}
local S = {}

local function loadSettings()
	for k, def in pairs(DEFAULTS) do
		local v = reaper.GetExtState(EXT_SECTION, k)
		if v == "" then S[k] = def
		elseif type(def) == "boolean" then S[k] = v == "1"
		else S[k] = tonumber(v) or def end
	end
end

local function saveSettings()
	for k, v in pairs(S) do
		reaper.SetExtState(EXT_SECTION, k, type(v) == "boolean" and (v and "1" or "0") or tostring(v), true)
	end
end

-----------------------------------------------------------------------------------------------------------------------
-- REAPER glue
-----------------------------------------------------------------------------------------------------------------------

-- The take open in the MIDI editor, or else the active MIDI takes of the selected items.
local function getTakes()
	local editor = reaper.MIDIEditor_GetActive()
	local take = editor and reaper.MIDIEditor_GetTake(editor)
	if take and reaper.ValidatePtr2(0, take, "MediaItem_Take*") then
		return { take }, "MIDI editor: " .. reaper.GetTakeName(take)
	end
	local takes = {}
	for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
		local tk = reaper.GetActiveTake(reaper.GetSelectedMediaItem(0, i))
		if tk and reaper.TakeIsMIDI(tk) then takes[#takes + 1] = tk end
	end
	return takes, ("%d selected MIDI item%s"):format(#takes, #takes == 1 and "" or "s")
end

local function readNotes(take)
	local notes = {}
	local _, count = reaper.MIDI_CountEvts(take)
	for i = 0, count - 1 do
		local _, sel, _, sp, ep, chan, pitch = reaper.MIDI_GetNote(take, i)
		notes[#notes + 1] = { idx = i, start = sp, finish = ep, pitch = pitch, chan = chan, sel = sel }
	end
	return notes
end

local function computeTake(take)
	local item = reaper.GetMediaItemTake_Item(take)
	local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
	local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
	local function tick(t) return reaper.MIDI_GetPPQPosFromProjTime(take, t) end
	local function time(p) return reaper.MIDI_GetProjTimeFromPPQPos(take, p) end

	local gap = math.max(0, S.gap)
	local endBefore
	if gap > 0 then
		if S.gapUnit == GAP_MS then
			endBefore = function(_, onset) return tick(time(onset) - gap / 1000) end
		elseif S.gapUnit == GAP_TICKS then
			endBefore = function(_, onset) return onset - gap end
		else
			local f = 1 - math.min(gap, 100) / 100
			endBefore = function(n, onset) return n.start + (onset - n.start) * f end
		end
	end

	local notes = readNotes(take)
	local newEnd, stats = Core.Compute(notes, {
		selectionOnly = S.scope == 1, countUnselected = S.countUnselected, next = S.next,
		tol = math.max(0, tick(pos + math.max(0, S.tolMs) / 1000) - tick(pos)),
		overlap = S.overlap, endBefore = endBefore, lastMode = S.last, itemEnd = tick(pos + len), minLen = 1,
	})
	return notes, newEnd, stats
end

local function apply(takes)
	reaper.Undo_BeginBlock2(0)
	reaper.PreventUIRefresh(1)
	local changed = 0
	for _, take in ipairs(takes) do
		local notes, newEnd = computeTake(take)
		local any = false
		for i, e in pairs(newEnd) do
			reaper.MIDI_SetNote(take, notes[i].idx, nil, nil, nil, e, nil, nil, nil, true)
			changed, any = changed + 1, true
		end
		if any then
			reaper.MIDI_Sort(take)
			local item = reaper.GetMediaItemTake_Item(take)
			reaper.MarkTrackItemsDirty(reaper.GetMediaItem_Track(item), item)
		end
	end
	reaper.PreventUIRefresh(-1)
	reaper.UpdateArrange()
	reaper.Undo_EndBlock2(0, "juno: Extend notes", -1)
	return changed
end

-----------------------------------------------------------------------------------------------------------------------
-- UI
-----------------------------------------------------------------------------------------------------------------------

local ctx = ImGui.CreateContext(SCRIPT_NAME)
local state = { key = nil, takes = {}, label = "", stats = nil, status = nil, closeAfter = false }

local function comboItems(list) return table.concat(list, "\0") .. "\0" end

local function combo(label, key, list)
	local changed, idx = ImGui.Combo(ctx, label, S[key] - 1, comboItems(list))
	if changed then S[key] = idx + 1 end
end

local function help(text)
	ImGui.SameLine(ctx)
	ImGui.TextDisabled(ctx, "(?)")
	if ImGui.IsItemHovered(ctx) and ImGui.BeginTooltip(ctx) then
		ImGui.PushTextWrapPos(ctx, ImGui.GetFontSize(ctx) * 25)
		ImGui.Text(ctx, text)
		ImGui.PopTextWrapPos(ctx)
		ImGui.EndTooltip(ctx)
	end
end

-- Recompute the preview only when the project, the takes or the settings change.
local function refresh()
	local takes, label = getTakes()
	local parts = { reaper.GetProjectStateChangeCount(0) }
	for _, tk in ipairs(takes) do
		parts[#parts + 1] = tostring(tk)
		parts[#parts + 1] = select(2, reaper.MIDI_GetHash(tk, true, ""))
	end
	for k, v in pairs(S) do parts[#parts + 1] = k .. "=" .. tostring(v) end
	table.sort(parts, function(a, b) return tostring(a) < tostring(b) end)
	local key = table.concat(parts, "|")
	if key == state.key then return end
	state.key, state.takes, state.label = key, takes, label
	local total = { processed = 0, longer = 0, shorter = 0, unchanged = 0 }
	for _, tk in ipairs(takes) do
		local _, _, st = computeTake(tk)
		for k, v in pairs(st) do total[k] = total[k] + v end
	end
	state.stats = total
end

local function drawUI()
	refresh()
	if #state.takes == 0 then
		ImGui.TextColored(ctx, 0xFFC857FF, "Open a MIDI editor or select MIDI items.")
	else
		ImGui.Text(ctx, state.label)
	end

	ImGui.SetNextItemWidth(ctx, 270)
	combo("Notes to extend", "scope", SCOPES)
	ImGui.BeginDisabled(ctx, S.scope ~= 1)
	local _, cu = ImGui.Checkbox(ctx, "Unselected notes count as the next note", S.countUnselected)
	S.countUnselected = cu
	ImGui.EndDisabled(ctx)
	help("On: a selected note extends up to the next note, selected or not.\n"
		.. "Off: only the other selected notes count, so unselected notes are ignored.")

	ImGui.SetNextItemWidth(ctx, 270)
	combo("Extend up to", "next", NEXTS)
	ImGui.SetNextItemWidth(ctx, 120)
	local _, tol = ImGui.InputDouble(ctx, "Chord tolerance (ms)", S.tolMs, 1, 10, "%.0f")
	S.tolMs = math.max(0, tol)
	help("Notes starting within this time of each other count as one chord, so a slightly early "
		.. "chord note doesn't stretch the others only up to itself.")

	ImGui.SeparatorText(ctx, "Overlapping notes")
	ImGui.SetNextItemWidth(ctx, 270)
	combo("Notes past the next note", "overlap", OVERLAPS)

	ImGui.SeparatorText(ctx, "Gap before the next note")
	ImGui.SetNextItemWidth(ctx, 120)
	local _, gap = ImGui.InputDouble(ctx, "##gap", S.gap, 1, 10, "%.1f")
	S.gap = math.max(0, gap)
	ImGui.SameLine(ctx)
	ImGui.SetNextItemWidth(ctx, 160)
	combo("##gapunit", "gapUnit", GAP_UNITS)
	help("0 = notes end exactly where the next note starts.")

	ImGui.SeparatorText(ctx, "Last notes (no next note)")
	ImGui.SetNextItemWidth(ctx, 270)
	combo("Last notes", "last", LASTS)

	ImGui.Separator(ctx)
	local st = state.stats
	if st and st.processed > 0 then
		ImGui.Text(ctx, ("%d notes: %d longer, %d shorter, %d unchanged"):format(
			st.processed, st.longer, st.shorter, st.unchanged))
	else
		ImGui.TextDisabled(ctx, "No notes to extend.")
	end

	ImGui.BeginDisabled(ctx, not st or st.longer + st.shorter == 0)
	if ImGui.Button(ctx, "Extend", 120, 0) then
		local n = apply(state.takes)
		state.status = ("Changed %d note%s."):format(n, n == 1 and "" or "s")
		state.key = nil
	end
	ImGui.EndDisabled(ctx)
	ImGui.SameLine(ctx)
	if ImGui.Button(ctx, "Close", 80, 0) then state.closeAfter = true end
	if state.status then
		ImGui.SameLine(ctx)
		ImGui.TextColored(ctx, 0x7FD67FFF, state.status)
	end
end

local function loop()
	ImGui.SetNextWindowSize(ctx, 470, 0, ImGui.Cond_FirstUseEver)
	local visible, open = ImGui.Begin(ctx, SCRIPT_NAME, true,
		ImGui.WindowFlags_NoCollapse | ImGui.WindowFlags_AlwaysAutoResize)
	if visible then
		drawUI()
		if ImGui.IsWindowFocused(ctx) and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then state.closeAfter = true end
		ImGui.End(ctx)
	end
	if open and not state.closeAfter then reaper.defer(loop) end
end

loadSettings()
reaper.atexit(saveSettings)
reaper.defer(loop)
