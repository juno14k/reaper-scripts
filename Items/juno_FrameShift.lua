-- @description juno: Frame shift (move item content by frames)
-- @author juno
-- @version 1.0.0
-- @changelog
--   Initial release.
-- @provides
--   [main] juno_FrameShiftForward.lua
--   [main] juno_FrameShiftBackward.lua
--   [main] juno_FrameSnap.lua
--   [nomain] juno_FrameShift/lib.lua
-- @about
--   # juno: Frame shift
--
--   Moves the content of the selected items (their take start offset) by whole video frames,
--   without moving the items themselves. Frame rates are read from the video files (through
--   ffprobe; the project frame rate is used if it can't be read).
--
--   ## Key map scripts (no UI)
--   - **juno_FrameShiftForward / juno_FrameShiftBackward**: every video moves by one of its own
--     frames. Audio moves by the same timeline amount as the videos. If the videos have different
--     frame rates, a message tells you, and audio moves by 1/60 s.
--   - **juno_FrameSnap**: snaps the start offset of every selected video to its nearest whole frame
--     (frames of the video itself, not the project grid). Nothing moves on the timeline; audio is left alone.
--
--   ## juno_FrameShift (UI)
--   - Move everything by the same amount: N frames at the detected FPS, N frames at a chosen FPS,
--     or a fixed time. Optionally each video can use its own FPS instead.
--   - Shows the FPS, playrate and offset (in frames) of every selected item.
--   - Optional snapping of video offsets to whole frames and of item positions to the project frame grid.
--   - A Snap button that only snaps the video offsets, without moving by any frames.
--
--   Requires ReaImGui for the UI script. Frame rate detection needs ffprobe (in REAPER's UserPlugins folder or on PATH).

local SCRIPT_NAME = "juno: Frame Shift"
local EXT_SECTION = "juno_FrameShift"

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
local L = dofile(SCRIPT_DIR .. "juno_FrameShift/lib.lua")

-----------------------------------------------------------------------------------------------------------------------
-- Settings
-----------------------------------------------------------------------------------------------------------------------

local MODE_DETECTED, MODE_CHOSEN, MODE_TIME, MODE_OWN = 1, 2, 3, 4
local MODE_NAMES = {
	"Frames at the detected FPS",
	"Frames at a chosen FPS",
	"Fixed time",
	"Frames, each video at its own FPS",
}
local FPS_PRESETS = { 23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60 }

local DEFAULTS = {
	mode       = MODE_DETECTED,
	frames     = 1,
	presetIdx  = 5,  -- 30 fps; 0 = custom
	customFps  = 30,
	timeMs     = 10,
	snapOffset = false,
	snapPos    = false,
}

local S = {}
local function loadSettings()
	for k, def in pairs(DEFAULTS) do
		local raw = reaper.GetExtState(EXT_SECTION, k)
		if raw == "" then S[k] = def
		elseif type(def) == "boolean" then S[k] = (raw == "1")
		else S[k] = tonumber(raw) or def end
	end
end
local function saveSettings()
	for k, v in pairs(S) do
		reaper.SetExtState(EXT_SECTION, k, type(v) == "boolean" and (v and "1" or "0") or tostring(v), true)
	end
end

local function chosenFps()
	if S.presetIdx >= 1 and FPS_PRESETS[S.presetIdx] then return FPS_PRESETS[S.presetIdx] end
	return math.max(S.customFps, 0.001)
end

-----------------------------------------------------------------------------------------------------------------------
-- State
-----------------------------------------------------------------------------------------------------------------------

local ctx = ImGui.CreateContext(SCRIPT_NAME)
local state = { sig = nil, entries = {}, fpsList = {}, status = nil, statusColor = 0x9BE29BFF, close = false }

local function selectionSignature()
	local parts = { tostring(reaper.GetProjectStateChangeCount(0)) }
	for i = 0, reaper.CountSelectedMediaItems(0) - 1 do parts[#parts + 1] = tostring(reaper.GetSelectedMediaItem(0, i)) end
	return table.concat(parts, ",")
end

local function refresh()
	local sig = selectionSignature()
	if sig ~= state.sig then
		state.sig = sig
		state.entries = L.Collect()
		state.fpsList = L.DistinctFPS(state.entries)
	end
end

local function countVideos()
	local n = 0
	for _, e in ipairs(state.entries) do if e.isVideo then n = n + 1 end end
	return n
end

--- Global timeline shift for the current settings, or nil + reason.
local function globalShift()
	if S.mode == MODE_TIME then return S.timeMs / 1000 end
	if S.mode == MODE_CHOSEN then return S.frames / chosenFps() end
	-- detected
	if #state.fpsList > 1 then return nil, "The selected videos have different frame rates: choose a FPS or another mode." end
	local fps = state.fpsList[1] or L.ProjectFPS()
	return S.frames / fps
end

-----------------------------------------------------------------------------------------------------------------------
-- Applying
-----------------------------------------------------------------------------------------------------------------------

local function apply(dir)
	local entries = L.Collect()
	if #entries == 0 then return end
	state.entries = entries
	state.fpsList = L.DistinctFPS(entries)

	local deltas, note = {}, nil
	if S.mode == MODE_OWN then
		local videoShift, mixed = nil, false
		for _, e in ipairs(entries) do
			if e.isVideo then
				local s = S.frames / (e.fps * e.rate)
				if videoShift and math.abs(s - videoShift) > 1e-9 then mixed = true end
				videoShift = videoShift or s
			end
		end
		local audioShift = (videoShift and not mixed) and videoShift or (S.frames / L.AUDIO_FALLBACK_FPS)
		if mixed then note = ("Videos have different frame rates: audio moved by %d/%d s."):format(S.frames, L.AUDIO_FALLBACK_FPS) end
		for i, e in ipairs(entries) do
			deltas[i] = e.isVideo and (S.frames / e.fps) or (audioShift * e.rate)
		end
	else
		local shift, err = globalShift()
		if not shift then
			state.status, state.statusColor = err, 0xFF7070FF
			return
		end
		for i, e in ipairs(entries) do deltas[i] = shift * e.rate end
	end

	reaper.Undo_BeginBlock()
	reaper.PreventUIRefresh(1)
	for i, e in ipairs(entries) do
		L.SetOffset(e, e.offs + dir * deltas[i], S.snapOffset)
		if S.snapPos then L.SnapPosition(e) end
		reaper.UpdateItemInProject(e.item)
	end
	reaper.PreventUIRefresh(-1)
	reaper.UpdateArrange()
	reaper.Undo_EndBlock(dir > 0 and "juno: Frame shift forward" or "juno: Frame shift backward", -1)

	state.status = note or ("Moved %d item%s %s."):format(#entries, #entries == 1 and "" or "s", dir > 0 and "forward" or "backward")
	state.statusColor = note and 0xFFC857FF or 0x9BE29BFF
end

local function snapOnly()
	local entries = L.Collect()
	reaper.Undo_BeginBlock()
	reaper.PreventUIRefresh(1)
	local videos, moved = L.SnapOffsets(entries)
	reaper.PreventUIRefresh(-1)
	reaper.UpdateArrange()
	reaper.Undo_EndBlock("juno: Frame snap", 4)
	state.entries = entries
	state.status = moved == 0 and ("All %d video%s already start on a whole frame."):format(videos, videos == 1 and "" or "s")
		or ("Snapped %d of %d video%s to a whole frame."):format(moved, videos, videos == 1 and "" or "s")
	state.statusColor = 0x9BE29BFF
end

-----------------------------------------------------------------------------------------------------------------------
-- UI
-----------------------------------------------------------------------------------------------------------------------

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

local function drawItemTable()
	local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg | ImGui.TableFlags_SizingFixedFit | ImGui.TableFlags_ScrollY
	local h = math.min(#state.entries, 8) * (ImGui.GetTextLineHeight(ctx) + 6) + ImGui.GetTextLineHeight(ctx) + 10
	if ImGui.BeginTable(ctx, "items", 5, flags, 0, h) then
		ImGui.TableSetupScrollFreeze(ctx, 0, 1)
		ImGui.TableSetupColumn(ctx, "Item", ImGui.TableColumnFlags_WidthStretch)
		ImGui.TableSetupColumn(ctx, "FPS")
		ImGui.TableSetupColumn(ctx, "Rate")
		ImGui.TableSetupColumn(ctx, "Offset (s)")
		ImGui.TableSetupColumn(ctx, "Offset (frames)")
		ImGui.TableHeadersRow(ctx)
		for _, e in ipairs(state.entries) do
			ImGui.TableNextRow(ctx)
			ImGui.TableNextColumn(ctx)
			ImGui.Text(ctx, (e.isVideo and "[V] " or "[A] ") .. (e.name ~= "" and e.name or "(unnamed)"))
			ImGui.TableNextColumn(ctx)
			if e.isVideo then
				if e.fpsDetected then ImGui.Text(ctx, L.FormatFPS(e.fps))
				else ImGui.TextColored(ctx, 0xFFC857FF, L.FormatFPS(e.fps) .. "*") end
			else
				ImGui.TextDisabled(ctx, "-")
			end
			ImGui.TableNextColumn(ctx)
			ImGui.Text(ctx, L.FormatFPS(e.rate) .. "x")
			ImGui.TableNextColumn(ctx)
			ImGui.Text(ctx, ("%.4f"):format(e.offs))
			ImGui.TableNextColumn(ctx)
			if e.isVideo then
				local f = e.offs * e.fps
				local whole = math.abs(f - math.floor(f + 0.5)) < 1e-3
				if whole then ImGui.Text(ctx, ("%d"):format(math.floor(f + 0.5)))
				else ImGui.TextColored(ctx, 0xFFC857FF, ("%.2f (between frames)"):format(f)) end
			else
				ImGui.TextDisabled(ctx, "-")
			end
		end
		ImGui.EndTable(ctx)
	end
end

local function drawUI()
	refresh()
	local entries = state.entries

	-- Selection summary
	if #entries == 0 then
		ImGui.TextColored(ctx, 0xFFC857FF, "Select one or more items.")
	else
		local nv = countVideos()
		local fpsText
		if nv == 0 then
			fpsText = "no videos"
		else
			local list = {}
			for i, f in ipairs(state.fpsList) do list[i] = L.FormatFPS(f) end
			fpsText = ((#list > 1) and "mixed FPS: " or "") .. table.concat(list, ", ") .. " fps"
		end
		ImGui.Text(ctx, ("%d item%s (%d video, %d audio)  -  %s"):format(
			#entries, #entries == 1 and "" or "s", nv, #entries - nv, fpsText))
		ImGui.TextDisabled(ctx, ("Project frame rate: %s fps"):format(L.FormatFPS(L.ProjectFPS())))
	end

	-- Amount
	ImGui.SeparatorText(ctx, "Amount")
	local changed, idx = ImGui.Combo(ctx, "Mode", S.mode - 1, table.concat(MODE_NAMES, "\0") .. "\0")
	if changed then S.mode = idx + 1 end
	if S.mode == MODE_OWN then
		infoMarker("Like the key map scripts: each video moves by its own frames, audio follows the videos "
			.. "(or 1/60 s per frame if the videos have different frame rates).")
	elseif S.mode == MODE_DETECTED then
		infoMarker("Everything moves by the same amount, based on the videos' frame rate. "
			.. "Without videos the project frame rate is used.")
	end

	if S.mode == MODE_TIME then
		local c, v = ImGui.InputDouble(ctx, "Time (ms)", S.timeMs, 1, 10, "%.3f")
		if c then S.timeMs = math.max(0, v) end
	else
		local c, v = ImGui.InputInt(ctx, "Frames", S.frames)
		if c then S.frames = math.max(1, v) end
	end

	if S.mode == MODE_CHOSEN then
		local names = {}
		for i, f in ipairs(FPS_PRESETS) do names[i] = L.FormatFPS(f) .. " fps" end
		names[#names + 1] = "Custom"
		local cur = (S.presetIdx >= 1 and FPS_PRESETS[S.presetIdx]) and (S.presetIdx - 1) or #FPS_PRESETS
		local c, i = ImGui.Combo(ctx, "FPS", cur, table.concat(names, "\0") .. "\0")
		if c then S.presetIdx = (i < #FPS_PRESETS) and (i + 1) or 0 end
		if S.presetIdx == 0 then
			local c2, v = ImGui.InputDouble(ctx, "Custom FPS", S.customFps, 0, 0, "%.3f")
			if c2 then S.customFps = math.max(0.001, v) end
		end
	end

	if S.mode ~= MODE_OWN then
		local shift, err = globalShift()
		if shift then
			ImGui.TextDisabled(ctx, ("= %.4f s on the timeline"):format(shift))
		else
			ImGui.TextColored(ctx, 0xFF7070FF, err)
		end
	end

	-- Snapping
	ImGui.SeparatorText(ctx, "Snapping")
	local c1, v1 = ImGui.Checkbox(ctx, "Snap video offsets to whole frames", S.snapOffset)
	if c1 then S.snapOffset = v1 end
	infoMarker("After moving, rounds each video's start offset to a whole frame of the video, so it never starts between two frames.")
	local c2, v2 = ImGui.Checkbox(ctx, "Snap item positions to the project frame grid", S.snapPos)
	if c2 then S.snapPos = v2 end
	infoMarker("After moving, also moves each item's position on the timeline to the nearest project frame.")

	-- Items
	ImGui.SeparatorText(ctx, "Selected items")
	if #entries > 0 then
		drawItemTable()
		for _, e in ipairs(entries) do
			if e.isVideo and not e.fpsDetected then
				ImGui.TextDisabled(ctx, "* frame rate could not be read (ffprobe missing?): using the project frame rate.")
				break
			end
		end
	end

	-- Actions
	ImGui.Spacing(ctx)
	local canMove = #entries > 0 and (S.mode == MODE_OWN or globalShift() ~= nil)
	ImGui.BeginDisabled(ctx, not canMove)
	if ImGui.Button(ctx, "<< Backward", 120, 0) then apply(-1) end
	ImGui.SameLine(ctx)
	if ImGui.Button(ctx, "Forward >>", 120, 0) then apply(1) end
	ImGui.EndDisabled(ctx)
	ImGui.SameLine(ctx)
	local hasVideo = false
	for _, e in ipairs(entries) do if e.isVideo then hasVideo = true break end end
	ImGui.BeginDisabled(ctx, not hasVideo)
	if ImGui.Button(ctx, "Snap", 80, 0) then snapOnly() end
	ImGui.EndDisabled(ctx)
	infoMarker("Doesn't move anything by frames: only rounds each video's start offset to its nearest whole frame "
		.. "(of the video, not the project). Audio is left alone.")
	ImGui.SameLine(ctx)
	if ImGui.Button(ctx, "Close", 80, 0) then state.close = true end
	if state.status then
		ImGui.TextColored(ctx, state.statusColor, state.status)
	end
end

local function loop()
	ImGui.SetNextWindowSize(ctx, 560, 520, ImGui.Cond_FirstUseEver)
	local visible, open = ImGui.Begin(ctx, SCRIPT_NAME, true, ImGui.WindowFlags_NoCollapse)
	if visible then
		drawUI()
		if ImGui.IsWindowFocused(ctx) and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then state.close = true end
		ImGui.End(ctx)
	end
	if open and not state.close then reaper.defer(loop) end
end

loadSettings()
reaper.atexit(saveSettings)
reaper.defer(loop)
