-- tokens.lua
-- Homescreen-scoped token expander. Bookends-compatible syntax, scoped
-- vocabulary tied to homescreen-available data sources.

local Tokens = {}

-- Token registry: name → function(book, state) → string
Tokens.expanders = {}

local function metaToken(field)
    return function(book) return book and book[field] or "" end
end

Tokens.expanders.title       = metaToken("title")
Tokens.expanders.author      = metaToken("author")
Tokens.expanders.author_2    = function(book)
    return book and book.authors and book.authors[2] or ""
end
Tokens.expanders.authors     = function(book)
    if not book or not book.authors then return "" end
    return table.concat(book.authors, ", ")
end
Tokens.expanders.series      = metaToken("series")
Tokens.expanders.series_name = metaToken("series_name")
Tokens.expanders.series_num  = metaToken("series_num")
Tokens.expanders.filename    = metaToken("filename")
Tokens.expanders.lang        = metaToken("lang")
Tokens.expanders.format      = metaToken("format")

local function pct(v) return string.format("%d%%", math.floor((v or 0) * 100 + 0.5)) end

Tokens.expanders.page_num   = function(b) return b and b.page_num and tostring(b.page_num) or "" end
Tokens.expanders.page_count = function(b) return b and b.page_count and tostring(b.page_count) or "" end
Tokens.expanders.book_pct       = function(b) return b and b.book_pct and pct(b.book_pct) or "" end
Tokens.expanders.book_pct_left  = function(b) return b and b.book_pct and pct(1 - b.book_pct) or "" end
Tokens.expanders.pages_left     = function(b)
    if not b or not b.page_num or not b.page_count then return "" end
    return tostring(b.page_count - b.page_num)
end

-- Match longest token names first so %book_pct_left wins over %book_pct.
local function compareLengthDesc(a, b) return #a > #b end
local function tokenNamesByLengthDesc()
    local names = {}
    for k in pairs(Tokens.expanders) do names[#names + 1] = k end
    table.sort(names, compareLengthDesc)
    return names
end

function Tokens.expand(format, book, state)
    if not format or format == "" then return "" end
    local names = tokenNamesByLengthDesc()
    local result = format
    for _, name in ipairs(names) do
        local expander = Tokens.expanders[name]
        result = result:gsub("%%" .. name, function()
            return tostring(expander(book, state) or "")
        end)
    end
    return result
end

return Tokens
