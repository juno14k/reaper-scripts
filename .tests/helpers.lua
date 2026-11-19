-- @noindex
-- Shared helpers for the mocked REAPER tests.
local H = {}

H.REPO = (debug.getinfo(1, "S").source:match("^@?(.*[\\/])%.tests[\\/]helpers%.lua$") or "./"):gsub("\\", "/")

function H.approx(a, b, msg)
	assert(math.abs(a - b) < 1e-6, (msg or "") .. ": " .. tostring(a) .. " vs " .. tostring(b))
end

function H.ok(msg) print("  ok  " .. msg) end

--- Installs a fake ReaImGui. Returns `ui`:
---   ui.press  = label prefix of the button pressed in the next frame
---   ui.select = label prefix of the selectable clicked in the next frame
---   ui.show   = print the texts drawn
---   ui.popup  = whether a popup is open
---   ui.toggle = id ("<PushID path>/<label>") of the checkbox clicked in the next frame
---   ui.click  = id of the InvisibleButton clicked in the next frame
---   ui.mods   = key modifiers held (ui.SHIFT)
---   ui.inputs = { [label] = text typed into that text field }
function H.imgui(extra)
	local ui = { press = nil, select = nil, show = false, popup = false, texts = {}, mods = 0, inputs = {}, SHIFT = 1, CTRL = 2 }
	local ids = {}
	local function id(label) return table.concat(ids, "/") .. "/" .. label end
	local function out(t) ui.texts[#ui.texts + 1] = t; if ui.show then print("    | " .. t) end end
	local function starts(l, p) return p ~= nil and l:find(p, 1, true) == 1 end
	local Im = {
		CreateContext = function() return {} end,
		Begin = function() return true, true end,
		Combo = function(_, _, c) return false, c end,
		Checkbox = function(_, l, v) if ui.toggle == id(l) then return true, not v end return false, v end,
		PushID = function(_, s) ids[#ids + 1] = s end,
		PopID = function() ids[#ids] = nil end,
		GetKeyMods = function() return ui.mods end,
		Mod_Shift = ui.SHIFT,
		Mod_Ctrl = ui.CTRL,
		InputTextWithHint = function(_, l, _, v) if ui.inputs[l] then return true, ui.inputs[l] end return false, v end,
		InputInt = function(_, _, v) return false, v end,
		InputDouble = function(_, _, v) return false, v end,
		SliderInt = function(_, l, v) if ui.inputs[l] ~= nil then return true, ui.inputs[l] end return false, v end,
		SliderDouble = function(_, _, v) return false, v end,
		BeginTable = function() return true end,
		BeginChild = function() return true end,
		BeginTooltip = function() return false end,
		IsItemHovered = function() return false end,
		IsWindowFocused = function() return false end,
		GetFontSize = function() return 13 end,
		GetTextLineHeight = function() return 13 end,
		GetFrameHeightWithSpacing = function() return 20 end,
		GetCursorScreenPos = function() return 0, 0 end,
		GetWindowPos = function() return 0, 0 end,
		GetWindowWidth = function() return 800 end,
		GetWindowHeight = function() return 600 end,
		GetStyleColor = function() return 0x4296FAFF end,
		GetCursorPosX = function() return 0 end,
		ColorConvertHSVtoRGB = function() return 1, 1, 1 end,
		ColorConvertRGBtoHSV = function() return 0, 0, 0 end,
		ColorConvertDouble4ToU32 = function() return 0 end,
		GetVersion = function() return "1.92.1", 19210, "0.10.0.5" end,
		OpenPopup = function() ui.popup = true end,
		BeginPopupModal = function() return ui.popup end,
		CloseCurrentPopup = function() ui.popup = false end,
		Button = function(_, l) return starts(l, ui.press) end,
		Selectable = function(_, l) out(l); return starts(l, ui.select) end,
		InvisibleButton = function(_, l) return ui.click == id(l) end,
		Text = function(_, t) out(t) end,
		BulletText = function(_, t) out("- " .. t) end,
		TextColored = function(_, _, t) out("[" .. t .. "]") end,
		TextDisabled = function(_, t) out("(" .. t .. ")") end,
	}
	for k, v in pairs(extra or {}) do Im[k] = v end

	-- Dear ImGui rule (asserts in REAPER): after SetCursorPos*/SetCursorScreenPos an item must be submitted
	-- before the row/cell/window ends. Moving the cursor marks it pending; submitting an item clears it.
	local pending = false
	local function moved() pending = true end
	local function check(name) assert(not pending, name .. ": cursor moved with SetCursorPos and no item submitted after it") end
	for _, f in ipairs({ "SetCursorPosX", "SetCursorPosY", "SetCursorPos", "SetCursorScreenPos" }) do Im[f] = moved end
	for _, f in ipairs({ "Checkbox", "Selectable", "Button", "InvisibleButton", "Text", "TextColored", "TextDisabled",
		"BulletText", "Dummy", "Combo", "SliderInt", "SliderDouble", "InputInt", "InputDouble", "InputTextWithHint" }) do
		local real = Im[f] or function() end
		Im[f] = function(...) pending = false; return real(...) end
	end
	for _, f in ipairs({ "TableNextRow", "TableSetColumnIndex", "EndTable", "End", "EndChild" }) do
		Im[f] = function() check(f) end
	end

	setmetatable(Im, { __index = function(_, k)
		if k:match("^%u%w*_") and not k:match("^DrawList_") then return 0 end -- constants (Col_Text...)
		return function() end
	end })
	package.loaded.imgui = function() return Im end
	return ui
end

--- Fake REAPER for scripts that edit one MIDI take open in the MIDI editor (960 ppq, 120 bpm, item at 0..4 s).
--- s = { take = { name, notes = { {s, e, p, sel, ch, vel} } }, ext = {} }; sets s.deferred.
H.TPS = 1920 -- ticks per second
function H.midiEditorReaper(s)
	local take = s.take
	take.item = take.item or {}
	return {
		ImGui_GetBuiltinPath = function() return "." end,
		GetExtState = function(sec, k) return s.ext[sec .. k] or "" end,
		SetExtState = function(sec, k, v) s.ext[sec .. k] = v end,
		MB = print, MIDIEditor_GetActive = function() return {} end, MIDIEditor_GetTake = function() return take end,
		ValidatePtr2 = function() return true end, GetTakeName = function(t) return t.name end,
		GetMediaItemTake_Item = function(t) return t.item end, GetMediaItem_Track = function() return {} end,
		GetMediaItemInfo_Value = function(_, k) return k == "D_POSITION" and 0 or 4 end,
		MIDI_GetPPQPosFromProjTime = function(_, t) return t * H.TPS end,
		MIDI_GetProjTimeFromPPQPos = function(_, p) return p / H.TPS end,
		MIDI_CountEvts = function(t) return 1, #t.notes, 0, 0 end,
		MIDI_GetNote = function(t, i) local n = t.notes[i + 1]; return true, n.sel or false, false, n.s, n.e, n.ch or 0, n.p, n.vel or 100 end,
		MIDI_SetNote = function(t, i, sel, _, _, e)
			local n = t.notes[i + 1]
			if sel ~= nil then n.sel = sel end
			if e then n.e = e end
		end,
		MIDI_DeleteNote = function(t, i) table.remove(t.notes, i + 1) end,
		MIDI_Sort = function() end, MIDI_GetHash = function() return true, tostring(math.random()) end,
		MarkTrackItemsDirty = function() end, Undo_BeginBlock2 = function() end, Undo_EndBlock2 = function() end,
		PreventUIRefresh = function() end, UpdateArrange = function() end, GetProjectStateChangeCount = function() return 1 end,
		defer = function(f) s.deferred = f end, atexit = function() end,
	}
end

--- Runs one frame of the script's defer loop, optionally pressing a button / clicking a selectable.
function H.frame(ui, getDeferred, press, select)
	ui.press, ui.select, ui.texts = press, select, {}
	getDeferred()()
	ui.press, ui.select, ui.toggle, ui.click, ui.inputs = nil, nil, nil, nil, {}
	return table.concat(ui.texts, "\n")
end

return H
