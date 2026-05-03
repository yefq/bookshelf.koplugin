-- cover_loader.lua
-- Lazy single-slot loader for HIGH-RESOLUTION cover bbs.
--
-- Why this exists: BookInfoManager caches a downscaled THUMBNAIL (sized
-- for the largest shelf cell that ever indexed the file). Painting that
-- thumbnail at hero size requires an UPSCALE in RenderImage:scaleBlitBuffer,
-- which corrupts on Kindle (horizontal-stripe static). By opening the
-- document fresh and asking it for its publisher cover, we get a bb at
-- native resolution (typically 600×900+), so every render becomes a
-- DOWNSCALE — the safe direction.
--
-- Single-slot rationale: only one hero is on screen at a time. Holding
-- the most recently requested file's bb is enough to make repeated paints
-- of the same hero free; switching previews evicts and reloads.
--
-- Lifetime: we OWN the bb (it's not in BookInfoManager's cache). Pass it
-- to ImageWidget with image_disposable=false so the widget never frees it.
-- We free the previous bb when a different filepath is requested, and on
-- explicit clear() (called when the bookshelf widget tears down).

local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local logger              = require("logger")

local CoverLoader = {
    _cached_path = nil,
    _cached_bb   = nil,
}

function CoverLoader:_release()
    if self._cached_bb and self._cached_bb.free then
        pcall(function() self._cached_bb:free() end)
    end
    self._cached_bb   = nil
    self._cached_path = nil
end

-- Returns a high-res cover bb for `filepath`, or nil on failure.
-- May be slow (opens the document) on cache miss; cheap on hit.
function CoverLoader:get(filepath)
    if not filepath or filepath == "" then return nil end
    if self._cached_path == filepath and self._cached_bb then
        return self._cached_bb
    end
    self:_release()

    -- FileManagerBookInfo:getCoverImage(document, file) — passing nil for
    -- document forces it to open `file` fresh (do_open=true), grab the
    -- publisher cover via doc:getCoverPageImage(), close the document,
    -- and return the bb. The function doesn't actually use `self`, so the
    -- method-call form is purely for symmetry with how coverimage.koplugin
    -- invokes it.
    local ok, bb = pcall(FileManagerBookInfo.getCoverImage,
                         FileManagerBookInfo, nil, filepath)
    if not ok or not bb then
        logger.info("[bookshelf] high-res cover load failed for "
                    .. tostring(filepath)
                    .. (ok and "" or (": " .. tostring(bb))))
        return nil
    end

    self._cached_path = filepath
    self._cached_bb   = bb
    return bb
end

-- Free the cached bb and forget the slot. Call from the bookshelf widget's
-- teardown path (or when the plugin closes) so we don't leak a bb when the
-- user leaves the home screen entirely.
function CoverLoader:clear()
    self:_release()
end

return CoverLoader
