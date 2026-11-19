-- @noindex
-- juno: Frame shift backward (no UI, for key maps).
-- Decreases the start offset of the selected items: videos by one of their own frames,
-- audio by the same timeline amount as the videos (1/60 s if the videos disagree).

local dir = debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or ""
local L = dofile(dir .. "juno_FrameShift/lib.lua")
L.KeymapShift(-1, "juno: Frame shift backward")
