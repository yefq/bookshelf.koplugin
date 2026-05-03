-- library_view.lua
-- Paginated 3-shelf grid view, reached via the › arrow on the home screen.
-- Reuses ChipStrip and ShelfRow.
--
-- Layout (top → bottom):
--   ChipStrip  (Recent / Latest / Series / ★)
--   3 × ShelfRow  (4 spines each = 12 books per page)
--   Page indicator  "Page N / total  ‹  ›"
--
-- Pagination: swipe west = next page, swipe east = prev page.
-- Chip switch: resets to page 1 and refetches.

local InputContainer  = require("ui/widget/container/inputcontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextWidget      = require("ui/widget/textwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local Size            = require("ui/size")
local Font            = require("ui/font")
local UIManager       = require("ui/uimanager")
local Screen          = require("device").screen
local ChipStrip       = require("chip_strip")
local ShelfRow        = require("shelf_row")
local Repo            = require("book_repository")

-- ─── Layout constants ─────────────────────────────────────────────────────────

local PER_ROW  = 4
local ROWS     = 3
local PER_PAGE = PER_ROW * ROWS  -- 12

-- Height of one chip-strip row.
-- Size.item.height_small does not exist in KOReader; use height_default (~30dp)
-- which matches the compact chip-strip look from the spec.
local CHIP_H = Size.item.height_default

-- Height of the bottom page-indicator label (same compact height as chips).
local LABEL_H = Size.item.height_default

-- The four standard chips, matching BookshelfWidget's chip set.
local CHIPS = {
    { key = "recent",    label = "Recent"  },
    { key = "latest",    label = "Latest"  },
    { key = "series",    label = "Series"  },
    { key = "favorites", label = "★"       },
}

-- ─── LibraryView ──────────────────────────────────────────────────────────────

local LibraryView = InputContainer:extend{
    -- Public API surface — caller sets these before :new{}.
    chip          = "recent",   -- initially-active chip key
    page          = 1,
    on_book_tap   = nil,        -- function(book)
    on_book_hold  = nil,        -- function(book)
    on_series_tap = nil,        -- function(series_group)
    on_series_hold= nil,        -- function(series_group)
    on_close      = nil,        -- function() — called when the view is dismissed
}

function LibraryView:init()
    self.width  = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen  = Geom:new{ w = self.width, h = self.height }

    self:_rebuild()

    -- Positional GestureRange form — keyed form is broken (see hero_card commit).
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
    }
end

-- ─── _rebuild ─────────────────────────────────────────────────────────────────
-- Full re-render of the widget tree from the current chip + page state.
-- Called on chip switch and on page turn.

