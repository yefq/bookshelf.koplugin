-- shelf_row.lua
-- A single shelf: 4 horizontally-arranged spine slots + dotted base rule.
-- Each slot can be a SpineWidget (single book) or a SeriesStack (series group).
-- Empty slots render as blank spacers so the row always has a fixed width.
--
-- The dotted base rule is a custom-painted Widget subclass. Its paintTo method
-- walks pixel columns 3dp apart and draws a 1×thickness fillRect at each stop.
-- Pattern reference: bookends_overlay_widget.lua lines 176–185 (MultiLineWidget).

local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup  = require("ui/widget/verticalgroup")
local HorizontalGroup= require("ui/widget/horizontalgroup")
local Widget         = require("ui/widget/widget")
local Geom           = require("ui/geometry")
local Size           = require("ui/size")
local Blitbuffer     = require("ffi/blitbuffer")
local SpineWidget    = require("spine_widget")
local SeriesStack    = require("series_stack")

local ShelfRow = {}

-- _renderDottedRule(width, thickness)
-- Returns a Widget subclass instance that paints a dotted horizontal rule via
-- bb:fillRect. Dot spacing is 3dp (1dp dot, 2dp gap). Uses COLOR_BLACK.
function ShelfRow._renderDottedRule(width, thickness)
    local DottedRule = Widget:extend{}

    function DottedRule:init()
        self.dimen = Geom:new{ w = width, h = thickness }
    end

    function DottedRule:paintTo(bb, x, y)
        -- Walk across the width placing 1×thickness filled rects every 3px.
        for px = 0, width - 1, 3 do
            bb:fillRect(x + px, y, 1, thickness, Blitbuffer.COLOR_BLACK)
        end
    end

    return DottedRule:new{}
end

-- ShelfRow.new(opts)
-- opts: {
--   width         number   total row width in pixels
--   height        number   slot height in pixels
--   items         table    list of up to 4 Book or SeriesGroup records (nil = empty slot)
--   gap           number   (optional) pixel gap between slots (default Size.padding.default)
--   on_book_tap   function (book) callback
--   on_book_hold  function (book) callback
--   on_series_tap function (series) callback
--   on_series_hold function (series) callback
-- }
function ShelfRow.new(opts)
    local n_slots = 4
    local gap     = opts.gap or Size.padding.default
    local slot_w  = math.floor((opts.width - gap * (n_slots - 1)) / n_slots)
    local row     = HorizontalGroup:new{}

    for i = 1, n_slots do
        -- Insert a gap spacer before every slot after the first.
        if i > 1 then
            row[#row + 1] = FrameContainer:new{
                bordersize = 0,
                Geom:new{ w = gap, h = opts.height },
            }
        end

        local item = opts.items and opts.items[i]
        if item and item.books then
            -- SeriesGroup (has a .books array)
            row[#row + 1] = SeriesStack:new{
                series    = item,
                width     = slot_w,
                height    = opts.height,
                on_tap    = opts.on_series_tap,
                on_hold   = opts.on_series_hold,
            }
        elseif item then
            -- Single book record
            row[#row + 1] = SpineWidget:new{
                book    = item,
                width   = slot_w,
                height  = opts.height,
                on_tap  = opts.on_book_tap,
                on_hold = opts.on_book_hold,
            }
        else
            -- Empty slot — blank spacer so layout is stable.
            row[#row + 1] = FrameContainer:new{
                bordersize = 0,
                Geom:new{ w = slot_w, h = opts.height },
            }
        end
    end

    -- Dotted base rule below the slot row.
    local rule = ShelfRow._renderDottedRule(opts.width, Size.line.thick)

    return VerticalGroup:new{ align = "left", row, rule }
end

return ShelfRow
