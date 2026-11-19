-- @noindex
-- juno_FrameShift (UI), FrameShiftForward/Backward and FrameSnap with a mocked REAPER and a fake ffprobe.
local H = dofile((debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or "") .. "helpers.lua")
local approx = H.approx

local ext, deferred, mbs = {}, nil, {}
local FPS_OF = { ["v2997.mp4"] = "30000/1001", ["v24.mp4"] = "24/1" }

local items = {}
local function vid(file, rate, offs)
	local it = { sel = true, pos = 1.01, take = { type = "VIDEO", file = "C:/media/" .. file, rate = rate or 1, offs = offs or 0, name = file } }
	it.take.item = it
	return it
end
local function aud(rate, offs)
	local it = { sel = true, pos = 0, take = { type = "WAVE", file = "x.wav", rate = rate or 1, offs = offs or 0, name = "audio" } }
	it.take.item = it
	return it
end
local function sel() local o = {} for _, i in ipairs(items) do if i.sel then o[#o + 1] = i end end return o end

reaper = {
	ImGui_GetBuiltinPath = function() return "." end,
	GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
	SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
	MB = function(m) mbs[#mbs + 1] = m end,
	GetOS = function() return "Win64" end,
	GetResourcePath = function() return "C:/nowhere" end,
	GetExePath = function() return "C:/nowhere" end,
	ExecProcess = function(cmd) -- fake ffprobe
		for file, rate in pairs(FPS_OF) do
			if cmd:find(file, 1, true) then return "0\navg_frame_rate=" .. rate .. "\nr_frame_rate=" .. rate .. "\n" end
		end
		return "1\n"
	end,
	TimeMap_curFrameRate = function() return 25, false end,
	CountSelectedMediaItems = function() return #sel() end,
	GetSelectedMediaItem = function(_, i) return sel()[i + 1] end,
	GetActiveTake = function(it) return it.take end,
	GetMediaItemTake_Source = function(tk) return tk end,
	GetMediaSourceParent = function() return nil end,
	GetMediaSourceType = function(src) return src.type end,
	GetMediaSourceFileName = function(src) return src.file end,
	GetTakeName = function(tk) return tk.name end,
	GetMediaItemTakeInfo_Value = function(tk, k) if k == "D_PLAYRATE" then return tk.rate else return tk.offs end end,
	SetMediaItemTakeInfo_Value = function(tk, _, v) tk.offs = v end,
	GetMediaItemInfo_Value = function(it) return it.pos end,
	SetMediaItemInfo_Value = function(it, _, v) it.pos = v end,
	UpdateItemInProject = function() end, UpdateArrange = function() end, PreventUIRefresh = function() end,
	Undo_BeginBlock = function() end, Undo_EndBlock = function() end,
	GetProjectStateChangeCount = function() return math.random(1, 1e9) end,
	defer = function(f) deferred = f end, atexit = function() end,
}
local ui = H.imgui()
local function frame(press) return H.frame(ui, function() return deferred end, press) end
local ITEMS = H.REPO .. "Items/"

-- Keymap, single FPS (29.97); audio at rate 2 follows the video's timeline shift
items = { vid("v2997.mp4"), aud(2) }
dofile(ITEMS .. "juno_FrameShiftForward.lua")
approx(items[1].take.offs, 1001 / 30000, "video +1 frame")
approx(items[2].take.offs, 2 * 1001 / 30000, "audio follows (rate 2)")
assert(#mbs == 0)
dofile(ITEMS .. "juno_FrameShiftBackward.lua")
approx(items[1].take.offs, 0, "back to 0"); approx(items[2].take.offs, 0)
H.ok("keymap, one frame rate")

-- Keymap, mixed FPS: each video by its own frame, audio by 1/60, message shown
items = { vid("v2997.mp4"), vid("v24.mp4"), aud(1) }
dofile(ITEMS .. "juno_FrameShiftForward.lua")
approx(items[1].take.offs, 1001 / 30000); approx(items[2].take.offs, 1 / 24); approx(items[3].take.offs, 1 / 60)
assert(#mbs == 1, "mixed message shown")
H.ok("keymap, mixed frame rates")

-- UI: 3 frames with both snaps
items = { vid("v24.mp4", 1, 0.01), aud(1, 0) }
ext["juno_FrameShift/frames"] = "3"
ext["juno_FrameShift/snapOffset"] = "1"
ext["juno_FrameShift/snapPos"] = "1"
dofile(ITEMS .. "juno_FrameShift.lua")
frame(); frame("Forward")
approx(items[1].take.offs, 3 / 24, "0.01 + 3/24 = 3.24 frames, snapped to frame 3")
approx(items[2].take.offs, 3 / 24, "audio same amount")
approx(items[1].pos, 1.0, "position snapped to the 25 fps grid")
H.ok("UI frames + snapping")

-- UI: detected mode refuses mixed frame rates
items = { vid("v2997.mp4"), vid("v24.mp4") }
ext["juno_FrameShift/snapOffset"] = "0"; ext["juno_FrameShift/snapPos"] = "0"
dofile(ITEMS .. "juno_FrameShift.lua")
frame(); frame("Forward")
approx(items[1].take.offs, 0, "not moved")
H.ok("UI refuses mixed frame rates")

-- FrameSnap keymap + UI Snap button: offsets rounded to the video's own frame, audio untouched
items = { vid("v24.mp4", 1, 0.05), vid("v2997.mp4", 1, 0.05), aud(1, 0.05) }
dofile(ITEMS .. "juno_FrameSnap.lua")
approx(items[1].take.offs, 1 / 24, "24 fps: 1.2 frames -> 1")
approx(items[2].take.offs, 1001 / 30000, "29.97 fps: 1.4985 frames -> 1")
approx(items[3].take.offs, 0.05, "audio untouched")
items = { vid("v24.mp4", 1, 0.03) }
dofile(ITEMS .. "juno_FrameShift.lua")
frame(); frame("Snap")
approx(items[1].take.offs, 1 / 24, "UI snap: 0.72 frames -> 1")
H.ok("frame snap (keymap + UI button)")
