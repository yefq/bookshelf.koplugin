-- folder_stack.lua
-- Renders a folder-as-magazine-file: the first book inside the folder peeks
-- out the top of a manilla cardboard "magazine file" shape; the folder name
-- sits centred on the cardboard's front face. Drop-shadowed to match the
-- depth of regular spine widgets.
--
-- Visual composition (back-to-front):
--   1. Magazine drop shadow — the magazine's polygon shape filled in
--      shadow-grey at SHADOW_OFFSET down+right of the card. Visible as an
--      L-shaped halo on the right and bottom edges of the magazine, and a
--      thinner band tracing the slope on its underside.
--   2. First-book cover (rendered via SpineWidget) inset slightly inside
--      the card so the cardboard's side walls visually wrap the book.
--   3. Magazine front: a filled cardboard polygon with a sloped top edge.
--      The slope rises on the LEFT (high y on right, low y on left → the
--      slope drops as the eye moves rightward, matching the reference
--      photo's open-mouth orientation). Below the slope: cardboard fill
--      to the bottom edge.
--   4. Folder name centred horizontally and vertically on the cardboard
--      (TextBoxWidget with bgcolor = CARDBOARD so its rendering matches
--      the surrounding fill rather than knocking out a white rectangle).
--
-- All shapes paint into an OverlapGroup at slot dimen so the whole stack
-- has the same getSize() / tap zone as a regular SpineWidget — drop-in
-- replacement at the ShelfRow slot level.

local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local CenterContainer= require("ui/widget/container/centercontainer")
local TopContainer   = require("ui/widget/container/topcontainer")
local TextWidget     = require("ui/widget/textwidget")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local Widget         = require("ui/widget/widget")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local Size           = require("ui/size")
local Font           = require("ui/font")
local Blitbuffer     = require("ffi/blitbuffer")
local Screen         = require("device").screen
local SpineWidget    = require("spine_widget")

-- The magazine front face is a TRIANGLE. Slope starts at (0, y_left)
-- on the left edge and runs down to the bottom-right corner (w-1, h-1)
-- — slope FALLS left-to-right. Edges by length at a 2:3 slot aspect:
-- TOP slope ≈ 0.82·card_h (longest), BOTTOM ≈ 0.67·card_h, LEFT ≈
-- 0.47·card_h (shortest). No right edge — slope meets the bottom at
-- the corner. The 0.47 LEFT edge keeps the magazine roughly 2/3 of
-- the prior quadrilateral height while still satisfying
-- "shortest edge on the left".
local SLOPE_LEFT_FRAC = 0.53   -- y at left edge (slope's top-left vertex)

-- Cardboard colour and a darker outline. Slightly denser than the
-- earlier values so the magazine reads as a solid object on the page
-- now that the drop shadow has been removed (see init below for the
-- composition; shadow was making the shape look 1-D rather than 3-D).
local CARDBOARD       = Blitbuffer.gray(0.30)
local CARDBOARD_EDGE  = Blitbuffer.gray(0.65)
local PAGE_BG         = Blitbuffer.COLOR_WHITE

-- Bottom-corner rounding (matches SpineWidget's CARD_RADIUS so adjacent
-- magazine and book spines on the same shelf have consistent corner
-- treatment). The TOP corners are kept angular — they're slope/wall
-- junctions, sharp by design in a real magazine file.
local CARD_RADIUS = Screen:scaleBySize(4)

-- Book inset in absolute pixels. Just enough that a thin band of
-- cardboard wraps the book on each side and the top — the book "barely
-- fits inside" the file rather than shrinking visibly inside it.
local BOOK_INSET_X = Screen:scaleBySize(3)
local BOOK_INSET_Y = Screen:scaleBySize(2)

-- Triangle painter for the magazine front. Vertices: (0, y_left),
-- (0, h-1), (w-1, h-1). Slope (top edge) runs from (0, y_left) down
-- to the bottom-right corner — falls left-to-right and meets the
-- bottom at the corner, so there's no separate right-side wall. Edge
-- ordering by length: TOP slope > BOTTOM > LEFT (the user's
-- "longest on top, shortest on left" constraint expressed as a 3-side
-- shape). Reused for both fill (CARDBOARD) and the drop-shadow
-- offset variant — only fill_color differs.
local MagazinePolygon = Widget:extend{
    width      = nil,
    height     = nil,
    y_left     = nil,    -- slope's y on the left edge (slope ends at bottom-right corner)
    fill_color = nil,
    edge_color = nil,    -- optional outline
    radius     = 0,      -- bottom-LEFT corner radius (0 = sharp)
}

function MagazinePolygon:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function MagazinePolygon:paintTo(bb, x, y)
    local w        = self.width
    local h        = self.height
    local yl       = self.y_left
    local fill     = self.fill_color
    local h1       = h - 1
    local slope_dy = h1 - yl
    if slope_dy <= 0 then return end
    -- Triangle interior. At row dy in [yl, h-1], the right boundary
    -- (the slope) is at x = (dy - yl) * (w-1) / slope_dy. Painted
    -- from x=0 (left edge) to that boundary inclusive.
    for dy = yl, h1 do
        local x_max = math.floor((dy - yl) * (w - 1) / slope_dy + 0.5)
        if x_max >= 0 then
            bb:paintRect(x, y + dy, x_max + 1, 1, fill)
        end
    end
    -- Round the bottom-left corner only — it's the only right-angle
    -- vertex. The other two (slope/left and slope/bottom) are acute
    -- angles that look natural sharp at chip-strip scale.
    local r    = self.radius or 0
    local r_sq = r * r
    if r > 0 then
        for i = 0, r - 1 do
            local dy = h - r + i
            local i_sq = (i + 1) * (i + 1)
            local cutoff = 0
            while cutoff < r and (r - cutoff) * (r - cutoff) + i_sq > r_sq do
                cutoff = cutoff + 1
            end
            if cutoff > 0 then
                bb:paintRect(x, y + dy, cutoff, 1, PAGE_BG)   -- BL only
            end
        end
    end
    if self.edge_color then
        local b    = Size.border.thin
        local edge = self.edge_color
        -- Bottom edge: full width (between BL rounded corner and BR sharp tip).
        bb:paintRect(x + r, y + h - b, w - r, b, edge)
        -- Left edge: from yl to bottom (stops at BL corner radius).
        bb:paintRect(x, y + yl, b, h - yl - r, edge)
        -- Slope: stair-step b×b stamps from (0, yl) to (w-1, h-1).
        local steps = math.max(w, slope_dy)
        for s = 0, steps do
            local px = math.floor(s * (w - 1) / steps + 0.5)
            local py = math.floor(yl + slope_dy * s / steps + 0.5)
            bb:paintRect(x + px, y + py, b, b, edge)
        end
        -- BL arc outline trace (where the rounded mask carved into the fill).
        if r > 0 then
            for i = 0, r - 1 do
                local dy = h - r + i
                local i_sq = (i + 1) * (i + 1)
                local cutoff = 0
                while cutoff < r and (r - cutoff) * (r - cutoff) + i_sq > r_sq do
                    cutoff = cutoff + 1
                end
                bb:paintRect(x + cutoff, y + dy, b, b, edge)
            end
        end
    end
end

local FolderStack = InputContainer:extend{
    folder      = nil,    -- { path, label, first_book }
    width       = nil,
    height      = nil,
    on_tap      = nil,
    on_hold     = nil,
    is_selected = false,
}

function FolderStack:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    -- No drop shadow on folders — the previous shadow read as "flat
    -- shape with shadow" rather than "3D file on the page". A darker
    -- cardboard fill plus the perimeter outline carry the solidity
    -- without extra layering. Folder fills the full slot (book covers
    -- still leave SHADOW_OFFSET space for their own shadows; the
    -- folder doesn't need that allocation).
    local card_w = self.width
    local card_h = self.height

    -- Slope's left endpoint (slope's right end is fixed at the
    -- bottom-right corner of the card).
    local y_left = math.floor(card_h * SLOPE_LEFT_FRAC)

    -- Book layer: SpineWidget for the first book, inset within the card
    -- by a few pixels on every side. The book's bottom extends to the
    -- card bottom and is hidden by the magazine's cardboard fill below
    -- the slope; only the top portion (above the slope) is visible.
    local book_w = card_w - BOOK_INSET_X * 2
    local book_h = card_h - BOOK_INSET_Y
    local book_widget
    if self.folder and self.folder.first_book then
        book_widget = SpineWidget:new{
            book        = self.folder.first_book,
            width       = book_w,
            height      = book_h,
            cover_fill  = true,
            is_selected = self.is_selected,
        }
    else
        -- Empty folder: SpineWidget's fallback path with the folder's
        -- label as the title so the "?" placeholder reads correctly.
        book_widget = SpineWidget:new{
            book        = { title = self.folder and self.folder.label or "" },
            width       = book_w,
            height      = book_h,
            is_selected = self.is_selected,
        }
    end
    local book_positioned = FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_top   = BOOK_INSET_Y,
        padding_left  = BOOK_INSET_X,
        book_widget,
    }

    -- Magazine front: cardboard triangle in front of the book.
    local magazine = MagazinePolygon:new{
        width      = card_w,
        height     = card_h,
        y_left     = y_left,
        fill_color = CARDBOARD,
        edge_color = CARDBOARD_EDGE,
        radius     = CARD_RADIUS,
    }

    -- Folder label: positioned inside the triangle. The triangle widens
    -- going down — at row y, the cardboard extends from x=0 to slope_x(y).
    -- We place the label band in the LOWER portion (where the triangle
    -- is widest) and constrain its width to what fits at the band's TOP
    -- row, then centre the label horizontally within that available
    -- space. Probing the unconstrained TextBoxWidget gives its content
    -- height so the CenterContainer can vertically centre it.
    local label_text = self.folder and self.folder.label or ""
    label_text = label_text:gsub("/$", "")
    -- Pick a label band starting at ~70% of cardboard height (where the
    -- triangle has reached ~70% of its right-bottom width).
    local label_top     = math.floor(y_left + (card_h - y_left) * 0.55)
    local label_h_avail = card_h - label_top - Size.padding.small
    -- Available width = slope's x at row label_top, minus a small
    -- inset on each side so the text doesn't kiss the slope.
    local slope_x_at_top = math.floor((label_top - y_left) * (card_w - 1)
                                       / math.max(1, card_h - 1 - y_left))
    local label_w_avail = slope_x_at_top - Size.padding.small * 2
    if label_w_avail < Size.padding.default * 2 then
        label_w_avail = Size.padding.default * 2
    end
    local face = Font:getFace("infofont", 14)
    local probe = TextBoxWidget:new{
        text  = label_text,
        face  = face,
        bold  = true,
        width = label_w_avail,
    }
    local content_h = probe:getSize().h
    probe:free()
    local fits      = content_h <= label_h_avail
    local label_h   = fits and content_h or label_h_avail
    local label_widget = TextBoxWidget:new{
        text                          = label_text,
        face                          = face,
        bold                          = true,
        fgcolor                       = Blitbuffer.COLOR_BLACK,
        bgcolor                       = CARDBOARD,
        width                         = label_w_avail,
        alignment                     = "center",
        height                        = label_h,
        height_overflow_show_ellipsis = not fits,
    }
    -- Centre horizontally within the available cardboard band (which
    -- starts at x=0 and extends to slope_x_at_top), and vertically
    -- within label_h_avail.
    local label_centered = CenterContainer:new{
        dimen = Geom:new{ w = slope_x_at_top, h = label_h_avail },
        label_widget,
    }
    local label_positioned = FrameContainer:new{
        bordersize  = 0,
        padding     = 0,
        padding_top = label_top,
        label_centered,
    }

    self[1] = OverlapGroup:new{
        dimen = self.dimen,
        book_positioned,       -- 1: book cover, inset within card
        magazine,              -- 2: cardboard front (covers book bottom)
        label_positioned,      -- 3: folder name centred on cardboard
    }
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function FolderStack:onTap()
    if self.on_tap then self.on_tap(self.folder) end
    return true
end
function FolderStack:onHold()
    if self.on_hold then self.on_hold(self.folder) end
    return true
end

return FolderStack
