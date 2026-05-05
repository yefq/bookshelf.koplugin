-- main.lua
-- Plugin entry point. Registers start_with=bookshelf, hooks close-document,
-- and takes over the home screen on launch when configured to do so.
--
-- KOReader API notes (verified against KOReader source):
--
--   * FileManagerMenu.menu_items is an *instance* attribute built lazily in
--     setUpdateItemTable(), which is called the first time the menu opens.
--     The class table itself has no menu_items — so we cannot patch it via
--     FMMenu.menu_items at init time.
--
--   * The start_with sub_item_table is constructed inside
--     FileManagerMenu:getStartWithMenuTable() and assigned to
--     self.menu_items.start_with only *after* addToMainMenu callbacks have
--     already fired (addToMainMenu runs at line ~458, start_with is set at
--     line ~491 in filemanagermenu.lua).
--
--   * Therefore we monkey-patch FileManagerMenu.getStartWithMenuTable at the
--     *class* level so that every instance builds the table with our entry
--     already included. The patch is idempotent (duplicate-guard on "bookshelf").
--
--   * onCloseDocument is dispatched via ReaderUI:handleEvent(Event:new(
--     "CloseDocument")) which propagates to all registered child widgets
--     (plugins are inserted via registerModule → table.insert(self, ...)). So
--     defining Bookshelf:onCloseDocument() is sufficient — no manual subscribe
--     needed.
--
--   * is_doc_only = false — plugin loads in both FileManager and Reader contexts,
--     which is required so the close-document hook fires inside the Reader.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local logger          = require("logger")
local _               = require("bookshelf_i18n").gettext
local T               = require("ffi/util").template

local Bookshelf = WidgetContainer:extend{
    name        = "bookshelf",
    is_doc_only = false, -- must be false: hook fires in Reader context
}

-- ---------------------------------------------------------------------------
-- init
-- ---------------------------------------------------------------------------

function Bookshelf:init()
    -- Patch the start_with menu so users can pick Bookshelf as their home.
    self:_registerStartWithMenu()

    -- Add bookshelf anchors to the FM menu_order so our entries don't get
    -- the "NEW:" prefix MenuSorter applies to anything orphan-positioned.
    self:_extendMenuOrder()

    -- Register "Open Bookshelf" in the main menu (works in both FM and Reader).
    self.ui.menu:registerToMainMenu(self)

    -- Takeover: if start_with=bookshelf and we're in the FileManager context
    -- (no document currently being opened), close FM and present Bookshelf.
    if G_reader_settings:readSetting("start_with") == "bookshelf"
            and not (self.ui and self.ui.document) then
        -- Capture FileManager.instance at schedule time. By the time the tick
        -- fires we want a known reference, not a fresh require lookup that
        -- could see different state.
        local FileManager = require("apps/filemanager/filemanager")
        local fm_instance = FileManager.instance
        UIManager:nextTick(function() self:_takeOver(fm_instance) end)
    end
end

-- ---------------------------------------------------------------------------
-- Start-with menu registration
-- ---------------------------------------------------------------------------

