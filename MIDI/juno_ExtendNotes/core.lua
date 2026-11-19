-- @noindex
-- juno: Extend Notes - pure Lua core (no REAPER calls), so it can be tested on its own.

local Core = {}

Core.NEXT_ANY, Core.NEXT_PITCH, Core.NEXT_CHANNEL = 1, 2, 3 -- what counts as "the next note"
Core.OVERLAP_TRIM, Core.OVERLAP_KEEP = 1, 2                 -- notes already past the next note
Core.LAST_LEAVE, Core.LAST_ITEM_END = 1, 2                  -- notes with no next note

local function partitionKey(n, next)
	if next == Core.NEXT_PITCH then return n.pitch end
	if next == Core.NEXT_CHANNEL then return n.chan end
	return 0
end

-- First value in the sorted list `onsets` that is greater than `t` (nil if none).
local function firstAfter(onsets, t)
	local lo, hi = 1, #onsets
	while lo <= hi do
		local mid = (lo + hi) // 2
		if onsets[mid] > t then hi = mid - 1 else lo = mid + 1 end
	end
	return onsets[lo]
end

-- notes: array of { start, finish, pitch, chan, sel } in ticks.
-- opts:
--   selectionOnly   process only selected notes (all notes if none is selected)
--   countUnselected unselected notes also count as "the next note"
--   next, overlap, lastMode   see the constants above
--   tol             notes starting within `tol` ticks of each other count as one onset (chord)
--   endBefore(note, onset) -> tick where the note should end, given the next onset (applies the gap)
--   itemEnd         tick of the item end (for LAST_ITEM_END)
--   minLen          shortest allowed note, in ticks
-- Returns newEnd (index -> new end tick, only for notes that change) and stats.
function Core.Compute(notes, opts)
	local anySel = false
	for _, n in ipairs(notes) do if n.sel then anySel = true break end end
	local onlySel = opts.selectionOnly and anySel

	local onsets = {}
	for _, n in ipairs(notes) do
		if not onlySel or n.sel or opts.countUnselected then
			local k = partitionKey(n, opts.next)
			onsets[k] = onsets[k] or {}
			table.insert(onsets[k], n.start)
		end
	end
	for _, list in pairs(onsets) do table.sort(list) end

	local minLen = math.max(1, opts.minLen or 1)
	local newEnd = {}
	local stats = { processed = 0, longer = 0, shorter = 0, unchanged = 0 }
	for i, n in ipairs(notes) do
		if not onlySel or n.sel then
			stats.processed = stats.processed + 1
			local onset = firstAfter(onsets[partitionKey(n, opts.next)] or {}, n.start + (opts.tol or 0))
			local target
			if onset then
				target = opts.endBefore and opts.endBefore(n, onset) or onset
			elseif opts.lastMode == Core.LAST_ITEM_END and opts.itemEnd and opts.itemEnd > n.start then
				target = opts.itemEnd
			end
			if target then
				target = math.floor(math.max(target, n.start + minLen) + 0.5)
				if target < n.finish and opts.overlap == Core.OVERLAP_KEEP then target = nil end
			end
			if target and target ~= math.floor(n.finish + 0.5) then
				newEnd[i] = target
				if target > n.finish then stats.longer = stats.longer + 1 else stats.shorter = stats.shorter + 1 end
			else
				stats.unchanged = stats.unchanged + 1
			end
		end
	end
	return newEnd, stats
end

return Core
