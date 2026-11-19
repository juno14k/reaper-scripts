-- @noindex
-- juno_MIDIExportHelper with a mocked REAPER project.
local H = dofile((debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or "") .. "helpers.lua")

local TPS = H.TPS
local ext, projExt, deferred = {}, {}, nil
local tracks, markers, guidN = {}, {}, 0
local scrolled = 0

local function newTrack(name, depth)
	guidN = guidN + 1
	return { name = name or "", ext = {}, depth = depth or 0, color = 0, spacer = 0, items = {}, guid = ("{T%04d}"):format(guidN) }
end
local function addItem(tr, it) it.track = tr; it.take.item = it; table.insert(tr.items, it); return it end
local function midiItem(tr, pos, len, notes, opts)
	opts = opts or {}
	return addItem(tr, { pos = pos, len = len, mute = 0, loop = opts.loop and 1 or 0, vol = 1,
		take = { midi = true, notes = notes, ccs = opts.ccs or {}, rate = 1, offs = 0, srcLenQN = opts.srcLenQN or 4, vol = 1, pitch = 0, ppitch = 1 } })
end
local function sampleItem(tr, pos, len, file, pitch, vol, opts)
	opts = opts or {}
	return addItem(tr, { pos = pos, len = len, mute = 0, loop = 0, vol = vol or 1,
		take = { midi = false, file = file, rate = opts.rate or 1, offs = opts.offs or 0, pitch = pitch or 0, ppitch = opts.ppitch or 1, vol = 1, env = opts.env } })
end
local function N(s, e, p, ch) return { s = s, e = e, p = p, ch = ch or 0, vel = 100 } end -- ticks

