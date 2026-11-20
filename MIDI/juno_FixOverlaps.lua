-- @description juno: Fix overlapping, duplicate and short notes or items
-- @author juno
-- @version 1.1.0
-- @changelog
--   - Works on audio/video items too: run it with items selected in the arrange view to remove duplicate and
--     short items and trim overlapping ones, with an optional crossfade. MIDI items always have their notes
--     fixed, never the items.
--   - Option to keep or remove the existing fades of overlapping items when trimming them
--   - Option to cut overlapping items at the start, middle or end of their overlap
-- @provides
--   [main=main,midi_editor] .
--   [nomain] juno_FixOverlaps/core.lua
-- @about
--   # juno: Fix Overlaps
--
--   Cleans up MIDI (for example after importing or recording it) or items on the timeline.
--
--   What it works on follows what you have in REAPER:
--   - the MIDI editor (or selected MIDI items): their notes. Only the selected notes are checked (all notes if
--     none is selected);
--   - selected audio/video items: the items themselves, compared with the other selected items on the same
--     track and lane. Duplicates are items of the same source file and part of the file starting together;
--     overlapping items are trimmed, optionally leaving a crossfade.
--   MIDI items are never fixed as items.
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
local CUT_POSITIONS = { "Start of the overlap", "Middle of the overlap", "End of the overlap" }
local CUT_START, CUT_MIDDLE, CUT_END = 1, 2, 3

