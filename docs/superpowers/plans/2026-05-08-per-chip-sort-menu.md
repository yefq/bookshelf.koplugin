# Per-Chip Sort Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the FileChooser-collate auto-refresh path with a per-chip sort menu opening from the pagination footer's page-text button, with chip-relevant options that persist per chip.

**Architecture:** A small `Repo.getSortKey(chip)` reads `bookshelf_sort_<chip>` from `G_reader_settings`, defaulting via a static map. Each chip getter (`getLatest`, `getFavorites`, `getSeriesGroups`, `getAuthors`, `getGenres`, `getTags`, `getAll`) branches on the active key to pick a comparator. Group caches (`_series_cache`, `_authors_cache`, `_genres_cache`) move sort from build-time to hydrate-time so a sort change doesn't force a rebuild. `BookshelfWidget:_openSortMenu()` builds an anchored `ButtonDialog` populated per `self.chip` and re-renders via `_swapShelvesInPlace` after a pick.

**Tech Stack:** Lua 5.1, KOReader plugin API, `ButtonDialog` (with `anchor` parameter), `G_reader_settings`, existing repo caches and `_swapShelvesInPlace` fast-path.

---

## File map

| File | Change |
|------|--------|
| `book_repository.lua` | Add `Repo.getSortKey(chip)` helper near top of module; update `getLatest`, `getFavorites`, `getSeriesGroups`, `getAuthors`, `getGenres`, `getTags`, `getAll` to branch on active sort key; move group sort to hydrate time |
| `bookshelf_widget.lua` | Stash page-text Button as `self._page_text_button` in `_buildPaginationFooter`; replace its inert callback with `self:_openSortMenu()`; add new `_openSortMenu` method; delete `_computeSortFingerprint` and the two `_sort_fingerprint` assignments |
| `main.lua` | Delete `_installSortRefreshHook` body + call site; delete `bookshelf_auto_refresh_on_sort` settings menu row |
| `tests/_test_book_repository.lua` | Append tests for `getSortKey` and the new comparator branches in `getLatest`, `getSeriesGroups`, `getAuthors` |

No new files.

---

## Task 1 — `Repo.getSortKey` helper + tests

**Files:**
- Modify: `book_repository.lua` (insert after the `local SUPPORTED_EXT = {...}` block near the top of the file, before `Repo.buildBookMeta`)
- Test: `tests/_test_book_repository.lua`

- [ ] **Step 1.1: Locate the insertion point**

Run: `grep -n "function Repo.buildBookMeta" book_repository.lua`
Expected: a line number near 153 — insert the new block immediately above it.

- [ ] **Step 1.2: Add the helper to `book_repository.lua`**

Insert this block immediately before `function Repo.buildBookMeta(filepath)`:

```lua
-- ─── per-chip sort settings ──────────────────────────────────────────────────
-- Each chip remembers its own sort dimension via "bookshelf_sort_<chip>".
-- Missing/unknown values fall back to the chip default below. The widget
-- writes via the sort menu (BookshelfWidget:_openSortMenu); each chip getter
-- reads via Repo.getSortKey(chip).
local _SORT_DEFAULT = {
    all        = "title",
    recent     = "recently_read",  -- not user-changeable; menu shows single row
    latest     = "mtime",
    favorites  = "date_added",
    series     = "latest_read",
    authors    = "latest_read",
    genres     = "latest_read",
    tags       = "latest_read",
}

local _SORT_VALID = {
    all        = { title = true, date_added = true, path = true },
    latest     = { mtime = true, title = true },
    favorites  = { date_added = true, title = true, recently_read = true },
    series     = { name = true, latest_read = true, book_count = true },
    authors    = { name = true, latest_read = true, book_count = true },
    genres     = { name = true, latest_read = true, book_count = true },
    tags       = { name = true, latest_read = true, book_count = true },
}

function Repo.getSortKey(chip)
    local k = G_reader_settings:readSetting("bookshelf_sort_" .. chip)
    local valid = _SORT_VALID[chip]
    if k and valid and valid[k] then return k end
    return _SORT_DEFAULT[chip]
end
```

- [ ] **Step 1.3: Append tests to `tests/_test_book_repository.lua`**

Find the last `test(` block and append after it (before any final summary `io.write`):

```lua
-- ============================================================================
-- getSortKey
-- ============================================================================

test("getSortKey: returns chip default when setting missing", function()
    _G._test_settings = {}
    assert(Repo.getSortKey("authors") == "latest_read")
    assert(Repo.getSortKey("all") == "title")
    assert(Repo.getSortKey("latest") == "mtime")
end)

test("getSortKey: returns saved setting when valid", function()
    _G._test_settings = { bookshelf_sort_authors = "book_count" }
    assert(Repo.getSortKey("authors") == "book_count")
end)

test("getSortKey: falls back to default when saved value is invalid", function()
    _G._test_settings = { bookshelf_sort_authors = "garbage_value" }
    assert(Repo.getSortKey("authors") == "latest_read")
end)

test("getSortKey: returns default for unknown chip", function()
    _G._test_settings = {}
    assert(Repo.getSortKey("nonexistent") == nil)
end)
```

- [ ] **Step 1.4: Verify Lua syntax**

Run: `luac -p book_repository.lua && echo OK`
Expected: `OK`

- [ ] **Step 1.5: Run tests**