function LibraryView:_rebuild()
    local items_all    = self:_fetchAll()
    local total_pages  = math.max(1, math.ceil(#items_all / PER_PAGE))
    -- Clamp page in case the new chip yields fewer pages.
    if self.page > total_pages then self.page = total_pages end
    -- Save for event handlers.
    self._total_pages  = total_pages
    self._items_all    = items_all

    -- ── Chip strip ────────────────────────────────────────────────────────────
    local chips = ChipStrip:new{
        chips     = CHIPS,
        active    = self.chip,
        width     = self.width,
        height    = CHIP_H,
        on_change = function(key)
            self.chip = key
            self.page = 1
            self:_rebuild()
            UIManager:setDirty(self, "ui")
        end,
    }

    -- ── Shelf rows ────────────────────────────────────────────────────────────
    -- Remaining vertical space after chip strip and page label.
    local reserved_h  = CHIP_H + LABEL_H + Size.padding.default * 2
    local shelves_h   = self.height - reserved_h
    -- Each shelf row gets an equal share, minus a small inter-row gap.
    local row_h = math.floor((shelves_h - Size.padding.small * (ROWS - 1)) / ROWS)

    local start   = (self.page - 1) * PER_PAGE + 1
    local shelf_vg = VerticalGroup:new{ align = "left" }

    for r = 0, ROWS - 1 do
        -- Slice items for this row.
        local items = {}
        for c = 1, PER_ROW do
            items[c] = items_all[start + r * PER_ROW + c - 1]  -- nil = empty slot
        end

        if r > 0 then
            -- Small vertical gap between shelf rows.
            shelf_vg[#shelf_vg + 1] = require("ui/widget/verticalspan"):new{
                width = self.width, height = Size.padding.small
            }
        end

        shelf_vg[#shelf_vg + 1] = ShelfRow.new{
            width          = self.width,
            height         = row_h,
            items          = items,
            on_book_tap    = self.on_book_tap,
            on_book_hold   = self.on_book_hold,
            on_series_tap  = self.on_series_tap,
            on_series_hold = self.on_series_hold,
        }
    end

    -- ── Page indicator ────────────────────────────────────────────────────────
    -- "Page N / total  ‹  ›"  — centred, tap-zones on ‹ and › are handled by
    -- the Swipe handler (swipe is the primary pagination surface). The label is
    -- informational; the ‹/› glyphs are visual affordances only in v0.1.
    local page_text = string.format(
        "Page %d / %d    ‹  ›",
        self.page, total_pages
    )
    local label = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = LABEL_H },
        TextWidget:new{
            text = page_text,
            face = Font:getFace("smallinfofont", 11),
        },
    }

    -- ── Assemble ──────────────────────────────────────────────────────────────
    self[1] = FrameContainer:new{
        width     = self.width,
        height    = self.height,
        bordersize = 0,
        padding   = Size.padding.default,
        VerticalGroup:new{
            align = "left",
            chips,
            shelf_vg,
            label,
        },
    }
end

-- ─── _fetchAll ────────────────────────────────────────────────────────────────
-- Dispatches to the correct Repo method based on the active chip.
-- Generous limits so pagination is meaningful (200 flat; 60 series groups).

function LibraryView:_fetchAll()
    if self.chip == "recent"    then return Repo.getRecent(200)       end
    if self.chip == "latest"    then return Repo.getLatest(200)       end
    if self.chip == "favorites" then return Repo.getFavorites(200)    end
    if self.chip == "series"    then return Repo.getSeriesGroups(60)  end
    return {}
end

-- ─── Gesture handlers ────────────────────────────────────────────────────────

function LibraryView:onSwipe(_, ges)
    if ges.direction == "west" then
        -- West swipe = forward (next page).
        if self.page < (self._total_pages or 1) then
            self.page = self.page + 1
            self:_rebuild()
            UIManager:setDirty(self, "ui")
        end
    elseif ges.direction == "east" then
        -- East swipe = backward (prev page).
        if self.page > 1 then
            self.page = self.page - 1
            self:_rebuild()
            UIManager:setDirty(self, "ui")
        end
    end
    return true
end

function LibraryView:onTap(_, ges)
    -- Primary tap handling is delegated to child widgets (ChipStrip, SpineWidget,
    -- SeriesStack). We only intercept taps in the page-indicator zone at the foot
    -- as a secondary pagination surface.
    local label_top = self.height - LABEL_H - Size.padding.default
    if ges.pos.y >= label_top then
        -- Decide prev/next by which half of the screen was tapped.
        if ges.pos.x < self.width / 2 then
            if self.page > 1 then
                self.page = self.page - 1
                self:_rebuild()
                UIManager:setDirty(self, "ui")
            end
        else
            if self.page < (self._total_pages or 1) then
                self.page = self.page + 1
                self:_rebuild()
                UIManager:setDirty(self, "ui")
            end
        end
        return true
    end
    -- Fall through — child widgets handle all other taps.
    return false
end

-- ─── Close ────────────────────────────────────────────────────────────────────

function LibraryView:onClose()
    if self.on_close then self.on_close() end
    UIManager:close(self)
    return true
end

return LibraryView
