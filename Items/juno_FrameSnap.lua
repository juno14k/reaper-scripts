-- @noindex
-- juno: Frame snap (no UI, for key maps).
-- Snaps the start offset of the selected videos to their nearest whole frame (frames of the video itself,
-- not the project grid). The items don't move on the timeline; audio items are left alone.

local dir = debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or ""
local L = dofile(dir .. "juno_FrameShift/lib.lua")
L.KeymapSnap("juno: Frame snap")
