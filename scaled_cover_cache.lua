-- scaled_cover_cache.lua
-- LRU of upscaled cover bbs for the small-cover branch in spine_widget.
--
-- Why this exists: BookInfoManager only DOWNSCALES when caching a cover
-- (see plugins/coverbrowser.koplugin/bookinfomanager.lua:536) — publisher
-- thumbnails smaller than its target are stored at native size. When such
-- a cover lands in our shelf slot, spine_widget calls bb:scale() (Lua
-- nearest-neighbour) to fill the slot — the only Kindle-safe upscale path,
-- but a ~111k pixel-op pass per render. Without caching, every chip switch
-- and page flip that keeps the same small-cover book on screen redoes the
-- scale from scratch.
--
-- Cache key includes target dimensions so the rare case where the same
-- bb is rendered into different-sized slots (e.g. hero vs shelf) doesn't
-- collide. Capacity caps RSS at ~capacity × img_w × img_h × bpp.
--
-- Lifetime: the cache OWNS each scaled bb. Callers should pass it to
-- ImageWidget with image_disposable = false. The cache frees evicted bbs
-- via bb:free() (FFI finalizer cleared, memory released immediately).
--
-- Invalidation: none required during a session — BookInfoManager only
-- re-extracts thumbnails on user-initiated metadata refresh, which is
-- out-of-band. clear() exists for plugin teardown.

local ScaledCoverCache = {
    _capacity = 16,    -- ~1.7 MiB at 271×410×4 bytes
    _cache    = {},    -- string key → bb
    _order    = {},    -- list of keys, oldest at front, MRU at back
}

local function key_for(filepath, w, h)
    return filepath .. ":" .. w .. "x" .. h
end

function ScaledCoverCache:_removeKey(key)
    for i, k in ipairs(self._order) do
        if k == key then
            table.remove(self._order, i)
            return
        end
    end
end

function ScaledCoverCache:_evictIfNeeded()
    while #self._order > self._capacity do
        local key = table.remove(self._order, 1)
        local bb  = self._cache[key]
        self._cache[key] = nil
        if bb and bb.free then pcall(function() bb:free() end) end
    end
end

-- get(filepath, w, h) — returns the cached scaled bb or nil. On hit, the
-- entry is promoted to MRU so it survives further eviction.
function ScaledCoverCache:get(filepath, w, h)
    if not filepath or filepath == "" then return nil end
    local key = key_for(filepath, w, h)
    local bb  = self._cache[key]
    if not bb then return nil end
    self:_removeKey(key)
    self._order[#self._order + 1] = key
    return bb
end

-- put(filepath, w, h, bb) — inserts or replaces. The cache takes ownership
-- of `bb`: callers must NOT free it (and should pass image_disposable=false
-- to ImageWidget). If a previous bb was cached at the same key, it's
-- freed before the new one replaces it.
function ScaledCoverCache:put(filepath, w, h, bb)
    if not filepath or filepath == "" then return end
    local key = key_for(filepath, w, h)
    local existing = self._cache[key]
    if existing and existing ~= bb and existing.free then
        pcall(function() existing:free() end)
        self:_removeKey(key)
    end
    self._cache[key] = bb
    self._order[#self._order + 1] = key
    self:_evictIfNeeded()
end

-- clear — drop everything. Call from plugin teardown if you want the
-- session's cache memory back before KOReader exits.
function ScaledCoverCache:clear()
    for _, bb in pairs(self._cache) do
        if bb and bb.free then pcall(function() bb:free() end) end
    end
    self._cache = {}
    self._order = {}
end

return ScaledCoverCache
