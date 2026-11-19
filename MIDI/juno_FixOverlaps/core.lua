-- @noindex
-- juno: Fix Overlaps - pure Lua core (no REAPER calls), so it can be tested on its own.

local Core = {}

Core.OVERLAP_TRIM, Core.OVERLAP_MERGE = 1, 2

-- notes: array of { start, finish, pitch, chan, sel, vel } in ticks.
-- opts:
--   selectionOnly  work on the selected notes only (all notes if none is selected)
--   separateChans  notes on different channels never conflict
--   dupes, dupTol  remove duplicates: same pitch starting within dupTol ticks (keeps the longest, then loudest)
--   short, minLen  remove notes shorter than minLen ticks (zero-length notes included)
--   overlaps, overlapMode  fix same-pitch overlaps by trimming the earlier note or merging both into one
--   mono           also trim overlaps between different pitches (monophonic line)
-- Returns:
--   delete  set of note indices to delete
--   newEnd  index -> new end tick
--   kind    index -> "duplicate" | "short" | "overlap" | "merged" | "mono" (what happened to that note)
--   involved set of every note in a conflict, including the note that stays as it is
--   stats   { notes, duplicate, short, overlap, merged, mono }
function Core.Fix(notes, opts)
	local anySel = false
	for _, n in ipairs(notes) do if n.sel then anySel = true break end end
	local onlySel = opts.selectionOnly and anySel

	local delete, newEnd, kind, involved = {}, {}, {}, {}
	local stats = { notes = 0, duplicate = 0, short = 0, overlap = 0, merged = 0, mono = 0 }
	local function mark(i, k, partner)
		involved[i] = true
		if partner then involved[partner] = true end
		if not kind[i] then kind[i] = k; stats[k] = stats[k] + 1 end
	end
	local function finish(i) return newEnd[i] or notes[i].finish end

	local work = {}
	for i, n in ipairs(notes) do
		if not onlySel or n.sel then work[#work + 1] = i end
	end
	stats.notes = #work

	-- Groups of note indices by `keyOf`, each sorted by start, then longest first, then loudest first.
	local function groups(keyOf)
		local g, order = {}, {}
		for _, i in ipairs(work) do
			if not delete[i] then
				local k = keyOf(notes[i])
				if not g[k] then g[k] = {}; order[#order + 1] = k end
				table.insert(g[k], i)
			end
		end
		local out = {}
		for _, k in ipairs(order) do
			table.sort(g[k], function(a, b)
				local na, nb = notes[a], notes[b]
				if na.start ~= nb.start then return na.start < nb.start end
				local la, lb = na.finish - na.start, nb.finish - nb.start
				if la ~= lb then return la > lb end
				if (na.vel or 0) ~= (nb.vel or 0) then return (na.vel or 0) > (nb.vel or 0) end
				return a < b
			end)
			out[#out + 1] = g[k]
		end
		return out
	end
	local function chanKey(n) return opts.separateChans and n.chan or 0 end
	local function pitchKey(n) return chanKey(n) * 128 + n.pitch end

	-- 1. Duplicates
	if opts.dupes then
		local function better(a, b) -- longer, then louder
			local la, lb = notes[a].finish - notes[a].start, notes[b].finish - notes[b].start
			if la ~= lb then return la > lb end
			return (notes[a].vel or 0) > (notes[b].vel or 0)
		end
		for _, list in ipairs(groups(pitchKey)) do
			local k = 1
			while k <= #list do
				-- cluster = notes starting within dupTol of the cluster's first note
				local first, last = list[k], k
				while last < #list and notes[list[last + 1]].start - notes[first].start <= (opts.dupTol or 0) do
					last = last + 1
				end
				local keep = list[k]
				for j = k + 1, last do if better(list[j], keep) then keep = list[j] end end
				for j = k, last do
					if list[j] ~= keep then delete[list[j]] = true; mark(list[j], "duplicate", keep) end
				end
				k = last + 1
			end
		end
	end

	-- 2. Short notes
	if opts.short then
		for _, i in ipairs(work) do
			local n = notes[i]
			if not delete[i] and (n.finish - n.start < (opts.minLen or 0) or n.finish <= n.start) then
				delete[i] = true; mark(i, "short")
			end
		end
	end

	-- 3. Same-pitch overlaps
	if opts.overlaps then
		for _, list in ipairs(groups(pitchKey)) do
			local prev
			for _, i in ipairs(list) do
				local n = notes[i]
				if prev and finish(prev) > n.start and n.start > notes[prev].start then
					if opts.overlapMode == Core.OVERLAP_MERGE then
						newEnd[prev] = math.max(finish(prev), finish(i))
						delete[i] = true; mark(i, "merged", prev)
					else
						newEnd[prev] = n.start; mark(prev, "overlap", i)
						prev = i
					end
				elseif not prev or n.start > notes[prev].start then
					prev = i
				end
			end
		end
	end

	-- 4. Overlaps between different pitches (monophonic line). Notes starting together (chords) are left alone.
	if opts.mono then
		for _, list in ipairs(groups(chanKey)) do
			for idx = 1, #list - 1 do
				local a = list[idx]
				for j = idx + 1, #list do
					local b = list[j]
					if notes[b].start > notes[a].start then
						if finish(a) > notes[b].start then newEnd[a] = notes[b].start; mark(a, "mono", b) end
						break
					end
				end
			end
		end
	end

	for i in pairs(delete) do newEnd[i] = nil end
	for i, e in pairs(newEnd) do if e == notes[i].finish then newEnd[i] = nil end end
	return delete, newEnd, kind, stats, involved
end

return Core
