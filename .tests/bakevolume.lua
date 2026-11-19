-- @noindex
-- juno_BakeVolume with a mocked REAPER.
local H = dofile((debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or "") .. "helpers.lua")
local approx = H.approx

local ext, deferred = {}, nil
local tracks, guidN = {}, 0
local function newFX(name) guidN = guidN + 1; return { name = name, guid = ("{%08d}"):format(guidN), vol = 0, enabled = true, offline = false } end
local function mkTrack(name, vol, fxs, envPts) return { name = name, vol = vol, fx = fxs or {}, ext = {}, sel = true, envPts = envPts or 0 } end
local added = {}

reaper = {
	ImGui_GetBuiltinPath = function() return "." end,
	GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
	SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
	MB = print,
	UpdateArrange = function() end, PreventUIRefresh = function() end,
	Undo_BeginBlock = function() end, Undo_EndBlock = function() end, TrackList_AdjustWindows = function() end,
	GetProjectStateChangeCount = function() return math.random(1, 1e9) end,
	defer = function(f) deferred = f end, atexit = function() end,
	CountSelectedTracks = function() local n = 0 for _, t in ipairs(tracks) do if t.sel then n = n + 1 end end return n end,
	GetSelectedTrack = function(_, i) local n = 0 for _, t in ipairs(tracks) do if t.sel then if n == i then return t end n = n + 1 end end end,
	GetTrackName = function(t) return true, t.name end,
	GetMediaTrackInfo_Value = function(t) return t.vol end,
	SetMediaTrackInfo_Value = function(t, _, v) t.vol = v end,
	GetSetMediaTrackInfo_String = function(t, k, v, set) if set then t.ext[k] = v; return true, v end return true, t.ext[k] or "" end,
	TrackFX_GetCount = function(t) return #t.fx end,
	TrackFX_GetFXGUID = function(t, i) return t.fx[i + 1].guid end,
	TrackFX_GetNumParams = function() return 3 end,
	TrackFX_GetParamName = function(_, _, p) return true, ({ "Volume (dB)", "Pan", "Pan Law (dB)" })[p + 1] end,
	TrackFX_GetParam = function(t, i) return t.fx[i + 1].vol, -60, 12 end,
	TrackFX_SetParam = function(t, i, _, v) t.fx[i + 1].vol = v end,
	TrackFX_GetEnabled = function(t, i) return t.fx[i + 1].enabled end,
	TrackFX_GetOffline = function(t, i) return t.fx[i + 1].offline end,
	TrackFX_GetFXName = function(t, i) return true, t.fx[i + 1].name end,
	-- REAPER 7.84: only the new JSFX exists, by file name
	TrackFX_AddByName = function(t, name)
		added[#added + 1] = name
		if name ~= "JS:utility/volume_pan_sample_accurate_auto" then return -1 end
		t.fx[#t.fx + 1] = newFX("JS: Volume/Pan Adjustment (Cockos)")
		return #t.fx - 1
	end,
	TrackFX_Delete = function(t, i) table.remove(t.fx, i + 1) end,
	TrackFX_SetNamedConfigParm = function(t, i, _, v) t.fx[i + 1].renamed = v end,
	GetTrackEnvelopeByName = function(t) return t.envPts > 0 and t or nil end,
	CountEnvelopePoints = function(t) return t.envPts end,
}
local ui = H.imgui()
local function frame(press) return H.frame(ui, function() return deferred end, press) end

local A = mkTrack("A", 10 ^ (-6 / 20), { newFX("ReaEQ") })
local B = mkTrack("B", 10 ^ (-80 / 20))
local C = mkTrack("C", 0.5, {}, 3)
local D = mkTrack("D", 0)
tracks = { A, B, C, D }
dofile(H.REPO .. "Tracks/juno_BakeVolume.lua")
frame(); frame("Bake")
approx(A.vol, 1, "A fader 0 dB"); approx(A.fx[2].vol, -6, "A baked -6"); assert(A.fx[2].renamed == "Baked volume")
assert(A.ext["P_EXT:juno_BakeVolume"] == A.fx[2].guid)
assert(#B.fx == 0 and #C.fx == 0 and #D.fx == 0, "B (out of range), C (envelope), D (-inf) skipped")
H.ok("bake (finds the REAPER 7 plugin by file name)")

A.vol = 10 ^ (-3 / 20)
frame("Bake")
assert(#A.fx == 2, "merged, no second plugin"); approx(A.fx[2].vol, -9, "merged -9"); approx(A.vol, 1)
H.ok("bake again merges into the same plugin")

A.fx[3] = newFX("Limiter")
frame("Revert")
assert(#A.fx == 3, "revert refused")
table.remove(A.fx, 3)
H.ok("revert refused with a plugin after the bake one")

A.vol = 10 ^ (2 / 20)
frame("Revert")
assert(#A.fx == 1 and A.fx[1].name == "ReaEQ"); approx(20 * math.log(A.vol, 10), -7, "fader = +2 - 9")
assert(A.ext["P_EXT:juno_BakeVolume"] == "")
H.ok("revert")
