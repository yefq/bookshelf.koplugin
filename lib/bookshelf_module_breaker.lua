--[[
Circuit-breaker for start-menu micro-modules.

A micro-module's render runs on every menu open. If it crashes the whole menu
- a Lua error in the unguarded getSize/row-assembly around the render call, or
a C-level text-shaping segfault that no pcall can catch - the user is locked
out: the menu crashes on every open, and they cannot even long-press to remove
the offending module (issue #163).

This guards the render in two layers:

  * In-session (catchable): guard() wraps the render in pcall, so a Lua error
    degrades to a fallback row instead of taking down _build. The marker is
    cleared on the way out, so the module is retried on the next open (the
    error may be transient).

  * Across a hard crash (uncatchable): guard() persists an "in-flight" marker
    (the key being rendered) BEFORE calling render and clears it AFTER. A
    segfault never reaches the clear, so the marker survives on disk. The next
    beginOpen() sees the stuck marker, promotes that key to a persistent
    blocklist, and isBlocked() then makes _build skip it - showing a removable,
    retry-able fallback row instead of crashing again.

The store is injected (a table with read/save/delete, matching
lib/bookshelf_settings_store) so the logic is unit-testable without KOReader's
LuaSettings or any widget infrastructure. save/delete on the real store flush
to disk, which is what makes the in-flight marker survive a crash.
]]

local M = {}

-- The module key currently being rendered (a string), or absent. Survives a
-- crash because the real store flushes on save.
M.INFLIGHT_KEY = "start_menu_module_inflight"
-- Set of module keys disabled after a hard crash: { [key] = true }.
M.BLOCKED_KEY = "start_menu_modules_blocked"
-- "An open is in progress and hasn't completed a paint yet." Armed before the
-- menu is shown, cleared once its first paint succeeds. If still set at the
-- next open, the previous open never painted (a paint-pass segfault, or a
-- crash outside any module's render that the per-module guard can't pin) - so
-- the menu opens in safe mode with all modules suppressed.
M.OPEN_KEY = "start_menu_open_inflight"

function M.inflightKey(store)
    return store.read(M.INFLIGHT_KEY)
end

local function blockedSet(store)
    local set = store.read(M.BLOCKED_KEY)
    return type(set) == "table" and set or {}
end

function M.isBlocked(store, key)
    return blockedSet(store)[key] == true
end

-- Called once at the start of each menu build. If a key is still in-flight, the
-- previous render of that key never disarmed - i.e. it crashed the app - so
-- promote it to the persistent blocklist and clear the stuck marker. Returns
-- the promoted key (so the caller knows the crash was pinned to a module), or
-- nil if nothing was in-flight.
function M.beginOpen(store)
    local stuck = store.read(M.INFLIGHT_KEY)
    if stuck == nil then return nil end
    local set = blockedSet(store)
    set[stuck] = true
    store.save(M.BLOCKED_KEY, set)
    store.delete(M.INFLIGHT_KEY)
    return stuck
end

-- Mark that an open is in progress (armed before the menu is shown). Durable:
-- the real store flushes, so it survives a crash before the first paint.
function M.armOpen(store)
    store.save(M.OPEN_KEY, true)
end

-- Clear the open marker once the first paint has succeeded.
function M.endOpen(store)
    store.delete(M.OPEN_KEY)
end

-- True if an open armed but never completed a paint (it crashed). Read at the
-- start of the next open, BEFORE armOpen re-arms it.
function M.openCrashed(store)
    return store.read(M.OPEN_KEY) == true
end

-- Render a module under the breaker. Returns (true, result) on success, or
-- (false, err) if the module is blocked (fn not called) or fn threw. A thrown
-- error is caught and the marker cleared, so the module is NOT persisted-blocked
-- (it may be a transient failure); only a hard crash leaves the marker set.
function M.guard(store, key, fn)
    if M.isBlocked(store, key) then
        return false, nil
    end
    store.save(M.INFLIGHT_KEY, key)
    local ok, res = pcall(fn)
    store.delete(M.INFLIGHT_KEY)
    if not ok then
        return false, res
    end
    return true, res
end

-- Re-enable a blocked module (user tapped its fallback row to retry).
function M.retry(store, key)
    local set = blockedSet(store)
    if set[key] == nil then return end
    set[key] = nil
    store.save(M.BLOCKED_KEY, set)
end

return M