function Bookshelf:_registerStartWithMenu()
    local plugin = self  -- captured by the patches below for runtime access

    -- Monkey-patch FileManagerMenu.getStartWithMenuTable at the class level.
    -- This is the only reliable way to inject into the lazy-built start_with
    -- sub_item_table (see API notes at top of file).
    local ok, FMMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not ok or not FMMenu then
        logger.dbg("[bookshelf] FileManagerMenu not available; skipping start_with registration")
        return
    end

    local orig_fn = FMMenu.getStartWithMenuTable
    if type(orig_fn) ~= "function" then
        logger.dbg("[bookshelf] getStartWithMenuTable not found; skipping start_with registration")
        return
    end

    -- Wrap once — idempotent across multiple plugin init() calls.
    if FMMenu._bookshelf_patched then return end
    FMMenu._bookshelf_patched = true

    FMMenu.getStartWithMenuTable = function(self_fm)
        local result = orig_fn(self_fm)
        -- result = { text_func = ..., sub_item_table = {...} }
        if type(result) ~= "table" or type(result.sub_item_table) ~= "table" then
            return result
        end

        -- Wrap the OTHER start_with options' callbacks: if the user picks
        -- file browser / history / etc. while Bookshelf is currently up,
        -- close it so they immediately see the new home (otherwise they'd
        -- have to manually dismiss Bookshelf and the change wouldn't seem
        -- to take effect until next launch).
        for _i, entry in ipairs(result.sub_item_table) do
            local orig_cb = entry.callback
            entry.callback = function(...)
                if orig_cb then orig_cb(...) end
                if plugin._isShowing and plugin:_isShowing()
                        and plugin._widget then
                    UIManager:close(plugin._widget)
                end
            end
        end

        -- Duplicate guard (safety net in case patch fires more than once).
        -- NB: do NOT name the loop index `_` — that would shadow the outer
        -- gettext binding and `_("Bookshelf")` below would call a number.
        local already
        for _i, entry in ipairs(result.sub_item_table) do
            if entry.text == _("Bookshelf") then already = true; break end
        end
        if not already then
            table.insert(result.sub_item_table, {
                text    = _("Bookshelf"),
                radio   = true,
                checked_func = function()
                    return G_reader_settings:readSetting("start_with") == "bookshelf"
                end,
                callback = function()
                    G_reader_settings:saveSetting("start_with", "bookshelf")
                    G_reader_settings:flush()
                    -- Show Bookshelf immediately if not already showing.
                    if plugin._isShowing and not plugin:_isShowing() then
                        plugin:show()
                    end
                end,
            })
        end

        -- Upstream text_func iterates a hard-coded list of start_with values
        -- (file browser / history / favorites / folder shortcuts / last
        -- file). When the user picks Bookshelf, none match — so the parent
        -- menu row reads "Start with: nil". Wrap text_func to label our
        -- value; defer to the original for everything else.
        local orig_text_func = result.text_func
        result.text_func = function()
            if G_reader_settings:readSetting("start_with") == "bookshelf" then
                return T(_("Start with: %1"), _("Bookshelf"))
            end
            return orig_text_func and orig_text_func() or ""
        end
        return result
    end

end

-- ---------------------------------------------------------------------------
-- Main menu entry
-- ---------------------------------------------------------------------------

-- Extend KOReader's filemanager_menu_order so our entries land in the
-- folder/file tab WITHOUT the "NEW:" prefix MenuSorter applies to items
-- not in any order list. Idempotent — safe to call from init() each load.
function Bookshelf:_extendMenuOrder()
    local ok, order = pcall(require, "ui/elements/filemanager_menu_order")
    if not ok or type(order) ~= "table"
       or type(order.filemanager_settings) ~= "table" then
        return
    end
    for _i, id in ipairs(order.filemanager_settings) do
        if id == "bookshelf_root" then return end
    end
    table.insert(order.filemanager_settings, "----------------------------")
    table.insert(order.filemanager_settings, "bookshelf_root")
end

-- True when the BookshelfWidget instance is in the UIManager window stack
-- (i.e. it's currently shown over FM, regardless of whether a Reader is
-- ALSO on top of it). Cleared via _on_close_callback when UIManager:close
-- removes our widget from the stack.
function Bookshelf:_isShowing()
    if not self._widget then return false end
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return false end
    for _i, win in ipairs(stack) do
        if win.widget == self._widget then return true end
    end
    return false
end

