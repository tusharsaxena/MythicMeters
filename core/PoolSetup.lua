local _, NS = ...

-- core/PoolSetup.lua — wires the addon into LibKa0s-Pool-1.0 (library-stack-§7).
--
-- ── WHAT MOVED, AND WHAT DELIBERATELY DID NOT ────────────────────────────────────────────────
--
-- The free/active half of the window row pool is the library's. What stays in modules/Window.lua
-- is the part the library holds no opinion about, and there are two pieces of it:
--
--   `pool.all` — every row ever built, free ones included, iterated whenever the layout or the
--     lock changes so a PARKED row is re-laid-out too. A pool that only knew about active rows
--     would leave a stale-width row to surface later, when the group grew and it was handed out.
--     The library's pool is `{ free, active }` and says so; `all` is host state living beside it.
--
--   batch growth — rows are built five at a time, because each one costs an ApplyLayout and an
--     EnableCellMouse at build. `Acquire` calls its factory once per miss, so the batching moved
--     INTO the factory closure: it builds the batch, parks the surplus, registers all of it in
--     `all`, and hands one back. The library never needed to know.
--
-- ── ONE BEHAVIOR THAT CHANGED ────────────────────────────────────────────────────────────────
--
-- `Acquire` SHOWS what it hands back, and this addon's hand-rolled one did not — the row was shown
-- later, by `Row:Update`. The row is therefore briefly shown carrying the previous entry's content
-- and no anchors. It is invisible: the render loop anchors and updates each row in the same
-- iteration it acquires it, and WoW draws at the end of the frame, not in the middle of a Lua call.
-- Recorded because "invisible today" is a fact about the current call site, not a guarantee — a
-- future caller that acquires a row and does not immediately draw it would have a real flicker.
--
-- ── WHAT A DEGRADED INSTALL GETS ─────────────────────────────────────────────────────────────
--
-- The same three members, locally. A meter that cannot pool is a meter that allocates a frame per
-- row per refresh, four times a second, and WoW never frees one — so a call site that branched on
-- the library's presence would be a call site with a memory leak on one of its two paths.

local Pool = LibStub and LibStub("LibKa0s-Pool-1.0", true)

NS.Pool = Pool or {
    New = function() return { free = {}, active = {} } end,

    Acquire = function(pool, factory)
        local o = table.remove(pool.free)
        if not o then o = factory() end
        pool.active[#pool.active + 1] = o
        o:Show()
        return o
    end,

    ReleaseAll = function(pool, before)
        local active = pool.active
        -- BACKWARD, mirroring LibKa0s-Pool-1.0 minor 3. Acquire pops the free list from the END,
        -- so parking the last rank first leaves rank 1 on top and the next Acquire hands each
        -- widget back to the rank it already held. Walking forward alternates that mapping every
        -- render, which is the flicker this module's degraded half must not reintroduce.
        for i = #active, 1, -1 do
            local o = active[i]
            if before then before(o) end
            o:Hide()
            pool.free[#pool.free + 1] = o
        end
        for i = #active, 1, -1 do active[i] = nil end
    end,

    Counts = function(pool) return #pool.free, #pool.active end,
}
