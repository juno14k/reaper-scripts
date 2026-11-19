-- @noindex
--[[
  juno_FrameShift - shared helpers.

  Shifting = changing the take start offset (D_STARTOFFS, in source seconds), so the item stays where it is
  on the timeline but its content moves. A timeline amount T becomes T * playrate in source time.
--]]

local L = {}

local FPS_CACHE = "juno_FrameShift_fps" -- session-only ExtState section: file -> fps
local AUDIO_FALLBACK_FPS = 60

L.AUDIO_FALLBACK_FPS = AUDIO_FALLBACK_FPS

-----------------------------------------------------------------------------------------------------------------------
-- FPS detection
-----------------------------------------------------------------------------------------------------------------------

function L.ProjectFPS()
	local fps = reaper.TimeMap_curFrameRate(0)
	if not fps or fps <= 0 then fps = 30 end
	return fps
end

local function fileExists(path)
	local f = io.open(path, "rb")
	if f then f:close() return true end
	return false
end

local ffprobePath
local function findFFprobe()
	if ffprobePath ~= nil then return ffprobePath end
	local isWin = reaper.GetOS():find("Win") ~= nil
	local exe = isWin and "ffprobe.exe" or "ffprobe"
	local candidates = {
		reaper.GetResourcePath() .. "/UserPlugins/" .. exe,
		reaper.GetExePath() .. "/" .. exe,
	}
	if not isWin then
		candidates[#candidates + 1] = "/opt/homebrew/bin/ffprobe"
		candidates[#candidates + 1] = "/usr/local/bin/ffprobe"
		candidates[#candidates + 1] = "/usr/bin/ffprobe"
	end
	for _, c in ipairs(candidates) do
		if fileExists(c) then ffprobePath = c return c end
	end
	ffprobePath = exe -- last resort: rely on PATH
	return ffprobePath
end

local function parseRate(str)
	local n, d = str:match("(%d+)/(%d+)")
	n, d = tonumber(n), tonumber(d)
	if n and d and n > 0 and d > 0 then return n / d end
	return nil
end

--- Frame rate of a video file through ffprobe (cached for the REAPER session). nil if unknown.
function L.FileFPS(file)
	local cached = reaper.GetExtState(FPS_CACHE, file)
	if cached ~= "" then
		local v = tonumber(cached)
		return (v and v > 0) and v or nil
	end
	local cmd = ('"%s" -v error -select_streams v:0 -show_entries stream=avg_frame_rate,r_frame_rate -of default=noprint_wrappers=1 "%s"')
		:format(findFFprobe(), file)
	local out = reaper.ExecProcess(cmd, 5000) or ""
	local fps = parseRate(out:match("avg_frame_rate=([%d/]+)") or "") or parseRate(out:match("r_frame_rate=([%d/]+)") or "")
	reaper.SetExtState(FPS_CACHE, file, tostring(fps or 0), false)
	return fps
end

local function rootSource(src)
	while true do
		local parent = reaper.GetMediaSourceParent(src)
		if not parent then return src end
		src = parent
	end
end

-----------------------------------------------------------------------------------------------------------------------
-- Selection
-----------------------------------------------------------------------------------------------------------------------

--- Selected items with an active take:
--- { item, take, name, isVideo, fps (video only), fpsDetected (bool), rate, offs }
function L.Collect()
	local list, projFps = {}, nil
	for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
		local item = reaper.GetSelectedMediaItem(0, i)
		local take = reaper.GetActiveTake(item)
		if take then
			local src = rootSource(reaper.GetMediaItemTake_Source(take))
			local srcType = reaper.GetMediaSourceType(src, "")
			local e = {
				item = item,
				take = take,
				name = reaper.GetTakeName(take),
				isVideo = (srcType == "VIDEO"),
				rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
				offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
			}
			if e.rate <= 0 then e.rate = 1 end
			if e.isVideo then
				local file = reaper.GetMediaSourceFileName(src, "")
				e.fps = (file ~= "") and L.FileFPS(file) or nil
				e.fpsDetected = e.fps ~= nil
				if not e.fps then
					projFps = projFps or L.ProjectFPS()
					e.fps = projFps
				end
			end
			list[#list + 1] = e
		end
	end
	return list
end

--- Distinct video frame rates (rounded to 0.001), sorted.
function L.DistinctFPS(entries)
	local seen, out = {}, {}
	for _, e in ipairs(entries) do
		if e.isVideo then
			local k = math.floor(e.fps * 1000 + 0.5) / 1000
			if not seen[k] then seen[k] = true; out[#out + 1] = k end
		end
	end
	table.sort(out)
	return out
end

function L.FormatFPS(fps)
	local s = ("%.3f"):format(fps):gsub("0+$", ""):gsub("%.$", "")
	return s
end

-----------------------------------------------------------------------------------------------------------------------
-- Applying
-----------------------------------------------------------------------------------------------------------------------

--- Sets the start offset (source seconds). Optionally snaps video offsets to a whole source frame.
function L.SetOffset(e, offs, snapFrame)
	if snapFrame and e.isVideo then
		offs = math.floor(offs * e.fps + 0.5) / e.fps
	end
	reaper.SetMediaItemTakeInfo_Value(e.take, "D_STARTOFFS", offs)
	e.offs = offs
end

--- Moves the item position onto the project frame grid.
function L.SnapPosition(e)
	local fps = L.ProjectFPS()
	local pos = reaper.GetMediaItemInfo_Value(e.item, "D_POSITION")
	reaper.SetMediaItemInfo_Value(e.item, "D_POSITION", math.floor(pos * fps + 0.5) / fps)
end

--- Snaps the start offset of every video to its nearest whole frame (of the video itself, not the project).
--- Audio is left alone. Returns the number of videos and how many of them actually moved.
function L.SnapOffsets(entries)
	local videos, moved = 0, 0
	for _, e in ipairs(entries) do
		if e.isVideo then
			videos = videos + 1
			local before = e.offs
			L.SetOffset(e, e.offs, true)
			if math.abs(e.offs - before) > 1e-9 then
				moved = moved + 1
				reaper.UpdateItemInProject(e.item)
			end
		end
	end
	return videos, moved
end

--- Keymap behaviour for juno_FrameSnap.
function L.KeymapSnap(title)
	local entries = L.Collect()
	reaper.Undo_BeginBlock()
	reaper.PreventUIRefresh(1)
	local videos = L.SnapOffsets(entries)
	reaper.PreventUIRefresh(-1)
	reaper.UpdateArrange()
	reaper.Undo_EndBlock(title, 4)
	if videos == 0 and #entries > 0 then
		reaper.MB("None of the selected items is a video: nothing to snap.", title, 0)
	end
end

--- Keymap behaviour: every video moves by one of its own frames; audio follows the videos' timeline shift.
--- If the videos disagree (different FPS or playrate), audio moves by 1/60 s and a message is shown.
function L.KeymapShift(dir, title)
	local entries = L.Collect()
	if #entries == 0 then return end

	local videoShift, mixed = nil, false -- timeline seconds
	for _, e in ipairs(entries) do
		if e.isVideo then
			local s = 1 / (e.fps * e.rate)
			if videoShift and math.abs(s - videoShift) > 1e-9 then mixed = true end
			videoShift = videoShift or s
		end
	end
	local audioShift = (videoShift and not mixed) and videoShift or (1 / AUDIO_FALLBACK_FPS)

	reaper.Undo_BeginBlock()
	reaper.PreventUIRefresh(1)
	for _, e in ipairs(entries) do
		local delta = e.isVideo and (1 / e.fps) or (audioShift * e.rate)
		L.SetOffset(e, e.offs + dir * delta, false)
		reaper.UpdateItemInProject(e.item)
	end
	reaper.PreventUIRefresh(-1)
	reaper.UpdateArrange()
	reaper.Undo_EndBlock(title, 4)

	if mixed then
		local list = {}
		for _, f in ipairs(L.DistinctFPS(entries)) do list[#list + 1] = L.FormatFPS(f) end
		reaper.MB(("The selected videos have different frame rates or playback rates (%s fps).\n\n"
			.. "Each video was moved by one of its own frames; audio was moved by 1/%d s.")
			:format(table.concat(list, ", "), AUDIO_FALLBACK_FPS), title, 0)
	end
end

return L