function Bookshelf:addToMainMenu(menu_items)
    local outer = self
    -- Single submenu that bundles the toggle + dismiss + settings, anchored
    -- to the bookshelf_root slot we registered in _extendMenuOrder. Built
    -- lazily so the live BookshelfWidget reference + window-stack state is
    -- current at open time.
    menu_items.bookshelf_root = {
        text                = _("Bookshelf"),
        sub_item_table_func = function()
            local out = {}
            local showing = outer:_isShowing()
            -- Toggle entry: label flips based on whether bookshelf is up.
            out[#out + 1] = {
                text     = showing and _("Close Bookshelf") or _("Open Bookshelf"),
                callback = function()
                    if outer:_isShowing() then
                        UIManager:close(outer._widget)
                    else
                        outer:show()
                    end
                end,
            }
            -- Dismiss-without-changing-start_with: useful when Bookshelf is
            -- the home but the user wants to peek at the underlying FM
            -- (which a skin plugin like ZenUI/SimpleUI may have decorated).
            -- Only meaningful when bookshelf is currently up.
            if showing then
                out[#out + 1] = {
                    text     = _("Show file browser"),
                    callback = function()
                        if outer._widget then UIManager:close(outer._widget) end
                        -- Explicitly reactivate FM after the dismiss. Just
                        -- removing the widget from the stack should be enough
                        -- but a full UI refresh ensures FM's gesture handlers
                        -- see themselves as the active surface.
                        local FileManager = require("apps/filemanager/filemanager")
                        if FileManager.instance then
                            UIManager:setDirty(FileManager.instance, "ui")
                        end
                    end,
                    separator = true,
                }
            else
                out[#out].separator = true
            end
            for _i, it in ipairs(require("settings"):menuItems(outer._widget)) do
                out[#out + 1] = it
            end
            return out
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Show / takeover
-- ---------------------------------------------------------------------------

-- Show or refresh the BookshelfWidget. We keep a single instance live
-- across the plugin's lifetime so opening a book and closing it doesn't
-- require destroying + recreating + flashing the FileManager underneath.
function Bookshelf:show()
    if self._widget then
        -- Already on the stack (probably underneath the Reader). Refresh data
        -- and request a repaint so freshly-closed books surface in Recent etc.
        self._widget:_rebuild()
        UIManager:setDirty(self._widget, "ui")
        return
    end
    local BookshelfWidget = require("bookshelf_widget")
    self._widget = BookshelfWidget:new{}
    -- Clear our reference if the widget is dismissed for any reason, so a
    -- subsequent show() falls back to the create path.
    local outer = self
    self._widget._on_close_callback = function()
        outer._widget = nil
    end
    UIManager:show(self._widget)
end

function Bookshelf:_takeOver(fm_instance)
    -- Leave FileManager loaded *underneath* Bookshelf — don't close it. Two
    -- reasons:
    --   1. KOReader's standard menu (FileManagerMenu top-zone tap/swipe) is
    --      registered against the FM instance via touch zones; if we close
    --      FM, those gestures have nowhere to land and the system menu
    --      stops working anywhere on the home screen.
    --   2. Closing back out of Bookshelf (e.g. user dismisses it through a
    --      future "show file browser" path) hits FM directly with no need
    --      to re-instantiate.
    -- Bookshelf paints fully opaque (white page bg) over FM, so there's no
    -- visible bleed-through; the only cost is a few hundred KB of FM widget
    -- tree in memory, which is acceptable on every target device.
    -- (We keep `fm_instance` in the signature for diagnostic use only —
    -- closing it is now intentional dead code.)
    local _ = fm_instance
    self:show()
end

-- ---------------------------------------------------------------------------
-- Close-document hook
-- ---------------------------------------------------------------------------

function Bookshelf:onCloseDocument()
    -- The walk cache has a 30s TTL; sideloaded / moved / mtime-changed files
    -- surface within that window without an explicit invalidate. Skipping
    -- invalidation here avoids re-walking the entire library + per-candidate
    -- meta build on every close-book → home transition (the common case).

    -- The just-closed file's stats DID change (new pages read), so its
    -- cached enrichStats fields should be dropped — the hero rebuild that
    -- follows must see the new totals. Targeted to the closed file only.
    local Repo = require("book_repository")
    if Repo and Repo.invalidateStatsCache and self.ui and self.ui.document
       and self.ui.document.file then
        Repo.invalidateStatsCache(self.ui.document.file)
    end

    -- Only re-show Bookshelf if the user is actually returning to "home"
    -- — not if the Reader is closing this document only to immediately open
    -- another. self.ui.document is still set in the latter case.
    if G_reader_settings:readSetting("start_with") ~= "bookshelf" then return end
    if self.ui and self.ui.document then return end
    -- If Bookshelf is already on the stack (the typical "open book from
    -- home, close back to home" flow now that _openBook leaves it there),
    -- self:show()'s refresh path handles the repaint without ever exposing
    -- FileManager. Fresh boot path through onCloseDocument (rare) creates
    -- a new instance.
    UIManager:nextTick(function() self:show() end)
end

return Bookshelf
