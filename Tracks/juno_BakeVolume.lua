-- @description juno: Bake volume (move track fader volume into an FX, with revert)
-- @author juno
-- @version 1.0.0
-- @changelog
--   Initial release.
-- @about
--   # juno: Bake volume
--
--   For the selected tracks: moves the fader volume into a "Volume/Pan Adjustment" JSFX at the
--   end of the FX chain and resets the fader to 0 dB. The sound doesn't change, because the fader
--   also acts after all the FX.
--
--   - **Bake**: adds the plugin (or, if the track is already baked and the plugin is still last,
--     adds the fader volume to it), then sets the fader to 0 dB.
--   - **Revert**: puts the plugin's gain back on the fader and removes the plugin. Only allowed
--     while the bake plugin is still the last FX: if plugins were added after it, moving the gain
--     back would change what those plugins receive.
--
--   Tracks with a volume envelope, a fader at -inf, or a volume outside the plugin's range are skipped.
--
--   Requires ReaImGui.

local SCRIPT_NAME   = "juno: Bake Volume"
-- The Cockos volume/pan JSFX, tried in order: REAPER 7 file, REAPER 7 name, legacy file, legacy name.
local FX_CANDIDATES = {
	"JS:utility/volume_pan_sample_accurate_auto",
	"JS:Volume/Pan Adjustment (Cockos)",
	"JS:utility/volume_pan",
	"Volume/Pan Smoother v5",
}
local INSTANCE_NAME = "Baked volume"
local EXT_KEY       = "P_EXT:juno_BakeVolume" -- per track: GUID of the bake FX instance

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

-----------------------------------------------------------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------------------------------------------------------

local function lin2db(lin)
	if lin <= 0 then return -math.huge end
	return 20 * math.log(lin, 10)
end

local function db2lin(db) return 10 ^ (db / 20) end

local function fmtDB(db)
	if db == -math.huge then return "-inf dB" end
	return ("%+.2f dB"):format(db)
end

local function trackName(track)
	local _, name = reaper.GetTrackName(track)
	return name
end

local function volumeParam(track, fx)
	for p = 0, reaper.TrackFX_GetNumParams(track, fx) - 1 do
		local _, name = reaper.TrackFX_GetParamName(track, fx, p, "")
		if name:lower():find("volume", 1, true) then return p end
	end
	return 0
end

local function fxName(track, fx)
	local _, name = reaper.TrackFX_GetFXName(track, fx, "")
	return name
end

--- Index of the bake FX on this track (nil if none), plus whether a marker exists at all.
local function findBakeFX(track)
	local _, guid = reaper.GetSetMediaTrackInfo_String(track, EXT_KEY, "", false)
	if guid == "" then return nil, false end
	for fx = 0, reaper.TrackFX_GetCount(track) - 1 do
		if reaper.TrackFX_GetFXGUID(track, fx) == guid then return fx, true end
	end
	return nil, true
end

local function hasVolumeEnvelope(track)
	local env = reaper.GetTrackEnvelopeByName(track, "Volume")
	return env ~= nil and reaper.CountEnvelopePoints(env) > 0
end

-----------------------------------------------------------------------------------------------------------------------
-- Analysis
-----------------------------------------------------------------------------------------------------------------------