Run: `cd /home/andyhazz/projects/bookshelf.koplugin && lua tests/_test_book_repository.lua`
Expected: all four new `getSortKey` tests pass; no existing tests regress.

- [ ] **Step 1.6: Commit**

```bash
git add book_repository.lua tests/_test_book_repository.lua
git commit -m "feat(repo): add Repo.getSortKey for per-chip sort settings

Helper reads bookshelf_sort_<chip> from G_reader_settings, validates
against the chip's allowed values (so a malformed settings.reader.lua
doesn't crash a getter), and falls back to a per-chip default. Wired
into the chip getters in subsequent commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2 — Wire `getLatest` to the sort key

**Files:**
- Modify: `book_repository.lua:460-480` (`Repo.getLatest`)
- Test: `tests/_test_book_repository.lua`

- [ ] **Step 2.1: Update `getLatest`**

Replace the function body with:

```lua
function Repo.getLatest(limit, offset)
    local _t0 = _gettime()
    local home       = G_reader_settings:readSetting("home_dir") or "/"
    local depth      = G_reader_settings:readSetting("bookshelf_latest_walk_depth") or 3
    local candidates = cachedWalk(home, depth)
    local key = Repo.getSortKey("latest")
    if key == "title" then
        -- Pre-fetch BIM titles so the comparator can read them O(1).
        local bim = getBookInfoMgr()
        local titles = {}
        for _, c in ipairs(candidates) do
            local info = bim:getBookInfo(c.fp, true) or {}
            titles[c.fp] = (info.title or c.fp:match("([^/]+)$") or ""):lower()
        end
        table.sort(candidates, function(a, b) return titles[a.fp] < titles[b.fp] end)
    else
        -- mtime (default): newest first.
        table.sort(candidates, function(a, b) return a.mtime > b.mtime end)
    end
    offset      = offset or 0
    local total = #candidates
    local out   = {}
    local stop  = math.min(offset + (limit or 8), total)
    for i = offset + 1, stop do
        local book = Repo.buildBookMeta(candidates[i].fp)
        if book then
            book.added_time = candidates[i].mtime
            out[#out + 1] = book
        end
    end
    logger.dbg(string.format("[bookshelf perf] getLatest: %.0fms cands=%d items=%d/%d sort=%s",
        (_gettime() - _t0) * 1000, #candidates, #out, total, key))
    return out, total
end
```

- [ ] **Step 2.2: Append a `getLatest` sort test**

Append to `tests/_test_book_repository.lua`:

```lua
test("getLatest: respects bookshelf_sort_latest=title", function()
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "z_oldest.epub", "a_newest.epub"} or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then
            return fp:match("z_oldest") and 100 or 200
        end
        return nil
    end
    _G._test_mtime = { ["/lib/z_oldest.epub"] = 100, ["/lib/a_newest.epub"] = 200 }
    _G._test_bim_data = {
        ["/lib/z_oldest.epub"] = { title = "Aardvark" },
        ["/lib/a_newest.epub"] = { title = "Zebra" },
    }
    _G._test_settings = {
        home_dir = "/lib",
        bookshelf_latest_walk_depth = 1,
        bookshelf_sort_latest = "title",
    }
    local out = Repo.getLatest(8)
    assert(#out == 2)
    assert(out[1].title == "Aardvark", "expected Aardvark first by title, got " .. tostring(out[1].title))
    assert(out[2].title == "Zebra")
end)
```

- [ ] **Step 2.3: Verify syntax + run tests**

Run: `luac -p book_repository.lua && lua tests/_test_book_repository.lua`
Expected: existing `getLatest: orders by mtime desc` still passes; new title-sort test passes.

- [ ] **Step 2.4: Commit**

```bash
git add book_repository.lua tests/_test_book_repository.lua
git commit -m "feat(repo): getLatest respects bookshelf_sort_latest

Adds 'title' as an alternative to the default 'mtime' sort. Pre-fetches
BIM titles into a map so the comparator stays O(1) per pair instead of
reading BIM inside the sort callback.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3 — Wire `getFavorites` to the sort key

**Files:**
- Modify: `book_repository.lua:757-775` (`Repo.getFavorites`)

- [ ] **Step 3.1: Update `getFavorites`**

Replace the function body with:

```lua
function Repo.getFavorites(limit)
    local rc    = getCollections()
    local items = {}
    for _file, item in pairs(rc.coll and rc.coll.favorites or {}) do
        items[#items + 1] = item
    end
    local key = Repo.getSortKey("favorites")
    if key == "title" then
        -- Pre-fetch titles via BIM, fall back to filename.
        local bim = getBookInfoMgr()
        local titles = {}
        for _, item in ipairs(items) do
            local fp = item.file
            local info = bim:getBookInfo(fp, true) or {}
            titles[fp] = (info.title or (fp and fp:match("([^/]+)$")) or ""):lower()
        end
        table.sort(items, function(a, b) return titles[a.file] < titles[b.file] end)
    elseif key == "recently_read" then
        -- ReadHistory time per filepath, fall back to attr.access (collection
        -- access time) so unread favourites still sort deterministically.
        local rh        = getReadHistory()
        local read_time = {}
        for _, e in ipairs(rh.hist or {}) do
            if e.file and e.time then read_time[e.file] = e.time end
        end
        table.sort(items, function(a, b)
            local ta = read_time[a.file] or (a.attr and a.attr.access) or 0
            local tb = read_time[b.file] or (b.attr and b.attr.access) or 0
            return ta > tb
        end)
    else
        -- date_added (default): collection access time (when the user added
        -- the book to the collection), newest first.
        table.sort(items, function(a, b)
            return (a.attr and a.attr.access or 0) > (b.attr and b.attr.access or 0)
        end)
    end
    local out = {}
    for i = 1, math.min(limit or 8, #items) do
        local book = Repo.buildBookMeta(items[i].file)
        if book then
            book.in_favorites = true
            out[#out + 1] = book
        end
    end
    return out
end
```

- [ ] **Step 3.2: Verify syntax**

Run: `luac -p book_repository.lua && echo OK`
Expected: `OK`

- [ ] **Step 3.3: Run tests**

Run: `lua tests/_test_book_repository.lua`
Expected: existing `getFavorites: pulls from ReadCollection.coll.favorites` still passes (the default branch matches its expectations).

- [ ] **Step 3.4: Commit**

```bash
git add book_repository.lua
git commit -m "feat(repo): getFavorites respects bookshelf_sort_favorites

Default 'date_added' branch preserves the existing collection-access-time
ordering. New 'title' and 'recently_read' branches added; 'recently_read'
falls back to collection access time when ReadHistory has no entry, so
unread favourites still sort deterministically.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4 — Sort `getSeriesGroups` at hydrate time

**Files:**
- Modify: `book_repository.lua:920-1017` (`Repo.getSeriesGroups`) and `hydrateSeriesShape` at line 899
- Test: `tests/_test_book_repository.lua`

The cache currently stores shapes in built-order (always sorted by `latest` desc at build). To support a setting-driven sort without invalidating the cache on every menu change, the build pass keeps insertion order, and the hydration pass applies the sort selected at read time.

- [ ] **Step 4.1: Make `_seriesGroupCmp(key)` helper above `hydrateSeriesShape`**

Insert immediately above `local function hydrateSeriesShape(shape)`:

```lua
-- Comparator for series/author/genre/tag group SHAPES — operates on the
-- cached shape (series_name, latest, filepaths) before hydration so we
-- don't pay buildBookMeta on items outside the requested page.
local function _groupShapeCmp(key)
    if key == "name" then
        return function(a, b)
            return (a.series_name or ""):lower() < (b.series_name or ""):lower()
        end
    elseif key == "book_count" then
        return function(a, b)
            local na = #(a.filepaths or {})
            local nb = #(b.filepaths or {})
            if na ~= nb then return na > nb end
            -- Tie-break: name ascending for determinism.
            return (a.series_name or ""):lower() < (b.series_name or ""):lower()
        end
    end
    -- latest_read (default): most recent first.
    return function(a, b) return (a.latest or 0) > (b.latest or 0) end
end
```

- [ ] **Step 4.2: Update `getSeriesGroups` to sort at hydrate time**

In `Repo.getSeriesGroups` (line 920), replace the cache-hit hydration block (lines 928-941) and the build-time sort (line 985) so the cache stores groups in insertion order and the slice sort runs on read.

Replace the HIT branch:

```lua
    -- Cache fast path: filepaths + sort metadata are stable across renders;
    -- Books get rehydrated each read so cover_bbs are fresh. Sort runs at
    -- hydrate time so changing bookshelf_sort_series doesn't invalidate the
    -- cache.
    local cached = _series_cache[key]
    if cached and cached.expires_at > now then
        local _t0   = _gettime()
        local shapes = {}
        for _, s in ipairs(cached.groups) do shapes[#shapes + 1] = s end
        table.sort(shapes, _groupShapeCmp(Repo.getSortKey("series")))
        local total = #shapes
        local out   = {}
        offset      = offset or 0
        local stop  = math.min(offset + (limit or 8), total)
        for i = offset + 1, stop do
            out[#out + 1] = hydrateSeriesShape(shapes[i])
        end
        logger.dbg(string.format("[bookshelf perf] getSeriesGroups: HIT hydrate=%.0fms groups=%d/%d sort=%s",
            (_gettime() - _t0) * 1000, #out, total, Repo.getSortKey("series")))
        return out, total
    end
```

Remove the build-time sort by changing line 985 from:

```lua
    table.sort(list, function(a, b) return a.latest > b.latest end)
```

to:

```lua
    -- Note: list stays in insertion order. Sort runs at hydrate time on the
    -- cached shapes (see HIT branch / MISS hydrate below), so a sort menu
    -- change re-renders without a re-walk.
```

After the cache write at line 1007 (`_series_cache[key] = ...`) and BEFORE the existing slice loop (lines 1010-1013), add the same hydrate-time sort applied to the freshly-built shapes. Replace the MISS-tail block with:

```lua
    _series_cache[key] = { groups = shapes, expires_at = now + SERIES_CACHE_TTL }

    local sorted_shapes = {}
    for _, s in ipairs(shapes) do sorted_shapes[#sorted_shapes + 1] = s end
    table.sort(sorted_shapes, _groupShapeCmp(Repo.getSortKey("series")))

    local total = #sorted_shapes
    local out   = {}
    offset      = offset or 0
    local stop  = math.min(offset + (limit or 8), total)
    for i = offset + 1, stop do
        out[#out + 1] = hydrateSeriesShape(sorted_shapes[i])
    end
    logger.dbg(string.format("[bookshelf perf] getSeriesGroups: MISS build=%.0fms cands=%d groups=%d/%d sort=%s",
        (_gettime() - _t0) * 1000, #candidates, #out, total, Repo.getSortKey("series")))
    return out, total
end
```

- [ ] **Step 4.3: Update existing series test**

Find the test at line 165 (`getSeriesGroups: groups books by series_name, sorts by latest activity`). The default sort is unchanged (latest_read), so this test should still pass without modification. Verify by running tests.

Append a new test that confirms the `book_count` sort works:

```lua
test("getSeriesGroups: respects bookshelf_sort_series=book_count", function()
    Repo.invalidateWalkCache()
    Repo.invalidateSeriesCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..",
            "small1.epub", "big1.epub", "big2.epub", "big3.epub"} or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then return "file" end
        return 0
    end
    _G._test_bim_data = {
        ["/lib/small1.epub"] = { title = "S1", series = "Smaller #1" },
        ["/lib/big1.epub"]   = { title = "B1", series = "Bigger #1" },
        ["/lib/big2.epub"]   = { title = "B2", series = "Bigger #2" },
        ["/lib/big3.epub"]   = { title = "B3", series = "Bigger #3" },
    }
    _G._test_settings = {
        home_dir = "/lib",
        bookshelf_latest_walk_depth = 1,
        bookshelf_sort_series = "book_count",
    }
    local out, total = Repo.getSeriesGroups(8)
    assert(total == 2, "expected 2 series groups, got " .. tostring(total))
    assert(out[1].series_name == "Bigger", "expected Bigger first (3 books), got " .. tostring(out[1].series_name))
    assert(out[2].series_name == "Smaller", "expected Smaller second (1 book), got " .. tostring(out[2].series_name))
end)
```

(`Repo.invalidateSeriesCache` exists at line 400 — verify with `grep -n invalidateSeriesCache book_repository.lua` if uncertain.)

- [ ] **Step 4.4: Verify syntax + run tests**

Run: `luac -p book_repository.lua && lua tests/_test_book_repository.lua`
Expected: all existing series tests pass; new `book_count` test passes.

- [ ] **Step 4.5: Commit**

```bash
git add book_repository.lua tests/_test_book_repository.lua
git commit -m "feat(repo): getSeriesGroups sorts at hydrate time, supports name/book_count

Move sort from build to hydrate so the menu can switch between
latest_read / name / book_count without invalidating the SERIES_CACHE
walk. _groupShapeCmp(key) returns the comparator; getSortKey('series')
selects it. Same helper feeds getAuthors/getGenres/getTags in following
commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5 — Wire `getAuthors` and `getGenres`

**Files:**
- Modify: `book_repository.lua:1133-1197` (`getAuthors`, `getGenres`) and `_buildGroups` at line 1059

- [ ] **Step 5.1: Drop the build-time sort from `_buildGroups`**

In `_buildGroups` (line 1059), remove line 1106:

```lua
    table.sort(list, function(a, b) return a.latest > b.latest end)
```

Replace with a comment:

```lua
    -- Insertion order; getAuthors/getGenres/getTags sort at hydrate time
    -- via _groupShapeCmp on the cached shapes.
```

- [ ] **Step 5.2: Update `getAuthors` to sort cached shapes**

Replace the slice loop (lines 1149-1162) so it sorts before slicing:

```lua
    -- Sort cached shapes per the active sort key, then slice the page window.
    local sorted = {}
    for _, s in ipairs(cached.groups) do sorted[#sorted + 1] = s end
    table.sort(sorted, _groupShapeCmp(Repo.getSortKey("authors")))
    local total = #sorted
    local out   = {}
    offset      = offset or 0
    local stop  = math.min(offset + (limit or 8), total)
    for i = offset + 1, stop do
        out[#out + 1] = _hydrateGroupShape(sorted[i])
    end
    logger.dbg(string.format("[bookshelf perf] getAuthors: %s %.0fms groups=%d/%d sort=%s",
        _hit and "HIT" or "MISS", (_gettime() - _t0) * 1000, #out, total, Repo.getSortKey("authors")))
    return out, total
end
```

- [ ] **Step 5.3: Update `getGenres` the same way**

Replace its slice loop (lines 1182-1196) with the analogue using `Repo.getSortKey("genres")`:

```lua
    local sorted = {}
    for _, s in ipairs(cached.groups) do sorted[#sorted + 1] = s end
    table.sort(sorted, _groupShapeCmp(Repo.getSortKey("genres")))
    local total = #sorted
    local out   = {}
    offset      = offset or 0
    local stop  = math.min(offset + (limit or 8), total)
    for i = offset + 1, stop do
        out[#out + 1] = _hydrateGroupShape(sorted[i])
    end
    logger.dbg(string.format("[bookshelf perf] getGenres: %s %.0fms groups=%d/%d sort=%s",
        _hit and "HIT" or "MISS", (_gettime() - _t0) * 1000, #out, total, Repo.getSortKey("genres")))
    return out, total
end
```

- [ ] **Step 5.4: Append author sort test**

```lua
test("getAuthors: respects bookshelf_sort_authors=name", function()
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "z.epub", "a.epub"} or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then return "file" end
        return 0
    end
    _G._test_bim_data = {
        ["/lib/z.epub"] = { title = "Z", authors = "Zelazny, Roger" },
        ["/lib/a.epub"] = { title = "A", authors = "Asimov, Isaac" },
    }
    _G._test_settings = {
        home_dir = "/lib",
        bookshelf_latest_walk_depth = 1,
        bookshelf_sort_authors = "name",
    }
    local out, total = Repo.getAuthors(8)
    assert(total == 2)
    assert(out[1].series_name:lower():find("asimov"), "expected Asimov first by name, got " .. tostring(out[1].series_name))
end)
```

(`book.author` is the comma-cleaned single primary author; the BIM stub returns `authors` as the raw string, which `buildBookMeta` splits. Verify by reading `buildBookMeta` if the assertion fails — `book.author` may need to be the split first author from the comma-separated string.)

- [ ] **Step 5.5: Verify syntax + run tests**

Run: `luac -p book_repository.lua && lua tests/_test_book_repository.lua`
Expected: all tests pass.

- [ ] **Step 5.6: Commit**

```bash
git add book_repository.lua tests/_test_book_repository.lua
git commit -m "feat(repo): getAuthors/getGenres sort at hydrate time

Drop the build-time latest sort in _buildGroups; getAuthors and
getGenres now apply _groupShapeCmp at hydrate time via getSortKey.
Adds 'name' and 'book_count' as alternatives to default 'latest_read'.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6 — Wire `getTags`

**Files:**
- Modify: `book_repository.lua:846-880` (`Repo.getTags`)

- [ ] **Step 6.1: Update `getTags`**

`getTags` doesn't use a shape cache (per the comment at line 784, ReadCollection state changes don't fire walk-cache invalidation), but the comparator pattern still applies — sort the in-memory groups list per the active key:

Replace the function body with:

```lua
function Repo.getTags(limit)
    local rc = getCollections()
    if not rc.coll then return {} end
    local groups = {}
    for coll_name, files in pairs(rc.coll) do
        if coll_name ~= "favorites" then
            local books     = {}
            local filepaths = {}
            local latest    = 0
            for _file, item in pairs(files) do
                local book = Repo.buildBookMeta(item.file or _file)
                if book then
                    books[#books + 1] = book
                    filepaths[#filepaths + 1] = book.filepath
                    local t = (item.attr and item.attr.access) or 0
                    if t > latest then latest = t end
                end
            end
            if #books > 0 then
                table.sort(books, function(a, b)
                    return (a.title or "") < (b.title or "")
                end)
                groups[#groups + 1] = {
                    kind        = "tag",
                    series_name = coll_name,
                    books       = books,
                    filepaths   = filepaths,  -- needed by _groupShapeCmp("book_count")
                    latest      = latest,
                }
            end
        end
    end
    table.sort(groups, _groupShapeCmp(Repo.getSortKey("tags")))
    if limit and #groups > limit then
        for i = limit + 1, #groups do groups[i] = nil end
    end
    return groups
end
```

(The `filepaths` field is added so `_groupShapeCmp("book_count")` reads `#filepaths` consistently with the cached-shape branches; the rendering path doesn't read it from a hydrated tag group, so this doesn't break anything downstream.)

- [ ] **Step 6.2: Verify syntax + run tests**

Run: `luac -p book_repository.lua && lua tests/_test_book_repository.lua`
Expected: all tests pass.

- [ ] **Step 6.3: Commit**

```bash
git add book_repository.lua
git commit -m "feat(repo): getTags respects bookshelf_sort_tags

Same _groupShapeCmp dispatch as series/authors/genres. Adds a filepaths
field on tag-group records so the shared book_count comparator works
without a tag-specific branch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7 — Wire `getAll`

**Files:**
- Modify: `book_repository.lua:535-604` (`_makeCollateSort`) and `:610-751` (`Repo.getAll`)

The All chip is the most invasive change: drop the four KOReader settings (`collate`, `reverse_collate`, `collate_mixed`, `show_filter.status`) entirely, swap to `bookshelf_sort_all` + `bookshelf_sort_all_reverse` + `bookshelf_sort_all_mixed`. The cache key changes from `path .. "\0" .. collate` to a fingerprint over the new settings.

- [ ] **Step 7.1: Replace `_makeCollateSort` with a bookshelf-only comparator**

Replace the entire `_makeCollateSort` function (line 535) with:

```lua
local function _makeAllSort(key, rh_map)
    local SORT_LAST = "\xEF\xBF\xBF"
    if key == "date_added" then
        return function(a, b)
            return (a.attr.modification or 0) > (b.attr.modification or 0)
        end
    elseif key == "path" then
        return function(a, b) return a.fp < b.fp end
    end
    -- title (default): alphabetical by display title (BIM-enriched in caller),
    -- falling back to filename.
    return function(a, b)
        local ta = (a.doc_props and a.doc_props.display_title) or a.name
        local tb = (b.doc_props and b.doc_props.display_title) or b.name
        return ta:lower() < tb:lower()
    end
end
```

The `rh_map` parameter is left in the signature unused (kept for symmetry with the previous helper); the All chip's "recently read" sort isn't in v1's scope.

- [ ] **Step 7.2: Update `Repo.getAll`**

Replace the cache-key construction and the per-collate enrichment block. Locate the lines:

```lua
    local collate   = G_reader_settings:readSetting("collate") or "strcoll"
    local cache_key = path .. "\0" .. collate
```

Replace with:

```lua
    local sort_key = Repo.getSortKey("all")
    local reverse  = G_reader_settings:readSetting("bookshelf_sort_all_reverse") == true
    local mixed    = G_reader_settings:readSetting("bookshelf_sort_all_mixed") == true
    local cache_key = table.concat({
        path, sort_key, reverse and "R" or "", mixed and "M" or "",
    }, "\0")
```

Locate the metadata-pre-fetch block (currently gated on `if collate == "title" or collate == "authors" or collate == "series" or collate == "keywords" then` at line 674):

Replace with:

```lua
    -- For the title sort, pre-fetch BIM display titles before sorting so the
    -- comparator stays O(1) per pair.
    if sort_key == "title" then
        local bim = getBookInfoMgr()
        for _, e in ipairs(entries) do
            if e.attr.mode == "file" then
                local info = bim:getBookInfo(e.fp, true) or {}
                e.doc_props = { display_title = info.title or e.name }
            else
                e.doc_props = { display_title = e.name }
            end
        end
    end
```

Locate the `if collate == "access" then ... end` block (line 702) and DELETE it (rh_map is no longer used by this code path).

Replace `table.sort(entries, _makeCollateSort(collate, rh_map))` (line 712) with:

```lua
    table.sort(entries, _makeAllSort(sort_key))
    if reverse then
        local n = #entries
        for i = 1, math.floor(n / 2) do
            entries[i], entries[n - i + 1] = entries[n - i + 1], entries[i]
        end
    end
```

Locate the `_all_cache[cache_key] = ...` build/store loop (line 717-744). After the loop builds `all_out` and `shapes`, insert mixed-folders handling BEFORE the cache write. KOReader's `collate_mixed` semantics:
- false (default): folders first, then files (within each, current sort)
- true: folders and files interleaved by the active sort

The current code interleaves naturally (the `for _, e in ipairs(entries)` loop honours the entry sort order). For non-mixed, we need to partition. Replace the existing loop with:

```lua
    -- Build all_out + shapes. When mixed=false, re-partition so all folders
    -- come before all files (preserving each partition's existing order from
    -- the entries sort).
    local function _entryToShape(e)
        if e.attr.mode == "file" then
            local ext = e.name:match("%.([^.]+)$")
            if ext and SUPPORTED_EXT[ext:lower()] then
                return e, "book"
            end
            return nil
        elseif e.attr.mode == "directory" then
            return e, "folder"
        end
    end

    local ordered_entries = entries
    if not mixed then
        local folders, files = {}, {}
        for _, e in ipairs(entries) do
            local _e, kind = _entryToShape(e)
            if kind == "folder" then folders[#folders + 1] = e
            elseif kind == "book" then files[#files + 1] = e
            end
        end
        ordered_entries = {}
        for _, e in ipairs(folders) do ordered_entries[#ordered_entries + 1] = e end
        for _, e in ipairs(files)   do ordered_entries[#ordered_entries + 1] = e end
    end

    local all_out = {}
    local shapes  = {}
    for _, e in ipairs(ordered_entries) do
        if e.attr.mode == "file" then
            local ext = e.name:match("%.([^.]+)$")
            if ext and SUPPORTED_EXT[ext:lower()] then
                local b = Repo.buildBookMeta(e.fp)
                if b then
                    all_out[#all_out + 1] = b
                    shapes[#shapes + 1] = { kind = "book", fp = e.fp }
                end
            end
        elseif e.attr.mode == "directory" then
            local fb = Repo.findFirstBookIn(e.fp, 3)
            all_out[#all_out + 1] = {
                kind       = "folder",
                path       = e.fp,
                label      = e.name,
                first_book = fb,
            }
            shapes[#shapes + 1] = {
                kind          = "folder",
                path          = e.fp,
                label         = e.name,
                first_book_fp = fb and fb.filepath,
            }
        end
    end
    local total = #all_out
    _all_cache[cache_key] = { shapes = shapes, expires_at = now + WALK_CACHE_TTL }
```

- [ ] **Step 7.3: Verify syntax + run tests**

Run: `luac -p book_repository.lua && lua tests/_test_book_repository.lua`
Expected: all tests pass. (No new test added — the All-chip sort is exercised manually on device since it depends on home_dir contents.)

- [ ] **Step 7.4: Commit**

```bash
git add book_repository.lua
git commit -m "feat(repo): getAll sorts via bookshelf settings, drops KOReader collate

Cache key now fingerprints (path, bookshelf_sort_all, reverse, mixed)
instead of (path, collate). _makeAllSort handles three keys: title
(default), date_added, path. Reverse is a post-sort table reversal so
it composes with all keys cleanly. Mixed=false partitions folders-first
after sorting; mixed=true preserves the natural sort interleaving.

The KOReader filemanager's collate setting no longer drives the All
chip — bookshelf is fully self-governing for ordering. The
auto-refresh-on-collate-change hook is removed in a separate commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8 — Add `_openSortMenu` + wire page-text Button

**Files:**
- Modify: `bookshelf_widget.lua` (lines 1310-1363 for `_buildPaginationFooter`; new method `_openSortMenu` after it)

- [ ] **Step 8.1: Stash the page-text Button on `self`**

In `_buildPaginationFooter` (line 1310), replace the existing `page_text` Button construction (around lines 1335-1340):

```lua
    local page_text = Button:new{
        text = string.format("Page %d of %d", self.page, total_pages),
        text_font_size = 15,
        callback = function() end,
        bordersize = 0, show_parent = self,
    }
```

with:

```lua
    local page_text = Button:new{
        text = string.format("Page %d of %d", self.page, total_pages),
        text_font_size = 15,
        callback = function() bw:_openSortMenu() end,
        bordersize = 0, show_parent = self,
    }
    self._page_text_button = page_text
```

- [ ] **Step 8.2: Add `_openSortMenu` method**

Insert immediately after `_buildPaginationFooter` (after the `return CenterContainer` block at line 1362):

```lua
-- _openSortMenu — opens an anchored ButtonDialog above the page-text button
-- showing chip-relevant sort options. Tapping a row writes the per-chip
-- setting and re-renders the shelf via _swapShelvesInPlace. The Recent chip
-- shows a single inert row so the gesture is consistent across chips.
function BookshelfWidget:_openSortMenu()
    local Repo = require("book_repository")
    local ButtonDialog = require("ui/widget/buttondialog")
    local CHECK = "\xe2\x9c\x93 "  -- "✓ " — matches _openBookMenu's pattern.

    local chip   = self.chip
    local active = Repo.getSortKey(chip)
    local bw     = self
    local dialog

    local function pick(setting_key, value)
        return function()
            G_reader_settings:saveSetting(setting_key, value)
            G_reader_settings:flush()
            UIManager:close(dialog)
            bw:_swapShelvesInPlace()
        end
    end

    local function radio_row(label, sort_value)
        local prefix = (active == sort_value) and CHECK or ""
        return { text = prefix .. label,
                 callback = pick("bookshelf_sort_" .. chip, sort_value) }
    end

    local function toggle_row(label, setting_key)
        local on     = G_reader_settings:readSetting(setting_key) == true
        local prefix = on and CHECK or ""
        return { text = prefix .. label,
                 callback = function()
                     G_reader_settings:saveSetting(setting_key, not on)
                     G_reader_settings:flush()
                     UIManager:close(dialog)
                     bw:_swapShelvesInPlace()
                 end }
    end

    local buttons
    if chip == "recent" then
        -- Single inert row: confirms the chip's intrinsic ordering.
        buttons = {
            { { text = CHECK .. _("By recently read"),
                callback = function() UIManager:close(dialog) end } },
        }
    elseif chip == "all" then
        buttons = {
            { radio_row(_("By title"),      "title") },
            { radio_row(_("By date added"), "date_added") },
            { radio_row(_("By path"),       "path") },
            { toggle_row(_("Reverse"),         "bookshelf_sort_all_reverse") },
            { toggle_row(_("Mixed folders"),   "bookshelf_sort_all_mixed") },
        }
    elseif chip == "latest" then
        buttons = {
            { radio_row(_("By date added"), "mtime") },
            { radio_row(_("By title"),      "title") },
        }
    elseif chip == "favorites" then
        buttons = {
            { radio_row(_("By date added"),    "date_added") },
            { radio_row(_("By title"),         "title") },
            { radio_row(_("By recently read"), "recently_read") },
        }
    elseif chip == "series" or chip == "authors"
            or chip == "genres" or chip == "tags" then
        buttons = {
            { radio_row(_("By name"),          "name") },
            { radio_row(_("By latest read"),   "latest_read") },
            { radio_row(_("By book count"),    "book_count") },
        }
    else
        logger.dbg("[bookshelf] _openSortMenu: unknown chip " .. tostring(chip))
        return
    end

    dialog = ButtonDialog:new{
        anchor  = self._page_text_button,
        buttons = buttons,
    }
    UIManager:show(dialog)
end
```

- [ ] **Step 8.3: Verify syntax**

Run: `luac -p bookshelf_widget.lua && echo OK`
Expected: `OK`

- [ ] **Step 8.4: Push to Kindle and verify md5**

```bash
tar c bookshelf_widget.lua book_repository.lua | ssh kindle 'cd /mnt/us/koreader/plugins/bookshelf.koplugin && tar x'
md5sum bookshelf_widget.lua book_repository.lua
ssh kindle 'cd /mnt/us/koreader/plugins/bookshelf.koplugin && md5sum bookshelf_widget.lua book_repository.lua'
```

Expected: matching md5s on both sides.

- [ ] **Step 8.5: Commit**

```bash
git add bookshelf_widget.lua
git commit -m "feat(widget): tap page-text button to open per-chip sort menu

Anchored ButtonDialog rises from the pagination footer's page-text
button, populated per self.chip with chip-relevant sort options. Picks
write bookshelf_sort_<chip> and re-render via _swapShelvesInPlace.
Recent chip shows a single inert checked row so the gesture is
consistent across chips.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9 — Remove auto-refresh path

**Files:**
- Modify: `main.lua` (delete `_installSortRefreshHook` body + call at line 61, delete settings menu row at lines 378-395)
- Modify: `bookshelf_widget.lua` (delete `_computeSortFingerprint` at lines 78-101, delete two `self._sort_fingerprint = ...` assignments at lines 702 and 809)

- [ ] **Step 9.1: Remove call site in `main.lua`**

In `main.lua`, find and delete the line:

```lua
    self:_installSortRefreshHook()
```

(Around line 61 of `main.lua`.)

- [ ] **Step 9.2: Remove `_installSortRefreshHook` definition**

In `main.lua`, delete the entire function body from line 206 (or wherever `function Bookshelf:_installSortRefreshHook()` starts) to its closing `end`. Delete the leading multi-line comment block above it as well (lines beginning ~200).

- [ ] **Step 9.3: Remove the settings menu row**

In `main.lua` around lines 378-395, delete the entire `{ text = _("Auto-refresh on sort change"), ... }` block (one entry in the `sub_item_table` list). Make sure the surrounding commas remain syntactically valid — if it was the last item, drop the trailing comma on the previous item.

- [ ] **Step 9.4: Remove `_computeSortFingerprint` from widget**

In `bookshelf_widget.lua`, delete the function and its leading comment block at lines 78-101.

- [ ] **Step 9.5: Remove `_sort_fingerprint` assignments**

In `bookshelf_widget.lua`, delete:

```lua
        self._sort_fingerprint = BookshelfWidget._computeSortFingerprint()
```

at line 702, and the same line at 809.

- [ ] **Step 9.6: Verify syntax**

Run: `luac -p main.lua && luac -p bookshelf_widget.lua && echo OK`
Expected: `OK`

- [ ] **Step 9.7: Run repo tests (sanity)**

Run: `lua tests/_test_book_repository.lua`
Expected: all tests pass (these changes don't touch the repo, but a regression check is cheap).

- [ ] **Step 9.8: Commit**

```bash
git add main.lua bookshelf_widget.lua
git commit -m "refactor: remove auto-refresh-on-collate hook and fingerprint

Bookshelf no longer reads KOReader's collate / reverse_collate /
collate_mixed / show_filter.status — the per-chip sort menu owns
ordering. Drops _installSortRefreshHook, _computeSortFingerprint, the
two _sort_fingerprint assignments, and the
'Auto-refresh on sort change' settings row.

The bookshelf_auto_refresh_on_sort setting key is left in
G_reader_settings as dead data; KOReader tolerates unknown keys and
removing it would require a one-shot migration that's not worth the
code.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10 — Deploy + manual verification

**Files:**
- None — verification only.

- [ ] **Step 10.1: Push the full plugin to Kindle**

```bash
tar c bookshelf_widget.lua book_repository.lua main.lua \
    | ssh kindle 'cd /mnt/us/koreader/plugins/bookshelf.koplugin && tar x'
```

Then verify md5 match for each file:

```bash
md5sum bookshelf_widget.lua book_repository.lua main.lua
ssh kindle 'cd /mnt/us/koreader/plugins/bookshelf.koplugin && md5sum bookshelf_widget.lua book_repository.lua main.lua'
```

Expected: three matching pairs.

- [ ] **Step 10.2: User restarts KOReader manually**

Tell the user: "Push complete. Please restart KOReader and run through the verification checklist."

- [ ] **Step 10.3: Verification checklist (user runs through each on device)**

Each chip in turn (All, Latest, Favourites, Series, Authors, Genres, Tags, Recent):

- Tap the "Page X of Y" button at the bottom of the bookshelf.
- A `ButtonDialog` appears anchored above the page-text button.
- Only chip-relevant rows are shown (per the spec's options table).
- The currently active sort is prefixed with the check glyph.

Cross-cutting:

- Pick a non-default option on each non-Recent chip; confirm the shelf
  re-renders in the new order without a flash of stale state.
- Switch chips after picking — Authors-by-count then Series should NOT carry
  the count sort.
- Recent chip: tap → single-row menu with "By recently read" checked; tapping
  it just dismisses the dialog (no re-render, no log line for `getRecent`
  with new sort).
- Cold restart KOReader; confirm per-chip choices persist.
- KOReader filemanager: change the global collate ("Sort by" in the FM menu)
  from "By title" to "By date added"; confirm the bookshelf's All chip does
  NOT change order. (The hook is removed; this MUST not auto-refresh.)
- Settings menu (long-press chip strip → Bookshelf settings): the
  "Auto-refresh on sort change" row is gone.

- [ ] **Step 10.4: After verification, no commit needed**

If the user reports issues, return to the relevant task and fix in a follow-up commit.

---

## Self-review notes

- Spec coverage: every spec section has a corresponding task. Recent's
  single-row menu is in Task 8; auto-refresh removal is Task 9; per-chip
  options table maps to the sort branches in Tasks 2-7 and the menu builder
  in Task 8.
- Type consistency: `Repo.getSortKey` returns string|nil; all callers handle
  nil via the per-key default lookup inside the comparator. `_groupShapeCmp`
  returns a comparator function in all three branches (no nil return).
  `bookshelf_sort_all_reverse` and `bookshelf_sort_all_mixed` are booleans
  (read with `== true` for explicit truthiness, set with `not on`).
- No placeholders. Every step has the exact code or command.
- Filepaths: every "modify" reference cites the function name + the recent
  line number. If the file has drifted by the time the task runs, locate
  via the function name (`grep -n "function Repo.getLatest"` etc.) — line
  numbers are advisory.
