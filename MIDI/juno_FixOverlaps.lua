-- @description juno: Fix overlapping, duplicate and short MIDI notes
-- @author juno
-- @version 1.0.0
-- @changelog
--   Initial release.
-- @provides
--   [main=main,midi_editor] .
--   [nomain] juno_FixOverlaps/core.lua
-- @about
--   # juno: Fix Overlaps
--
--   Cleans up MIDI, for example after importing or recording it.
--
--   Run it from the MIDI editor to work on the take being edited, or from the arrange view to
--   work on the selected MIDI items. Only the selected notes are checked (all notes if none is selected).
--
--   - **Duplicates**: notes of the same pitch starting at (almost) the same time. The longest one is kept.
--   - **Short notes**: notes shorter than a given length, including zero-length notes.
--   - **Same-pitch overlaps**: the earlier note is trimmed to where the next one starts, or both are merged
--     into one long note.
--   - **Monophonic overlaps** (optional): trims overlaps between different pitches too, for mono lines.
--
--   Shows what it found before changing anything, and can select the affected notes so you can look at them.
--
--   Requires ReaImGui (ReaTeam Extensions repository).

local SCRIPT_NAME = "juno: Fix Overlaps"
local EXT_SECTION = "juno_FixOverlaps"

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
local Core = dofile(SCRIPT_DIR .. "juno_FixOverlaps/core.lua")

-----------------------------------------------------------------------------------------------------------------------
-- Settings
-----------------------------------------------------------------------------------------------------------------------

local SETTINGS_VERSION = "1" -- bump when defaults change, so stale saved settings are ignored

local SCOPES        = { "Selected notes (all if none is selected)", "All notes" }
local OVERLAP_MODES = { "Trim the earlier note", "Merge them into one note" }

local DEFAULTS = {
	scope = 1, separateChans = true,
	dupes = true, dupTolMs = 10,
	overlaps = true, overlapMode = Core.OVERLAP_TRIM,
	short = false, minLenMs = 20,
	mono = false,
}
local S = {}

local function loadSettings()
	local current = reaper.GetExtState(EXT_SECTION, "_version") == SETTINGS_VERSION
	for k, def in pairs(DEFAULTS) do
		local v = current and reaper.GetExtState(EXT_SECTION, k) or ""
		if v == "" then S[k] = def
		elseif type(def) == "boolean" then S[k] = v == "1"
		else S[k] = tonumber(v) or def end
	end
end

local function saveSettings()
	reaper.SetExtState(EXT_SECTION, "_version", SETTINGS_VERSION, true)
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