--- Everything the UI and the actions need to know about one track.
local function analyse(track)
	local a = { track = track, name = trackName(track) }
	a.vol = reaper.GetMediaTrackInfo_Value(track, "D_VOL")
	a.db = lin2db(a.vol)

	local fx, marked = findBakeFX(track)
	a.fx = fx
	if fx then
		local p = volumeParam(track, fx)
		local val, mn, mx = reaper.TrackFX_GetParam(track, fx, p)
		a.param, a.fxDB, a.fxMin, a.fxMax = p, val, mn, mx
		a.fxActive = reaper.TrackFX_GetEnabled(track, fx) and not reaper.TrackFX_GetOffline(track, fx)
		local after = {}
		for i = fx + 1, reaper.TrackFX_GetCount(track) - 1 do after[#after + 1] = fxName(track, i) end
		a.after = after
		a.isLast = (#after == 0)
	end

	-- Revert
	if not fx then
		a.canRevert = false
		a.revertWhy = marked and "the bake plugin is no longer on the track" or "not baked"
	elseif not a.isLast then
		a.canRevert = false
		a.revertWhy = "FX added after the bake plugin: " .. table.concat(a.after, ", ")
	else
		a.canRevert = true
	end

	-- Bake
	if a.db == -math.huge then
		a.canBake, a.bakeWhy = false, "fader at -inf"
	elseif hasVolumeEnvelope(track) then
		a.canBake, a.bakeWhy = false, "has a volume envelope"
	elseif math.abs(a.db) < 1e-6 then
		a.canBake, a.bakeWhy = false, "fader already at 0 dB"
	elseif fx and not a.isLast then
		a.canBake, a.bakeWhy = false, "already baked, and other FX come after the bake plugin"
	elseif fx and (a.fxDB + a.db < a.fxMin - 1e-6 or a.fxDB + a.db > a.fxMax + 1e-6) then
		a.canBake, a.bakeWhy = false, ("total %s is outside the plugin range"):format(fmtDB(a.fxDB + a.db))
	else
		a.canBake = true
	end
	return a
end

local function selectedTracks()
	local list = {}
	for i = 0, reaper.CountSelectedTracks(0) - 1 do list[#list + 1] = reaper.GetSelectedTrack(0, i) end
	return list
end

-----------------------------------------------------------------------------------------------------------------------
-- Actions
-----------------------------------------------------------------------------------------------------------------------

--- Returns true, or false + reason.
local function bakeTrack(a)
	local track = a.track
	if a.fx then -- merge into the existing bake plugin
		reaper.TrackFX_SetParam(track, a.fx, a.param, a.fxDB + a.db)
		reaper.SetMediaTrackInfo_Value(track, "D_VOL", 1.0)
		return true
	end

	local fx = -1
	for _, name in ipairs(FX_CANDIDATES) do
		fx = reaper.TrackFX_AddByName(track, name, false, -1)
		if fx >= 0 then break end
	end
	if fx < 0 then return false, 'plugin "Volume/Pan Adjustment" (JS: utility/volume_pan) not found' end
	local p = volumeParam(track, fx)
	local _, mn, mx = reaper.TrackFX_GetParam(track, fx, p)
	if a.db < mn or a.db > mx then
		reaper.TrackFX_Delete(track, fx)
		return false, ("%s is outside the plugin range (%s to %s)"):format(fmtDB(a.db), fmtDB(mn), fmtDB(mx))
	end
	reaper.TrackFX_SetNamedConfigParm(track, fx, "renamed_name", INSTANCE_NAME)
	reaper.TrackFX_SetParam(track, fx, p, a.db)
	reaper.SetMediaTrackInfo_Value(track, "D_VOL", 1.0)
	reaper.GetSetMediaTrackInfo_String(track, EXT_KEY, reaper.TrackFX_GetFXGUID(track, fx), true)
	return true
end

local function revertTrack(a)
	local gainDB = a.fxActive and a.fxDB or 0 -- a bypassed/offline plugin wasn't applying any gain
	reaper.SetMediaTrackInfo_Value(a.track, "D_VOL", a.vol * db2lin(gainDB))
	reaper.TrackFX_Delete(a.track, a.fx)
	reaper.GetSetMediaTrackInfo_String(a.track, EXT_KEY, "", true)
	return true
end

local function runOnSelection(kind)
	local done, skipped = 0, {}
	reaper.Undo_BeginBlock()
	reaper.PreventUIRefresh(1)
	for _, track in ipairs(selectedTracks()) do
		local a = analyse(track)
		local can, why = a.canBake, a.bakeWhy
		if kind == "revert" then can, why = a.canRevert, a.revertWhy end
		if can then
			local ok, err = (kind == "bake" and bakeTrack or revertTrack)(a)
			if ok then done = done + 1 else skipped[#skipped + 1] = a.name .. ": " .. err end
		elseif not (kind == "revert" and why == "not baked") then
			skipped[#skipped + 1] = a.name .. ": " .. why
		end
	end
	reaper.PreventUIRefresh(-1)
	reaper.TrackList_AdjustWindows(false)
	reaper.UpdateArrange()
	reaper.Undo_EndBlock(kind == "bake" and "juno: Bake track volume" or "juno: Revert baked track volume", -1)
	return done, skipped
end

-----------------------------------------------------------------------------------------------------------------------
-- UI
-----------------------------------------------------------------------------------------------------------------------

local ctx = ImGui.CreateContext(SCRIPT_NAME)
local state = { sig = nil, rows = {}, status = nil, statusColor = 0x9BE29BFF, skipped = {}, close = false }

local function refresh()
	local parts = { tostring(reaper.GetProjectStateChangeCount(0)) }
	for _, t in ipairs(selectedTracks()) do parts[#parts + 1] = tostring(t) end
	local sig = table.concat(parts, ",")
	if sig ~= state.sig then
		state.sig = sig
		state.rows = {}
		for _, t in ipairs(selectedTracks()) do state.rows[#state.rows + 1] = analyse(t) end
	end
end

local function statusText(a)
	if a.fx then
		local s = "Baked: " .. fmtDB(a.fxDB) .. (a.fxActive and "" or " (plugin bypassed)")
		if not a.isLast then return s .. " - can't revert, FX after it: " .. table.concat(a.after, ", "), 0xFFC857FF end
		return s, 0x9BE29BFF
	end
	if a.revertWhy == "the bake plugin is no longer on the track" then return "Bake plugin was removed", 0xFFC857FF end
	return "Not baked", nil
end

local function drawUI()
	refresh()
	local rows = state.rows

	if #rows == 0 then
		ImGui.TextColored(ctx, 0xFFC857FF, "Select one or more tracks.")
	else
		local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg | ImGui.TableFlags_SizingFixedFit | ImGui.TableFlags_ScrollY
		local line = ImGui.GetTextLineHeight(ctx) + 6
		if ImGui.BeginTable(ctx, "tracks", 3, flags, 0, math.min(#rows, 12) * line + line + 6) then
			ImGui.TableSetupScrollFreeze(ctx, 0, 1)
			ImGui.TableSetupColumn(ctx, "Track")
			ImGui.TableSetupColumn(ctx, "Fader")
			ImGui.TableSetupColumn(ctx, "Status", ImGui.TableColumnFlags_WidthStretch)
			ImGui.TableHeadersRow(ctx)
			for _, a in ipairs(rows) do
				ImGui.TableNextRow(ctx)
				ImGui.TableNextColumn(ctx)
				ImGui.Text(ctx, a.name)
				ImGui.TableNextColumn(ctx)
				ImGui.Text(ctx, fmtDB(a.db))
				ImGui.TableNextColumn(ctx)
				local txt, col = statusText(a)
				if col then ImGui.TextColored(ctx, col, txt) else ImGui.TextDisabled(ctx, txt) end
				if not a.canBake and ImGui.IsItemHovered(ctx) then
					ImGui.SetTooltip(ctx, "Bake not possible: " .. a.bakeWhy)
				end
			end
			ImGui.EndTable(ctx)
		end
	end

	local nBake, nRevert = 0, 0
	for _, a in ipairs(rows) do
		if a.canBake then nBake = nBake + 1 end
		if a.canRevert then nRevert = nRevert + 1 end
	end

	ImGui.Spacing(ctx)
	ImGui.BeginDisabled(ctx, nBake == 0)
	if ImGui.Button(ctx, ("Bake (%d)"):format(nBake), 120, 0) then
		local done, skipped = runOnSelection("bake")
		state.status, state.skipped = ("Baked %d track%s."):format(done, done == 1 and "" or "s"), skipped
	end
	ImGui.EndDisabled(ctx)
	ImGui.SameLine(ctx)
	ImGui.BeginDisabled(ctx, nRevert == 0)
	if ImGui.Button(ctx, ("Revert (%d)"):format(nRevert), 120, 0) then
		local done, skipped = runOnSelection("revert")
		state.status, state.skipped = ("Reverted %d track%s."):format(done, done == 1 and "" or "s"), skipped
	end
	ImGui.EndDisabled(ctx)
	ImGui.SameLine(ctx)
	if ImGui.Button(ctx, "Close", 80, 0) then state.close = true end

	if state.status then
		ImGui.TextColored(ctx, state.statusColor, state.status)
		if #state.skipped > 0 then
			ImGui.TextColored(ctx, 0xFFC857FF, ("Skipped %d:"):format(#state.skipped))
			for _, s in ipairs(state.skipped) do ImGui.BulletText(ctx, s) end
		end
	end
end

local function loop()
	ImGui.SetNextWindowSize(ctx, 560, 360, ImGui.Cond_FirstUseEver)
	local visible, open = ImGui.Begin(ctx, SCRIPT_NAME, true, ImGui.WindowFlags_NoCollapse)
	if visible then
		drawUI()
		if ImGui.IsWindowFocused(ctx) and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then state.close = true end
		ImGui.End(ctx)
	end
	if open and not state.close then reaper.defer(loop) end
end

reaper.defer(loop)