local DEFAULTS = {
	scope = 1, separateChans = true,
	dupes = true, dupTolMs = 10,
	overlaps = true, overlapMode = Core.OVERLAP_TRIM,
	short = false, minLenMs = 20,
	mono = false,
	xfadeMs = 0, -- items: crossfade left when trimming an overlap
	keepFades = true, -- items: keep the fades of the two items when trimming an overlap
	cutPos = 1,       -- items: where an overlap is cut: 1 at its start, 2 in the middle, 3 at its end
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

-----------------------------------------------------------------------------------------------------------------------
-- Items: the selected audio/video items of each track (and fixed lane) are checked like notes on one pitch.
-- Times are in microseconds, so the core's whole-number rounding stays precise.
-----------------------------------------------------------------------------------------------------------------------

local US = 1e6

local function sourceFile(take)
	local src = reaper.GetMediaItemTake_Source(take)
	while true do
		local parent = reaper.GetMediaSourceParent(src)
		if not parent then break end
		src = parent
	end
	return reaper.GetMediaSourceFileName(src, "")
end

local function itemGroups(items)
	local groups, order = {}, {}
	for _, item in ipairs(items) do
		local track = reaper.GetMediaItem_Track(item)
		local key = tostring(track) .. "|" .. (reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE") or 0)
		if not groups[key] then groups[key] = {}; order[#order + 1] = key end
		local take = reaper.GetActiveTake(item)
		local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
		table.insert(groups[key], {
			item = item, track = track, pos = pos,
			start = math.floor(pos * US + 0.5),
			finish = math.floor((pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")) * US + 0.5),
			file = sourceFile(take), offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
			rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1,
		})
	end
	local out = {}
	for _, key in ipairs(order) do out[#out + 1] = groups[key] end
	return out
end

-- Returns { list = {entries}, delete = {[entry] = true}, newEnd = {[entry] = us}, trimStart = {[entry] = us later},
-- fadeIn/fadeOut = {[entry] = us}, involved = {[entry] = true}, pairs = { {earlier, later} },
-- stats = { items, duplicate, short, overlap } }.
local function analyseItems(items)
	local r = { list = {}, delete = {}, newEnd = {}, trimStart = {}, fadeIn = {}, fadeOut = {}, involved = {}, pairs = {},
		stats = { items = 0, duplicate = 0, short = 0, overlap = 0 } }
	local tolUs = math.max(0, S.dupTolMs) * 1000
	for _, list in ipairs(itemGroups(items)) do
		r.stats.items = r.stats.items + #list
		-- 1. Duplicates (same file and part of the file, starting together) and short items
		local keys, nextKey = {}, 0
		local A = {}
		for i, e in ipairs(list) do
			r.list[#r.list + 1] = e
			local k = e.file .. "@" .. math.floor(e.offs * US / math.max(tolUs, 1) + 0.5)
			if not keys[k] then nextKey = nextKey + 1; keys[k] = nextKey end
			A[i] = { start = e.start, finish = e.finish, pitch = keys[k], chan = 0, sel = true, vel = 0 }
		end
		local delA, _, _, stA, invA = Core.Fix(A, {
			dupes = S.dupes, dupTol = tolUs, short = S.short, minLen = math.max(0, S.minLenMs) * 1000,
		})
		r.stats.duplicate, r.stats.short = r.stats.duplicate + stA.duplicate, r.stats.short + stA.short
		for i in pairs(delA) do r.delete[list[i]] = true end
		for i in pairs(invA) do r.involved[list[i]] = true end

		-- 2. Overlaps between the items that are left: trim the earlier one, optionally keeping a crossfade
		if S.overlaps then
			local B, map = {}, {}
			for i, e in ipairs(list) do
				if not delA[i] then
					B[#B + 1] = { start = e.start, finish = e.finish, pitch = 0, chan = 0, sel = true }
					map[#B] = e
				end
			end
			local _, endB, _, stB, invB = Core.Fix(B, { overlaps = true, overlapMode = Core.OVERLAP_TRIM })
			r.stats.overlap = r.stats.overlap + stB.overlap
			for j in pairs(invB) do r.involved[map[j]] = true end
			local xf = math.max(0, S.xfadeMs) * 1000
			for j, nextStart in pairs(endB) do
				local e = map[j]
				local later -- the item it overlapped: the one starting where it is trimmed (the cut point)
				for k, b in ipairs(B) do
					if b.start == nextStart and map[k] ~= e then later = map[k]; break end
				end
				-- The overlap runs from where the later item starts to where the earlier one ends (or the later one,
				-- if it sits entirely inside). Both items are cut at the same point in it: the earlier one's end is
				-- trimmed back, the later one's start trimmed forward. A crossfade keeps them overlapping around the
				-- cut point, inside the original overlap (nothing is ever extended).
				local ovStart, ovEnd = nextStart, math.min(e.finish, later and later.finish or e.finish)
				local xfLen = math.max(0, math.min(xf, ovEnd - ovStart))
				local rs, re -- the part that stays overlapped (the crossfade); rs == re without one
				if S.cutPos == CUT_MIDDLE then
					local c = (ovStart + ovEnd) / 2
					rs, re = c - xfLen / 2, c + xfLen / 2
				elseif S.cutPos == CUT_END then
					rs, re = ovEnd - xfLen, ovEnd
				else
					rs, re = ovStart, ovStart + xfLen
				end
				rs, re = math.floor(rs + 0.5), math.floor(re + 0.5)
				r.newEnd[e] = re
				if later and rs > later.start then r.trimStart[later] = rs - later.start end
				r.pairs[#r.pairs + 1] = { earlier = e, later = later }
				local len = re - rs
				if len > 0 then
					r.fadeOut[e] = len
					if later then r.fadeIn[later] = len end
				end
			end
		end
	end
	return r
end

local function finishEdit(take)
	reaper.MIDI_Sort(take)
	local item = reaper.GetMediaItemTake_Item(take)
	reaper.MarkTrackItemsDirty(reaper.GetMediaItem_Track(item), item)
end

local function fix(t)
	reaper.Undo_BeginBlock2(0)
	reaper.PreventUIRefresh(1)
	local changed, changedItems = 0, 0
	if #t.items > 0 then
		local r = analyseItems(t.items)
		local touched = {}
		for e in pairs(r.newEnd) do touched[e] = true end
		for e in pairs(r.trimStart) do touched[e] = true end
		for e in pairs(touched) do
			if not r.delete[e] then
				-- trimming the start: the item starts later and its content moves with it, so the audio stays in place
				local trim = r.trimStart[e] or 0
				local newStart = e.start + trim
				local newEnd = math.max(r.newEnd[e] or e.finish, newStart + 1000) -- at least 1 ms
				if trim > 0 then
					reaper.SetMediaItemInfo_Value(e.item, "D_POSITION", newStart / US)
					for ti = 0, reaper.CountTakes(e.item) - 1 do
						local take = reaper.GetTake(e.item, ti)
						local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1
						local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
						reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", offs + trim / US * rate)
					end
				end
				reaper.SetMediaItemInfo_Value(e.item, "D_LENGTH", (newEnd - newStart) / US)
				changedItems = changedItems + 1
			end
		end
		if not S.keepFades then -- remove the old (cross)fades between the two items of each fixed overlap
			for _, p in ipairs(r.pairs) do
				if not r.delete[p.earlier] then
					reaper.SetMediaItemInfo_Value(p.earlier.item, "D_FADEOUTLEN", 0)
					reaper.SetMediaItemInfo_Value(p.earlier.item, "D_FADEOUTLEN_AUTO", 0)
				end
				if p.later and not r.delete[p.later] then
					reaper.SetMediaItemInfo_Value(p.later.item, "D_FADEINLEN", 0)
					reaper.SetMediaItemInfo_Value(p.later.item, "D_FADEINLEN_AUTO", 0)
				end
			end
		end
		for e, len in pairs(r.fadeOut) do reaper.SetMediaItemInfo_Value(e.item, "D_FADEOUTLEN_AUTO", len / US) end
		for e, len in pairs(r.fadeIn) do reaper.SetMediaItemInfo_Value(e.item, "D_FADEINLEN_AUTO", len / US) end
		for e in pairs(r.delete) do
			reaper.DeleteTrackMediaItem(e.track, e.item)
			changedItems = changedItems + 1
		end
	end
	for _, take in ipairs(t.takes) do
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
	return changed, changedItems
end

-- Selects exactly the notes (or items) in a conflict, both the one that changes and its partner (deselects the rest).
local function selectAffected(t)
	reaper.Undo_BeginBlock2(0)
	local count = 0
	if #t.items > 0 then
		local r = analyseItems(t.items)
		for _, e in ipairs(r.list) do
			local hit = r.involved[e] == true
			if hit then count = count + 1 end
			reaper.SetMediaItemSelected(e.item, hit)
		end
	end
	for _, take in ipairs(t.takes) do
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
local state = { key = nil, t = { takes = {}, items = {}, label = "" }, stats = nil, itemStats = nil, status = nil, closeAfter = false }

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

-- Recompute only when the project, the notes or the settings change.
local function refresh()
	local t = getTargets()
	local parts = { tostring(reaper.GetProjectStateChangeCount(0)) }
	for _, tk in ipairs(t.takes) do
		parts[#parts + 1] = tostring(tk)
		parts[#parts + 1] = select(2, reaper.MIDI_GetHash(tk, true, ""))
	end
	for _, item in ipairs(t.items) do
		parts[#parts + 1] = ("%s:%.9f:%.9f"):format(tostring(item), reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
			reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))
	end
	local keys = {}
	for k in pairs(S) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(S[k]) end
	local key = table.concat(parts, "|")
	if key == state.key then return end
	state.key, state.t = key, t
	local total = { notes = 0, duplicate = 0, short = 0, overlap = 0, merged = 0, mono = 0 }
	for _, tk in ipairs(t.takes) do
		local st = select(4, analyse(tk))
		for k, v in pairs(st) do total[k] = total[k] + v end
	end
	state.stats = #t.takes > 0 and total or nil
	state.itemStats = #t.items > 0 and analyseItems(t.items).stats or nil
end

-- "In 12 notes:" + one bullet per kind of problem found; returns how many problems.
local function drawFound(total, what, rows)
	local list, found = {}, 0
	for _, pair in ipairs(rows) do -- explicit loop: a zero count must not stop the list
		found = found + pair[1]
		if pair[1] > 0 then list[#list + 1] = ("%d %s"):format(pair[1], pair[2]) end
	end
	if #list > 0 then
		ImGui.Text(ctx, ("In %s:"):format(plural(total, what)))
		for _, c in ipairs(list) do ImGui.BulletText(ctx, c) end
	elseif total > 0 then
		ImGui.TextColored(ctx, 0x7FD67FFF, ("%s checked: nothing to fix."):format(plural(total, what)))
	end
	return found
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
		combo("Notes to check", "scope", SCOPES)
		checkbox("Treat MIDI channels separately", "separateChans")
		help("On: notes on different channels never count as duplicates or overlaps of each other.")
		checkbox("Trim overlaps between different pitches (monophonic)", "mono")
		help("For mono lines (bass, lead, a single voice): each note ends where the next note starts, "
			.. "whatever its pitch. Notes starting together (chords) are left alone.")
		ImGui.SetNextItemWidth(ctx, 200)
		combo("Same-pitch overlaps", "overlapMode", OVERLAP_MODES)
	end
	if hasItems then
		ImGui.SeparatorText(ctx, "Items")
		ImGui.SetNextItemWidth(ctx, 200)
		combo("Cut overlaps at the", "cutPos", CUT_POSITIONS)
		help("Where two overlapping items are cut. The overlap is the part where both play, from the next item's "
			.. "start to the earlier item's end.\n"
			.. "- Start: the earlier item is trimmed back to where the next one starts.\n"
			.. "- Middle: both are trimmed to the middle of the overlap (the next item's start moves forward, "
			.. "its audio stays in place).\n"
			.. "- End: the next item's start is trimmed forward to where the earlier one ends.\n"
			.. "Only the selected items are checked, each against the others on the same track and lane.")
		ImGui.SetNextItemWidth(ctx, 90)
		local _, xf = ImGui.InputDouble(ctx, "Crossfade (ms)", S.xfadeMs, 1, 10, "%.0f")
		S.xfadeMs = math.max(0, xf)
		help("0: the two items just touch at the cut point.\n"
			.. "More: they keep overlapping by this much around the cut point, with a fade-out and fade-in "
			.. "(a crossfade). It always stays inside the original overlap.")
		checkbox("Keep the existing fades when trimming overlaps", "keepFades")
		help("On: the fade-out of the trimmed item and the fade-in of the next one stay as they are.\n"
			.. "Off: they are removed (usually the old crossfade between the two). With a crossfade length "
			.. "above 0, the new crossfade is then the only fade left.")
	end

	ImGui.SeparatorText(ctx, "Fixes")
	checkbox("Remove duplicates", "dupes")
	help("Notes of the same pitch, or items of the same file and part of the file, starting within this time "
		.. "of each other. The longest one is kept (the loudest note if they are equally long).")
	ImGui.BeginDisabled(ctx, not S.dupes)
	msInput("ms##dup", "dupTolMs")
	ImGui.EndDisabled(ctx)

	checkbox("Fix overlaps", "overlaps")
	help("A note still playing when the next note of the same pitch starts, or an item still playing when the "
		.. "next item on its track starts.")

	checkbox("Remove ones shorter than", "short")
	help("Notes or items shorter than this. Also removes zero-length notes.")
	ImGui.BeginDisabled(ctx, not S.short)
	msInput("ms##short", "minLenMs")
	ImGui.EndDisabled(ctx)

	ImGui.SeparatorText(ctx, "Found")
	local found = 0
	local st = state.stats
	if st then
		found = found + drawFound(st.notes, "note", {
			{ st.duplicate, "duplicates" }, { st.short, "short notes" }, { st.overlap, "same-pitch overlaps" },
			{ st.merged, "notes to merge" }, { st.mono, "monophonic overlaps" },
		})
	end
	local it = state.itemStats
	if it then
		found = found + drawFound(it.items, "item", {
			{ it.duplicate, "duplicate items" }, { it.short, "short items" }, { it.overlap, "overlapping items" },
		})
	end
	if not st and not it then ImGui.TextDisabled(ctx, "Nothing to check.") end

	ImGui.Spacing(ctx)
	ImGui.BeginDisabled(ctx, found == 0)
	if ImGui.Button(ctx, "Fix", 100, 0) then
		local n, i = fix(t)
		local done = {}
		if n > 0 then done[#done + 1] = plural(n, "note") end
		if i > 0 then done[#done + 1] = plural(i, "item") end
		state.status = "Fixed " .. (#done > 0 and table.concat(done, " and ") or "nothing") .. "."
		state.key = nil
	end
	ImGui.SameLine(ctx)
	if ImGui.Button(ctx, "Select affected", 140, 0) then
		local n = selectAffected(t)
		state.status = ("Selected %d."):format(n)
		state.key = nil
	end
	ImGui.EndDisabled(ctx)
	help("Selects only the notes or items involved in a problem (the ones Fix would change and the ones they clash "
		.. "with), so you can look at them first. The next check then covers just those.")
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
