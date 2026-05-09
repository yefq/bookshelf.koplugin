# Tall-Screen 3-Column Layout Design

**Date:** 2026-05-09
**Branch:** mobile-layout
**Builds on:** `2026-05-09-tall-screen-extra-rows-design.md`
**Status:** Approved

## Problem

With 4 columns on a tall phone screen the covers are narrower than ideal.
3 columns gives larger, more readable covers while keeping the row counts
established in the extra-rows feature.

## Goal

On tall screens (width/height < 0.65) use 3 columns instead of 4. Standard
screens keep 4 columns unchanged.

## Layout matrix

```
                   cols   rows   books/page (normal)   books/page (expanded)
standard screen:    4      2/3        8 / 12                  12
tall screen:        3      3/4        9 / 12                  12
```

## Pagination

`_pageSize()` = non-expanded rows × cols. `_viewSize()` = current rows × cols.
The one-row overlap in expanded mode is preserved in both screen types.

```
                   PAGE_SIZE    VIEW_SIZE    overlap
standard normal:       8            8           0
standard expanded:     8           12           4   (one row of 4)
tall normal:           9            9           0
tall expanded:         9           12           3   (one row of 3)
```

## New helper

```lua
function BookshelfWidget:_nCols()
    return self:_isTallScreen() and 3 or 4
end
```

Placed alongside `_isTallScreen` / `_nShelves` in `bookshelf_widget.lua`.

## Touch points

### `shelf_row.lua`

| Line | Change |
|------|--------|
| 67 | `local n_slots = opts.n_slots or 4` |

### `bookshelf_widget.lua`

| Location | Change |
|----------|--------|
| After `_nShelves` | Add `_nCols()` helper |
| Line ~465 (`slot_w_natural`) | `local n_cols = self:_nCols()` then `(content_w - PAD*(n_cols-1)) / n_cols` |
| Line ~825 (`n_slots = 4` in BIM block) | `local n_slots = self:_nCols()` |
| `_buildShelfRows` body | `local n_cols = self:_nCols()` at top; add `n_slots = n_cols` to `row_opts`; item-slice loop: `for i = 1, n_cols do row_items[i] = items[(r-1)*n_cols+i] end` |
| Line ~1945 (`n_slots = 4` in fast-path) | `local n_slots = self:_nCols()` (fast-path only runs on standard screens; value is still 4, but kept consistent) |
| `_pageSize()` | `return (self:_isTallScreen() and 3 or 2) * self:_nCols()` |
| `_viewSize()` | `return self:_nShelves() * self:_nCols()` |

### `tests/_test_tall_screen.lua`

- Add `_nCols` tests: standard → 4, tall → 3
- Update `_pageSize` tall expectation: 12 → 9
- Update `_viewSize` tall normal expectation: 12 → 9
- Update `_viewSize` tall expanded expectation: 16 → 12

## What does NOT change

- Standard screen layout: 4 cols × 2/3 rows, page sizes 8/12 — identical
- `_isTallScreen()` threshold (0.65) — unchanged
- `_nShelves()` — unchanged
- `_swapShelvesInPlace` guard (`_nShelves() ~= 2`) — unchanged; fast-path
  still only runs for standard non-expanded screens where `_nCols()` = 4
- Hero card, chip strip, pagination footer — unchanged