reaper = {
	ImGui_GetBuiltinPath = function() return "." end,
	GetExtState = function(s, k) return ext[s .. k] or "" end, SetExtState = function(s, k, v) ext[s .. k] = v end,
	GetProjExtState = function(_, s, k) return 1, projExt[s .. k] or "" end, SetProjExtState = function(_, s, k, v) projExt[s .. k] = v end,
	MB = function(m) print("MB: " .. m) end, ReaPack_BrowsePackages = function() end,
	GetProjectStateChangeCount = function() return math.random(1, 1e9) end,
	EnumProjectMarkers = function(i) local m = markers[i + 1]; if not m then return 0 end return i + 1, false, m.pos, 0, m.name, i end,
	GetProjectLength = function() return 10 end,
	format_timestr_pos = function(t) return ("0:%06.3f"):format(t) end,
	CountTracks = function() return #tracks end,
	GetTrack = function(_, i) return tracks[i + 1] end,
	GetTrackGUID = function(t) return t.guid end,
	CountSelectedTracks = function() local n = 0 for _, t in ipairs(tracks) do if t.selected then n = n + 1 end end return n end,
	GetSelectedTrack = function(_, i)
		local k = 0
		for _, t in ipairs(tracks) do
			if t.selected then if k == i then return t end k = k + 1 end
		end
	end,
	SetOnlyTrackSelected = function(t) for _, x in ipairs(tracks) do x.selected = false end t.selected = true end,
	SetTrackSelected = function(t, v) t.selected = v end,
	Main_OnCommand = function(id) if id == 40913 then scrolled = scrolled + 1 end end,
	GetMediaTrackInfo_Value = function(t, k)
		return ({ I_FOLDERDEPTH = t.depth, I_CUSTOMCOLOR = t.color, I_SPACER = t.spacer })[k]
	end,
	SetMediaTrackInfo_Value = function(t, k, v)
		if k == "I_FOLDERDEPTH" then t.depth = v elseif k == "I_CUSTOMCOLOR" then t.color = v elseif k == "I_SPACER" then t.spacer = v end
	end,
	GetSetMediaTrackInfo_String = function(t, k, v, set)
		if k == "P_NAME" then if set then t.name = v end return true, t.name end
		if set then t.ext[k] = v end return true, t.ext[k] or ""
	end,
	InsertTrackAtIndex = function(i) table.insert(tracks, i + 1, newTrack()) end,
	DeleteTrack = function(t) for i, x in ipairs(tracks) do if x == t then table.remove(tracks, i) return end end end,
	CountTrackMediaItems = function(t) return #t.items end,
	GetTrackMediaItem = function(t, i) return t.items[i + 1] end,
	GetActiveTake = function(it) return it.take end,
	TakeIsMIDI = function(tk) return tk.midi end,
	GetMediaItemInfo_Value = function(it, k)
		return ({ D_POSITION = it.pos, D_LENGTH = it.len, B_MUTE = it.mute, B_LOOPSRC = it.loop, D_VOL = it.vol })[k]
	end,
	GetMediaItemTakeInfo_Value = function(tk, k)
		return ({ D_PLAYRATE = tk.rate, D_PITCH = tk.pitch, B_PPITCH = tk.ppitch, D_VOL = tk.vol, D_STARTOFFS = tk.offs })[k]
	end,
	GetSetMediaItemTakeInfo_String = function(tk, _, v) tk.name = v; return true, v end,
	GetMediaItemTake_Source = function(tk) return tk end,
	GetMediaSourceParent = function() return nil end,
	GetMediaSourceFileName = function(src) return src.file or "" end,
	GetMediaSourceLength = function(src) return src.srcLenQN, true end,
	MIDI_GetPPQPosFromProjQN = function(_, qn) return qn * 960 end,
	MIDI_GetProjTimeFromPPQPos = function(tk, ppq) return tk.item.pos + ppq / TPS / tk.rate - tk.offs end,
	MIDI_GetPPQPosFromProjTime = function(tk, t) return (t - tk.item.pos + tk.offs) * TPS * tk.rate end,
	MIDI_GetHash = function(tk) return true, tostring(#tk.notes) end,
	MIDI_CountEvts = function(tk) return 1, #tk.notes, #tk.ccs, 0 end,
	MIDI_GetNote = function(tk, i) local n = tk.notes[i + 1]; return true, false, false, n.s, n.e, n.ch, n.p, n.vel end,
	MIDI_GetCC = function(tk, i) local c = tk.ccs[i + 1]; return true, false, false, c.ppq, c.chanmsg, 0, c.msg2, c.msg3 end,
	MIDI_InsertNote = function(tk, _, _, s, e, ch, p, v) table.insert(tk.notes, { s = s, e = e, ch = ch, p = p, vel = v }) end,
	MIDI_InsertCC = function(tk, _, _, ppq, cm, _, m2, m3) table.insert(tk.ccs, { ppq = ppq, chanmsg = cm, msg2 = m2, msg3 = m3 }) end,
	MIDI_InsertTextSysexEvt = function(tk, _, _, ppq, typ, str) tk.texts = tk.texts or {}; table.insert(tk.texts, { ppq = ppq, type = typ, text = str }) end,
	TrackFX_GetInstrument = function(t) return t.instrument and 0 or -1 end,
	TrackFX_GetFXName = function(t) return true, t.instrument or "" end,
	MIDI_Sort = function() end,
	CreateNewMIDIItemInProj = function(tr, s, e) return midiItem(tr, s, e - s, {}) end,
	GetTakeEnvelopeByName = function(tk) return tk.env end,
	CountEnvelopePoints = function(env) return #env end,
	GetEnvelopePoint = function(env, i) return true, env[i + 1][1], env[i + 1][2] end,
	GetEnvelopeStateChunk = function() return true, "<ENV\nACT 1\n>" end,
	GetEnvelopeScalingMode = function() return 0 end,
	Envelope_Evaluate = function(env, t)
		if t <= env[1][1] then return 0, env[1][2] end
		for i = 2, #env do
			local a, b = env[i - 1], env[i]
			if t <= b[1] then return 0, a[2] + (b[2] - a[2]) * (t - a[1]) / (b[1] - a[1]) end
		end
		return 0, env[#env][2]
	end,
	ColorFromNative = function(c) return c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF end,
	ColorToNative = function(r, g, b) return r | (g << 8) | (b << 16) end,
	Undo_BeginBlock = function() end, Undo_EndBlock = function() end, PreventUIRefresh = function() end,
	TrackList_AdjustWindows = function() end, UpdateArrange = function() end,
	defer = function(f) deferred = f end, atexit = function() end,
}
local ui = H.imgui()
local function frame(press, select) return H.frame(ui, function() return deferred end, press, select) end
local function names() local o = {} for i, t in ipairs(tracks) do o[i] = ("%s[%d]"):format(t.name, t.depth) end return table.concat(o, " | ") end
local function find(name) for _, t in ipairs(tracks) do if t.name == name then return t end end error("no track " .. name .. "\n" .. names()) end
local function notesOf(name) local t = find(name); return t.items[1] and t.items[1].take.notes or {} end

---------------------------------------------------------------------------------------------------------------------
-- Project: =START at 1 s, =END at 6 s
---------------------------------------------------------------------------------------------------------------------
markers = { { pos = 1.0, name = "=START" }, { pos = 6.0, name = "=END" } }

local band = newTrack("Band", 1) -- folder with no items: shown as context only
local piano = newTrack("Piano", -1)
-- a note before =START (clipped), a C-E-G chord, a melody note; sustain set before =START
midiItem(piano, 0, 3, { N(0, 1920 * 1.5, 72), N(1920, 3840, 60), N(1920, 3840, 64), N(1920, 3840, 67), N(3840, 4800, 62) },
	{ ccs = { { ppq = 0, chanmsg = 0xB0, msg2 = 64, msg3 = 127 }, { ppq = 2000, chanmsg = 0xB0, msg2 = 7, msg3 = 90 } } })
-- looped 2-QN (1 s) source, item 3..5 s -> the note plays at 3 and 4 s
midiItem(piano, 3, 2, { N(0, 960, 50) }, { loop = true, srcLenQN = 2 })
midiItem(piano, 5, 1, { N(0, 960, 70) }).mute = 1 -- muted: skipped, with a warning
piano.instrument = "VSTi: Pianoteq 8 (Modartt)"

local voice = newTrack("") -- unnamed: named after its sample file
sampleItem(voice, 1.0, 0.5, "C:/v/voice.mp4", 0, 1.0)
sampleItem(voice, 2.0, 0.5, "C:/v/voice.mp4", 3, 0.5)
sampleItem(voice, 3.0, 0.5, "C:/v/voice.mp4", -2.4, 0.25, { env = { { 0, 0 }, { 0.4, 13 } } }) -- slide to +13 -> bend +/-24
sampleItem(voice, 4.0, 0.5, "C:/v/voice.mp4", 0, 1.0, { rate = 2, ppitch = 0 }) -- rate 2 without preserve pitch = +12
sampleItem(voice, 4.2, 0.5, "C:/v/voice.mp4", 0, 1.0, { offs = 0.005 }) -- same sample (within 20 ms)

local drums = newTrack("Drums")
drums.color = 0x00FF00 | 0x1000000
sampleItem(drums, 1.0, 0.1, "C:/d/kick.wav", 0, 1)
sampleItem(drums, 1.5, 0.1, "C:/d/snare.wav", 0, 1)

local chops = newTrack("Chops")
sampleItem(chops, 1.0, 0.3, "C:/c/chop.mp4", 0, 1, { offs = 0 })
sampleItem(chops, 2.0, 0.3, "C:/c/chop.mp4", 5, 1, { offs = 2.5 })

local beat = newTrack("Beat") -- channel 10: detected as drums
midiItem(beat, 1, 2, { N(0, 100, 36, 9), N(960, 1060, 38, 9), N(1920, 2020, 36, 9), N(1920, 2020, 42, 9) })

tracks = { band, piano, voice, drums, chops, beat }
local originals = { band, piano, voice, drums, chops, beat }

---------------------------------------------------------------------------------------------------------------------
dofile(H.REPO .. "MIDI/juno_MIDIExportHelper.lua")
local text = frame()
assert(text:find("Band") and text:find("%(folder%)"), "folder parent shown")
H.ok("folder parent shown in the list")

-- clicking a row selects the track in REAPER; selecting in REAPER shows its voice settings
frame(nil, "Piano")
assert(piano.selected and scrolled == 1, "row click selects the track in REAPER")
text = frame()
assert(text:find("Piano: Voice leading"),"voice settings of the selected track:\n" .. text)
piano.selected, beat.selected = false, true
text = frame()
assert(text:find("Drums") and text:find("one track per note"), "selection from REAPER followed")
H.ok("selection sync both ways")

-- Warnings column: Piano has a muted item and a note cut at =START; voice has a pitch between two notes
text = frame()
assert(text:find("%[! 2 warnings%]") and text:find("%[! 1 warning%]"), "warnings column:\n" .. text)
H.ok("warnings column")

-- Faster selection (row ids: 1 Band, 2 Piano, 3 voice, 4 Drums, 5 Chops, 6 Beat)
local function ticked()
	local o = {}
	for _, t in ipairs(originals) do
		if projExt["juno_MIDIExportHelper" .. t.guid .. "_sel"] == "1" then o[#o + 1] = t.name ~= "" and t.name or "voice" end
	end
	return table.concat(o, ",")
end
frame("MIDI tracks")
assert(ticked() == "Piano,Beat", ticked())
frame("None"); frame("Sample tracks")
assert(ticked() == "voice,Drums,Chops", ticked())
frame("None")
frame("None")

-- Multi-selection like a file list, in sync with REAPER (row ids: 1 Band, 2 Piano, 3 voice, 4 Drums, 5 Chops, 6 Beat)
local function selectedNames()
	local o = {}
	for _, t in ipairs(originals) do if t.selected then o[#o + 1] = t.name ~= "" and t.name or "voice" end end
	return table.concat(o, ",")
end
frame(nil, "voice")
ui.mods = ui.SHIFT; frame(nil, "Chops"); ui.mods = 0
assert(selectedNames() == "voice,Drums,Chops", "shift-click range: " .. selectedNames())
ui.mods = ui.CTRL; frame(nil, "Drums"); ui.mods = 0
assert(selectedNames() == "voice,Chops", "ctrl-click toggles: " .. selectedNames())
ui.toggle = "3/##sel"; frame()
assert(ticked() == "voice,Chops", "ticking a selected row ticks the whole selection: " .. ticked())
ui.toggle = "4/##sel"; frame()
assert(ticked() == "voice,Drums,Chops", "ticking an unselected row ticks only it: " .. ticked())
frame("None")
H.ok("multi-selection (click, shift, ctrl) synced with REAPER; ticking applies to the selection")
ui.inputs["##filter"] = "dru"; frame()
frame("All")
assert(ticked() == "Drums", "filter + All: " .. ticked())
ui.inputs["##filter"] = ""; frame()
H.ok("tick buttons, filter")

frame("All")
frame("Export")
print("    " .. names())

-- originals untouched (except the spacer on the first one)
for _, t in ipairs(originals) do assert(next(t.ext) == nil, "original tagged!") end
assert(#piano.items == 3 and piano.name == "Piano" and voice.name == "" and piano.depth == -1 and band.depth == 1)
assert(band.spacer == 1, "spacer above the first original track")
for _, t in ipairs(tracks) do assert(t.ext["P_EXT:juno_MIDIExport"] ~= "separator", "no separator track") end
H.ok("originals untouched, spacer instead of a separator track")

-- MIDI: folder with the full MIDI + voices
local full = notesOf("MIDI: Piano")
assert(#full == 7, "full MIDI notes: " .. #full)
assert(find("MIDI: Piano").depth == 1, "piano folder")
local ccs = find("MIDI: Piano").items[1].take.ccs
assert(#ccs == 2 and ccs[1].ppq == 0, "sustain set before =START carried to the start")
H.ok("MIDI folder: full MIDI + voices")

-- MIDI drums (channel 10): one track per note, GM names
assert(find("MIDI: Beat").depth == 1)
assert(#notesOf("MIDI: Beat 1 (C2 Kick)") == 2 and #notesOf("MIDI: Beat 2 (D2 Snare)") == 1)
assert(find("MIDI: Beat 3 (F#2 Closed Hi-Hat)").depth == -1)
H.ok("drum track detected and split per note")

-- Samples on one unnamed track
local vn = find("MIDI: voice").items[1].take.notes
table.sort(vn, function(a, b) return a.s < b.s end)
local pitches, vels = {}, {}
for i, n in ipairs(vn) do pitches[i] = n.p; vels[i] = n.vel end
assert(table.concat(pitches, ",") == "60,63,58,72,60", table.concat(pitches, ","))
assert(vels[1] == 127 and vels[3] == 1, "quietest 1, loudest 127")
local bends, rpn = 0, nil
for _, c in ipairs(find("MIDI: voice").items[1].take.ccs) do
	if c.chanmsg == 0xE0 then bends = bends + 1 elseif c.msg2 == 6 then rpn = c.msg3 end
end
assert(rpn == 24 and bends > 10, "bend range 24")
H.ok("samples: pitch, velocity, slide as pitch bend")

assert(find("MIDI: Drums").depth == 1 and find("MIDI: Drums 2 (snare.wav)").depth == -1)
assert(notesOf("MIDI: Drums 1 (kick.wav)")[1].p == 60)
find("MIDI: Chops 1 (chop.mp4 @ 0.000)")
assert(notesOf("MIDI: Chops 2 (chop.mp4 @ 2.500)")[1].p == 65)
H.ok("sample folders (different files, parts of one file)")

-- Text event at the start of each track: instrument (MIDI) or source file(s) (samples)
local function firstText(name) local tk = find(name).items[1].take; return tk.texts and tk.texts[1] end
assert(firstText("MIDI: Piano").text == "Instrument: VSTi: Pianoteq 8 (Modartt)" and firstText("MIDI: Piano").type == 1)
assert(firstText("MIDI: Piano 2").text == "Instrument: VSTi: Pianoteq 8 (Modartt)")
assert(firstText("MIDI: Drums 1 (kick.wav)").text == "Source: kick.wav")
assert(firstText("MIDI: voice").text == "Source: voice.mp4")
assert(firstText("MIDI: Beat") == nil, "no instrument, no text")
H.ok("text events: instrument / source file")

-- per-track voice settings: 2 voices with overflow on the nearest one
projExt["juno_MIDIExportHelper" .. piano.guid .. "_split"] = "voiceCount=2,overflow=1"
local count = #tracks
frame()
frame("Export")
assert(ui.popup, "confirm popup")
frame("Replace")
assert(find("MIDI: Piano 2").depth == -1 and not pcall(find, "MIDI: Piano 3"), "2 voices now")
assert(#tracks == count - 2, "replaced (2 voices fewer)")
H.ok("voice settings per track + replace")

count = #tracks
frame("Export"); frame("Create new copies")
assert(#tracks == count + (count - #originals), "copies added")
H.ok("create new copies")

-- Remove all exports: only the originals are left, and the spacer the script added is gone
frame("Remove all exports")
assert(ui.popup, "remove confirmation")
frame("Remove")
assert(#tracks == #originals, "only originals left: " .. names())
assert(band.spacer == 0, "spacer removed")
for i, t in ipairs(originals) do assert(tracks[i] == t) end
H.ok("remove all exports")

-- Split mode and voice settings changed on a selected row apply to every selected track
local function ps(t, key) return projExt["juno_MIDIExportHelper" .. t.guid .. key] end
frame(nil, "Piano"); ui.mods = ui.CTRL; frame(nil, "Beat"); ui.mods = 0
ui.click = "2/m4"; frame() -- "Don't split" on Piano's row
assert(ps(piano, "_midi") == "4" and ps(beat, "_midi") == "4", "split mode applied to the selection")
assert(ps(drums, "_midi") == nil, "unselected track untouched")
ui.click = "2/m1"; frame() -- Voice leading
ui.inputs["Chord tolerance"] = 55; frame()
assert(ps(piano, "_split"):find("chordTolMs=55") and ps(beat, "_split"):find("chordTolMs=55"), "voice settings applied to the selection")
H.ok("split mode and voice settings apply to the selection")

-- Drum detection: drum words in the track name, the folders above it, or the instrument; else channel 10
local L = dofile(H.REPO .. "MIDI/juno_MIDIExportHelper/lib.lua")
assert(L.DrumWord("Kick In") == "kick" and L.DrumWord("HiHat") == "hihat" and L.DrumWord("Hi-Hat") == "hat")
assert(L.DrumWord("EZdrummer 3") == "drum" and L.DrumWord("Toms") == "toms" and L.DrumWord("HH open") == "hh")
assert(L.DrumWord("Custom Pad") == nil and L.DrumWord("Bottom") == nil and L.DrumWord("Piano") == nil, "no false positives")
local yes, why = L.LooksLikeDrums({ name = "Synth", folders = { "Band", "Drums" } }, {})
assert(yes and why:find("Drums"), "folder name")
yes, why = L.LooksLikeDrums({ name = "Track 3", folders = {} }, {}, "VSTi: Addictive Drums 2 (XLN Audio)")
assert(yes and why:find("instrument"), "instrument name")
assert(not L.LooksLikeDrums({ name = "Strings", folders = { "Orchestra" } }, { { chan = 0 } }, "VSTi: Kontakt 7"))
H.ok("drum detection: names, folders, instrument, channel 10")
