-- @description juno: Extend notes or items to the next one
-- @author juno
-- @version 1.1.0
-- @changelog
--   - Works on audio/video items too: run it with items selected in the arrange view to extend each item
--     to the next item on its track. MIDI items always have their notes extended, never the items.
-- @provides
--   [main=main,midi_editor] .
--   [nomain] juno_ExtendNotes/core.lua
-- @about
--   # juno: Extend Notes
--
--   Extends every note so it ends where the next note starts (legato), or every item so it ends where the
--   next item on its track starts.
--
--   What it works on follows what you have in REAPER:
--   - the MIDI editor (or selected MIDI items): their notes. Only the selected notes are changed (all notes if
--     none is selected);
--   - selected audio/video items: the items themselves, each up to the next item on the same track (and lane).
--   MIDI items are never extended as items.
--
--   - The next note can be the next note of any pitch, of the same pitch or of the same channel; the next item
--     can be the next item on the track or the next item from the same source file.
--   - Notes or items that already overlap the next one can be trimmed or kept.
--   - An optional gap (ms, ticks or % of the distance) leaves some space before the next one.
--   - The last notes can be left alone or extended to the item end. The last item on a track is left alone.
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

local SCOPES     = { "Selected notes (all if none is selected)", "All notes" }
local NEXTS      = { "Next note of any pitch (legato)", "Next note of the same pitch", "Next note on the same channel" }
local ITEM_NEXTS = { "Next item on the track", "Next item from the same source file" }
local OVERLAPS   = { "Trim them to the next one", "Keep them (only lengthen)" }
local GAP_UNITS  = { "ms", "ticks", "% of the distance" }
local LASTS      = { "Leave as they are", "Extend to the item end" }

local GAP_MS, GAP_TICKS, GAP_PERCENT = 1, 2, 3
local ITEM_NEXT_ANY, ITEM_NEXT_SOURCE = 1, 2