local function analyse(take)
	local notes = {}
	local _, count = reaper.MIDI_CountEvts(take)
	for i = 0, count - 1 do
		local _, sel, _, sp, ep, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
		notes[#notes + 1] = { idx = i, start = sp, finish = ep, pitch = pitch, chan = chan, sel = sel, vel = vel }
	end
	local item = reaper.GetMediaItemTake_Item(take)
	local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
	local function ticks(ms) -- length in ticks of `ms` at the item start
		return reaper.MIDI_GetPPQPosFromProjTime(take, pos + ms / 1000) - reaper.MIDI_GetPPQPosFromProjTime(take, pos)
	end
	local delete, newEnd, kind, stats, involved = Core.Fix(notes, {
		selectionOnly = S.scope == 1, separateChans = S.separateChans,
		dupes = S.dupes, dupTol = ticks(math.max(0, S.dupTolMs)),
		short = S.short, minLen = ticks(math.max(0, S.minLenMs)),
		overlaps = S.overlaps, overlapMode = S.overlapMode,
		mono = S.mono,
	})
	return notes, delete, newEnd, stats, involved
end

local function finishEdit(take)
	reaper.MIDI_Sort(take)
	local item = reaper.GetMediaItemTake_Item(take)
	reaper.MarkTrackItemsDirty(reaper.GetMediaItem_Track(item), item)
end

local function fix(takes)
	reaper.Undo_BeginBlock2(0)
	reaper.PreventUIRefresh(1)
	local changed = 0
	for _, take in ipairs(takes) do
		local notes, delete, newEnd = analyse(take)
		local dels = {}
		for i in pairs(delete) do dels[#dels + 1] = notes[i].idx end
		for i, e in pairs(newEnd) do
			reaper.MIDI_SetNote(take, notes[i].idx, nil, nil, nil, e, nil, nil, nil, true)
			changed = changed + 1
		end
		table.sort(dels, function(a, b) return a > b end) -- delete from the end so indices stay valid
		for _, idx in ipairs(dels) do reaper.MIDI_DeleteNote(take, idx) end
		changed = changed + #dels
		if #dels > 0 or next(newEnd) then finishEdit(take) end
	end
	reaper.PreventUIRefresh(-1)
	reaper.UpdateArrange()
	reaper.Undo_EndBlock2(0, "juno: Fix overlaps", -1)
	return changed
end

-- Selects exactly the notes in a conflict, both the one that changes and its partner (deselects the rest).
local function selectAffected(takes)
	reaper.Undo_BeginBlock2(0)
	local count = 0
	for _, take in ipairs(takes) do
		local notes, _, _, _, involved = analyse(take)
		for i, n in ipairs(notes) do
			local hit = involved[i] == true
			if hit then count = count + 1 end
			if hit ~= n.sel then reaper.MIDI_SetNote(take, n.idx, hit, nil, nil, nil, nil, nil, nil, true) end
		end
		finishEdit(take)
	end
	reaper.UpdateArrange()
	reaper.Undo_EndBlock2(0, "juno: Select overlapping notes", -1)
	return count
end

-----------------------------------------------------------------------------------------------------------------------
-- UI
-----------------------------------------------------------------------------------------------------------------------

local ctx = ImGui.CreateContext(SCRIPT_NAME)
local state = { key = nil, takes = {}, label = "", stats = nil, status = nil, closeAfter = false }

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

local function combo(label, key, list)
	local changed, idx = ImGui.Combo(ctx, label, S[key] - 1, table.concat(list, "\0") .. "\0")
	if changed then S[key] = idx + 1 end
end

local function checkbox(label, key)
	local _, v = ImGui.Checkbox(ctx, label, S[key])
	S[key] = v
end

local function msInput(label, key)
	ImGui.SameLine(ctx)
	ImGui.SetNextItemWidth(ctx, 90)
	local _, v = ImGui.InputDouble(ctx, label, S[key], 1, 10, "%.0f")
	S[key] = math.max(0, v)
end

local function count(n, what)
	return n > 0 and ("%d %s"):format(n, what) or nil
end

-- Recompute only when the project, the notes or the settings change.
local function refresh()
	local takes, label = getTakes()
	local parts = { tostring(reaper.GetProjectStateChangeCount(0)) }
	for _, tk in ipairs(takes) do
		parts[#parts + 1] = tostring(tk)
		parts[#parts + 1] = select(2, reaper.MIDI_GetHash(tk, true, ""))
	end
	local keys = {}
	for k in pairs(S) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(S[k]) end
	local key = table.concat(parts, "|")
	if key == state.key then return end
	state.key, state.takes, state.label = key, takes, label
	local total = { notes = 0, duplicate = 0, short = 0, overlap = 0, merged = 0, mono = 0 }
	for _, tk in ipairs(takes) do
		local st = select(4, analyse(tk))
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
	combo("Notes to check", "scope", SCOPES)
	checkbox("Treat MIDI channels separately", "separateChans")
	help("On: notes on different channels never count as duplicates or overlaps of each other.")

	ImGui.SeparatorText(ctx, "Fixes")
	checkbox("Remove duplicates", "dupes")
	help("Notes of the same pitch starting within this time of each other. The longest one is kept "
		.. "(the loudest if they are equally long).")
	ImGui.BeginDisabled(ctx, not S.dupes)
	msInput("ms##dup", "dupTolMs")
	ImGui.EndDisabled(ctx)

	checkbox("Fix same-pitch overlaps", "overlaps")
	help("A note that is still playing when the next note of the same pitch starts.")
	ImGui.BeginDisabled(ctx, not S.overlaps)
	ImGui.SameLine(ctx)
	ImGui.SetNextItemWidth(ctx, 200)
	combo("##overlapMode", "overlapMode", OVERLAP_MODES)
	ImGui.EndDisabled(ctx)

	checkbox("Remove notes shorter than", "short")
	help("Also removes zero-length notes.")
	ImGui.BeginDisabled(ctx, not S.short)
	msInput("ms##short", "minLenMs")
	ImGui.EndDisabled(ctx)

	checkbox("Trim overlaps between different pitches (monophonic)", "mono")
	help("For mono lines (bass, lead, a single voice): each note ends where the next note starts, "
		.. "whatever its pitch. Notes starting together (chords) are left alone.")

	ImGui.SeparatorText(ctx, "Found")
	local st = state.stats
	local found = 0
	if st then
		local list = {}
		-- count() returns nil for zero, so collect explicitly (ipairs would stop at the first nil)
		for _, pair in ipairs({
			{ st.duplicate, "duplicates" }, { st.short, "short notes" },
			{ st.overlap, "same-pitch overlaps" }, { st.merged, "notes to merge" },
			{ st.mono, "monophonic overlaps" },
		}) do
			local c = count(pair[1], pair[2])
			if c then list[#list + 1] = c end
		end
		found = st.duplicate + st.short + st.overlap + st.merged + st.mono
		if #list > 0 then
			ImGui.Text(ctx, ("In %d notes:"):format(st.notes))
			for _, c in ipairs(list) do ImGui.BulletText(ctx, c) end
		elseif st.notes > 0 then
			ImGui.TextColored(ctx, 0x7FD67FFF, ("%d notes checked: nothing to fix."):format(st.notes))
		else
			ImGui.TextDisabled(ctx, "No notes to check.")
		end
	end

	ImGui.Spacing(ctx)
	ImGui.BeginDisabled(ctx, found == 0)
	if ImGui.Button(ctx, "Fix", 100, 0) then
		local n = fix(state.takes)
		state.status = ("Fixed %d note%s."):format(n, n == 1 and "" or "s")
		state.key = nil
	end
	ImGui.SameLine(ctx)
	if ImGui.Button(ctx, "Select affected notes", 170, 0) then
		local n = selectAffected(state.takes)
		state.status = ("Selected %d note%s."):format(n, n == 1 and "" or "s")
		state.key = nil
	end
	ImGui.EndDisabled(ctx)
	help("Selects only the notes involved in a problem (the ones Fix would change and the notes they clash with), so you can look at them first.\n"
		.. "With \"Selected notes\" as the scope, the next check then covers just those notes.")
	ImGui.SameLine(ctx)
	if ImGui.Button(ctx, "Close", 80, 0) then state.closeAfter = true end
	if state.status then ImGui.TextColored(ctx, 0x7FD67FFF, state.status) end
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