local DEFAULTS = {
	scope = 1, countUnselected = true, next = Core.NEXT_ANY, tolMs = 10,
	overlap = Core.OVERLAP_TRIM, gap = 0, gapUnit = GAP_MS, last = Core.LAST_LEAVE,
	itemNext = ITEM_NEXT_ANY,
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
-- What to work on
-----------------------------------------------------------------------------------------------------------------------

local function plural(n, word) return ("%d %s%s"):format(n, word, n == 1 and "" or "s") end

-- Follows what you have in REAPER:
--   * the MIDI editor's take, when no item is selected or its own item is selected -> its notes;
--   * otherwise the selected items: MIDI items -> their notes, audio/video items -> the items themselves.
-- MIDI items are never treated as items.
local function getTargets()
	local editor = reaper.MIDIEditor_GetActive()
	local edTake = editor and reaper.MIDIEditor_GetTake(editor)
	if edTake and not reaper.ValidatePtr2(0, edTake, "MediaItem_Take*") then edTake = nil end

	local takes, items, edSelected = {}, {}, false
	local nSel = reaper.CountSelectedMediaItems(0)
	for i = 0, nSel - 1 do
		local item = reaper.GetSelectedMediaItem(0, i)
		local take = reaper.GetActiveTake(item)
		if take then
			if reaper.TakeIsMIDI(take) then
				takes[#takes + 1] = take
				if take == edTake then edSelected = true end
			else
				items[#items + 1] = item
			end
		end
	end
	if edTake and (nSel == 0 or edSelected) then
		return { takes = { edTake }, items = {}, label = "MIDI editor: " .. reaper.GetTakeName(edTake) }
	end
	local parts = {}
	if #takes > 0 then parts[#parts + 1] = "notes in " .. plural(#takes, "MIDI item") end
	if #items > 0 then parts[#parts + 1] = plural(#items, "audio/video item") end
	local label = table.concat(parts, " + ")
	return { takes = takes, items = items, label = label:sub(1, 1):upper() .. label:sub(2) }
end

-----------------------------------------------------------------------------------------------------------------------
-- Notes
-----------------------------------------------------------------------------------------------------------------------

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

-----------------------------------------------------------------------------------------------------------------------
-- Items: each track (and fixed lane) is like one pitch of notes. Times are in microseconds, so the core's
-- whole-number rounding stays precise.
-----------------------------------------------------------------------------------------------------------------------

local US = 1e6
local TICKS_PER_QN = 960 -- for a gap in ticks

local function sourceFile(take)
	local src = reaper.GetMediaItemTake_Source(take)
	while true do
		local parent = reaper.GetMediaSourceParent(src)
		if not parent then break end
		src = parent
	end
	return reaper.GetMediaSourceFileName(src, "")
end

-- Groups (track + lane) holding the selected items. Each group lists every audio/video item on that track and
-- lane (MIDI items are left out), as core "notes": { item, start, finish (us), pitch (source id), chan, sel }.
local function itemGroups(items)
	local selected, groups, order = {}, {}, {}
	for _, item in ipairs(items) do
		selected[item] = true
		local track = reaper.GetMediaItem_Track(item)
		local lane = reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE") or 0
		local key = tostring(track) .. "|" .. lane
		if not groups[key] then groups[key] = { track = track, lane = lane }; order[#order + 1] = key end
	end
	local sourceIds, nextId = {}, 0
	local out = {}
	for _, key in ipairs(order) do
		local g = groups[key]
		local list = {}
		for i = 0, reaper.CountTrackMediaItems(g.track) - 1 do
			local item = reaper.GetTrackMediaItem(g.track, i)
			local take = reaper.GetActiveTake(item)
			if take and not reaper.TakeIsMIDI(take) and (reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE") or 0) == g.lane then
				local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
				local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
				local file = sourceFile(take)
				if not sourceIds[file] then nextId = nextId + 1; sourceIds[file] = nextId end
				list[#list + 1] = {
					item = item, pos = pos, start = math.floor(pos * US + 0.5), finish = math.floor((pos + len) * US + 0.5),
					pitch = S.itemNext == ITEM_NEXT_SOURCE and sourceIds[file] or 0, chan = 0, sel = selected[item] == true,
				}
			end
		end
		out[#out + 1] = list
	end
	return out
end

local function computeItems(items)
	local gap = math.max(0, S.gap)
	local endBefore
	if gap > 0 then
		if S.gapUnit == GAP_MS then
			endBefore = function(_, onset) return onset - gap * 1000 end
		elseif S.gapUnit == GAP_TICKS then -- ticks of a quarter note at 960 per quarter, following the tempo map
			endBefore = function(_, onset)
				local qn = reaper.TimeMap2_timeToQN(0, onset / US)
				return reaper.TimeMap2_QNToTime(0, qn - gap / TICKS_PER_QN) * US
			end
		else
			local f = 1 - math.min(gap, 100) / 100
			endBefore = function(n, onset) return n.start + (onset - n.start) * f end
		end
	end
	local changes = {} -- { item, pos, newEnd (us) }
	local total = { processed = 0, longer = 0, shorter = 0, unchanged = 0 }
	for _, list in ipairs(itemGroups(items)) do
		local newEnd, stats = Core.Compute(list, {
			selectionOnly = true, countUnselected = S.countUnselected, next = Core.NEXT_PITCH, tol = 0,
			overlap = S.overlap, endBefore = endBefore, lastMode = Core.LAST_LEAVE, minLen = 1000, -- 1 ms
		})
		for k, v in pairs(stats) do total[k] = total[k] + v end
		for i, e in pairs(newEnd) do changes[#changes + 1] = { item = list[i].item, pos = list[i].pos, newEnd = e } end
	end
	return changes, total
end

-----------------------------------------------------------------------------------------------------------------------
-- Applying
-----------------------------------------------------------------------------------------------------------------------

local function apply(t)
	reaper.Undo_BeginBlock2(0)
	reaper.PreventUIRefresh(1)
	local notes, items = 0, 0
	for _, take in ipairs(t.takes) do
		local list, newEnd = computeTake(take)
		local any = false
		for i, e in pairs(newEnd) do
			reaper.MIDI_SetNote(take, list[i].idx, nil, nil, nil, e, nil, nil, nil, true)
			notes, any = notes + 1, true
		end
		if any then
			reaper.MIDI_Sort(take)
			local item = reaper.GetMediaItemTake_Item(take)
			reaper.MarkTrackItemsDirty(reaper.GetMediaItem_Track(item), item)
		end
	end
	if #t.items > 0 then
		for _, c in ipairs((computeItems(t.items))) do
			reaper.SetMediaItemInfo_Value(c.item, "D_LENGTH", c.newEnd / US - c.pos)
			reaper.UpdateItemInProject(c.item)
			items = items + 1
		end
	end
	reaper.PreventUIRefresh(-1)
	reaper.UpdateArrange()
	reaper.Undo_EndBlock2(0, #t.items > 0 and #t.takes == 0 and "juno: Extend items" or "juno: Extend notes", -1)
	return notes, items
end

-----------------------------------------------------------------------------------------------------------------------
-- UI
-----------------------------------------------------------------------------------------------------------------------

local ctx = ImGui.CreateContext(SCRIPT_NAME)
local state = { key = nil, t = { takes = {}, items = {}, label = "" }, stats = nil, itemStats = nil, status = nil, closeAfter = false }

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

-- Recompute the preview only when the project, the targets or the settings change.
local function refresh()
	local t = getTargets()
	local parts = { reaper.GetProjectStateChangeCount(0) }
	for _, tk in ipairs(t.takes) do
		parts[#parts + 1] = tostring(tk)
		parts[#parts + 1] = select(2, reaper.MIDI_GetHash(tk, true, ""))
	end
	for _, item in ipairs(t.items) do
		parts[#parts + 1] = ("%s:%.9f:%.9f"):format(tostring(item), reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
			reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))
	end
	for k, v in pairs(S) do parts[#parts + 1] = k .. "=" .. tostring(v) end
	table.sort(parts, function(a, b) return tostring(a) < tostring(b) end)
	local key = table.concat(parts, "|")
	if key == state.key then return end
	state.key, state.t = key, t
	local total = { processed = 0, longer = 0, shorter = 0, unchanged = 0 }
	for _, tk in ipairs(t.takes) do
		local _, _, st = computeTake(tk)
		for k, v in pairs(st) do total[k] = total[k] + v end
	end
	state.stats = #t.takes > 0 and total or nil
	state.itemStats = #t.items > 0 and select(2, computeItems(t.items)) or nil
end

local function statLine(st, what)
	ImGui.Text(ctx, ("%s: %d longer, %d shorter, %d unchanged"):format(plural(st.processed, what), st.longer, st.shorter, st.unchanged))
end

local function drawUI()
	refresh()
	local t = state.t
	local hasNotes, hasItems = #t.takes > 0, #t.items > 0
	if not hasNotes and not hasItems then
		ImGui.TextColored(ctx, 0xFFC857FF, "Open a MIDI editor, or select MIDI or audio/video items.")
	else
		ImGui.Text(ctx, t.label)
	end

	if hasNotes or not hasItems then
		ImGui.SeparatorText(ctx, "Notes")
		ImGui.SetNextItemWidth(ctx, 270)
		combo("Notes to extend", "scope", SCOPES)
		ImGui.SetNextItemWidth(ctx, 270)
		combo("Extend up to", "next", NEXTS)
		ImGui.SetNextItemWidth(ctx, 120)
		local _, tol = ImGui.InputDouble(ctx, "Chord tolerance (ms)", S.tolMs, 1, 10, "%.0f")
		S.tolMs = math.max(0, tol)
		help("Notes starting within this time of each other count as one chord, so a slightly early "
			.. "chord note doesn't stretch the others only up to itself.")
		ImGui.SetNextItemWidth(ctx, 270)
		combo("Last notes (no next note)", "last", LASTS)
	end
	if hasItems then
		ImGui.SeparatorText(ctx, "Items")
		ImGui.SetNextItemWidth(ctx, 270)
		combo("Extend up to##items", "itemNext", ITEM_NEXTS)
		help("Only items on the same track (and the same fixed lane) count. The last item on a track is left as it is.")
	end

	ImGui.SeparatorText(ctx, "Options")
	local _, cu = ImGui.Checkbox(ctx, "Unselected ones count as the next one", S.countUnselected)
	S.countUnselected = cu
	help("On: a selected note or item extends up to the next one, selected or not.\n"
		.. "Off: only the other selected ones count, so unselected ones are ignored.")
	ImGui.SetNextItemWidth(ctx, 270)
	combo("Already past the next one", "overlap", OVERLAPS)
	ImGui.SetNextItemWidth(ctx, 120)
	local _, gap = ImGui.InputDouble(ctx, "##gap", S.gap, 1, 10, "%.1f")
	S.gap = math.max(0, gap)
	ImGui.SameLine(ctx)
	ImGui.SetNextItemWidth(ctx, 140)
	combo("Gap##gapunit", "gapUnit", GAP_UNITS)
	help("Space left before the next note or item. 0 = they touch.\nTicks are 1/960 of a beat.")

	ImGui.Separator(ctx)
	local any = false
	for _, pair in ipairs({ { state.stats, "note" }, { state.itemStats, "item" } }) do
		local st = pair[1]
		if st and st.processed > 0 then statLine(st, pair[2]) end
		if st then any = any or st.longer + st.shorter > 0 end
	end
	if not any and not (state.stats and state.stats.processed > 0) and not (state.itemStats and state.itemStats.processed > 0) then
		ImGui.TextDisabled(ctx, "Nothing to extend.")
	end

	ImGui.BeginDisabled(ctx, not any)
	if ImGui.Button(ctx, "Extend", 120, 0) then
		local n, i = apply(t)
		local done = {}
		if n > 0 then done[#done + 1] = plural(n, "note") end
		if i > 0 then done[#done + 1] = plural(i, "item") end
		state.status = "Changed " .. (#done > 0 and table.concat(done, " and ") or "nothing") .. "."
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
