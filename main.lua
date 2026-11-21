-- main.lua - Clipboard, a SnowDesktop clipboard-history card.
--
-- The clipboard subscription records text, files and images.
-- The refresh button uses a trusted gesture to read the current clipboard.
--
-- Image and file entries are session-bound. Original images and file paths
-- are copied using opaque references owned by the host.

local clipboard = module.require("modules/clipboard.lua")
local historyStorage = module.require("modules/storage.lua")
local thumbnail = module.require("modules/preview.lua")

local ACCENT = 0x6D8DFF
local TOAST_MS = 2800
local CONFIRM_MS = 3000
local MAX_TEXT = clipboard.MAX_TEXT
local MAX_STORED_TEXT = clipboard.MAX_STORED_TEXT
local TOOLTIPS = widget.hasFeature("interaction.tooltip")
local EDGE_FADE = widget.hasFeature("draw.clip.edgeFade")
local SEMANTIC_METADATA = widget.hasFeature("interaction.accessibility.metadata")
local SEARCH_INPUT = widget.hasFeature("control.textInput")
local PREVIEW_EDITOR = widget.hasFeature("view.surface.panel") and
    widget.hasFeature("view.tree.core") and widget.hasFeature("view.inputControls")
local PREVIEW_TEXT_MAX_BYTES = widget.hasFeature("view.textArea.largeValue") and MAX_TEXT or 4096
local WATCH_IMAGE = widget.hasFeature("data.clipboard.changes.image")
local IMAGE_DRAG = widget.hasFeature("interaction.dragImage")
local FILE_PATHS = widget.hasFeature("clipboard.filePaths")
local CENTER_GLYPH = widget.hasFeature("draw.glyph")
local HEADER_BG_HOVER = 0.10
local HEADER_BG_ACTIVE = 0.16

-- Keep the type hues quiet; the content, not the icon, carries the emphasis.
local TYPE_COLORS = {
    text = 0x8F9BAA,
    link = 0x64A7FF,
    code = 0xB89CFF,
    image = 0x53C9A2,
    files = 0xE8B467,
}

local settings = {
    presets = {
        {
            id = "frosted",
            label = l10n.tr("lua_widget.clipboard.preset_frosted"),
            default = true,
            values = {
                bg = 0x0E0E12, border = 0xFFFFFF, alpha = 0.24,
                borderAlpha = 0.10, gradientEndA = 0.24,
            },
        },
        {
            id = "solid",
            label = l10n.tr("lua_widget.clipboard.preset_solid"),
            values = {
                bg = 0x1C1C1E, border = 0xFFFFFF, alpha = 0.97,
                borderAlpha = 0.08, gradientEndA = 0.40,
            },
        },
        {
            id = "clear",
            label = l10n.tr("lua_widget.clipboard.preset_clear"),
            values = {
                bg = 0x000000, border = 0x000000, alpha = 0,
                borderAlpha = 0, gradientEndA = 0,
            },
        },
    },
    fields = {
        {
            key = "autoWatch",
            label = l10n.tr("lua_widget.clipboard.settings_watch"),
            description = l10n.tr("lua_widget.clipboard.settings_watch_desc"),
            type = "bool",
            default = true,
        },
        {
            key = "maxCount",
            label = l10n.tr("lua_widget.clipboard.settings_max"),
            description = l10n.tr("lua_widget.clipboard.settings_max_desc"),
            type = "select",
            default = "20",
            options = { "10", "20", "30", "50", "100", "150", "200" },
        },
        {
            key = "captureImages",
            label = l10n.tr("lua_widget.clipboard.settings_images"),
            description = l10n.tr("lua_widget.clipboard.settings_images_desc"),
            type = "bool",
            default = true,
        },
        {
            key = "captureFiles",
            label = l10n.tr("lua_widget.clipboard.settings_files"),
            description = l10n.tr("lua_widget.clipboard.settings_files_desc"),
            type = "bool",
            default = true,
        },
    },
}

local FILTERS = { "all", "text", "image", "files" }
local MENU_FILTERS = { "all", "text", "link", "code", "image", "files" }
local FILTER_KEYS = {
    all = "lua_widget.clipboard.menu_all",
    text = "lua_widget.clipboard.menu_text",
    link = "lua_widget.clipboard.menu_link",
    code = "lua_widget.clipboard.menu_code",
    image = "lua_widget.clipboard.menu_image",
    files = "lua_widget.clipboard.menu_files",
}
local FILTER_TOOLTIPS = {
    all = "lua_widget.clipboard.menu_filter_all",
    text = "lua_widget.clipboard.menu_filter_text",
    link = "lua_widget.clipboard.menu_filter_link",
    code = "lua_widget.clipboard.menu_filter_code",
    image = "lua_widget.clipboard.menu_filter_image",
    files = "lua_widget.clipboard.menu_filter_files",
}

local function isOn(key, fallback)
    local value = storage.get(key)
    if value == nil then return fallback ~= false end
    if type(value) ~= "string" then return value ~= false end
    value = value:lower()
    return value ~= "false" and value ~= "0"
end

local function config()
    local filter = storage.get("filter")
    if not FILTER_KEYS[tostring(filter or "")] then filter = "all" end
    local maxCount = tonumber(storage.get("maxCount")) or 20
    return {
        maxCount = math.max(10, math.min(200, maxCount)),
        autoWatch = isOn("autoWatch", true),
        captureImages = isOn("captureImages", true),
        captureFiles = isOn("captureFiles", true),
        filter = filter,
    }
end

local function isZh()
    return (l10n.language() or ""):sub(1, 2) == "zh"
end

-- contentTheme is the resolved foreground, not a guess based on wallpaper or
-- background RGB: 1 = dark ink, 0 = light ink. All card fills derive from it.
local function foregroundColor(color, lightTheme)
    if not lightTheme then return color end
    local r = math.floor(math.floor(color / 65536) % 256 * 0.57)
    local g = math.floor(math.floor(color / 256) % 256 * 0.57)
    local b = math.floor((color % 256) * 0.57)
    return r * 65536 + g * 256 + b
end

local function palette(snapshot)
    local light = snapshot.contentTheme == 1
    local accent = foregroundColor(snapshot.accentColor or ACCENT, light)
    -- Keep the filter readable on system accent colors with a light foreground.
    local brightness = (math.floor(accent / 65536) % 256) * 0.299
        + (math.floor(accent / 256) % 256) * 0.587 + (accent % 256) * 0.114
    return {
        ink = light and 0x25252B or 0xF5F6F8,
        muted = light and 0x575962 or 0xB7B9C3,
        surface = light and 0xFFFFFF or 0x0A0A0D,
        accent = accent,
        accentInk = brightness > 165 and 0x1C1C1E or 0xFFFFFF,
        light = light,
    }
end

-- Resolved palette cached per theme signature; the snapshot table is cheap to
-- read every frame, the derived palette is not rebuilt while it is stable.
local function paletteCached(model)
    local snapshot = widget.theme() or {}
    local sig = tostring(snapshot.contentTheme) .. "\1"
        .. tostring(snapshot.accentColor)
    local cached = model._palette
    if cached and cached.sig == sig then return cached.value end
    local value = palette(snapshot)
    model._palette = { sig = sig, value = value }
    return value
end

-- Text helpers -------------------------------------------------------------

local function textWidth(text, size, bold)
    return draw.measureText(text, size, 0, bold or false).width
end

local function ellipsize(text, size, maxWidth, bold)
    if maxWidth <= 1 then return "" end
    text = text or ""
    if textWidth(text, size, bold) <= maxWidth then return text end
    local ell = "\226\128\166"
    local count = clipboard.charCount(text)
    local low, high = 0, count
    while low < high do
        local mid = math.floor((low + high + 1) / 2)
        local probe = clipboard.truncate(text, mid) .. ell
        if textWidth(probe, size, bold) <= maxWidth then
            low = mid
        else
            high = mid - 1
        end
    end
    if low == 0 then return ell end
    return clipboard.truncate(text, low) .. ell
end

-- History and storage ------------------------------------------------------

local storageError

-- Bulk deletes run through transactions in batches of 50 keys: 1.0.2 proved
-- transactions of that size live, and 4-5 transactions stay far inside the
-- host's 32-write burst budget even when clearing a 200-entry history.
-- minHostVersion 1.0.16 guarantees storage.transaction, so there is no
-- per-key fallback.
local function removeKeys(keys)
    if #keys == 0 then return true end
    for start = 1, #keys, 50 do
        local batch = {}
        for index = start, math.min(start + 49, #keys) do
            batch[#batch + 1] = keys[index]
        end
        if not pcall(historyStorage.removeDropped, storage.transaction, batch) then
            return false
        end
    end
    return true
end

local function removeDropped(keys, dropped)
    for index = 1, #dropped do keys[#keys + 1] = "entry." .. dropped[index] end
    return removeKeys(keys)
end

local function loadHistory(model)
    local entries = {}
    local stale = {}
    local keys = storage.keys() or {}
    for index = 1, #keys do
        local key = keys[index]
        if key:sub(1, 6) == "entry." then
            local entry = clipboard.decode(storage.get(key))
            if entry then
                entry.id = key:sub(7)
                entries[#entries + 1] = entry
            else
                stale[#stale + 1] = key
            end
        end
    end
    local kept, removed = clipboard.dedupeText(entries)
    for index = 1, #removed do
        stale[#stale + 1] = "entry." .. removed[index]
    end
    removeKeys(stale)
    model.history = kept
    local pruned, dropped = clipboard.upsert(kept, nil, model.cfg.maxCount)
    model.history = pruned
    removeDropped({}, dropped)
end

local function persistEntry(entry)
    if entry.kind == "text" and entry.id then
        storage.set("entry." .. entry.id, clipboard.encode(entry))
    end
end

local function nextId(model, now)
    model.seq = (model.seq or 0) + 1
    return string.format("%d-%d", now, model.seq)
end

local function isQuotaError(err)
    return tostring(err or ""):find("quota", 1, true) ~= nil
end

-- Oldest unpinned persisted entries, for quota eviction. Pins sort first, so
-- the unpinned tail is scanned from the end; session-only kinds have no key.
local function evictOldestStored(list, excludeId, max)
    local evicted = {}
    for index = #list, 1, -1 do
        if #evicted >= max then break end
        local entry = list[index]
        if entry.kind == "text" and not entry.pinned
            and entry.id ~= excludeId then
            evicted[#evicted + 1] = entry.id
        end
    end
    return evicted
end

local function hasPending(model, kind)
    for _, job in pairs(model.tasks) do
        if job.kind == kind then return true end
    end
    return false
end

local function addSessionEntry(model, entry)
    local target = entry.refreshId
    if entry.kind == "image" and entry.imageId then
        target = clipboard.findImageEntryId(model.history, entry.imageId)
    elseif entry.kind == "files" and entry.pathRefs then
        local identity = table.concat(entry.pathRefs, "\1")
        target = nil
        for _, current in ipairs(model.history) do
            if current.pathRefs and table.concat(current.pathRefs, "\1") == identity then
                target = current.id
                break
            end
        end
    end
    local sorted, enriched, dropped
    if target then
        sorted, enriched = clipboard.enrichSession(model.history, target, entry)
    end
    if enriched then
        dropped = {}
    else
        target = entry.id
        entry.refreshId = nil
        sorted, dropped = clipboard.upsert(model.history, entry, model.cfg.maxCount)
    end
    if not removeDropped({}, dropped) then
        storageError(model, "storage remove failed")
        return false
    end
    model.history = sorted
    widget.invalidate()
    for _, kept in ipairs(sorted) do
        if kept.id == target then return target end
    end
end

local function hasIdentity(model, text)
    return clipboard.sameIdentity(model.history, text)
end

local function addTextEntry(model, text)
    local now = time.now()
    local sorted, dropped = clipboard.upsert(model.history, {
        id = nextId(model, now), ts = now, pinned = false, kind = "text", text = text,
    }, model.cfg.maxCount)
    local item = nil
    for index = 1, #sorted do
        if sorted[index].kind == "text" and sorted[index].text == text then
            item = sorted[index]
            break
        end
    end
    -- A pin-only history can reject a new unpinned entry at the cap.
    if not item then return end
    if #item.text <= MAX_STORED_TEXT then
        -- Commit the new text and pruning together: a full quota must not leave
        -- the old entry deleted while the new one exists only in memory.
        local ok, err = pcall(historyStorage.write, storage.transaction,
            item, dropped, clipboard.encode)
        if not ok and isQuotaError(err) then
            -- Storage full: evict the oldest unpinned entries and retry once
            -- before degrading to a session-only entry.
            local evicted = evictOldestStored(model.history, item.id, 8)
            if #evicted > 0 then
                local merged = {}
                for index = 1, #dropped do merged[#merged + 1] = dropped[index] end
                for index = 1, #evicted do merged[#merged + 1] = evicted[index] end
                ok, err = pcall(historyStorage.write, storage.transaction,
                    item, merged, clipboard.encode)
                if ok then
                    for index = 1, #evicted do
                        sorted = clipboard.removeId(sorted, evicted[index])
                    end
                end
            end
        end
        if not ok then
            storageError(model, err)
            item.sessionOnly = true
            model.history = clipboard.upsert(model.history, item, model.cfg.maxCount)
            widget.invalidate()
            return
        end
    elseif model.sessionNoticeAt ~= now then
        model.sessionNoticeAt = now
        toast(model, l10n.tr("lua_widget.clipboard.toast_session_text"))
    end
    model.history = sorted
    if #item.text > MAX_STORED_TEXT and #dropped > 0
        and not removeDropped({}, dropped) then
        storageError(model, "storage remove failed")
    end
    widget.invalidate()
end

local function toast(model, text)
    model.toast = { text = text, at = time.monotonic() }
    schedule.after("toast", TOAST_MS)
    widget.invalidate()
end

storageError = function(model, err)
    local message = tostring(err or "")
    if message:find("quota", 1, true) or message:find("storage", 1, true) then
        toast(model, l10n.tr("lua_widget.clipboard.toast_storage_full"))
    else
        toast(model, l10n.tr("lua_widget.clipboard.toast_save_failed"))
    end
    widget.log("warn", "clipboard: " .. message)
end

-- Clipboard subscription ---------------------------------------------------

local function startWatch(model)
    if model.watch or model.preview or not model.cfg.autoWatch then return end
    if not widget.hasPermission("clipboard.observe") then
        model.watchError = "permissionDenied"
        return
    end
    local ok, subscription = pcall(function()
        return data.subscribe("clipboard.changes")
    end)
    if not ok then
        model.watchError = "subscriptionUnavailable"
        return
    end
    local status = subscription:value()
    if status.available then
        model.watch = subscription
        model.watchError = nil
        return
    end
    model.watchError = status.error or "subscriptionUnavailable"
    subscription:unsubscribe()
end

local function stopWatch(model)
    if model.watch then model.watch:unsubscribe() end
    model.watch = nil
    model.watchError = nil
    model.watchKind = nil
    model.watchEntryId = nil
end

-- Clipboard tasks ----------------------------------------------------------

local refreshClipboard  -- defined below; a queued click re-enters after capture

local function finishCapture(model, batch)
    if model.captureGeneration ~= batch.generation or model.captureBatch ~= batch then
        return
    end
    model.captureActive = false
    model.captureBatch = nil
    widget.invalidate()
    -- A click during an active capture is queued instead of dropped.
    if model.pendingRefresh ~= nil then
        local preferred = model.pendingRefresh
        model.pendingRefresh = nil
        if preferred ~= true then
            refreshClipboard(model, preferred)
        else
            refreshClipboard(model)
        end
    end
end

local function readClipboard(model, format, batch, refreshId)
    if not batch or model.captureGeneration ~= batch.generation then return end
    local taskId, err = task.start("clipboard.read", { format = format })
    if not taskId then
        widget.log("warn", "clipboard read " .. format .. ": " .. tostring(err))
        toast(model, l10n.tr("lua_widget.clipboard.toast_read_failed"))
        finishCapture(model, batch)
        return
    end
    -- The watched row id rides on the task: an explicit refresh may enrich
    -- that exact row with a host handle/reference (id and kind must match).
    model.tasks[taskId] = {
        kind = "read", format = format, generation = batch.generation,
        refreshId = refreshId or nil,
    }
    widget.invalidate()
end

-- Read the last observed format or the explicit choice in the refresh menu.
refreshClipboard = function(model, preferred)
    if model.captureActive or hasPending(model, "read") then
        model.pendingRefresh = preferred or true
        return
    end
    local format = preferred or model.watchKind or "text"
    if format == "files" then format = "file-reference" end
    if format == "image" and not model.cfg.captureImages then format = "text" end
    if format == "file-reference" and not model.cfg.captureFiles then format = "text" end
    if format ~= "text" and format ~= "image" and format ~= "file-reference" then
        toast(model, l10n.tr("lua_widget.clipboard.toast_read_failed"))
        return
    end
    model.captureGeneration = (model.captureGeneration or 0) + 1
    local batch = { generation = model.captureGeneration, captured = 0 }
    model.captureActive = true
    model.captureBatch = batch
    readClipboard(model, format, batch, model.watchEntryId)
end

local function findEntry(model, id)
    for _, entry in ipairs(model.history) do
        if entry.id == id then return entry end
    end
end

local function canCopyEntry(entry)
    if entry.kind == "text" then return (entry.text or "") ~= "" end
    if entry.kind == "files" then return FILE_PATHS and entry.pathRefs ~= nil end
    if entry.kind ~= "image" or not entry.image then return false end
    local status = resource.status(entry.image)
    return status ~= nil and status.state == "ready"
end

local function copyEntry(model, id)
    local entry = findEntry(model, id)
    if not entry or hasPending(model, "write") then return end
    if not canCopyEntry(entry) then
        if entry.kind == "image" then
            toast(model, l10n.tr("lua_widget.clipboard.toast_image_unavailable"))
        end
        return
    end
    local arguments
    if entry.kind == "image" then
        arguments = { format = "image", image = entry.image }
    elseif entry.kind == "files" then
        arguments = { format = "file-paths", items = entry.pathRefs }
    else
        arguments = { format = "text", text = entry.text }
    end
    local taskId = task.start("clipboard.write", arguments)
    if not taskId then
        toast(model, l10n.tr("lua_widget.clipboard.toast_write_failed"))
        return
    end
    model.tasks[taskId] = { kind = "write", entryId = id }
    widget.invalidate()
end

local function deleteEntry(model, id)
    local entry = nil
    for index = 1, #model.history do
        if model.history[index].id == id then
            entry = model.history[index]
            break
        end
    end
    if not entry then return end
    local ok, err = true, nil
    if entry.kind == "text" then
        ok, err = pcall(storage.remove, "entry." .. id)
    end
    if not ok then
        toast(model, l10n.tr("lua_widget.clipboard.toast_delete_failed"))
        widget.log("warn", "clipboard delete: " .. tostring(err))
        return
    end
    model.history = clipboard.removeId(model.history, id)
    widget.invalidate()
end

local function pinEntry(model, id)
    local entry = nil
    for index = 1, #model.history do
        if model.history[index].id == id then
            entry = model.history[index]
            break
        end
    end
    if not entry then return end
    -- One toggle over the full list; the updated row is the persistence target.
    local updated = clipboard.togglePin(model.history, id, time.now())
    if entry.kind == "text" and #entry.text <= MAX_STORED_TEXT then
        local item
        for index = 1, #updated do
            if updated[index].id == id then item = updated[index] break end
        end
        if not item then return end
        local ok, err = pcall(persistEntry, item)
        if not ok then
            storageError(model, err)
            return
        end
    end
    model.history = updated
    widget.invalidate()
end

local function clearHistory(model)
    local keys = {}
    for index = 1, #model.history do
        local entry = model.history[index]
        if not entry.pinned and entry.kind == "text" and entry.id then
            keys[#keys + 1] = "entry." .. entry.id
        end
    end
    local remaining, changed = clipboard.clear(model.history, true)
    if not changed then return false end
    if not removeKeys(keys) then
        storageError(model, "storage remove failed")
        return false
    end
    model.history = remaining
    if #clipboard.filtered(model.history, model.cfg.filter) == 0 then
        storage.set("filter", "all")
        model.cfg = config()
    end
    local pruned, dropped = clipboard.upsert(model.history, nil, model.cfg.maxCount)
    model.history = pruned
    removeDropped({}, dropped)
    widget.invalidate()
    return true
end

-- Geometry -----------------------------------------------------------------

local entryMatches  -- defined with the row helpers below

local function buildFrame(model)
    local width = layout.contentWidth()
    local height = layout.contentHeight()
    if width < 120 or height < 120 then return nil end

    local cfg = model.cfg
    local compact = width < 300 or height < 240
    local controlRow = ui.metrics().layoutRowHeight
    local entryScale = controlRow / 28
    local entryGap = 6 * entryScale
    local padX = math.max(8, math.min(14, width * 0.045))
    local contentWidth = width - padX * 2
    -- A tall, narrow card still needs room for the title and tab labels.
    local controlSize = math.min(controlRow, math.max(28, contentWidth / 9))
    local toolWidth = math.min(controlSize * 21 / 28, contentWidth / 5)
    local toolGap = controlSize * 4 / 28
    local padY = controlRow * 7 / 28
    local rowGap = controlRow * 3 / 28
    local filterTop = padY + controlRow + rowGap
    local searchTop = filterTop + controlRow + rowGap
    local canSearch = SEARCH_INPUT and height >= searchTop + controlRow * 2 + padY
    local searchOpen = canSearch and model.searchOpen == true
    local bodyTop = (searchOpen and searchTop or filterTop) + controlRow + entryGap
    local bodyBottom = height - padY
    local rows = clipboard.filtered(model.history, cfg.filter)
    local query = searchOpen
        and string.lower(tostring(model.searchQuery or "")) or ""
    if query ~= "" then
        local zh = isZh()
        local matched = {}
        for index = 1, #rows do
            if entryMatches(rows[index], query, zh) then
                matched[#matched + 1] = rows[index]
            end
        end
        rows = matched
    end
    local columns = contentWidth >= controlRow * 14 and 2 or 1
    local gap = columns > 1 and 12 * entryScale or 0

    return {
        width = width,
        left = padX, right = width - padX, top = padY,
        controlRow = controlRow, controlSize = controlSize,
        toolWidth = toolWidth, toolGap = toolGap,
        filterTop = filterTop,
        canSearch = canSearch, searchOpen = searchOpen, searchTop = searchTop,
        bodyTop = bodyTop, bodyBottom = bodyBottom,
        bodyHeight = math.max(1, bodyBottom - bodyTop),
        entryHeight = controlRow * 1.5,
        entryGap = entryGap,
        entryScale = entryScale,
        columns = columns, gap = gap,
        rows = rows,
        count = #rows,
        cfg = cfg,
        compact = compact,
        model = model,
        c = paletteCached(model),
        titleFont = controlSize * 16 / 28,
        metaFont = controlSize * 11 / 28,
        rowTitleFont = 12 * entryScale,
        rowMetaFont = 10 * entryScale,
    }
end

-- Fluent System Icons Regular 20 from the font bundled with SnowDesktop.
local GLYPHS = {
    all = "\u{f406}",
    text = "\u{e557}",
    image = "\u{f488}",
    files = "\u{f418}",
    link = "\u{f4e4}",
    code = "\u{f2ef}",
    refresh = "\u{f190}",
    clipboard = "\u{f2c9}",
    search = "\u{f68f}",
    delete = "\u{f34c}",
    copy = "\u{f32b}",
    pin = "\u{f601}",
    unpin = "\u{f603}",
    close = "\u{f369}",
    history = "\u{f47e}",
    settings = "\u{f6a9}",
    warning = "\u{f869}",
}

local function drawGlyph(kind, cx, cy, size, color)
    if CENTER_GLYPH then
        draw.glyph(GLYPHS[kind], cx, cy, size, color, "fluent")
    else
        draw.fluent(GLYPHS[kind], cx - size / 2, cy - size / 2, size, color)
    end
end

local INK_TEXT = widget.hasFeature("draw.text.inkAlignment")
local CENTER_Y = { y = "center" }
local CENTER_TEXT = { x = "center", y = "center" }
local LEFT_TEXT = { x = "start", y = "center" }

local function drawAlignedText(x, y, text, font, color, width, bold, alpha, anchors, metrics)
    if not INK_TEXT then
        metrics = metrics or draw.measureText(text, font, 0, bold)
        local ink = metrics.ink
        y = (ink and ink.height > 0) and (y - ink.top - ink.height / 2)
            or (y - metrics.height / 2)
        if anchors.x == "center" then
            x = (ink and ink.width > 0) and (x - ink.left - ink.width / 2)
                or (x - metrics.width / 2)
        elseif anchors.x == "start" and ink then
            x = x - ink.left
        end
    end
    draw.text(x, y, text, font, color, width, bold, true, 0, alpha,
        nil, INK_TEXT and anchors or nil)
end

-- Header -------------------------------------------------------------------

-- The header title only changes with card size; keep it off the measure path.
local function headerTitle(model, font, room)
    local key = tostring(font) .. "\1" .. tostring(room)
    local cache = model._headerTitle
    if cache and cache.key == key then return cache.value end
    local title = ellipsize(l10n.tr("lua_widget.clipboard.name"), font, room, true)
    local value = { text = title, metrics = draw.measureText(title, font, 0, true) }
    model._headerTitle = { key = key, value = value }
    return value
end

local function drawHeader(f, model)
    local ink = f.c.ink
    local row = f.controlRow
    local cy = f.top + row / 2
    local buttonWidth = f.toolWidth
    local iconSize = math.min(f.controlSize * 16 / 28, buttonWidth - 2)
    local clearX = f.right - buttonWidth
    local searchX = f.canSearch and (clearX - f.toolGap - buttonWidth) or nil
    local showWarning = model.cfg.autoWatch and model.watchError
        and model.watchError ~= "permissionDenied"
    local titleRoom = (searchX or clearX) - (showWarning and 20 or 5) - f.left
    local title = headerTitle(model, f.titleFont, titleRoom)
    if title.text ~= "" then
        drawAlignedText(f.left, cy, title.text, f.titleFont, ink, titleRoom,
            true, 0.97, LEFT_TEXT, title.metrics)
        interaction.region({
            key = "header.title",
            shape = { type = "rect", x = f.left, y = f.top,
                width = titleRoom, height = row },
            events = { contextMenu = { id = "capture.menu" } },
            accessibility = { role = "heading", label = title.text },
        })
    end

    if showWarning and titleRoom >= 12 then
        local badgeX = f.left + title.metrics.width + 9
        drawGlyph("warning", badgeX, cy, 12, f.c.muted)
        interaction.region({
            key = "watch.badge",
            shape = { type = "roundedRect", x = badgeX - 5, y = cy - 7,
                width = 11, height = 14, radius = 5 },
            cursor = "hand",
            events = { click = { id = "watch.retry" } },
            tooltip = TOOLTIPS and
                l10n.tr("lua_widget.clipboard.badge_watch_offline") or nil,
            accessibility = { role = "button",
                label = l10n.tr("lua_widget.clipboard.badge_watch_offline") },
        })
    end

    if SEARCH_INPUT and searchX then
        local searchKey = "search.toggle"
        local searchActive = f.searchOpen == true
        local searchHovered = interaction.isHovered(searchKey)
        draw.rect(searchX, f.top, buttonWidth, row,
            searchActive and f.c.accent or ink, 7,
            searchActive and HEADER_BG_ACTIVE
                or (searchHovered and HEADER_BG_HOVER or 0))
        drawGlyph("search", searchX + buttonWidth / 2, cy, iconSize,
            searchActive and f.c.accent or f.c.muted)
        local searchRegion = {
            key = searchKey,
            shape = { type = "roundedRect", x = searchX, y = f.top,
                width = buttonWidth, height = row, radius = 7 },
            cursor = "hand",
            events = { click = { id = "search.toggle" } },
            accessibility = { role = "button",
                label = l10n.tr("lua_widget.clipboard.menu_search") },
        }
        if TOOLTIPS then
            searchRegion.tooltip = l10n.tr("lua_widget.clipboard.search_hint")
        end
        interaction.region(searchRegion)
    end

    local clearKey = "clear"
    local armed = model.confirmAt > 0 and time.monotonic() < model.confirmAt
    local hovered = interaction.isHovered(clearKey)
    draw.rect(clearX, f.top, buttonWidth, row,
        armed and f.c.accent or ink, 7,
        armed and HEADER_BG_ACTIVE or (hovered and HEADER_BG_HOVER or 0))
    drawGlyph("delete", clearX + buttonWidth / 2, cy, iconSize,
        armed and f.c.accent or f.c.muted)
    local clearRegion = {
        key = clearKey,
        shape = { type = "roundedRect", x = clearX, y = f.top,
            width = buttonWidth, height = row, radius = 7 },
        cursor = "hand",
        events = { click = { id = "clear.click" } },
        accessibility = { role = "button",
            label = l10n.tr("lua_widget.clipboard.menu_clear") },
    }
    if TOOLTIPS then
        clearRegion.tooltip = l10n.tr(armed and
            "lua_widget.clipboard.toast_confirm" or
            "lua_widget.clipboard.menu_clear_hint")
    end
    interaction.region(clearRegion)

end

-- Category filters ----------------------------------------------------------

local function drawFilters(f)
    local ink = f.c.ink
    local y = f.filterTop
    local height = f.controlRow
    local cy = y + height / 2
    local wide = f.width >= 285
    local groupWidth = f.right - f.left
    draw.rect(f.left, y, groupWidth, height, ink, 9, 0.055)

    local tabWidth = groupWidth / #FILTERS
    for index, key in ipairs(FILTERS) do
        local x = f.left + (index - 1) * tabWidth
        local selected = f.cfg.filter == key
        local regionKey = "filter." .. key
        local hovered = interaction.isHovered(regionKey)
        local font = f.metaFont
        local glyphSize = f.controlSize * (wide and 14 or 16) / 28
        local label = wide and ellipsize(l10n.tr(FILTER_KEYS[key]), font,
            tabWidth - glyphSize - 11, selected) or ""
        local metrics = wide and draw.measureText(label, font, 0, selected)
        local contentW = glyphSize + (wide and (4 + metrics.width) or 0)
        local gx = x + (tabWidth - contentW) / 2 + glyphSize / 2
        if selected then
            draw.rect(x + 2, y + 2, tabWidth - 4, height - 4,
                f.c.surface, 7, wide and 0.16 or 0.20)
            draw.strokeRect(x + 2, y + 2, tabWidth - 4, height - 4,
                f.c.accent, 7, 1, wide and 0.45 or 0.62)
        elseif hovered then
            draw.rect(x + 2, y + 2, tabWidth - 4, height - 4, ink, 7, 0.055)
        end
        local glyphY = CENTER_GLYPH and cy
            or (cy + (key == "all" and glyphSize * 0.13 or glyphSize * 0.07))
        drawGlyph(key, gx, glyphY, glyphSize, selected and f.c.accent or f.c.muted)
        if wide then
            drawAlignedText(gx + glyphSize / 2 + 4, cy,
                label, font, selected and f.c.accent or f.c.muted,
                0, selected, nil, CENTER_Y, metrics)
        end
        local region = {
            key = regionKey,
            shape = { type = "roundedRect", x = x, y = y,
                width = tabWidth, height = height, radius = 8 },
            cursor = "hand",
            events = {
                click = { id = "filter.set:" .. key },
                contextMenu = { id = "filter.menu" },
            },
            accessibility = { role = "button",
                label = l10n.tr(FILTER_KEYS[key]) },
        }
        if TOOLTIPS then region.tooltip = l10n.tr(FILTER_TOOLTIPS[key]) end
        interaction.region(region)
    end
end

-- Rows ---------------------------------------------------------------------

-- Calendar parts are stable per timestamp; relativeTime reads them once.
local function entryParts(entry)
    if entry._partsAt ~= entry.ts then
        entry._partsAt = entry.ts
        entry._parts = time.parts(entry.ts)
    end
    return entry._parts
end

local function rowTitle(entry, zh)
    if entry.kind == "image" then
        if entry.image then
            return (zh and "图片 · " or "Image · ")
                .. tostring(entry.width or 0) .. " × " .. tostring(entry.height or 0)
        end
        if entry.imageData then return zh and "图片缩略图" or "Image thumbnail" end
        return (zh and "图片 · " or "Image · ")
            .. tostring(entry.width or 0) .. " × " .. tostring(entry.height or 0)
    elseif entry.kind == "files" then
        return clipboard.fileTitle(entry.names, zh)
    end
    return clipboard.preview(entry.text, 320)
end

-- Cached row title. The text branch runs a full-text gsub per call, so it is
-- memoized behind a content signature; underscore fields never reach storage
-- (encode reads ts/pinned/text only) and are copied with the entry by pin.
local function rowTitleCached(entry, zh)
    local sig
    if entry.kind == "image" then
        sig = (entry.image and "i" or "p") .. tostring(entry.width or 0)
            .. "x" .. tostring(entry.height or 0)
    elseif entry.kind == "files" then
        sig = tostring(entry.names and #entry.names or 0) .. "\1"
            .. tostring(entry.names and entry.names[1] or "")
    else
        sig = "t"
    end
    local key = (zh and "zh" or "en") .. "\1" .. sig
    if entry._titleAt == key then return entry._title end
    local value = rowTitle(entry, zh)
    entry._titleAt, entry._title = key, value
    return value
end

-- Full-text search for text entries (cached lowercase, text is immutable per
-- entry); image and file rows match against their display title.
local function entrySearchText(entry)
    if entry.kind ~= "text" then return nil end
    if entry._searchLower == nil then
        entry._searchLower = string.lower(entry.text or "")
    end
    return entry._searchLower
end

entryMatches = function(entry, query, zh)
    local haystack = entrySearchText(entry)
    if haystack == nil then
        haystack = string.lower(rowTitleCached(entry, zh))
    end
    return string.find(haystack, query, 1, true) ~= nil
end

local function rowMeta(entry, zh, now, nowParts, copyable)
    local timeText = clipboard.relativeTime(entry.ts, now, zh,
        entryParts(entry), nowParts)
    local sizeText
    if entry.kind == "text" and entry.sessionOnly then
        sizeText = l10n.tr("lua_widget.clipboard.meta_unsaved")
    elseif entry.kind == "text" then
        sizeText = l10n.tr("lua_widget.clipboard.meta_chars",
            clipboard.charCount(entry.text))
    elseif entry.kind == "image" then
        sizeText = copyable and l10n.tr("lua_widget.clipboard.meta_image_session")
            or l10n.tr("lua_widget.clipboard.meta_thumbnail")
    else
        local count = entry.names and #entry.names or 0
        if count > 1 then
            sizeText = l10n.tr("lua_widget.clipboard.meta_files", count)
        else
            sizeText = l10n.tr(copyable and "lua_widget.clipboard.meta_file_session"
                or "lua_widget.clipboard.meta_read_only")
        end
    end
    return timeText .. " · " .. sizeText
end

local function drawRowAction(key, x, y, size, glyph, color,
        label, tooltip, value)
    local hovered = interaction.isHovered(key)
    local pressed = interaction.isPressed(key)
    local radius = size * 6 / 22
    draw.rect(x, y, size, size, color, radius,
        pressed and 0.20 or (hovered and 0.12 or 0))
    drawGlyph(glyph, x + size / 2, y + size / 2, size * 15 / 22, color)
    local region = {
        key = key,
        shape = { type = "roundedRect", x = x, y = y,
            width = size, height = size, radius = radius },
        cursor = "hand",
        events = { click = { id = glyph == "copy" and "entry.copy"
            or "entry.delete", value = value } },
        accessibility = { role = "button", label = label },
    }
    if TOOLTIPS then region.tooltip = tooltip end
    interaction.region(region)
end

local function drawImagePreview(entry, x, y, width, height)
    if entry.image and canCopyEntry(entry) and pcall(draw.imageFit,
        entry.image, x, y, width, height, "contain") then
        return true
    end
    local pixels = entry.pixels
    if not pixels then return false end
    local scale = math.min(width / pixels.width, height / pixels.height)
    local imageX = x + (width - pixels.width * scale) / 2
    local imageY = y + (height - pixels.height * scale) / 2
    for row, runs in ipairs(pixels.rows) do
        for _, run in ipairs(runs) do
            draw.rect(imageX + run.x * scale, imageY + (row - 1) * scale,
                run.width * scale + 0.05, scale + 0.05, run.color, 0, 0.98)
        end
    end
    return true
end

local function drawRow(f, entry, x, width, y, now, zh, nowParts)
    local ink = f.c.ink
    local height = f.entryHeight
    local scale = f.entryScale
    local radius = 10 * scale
    -- Reserve text room on narrow cards by compressing horizontal chrome.
    local insetScale = math.min(scale, width / (6 * 28))
    local key = "row." .. tostring(entry.id)
    local hovered = interaction.isHovered(key)
    local pressed = interaction.isPressed(key)
    draw.rect(x, y, width, height, f.c.surface, radius,
        pressed and 0.22 or (hovered and 0.18 or 0.14))
    draw.strokeRect(x, y, width, height, entry.pinned and f.c.accent or ink,
        radius, (entry.pinned and 1.2 or 1) * scale,
        entry.pinned and 0.55 or (hovered and 0.22 or 0.16))

    local glyphKind = entry.kind
    local copyable = canCopyEntry(entry)
    if glyphKind == "text" then glyphKind = clipboard.kindOfEntry(entry) end
    local tint = foregroundColor(TYPE_COLORS[glyphKind] or TYPE_COLORS.text, f.c.light)
    local tile = 30 * insetScale
    local tileX = x + 10 * insetScale
    local tileY = y + (height - tile) / 2
    if entry.kind ~= "image" or not drawImagePreview(entry, tileX, tileY, tile, tile) then
        draw.rect(tileX, tileY, tile, tile, tint, 8 * insetScale, f.c.light and 0.075 or 0.09)
        drawGlyph(glyphKind, tileX + tile / 2, tileY + tile / 2,
            tile * 0.56, tint)
    end

    local actionSize = 22 * insetScale
    local actionGap = 3 * insetScale
    local actionsX = x + width - 10 * insetScale - actionSize * 2 - actionGap
    local textX = tileX + tile + 10 * insetScale
    local titleMax = math.max(0, actionsX - 8 * insetScale - textX)
    local titleText = rowTitleCached(entry, zh)
    local titleKey = tostring(f.rowTitleFont) .. "\1" .. tostring(titleMax)
    local titleCache = entry._titleFit
    if not titleCache or titleCache.key ~= titleKey or titleCache.text ~= titleText then
        local title = ellipsize(titleText, f.rowTitleFont, titleMax, false)
        titleCache = {
            key = titleKey, text = titleText, value = title,
            metrics = draw.measureText(title, f.rowTitleFont),
        }
        entry._titleFit = titleCache
    end
    local metaText = rowMeta(entry, zh, now, nowParts, copyable)
    local metaKey = tostring(f.rowMetaFont) .. "\1" .. tostring(titleMax)
        .. "\1" .. metaText
    local metaCache = entry._metaFit
    if not metaCache or metaCache.key ~= metaKey then
        local meta = ellipsize(metaText, f.rowMetaFont, titleMax, false)
        metaCache = {
            key = metaKey, value = meta,
            metrics = draw.measureText(meta, f.rowMetaFont),
        }
        entry._metaFit = metaCache
    end
    if titleMax > 0 then
        local titleLine = math.max(titleCache.metrics.height, f.rowTitleFont)
        local metaLine = math.max(metaCache.metrics.height, f.rowMetaFont)
        local textGap = 2 * scale
        local textTop = y + (height - titleLine - metaLine - textGap) / 2
        drawAlignedText(textX, textTop + titleLine / 2, titleCache.value, f.rowTitleFont,
            ink, titleMax, false, 0.96, CENTER_Y, titleCache.metrics)
        local metaY = textTop + titleLine + textGap + metaLine / 2
        drawAlignedText(textX, metaY, metaCache.value, f.rowMetaFont,
            f.c.muted, titleMax, false, nil, CENTER_Y, metaCache.metrics)
    end

    local actionY = y + (height - actionSize) / 2
    if copyable then
        local copied = f.model ~= nil and f.model.copiedId == entry.id
        drawRowAction("copy." .. entry.id, actionsX, actionY, actionSize,
            "copy", copied and f.c.accent or f.c.muted,
            l10n.tr(entry.kind == "files" and "lua_widget.clipboard.menu_copy_path"
                or "lua_widget.clipboard.menu_copy"),
            l10n.tr(entry.kind == "files" and "lua_widget.clipboard.menu_copy_path"
                or "lua_widget.clipboard.menu_copy_hint"), entry.id)
    elseif entry.pinned then
        drawGlyph("pin", actionsX + actionSize / 2, actionY + actionSize / 2,
            actionSize * 14 / 22, f.c.accent)
    end
    drawRowAction("delete." .. entry.id, actionsX + actionSize + actionGap,
        actionY, actionSize, "delete", f.c.muted,
        l10n.tr("lua_widget.clipboard.menu_delete"),
        l10n.tr("lua_widget.clipboard.menu_delete_hint"), entry.id)
    if entry.pinned and copyable then
        drawGlyph("pin", x + 6 * insetScale, y + 7 * scale, 9 * insetScale, f.c.accent)
    end

    local regionTop = math.max(y, f.bodyTop)
    local regionBottom = math.min(y + height, f.bodyBottom)
    if regionBottom - regionTop > 2 then
        local previewable = entry.kind == "text" or
            (entry.kind == "image" and (copyable or entry.pixels ~= nil))
        interaction.region({
            key = key,
            shape = { type = "roundedRect", x = x, y = regionTop,
                width = math.max(1, actionsX - x), height = regionBottom - regionTop,
                radius = radius },
            cursor = previewable and "hand" or "default",
            dragImage = IMAGE_DRAG and entry.kind == "image" and copyable and entry.image or nil,
            events = {
                click = previewable and { id = "entry.preview", value = entry.id } or nil,
                contextMenu = { id = "entry.menu", value = entry.id },
            },
            accessibility = {
                role = previewable and "button" or "listitem",
                label = titleText,
                hint = previewable and l10n.tr("lua_widget.clipboard.preview_title") or nil,
                value = SEMANTIC_METADATA and metaText or nil,
            },
        })
    end
end

local function drawEmpty(f, model)
    local cx = (f.left + f.right) / 2
    local filter = f.cfg.filter
    local searching = f.searchOpen and (model.searchQuery or "") ~= ""
    local titleKey = searching and "lua_widget.clipboard.search_empty_title"
        or (filter == "all" and "lua_widget.clipboard.empty_title"
        or "lua_widget.clipboard.empty_filter")
    local font = f.compact and 12 or 14
    local iconSize, gap = 17, 6
    local width = f.right - f.left
    local title = ellipsize(l10n.tr(titleKey), font, width - iconSize - gap, false)
    local metrics = draw.measureText(title, font)
    local x = cx - (iconSize + gap + metrics.width) / 2
    local showAction = not searching and f.bodyHeight >= 58
    local buttonHeight = 26
    local blockHeight = math.max(iconSize, metrics.height) + (showAction and 9 + buttonHeight or 0)
    local centerY = f.bodyTop + math.max(0, (f.bodyHeight - blockHeight) / 2)
        + math.max(iconSize, metrics.height) / 2
    drawGlyph(searching and "search" or "clipboard",
        x + iconSize / 2, centerY, iconSize, f.c.muted)
    drawAlignedText(x + iconSize + gap, centerY, title,
        font, f.c.ink, 0, false, 0.78, CENTER_Y, metrics)
    if not showAction then return end

    local actionKey = filter == "image" and "lua_widget.clipboard.menu_capture_image"
        or (filter == "files" and "lua_widget.clipboard.menu_capture_files"
            or "lua_widget.clipboard.empty_action")
    local action = filter == "image" and "capture.image"
        or (filter == "files" and "capture.files" or "capture.refresh")
    local buttonFont = 11
    local label = ellipsize(l10n.tr(actionKey), buttonFont, width - 20, true)
    local labelMetrics = draw.measureText(label, buttonFont, 0, true)
    local buttonWidth = labelMetrics.width + 20
    local buttonX = cx - buttonWidth / 2
    local buttonY = centerY + math.max(iconSize, metrics.height) / 2 + 9
    draw.rect(buttonX, buttonY, buttonWidth, buttonHeight, f.c.accent, 7, 0.92)
    drawAlignedText(cx, buttonY + buttonHeight / 2, label, buttonFont,
        f.c.accentInk, 0, true, 0.98, CENTER_TEXT, labelMetrics)
    interaction.region({
        key = "empty.capture",
        shape = { type = "roundedRect", x = buttonX, y = buttonY,
            width = buttonWidth, height = buttonHeight, radius = 7 },
        cursor = "hand",
        events = {
            click = { id = action },
            contextMenu = { id = "capture.menu" },
        },
        accessibility = { role = "button", label = label },
    })
end

-- Session search row: the host-owned editor commits a stable descriptor every
-- render and binds its value to instance storage; clearing on close and at
-- setup keeps the query session-scoped in practice.
local function drawSearchRow(f, model)
    local ink = f.c.ink
    local y = f.searchTop
    local height = f.controlRow
    -- Reuse the trailing toolbar slot so the close and clear glyphs share a center.
    local closeWidth = f.toolWidth
    local closeX = f.right - closeWidth
    local inputRight = closeX - f.toolGap
    model.searchQuery = tostring(control.textInput({
        key = "search",
        storageKey = "searchQuery",
        shape = { type = "rect", x = f.left, y = y,
            width = math.max(40, inputRight - f.left), height = height },
        placeholder = l10n.tr("lua_widget.clipboard.search_hint"),
        fontSize = f.compact and 11 or 12,
        textColor = ink,
        placeholderColor = f.c.light and 0x8A8A92 or 0x6F7480,
        backgroundColor = ink,
        backgroundAlpha = 0.06,
        focusedBackgroundAlpha = 0.10,
        borderColor = ink,
        borderAlpha = 0.14,
        focusedBorderAlpha = 0.42,
        radius = 8,
        liveUpdate = true,
        maxBytes = 256,
    }) or "")
    local cy = y + height / 2
    local key = "search.close"
    local hovered = interaction.isHovered(key)
    draw.rect(closeX, y, closeWidth, height, ink, 7,
        hovered and 0.14 or 0)
    local iconSize = math.min(f.controlSize * 16 / 28, closeWidth - 2)
    local cx = closeX + closeWidth / 2
    if not CENTER_GLYPH then
        -- Older hosts position this glyph using font layout metrics.
        cx = cx - (1 + iconSize * 0.06)
        cy = cy + iconSize * 0.10
    end
    drawGlyph("close", cx, cy, iconSize, f.c.muted)
    interaction.region({
        key = key,
        shape = { type = "roundedRect", x = closeX, y = y,
            width = closeWidth, height = height, radius = 7 },
        cursor = "hand",
        events = { click = { id = "search.close" } },
        accessibility = { role = "button",
            label = l10n.tr("lua_widget.clipboard.menu_close_search") },
    })
end

local function drawToast(f, model)
    if not model.toast then return end
    local age = time.monotonic() - (model.toast.at or 0)
    if age > TOAST_MS then
        model.toast = nil
        return
    end
    local font = f.metaFont
    local maxWidth = f.right - f.left
    local text = ellipsize(model.toast.text, font, maxWidth - 24, false)
    local metrics = draw.measureText(text, font, 0, false)
    local width = math.min(maxWidth, metrics.width + 24)
    local height = 30
    local x = f.left + (maxWidth - width) / 2
    local y = f.bodyBottom - height - 8
    local background = f.c.light and 0xFFFFFF or 0x252936
    draw.rect(x, y, width, height, background, 10, 0.98)
    draw.strokeRect(x, y, width, height, f.c.ink, 10, 1, 0.10)
    drawAlignedText(x + width / 2, y + height / 2, text, font,
        f.c.ink, 0, false, 0.94, CENTER_TEXT, metrics)
end

local function render(_context, model)
    local f = buildFrame(model)
    if not f then return end

    drawHeader(f, model)
    drawFilters(f)
    if f.searchOpen then drawSearchRow(f, model) end

    if f.bodyHeight < f.controlRow / 2 then return end
    if f.count == 0 then
        drawEmpty(f, model)
    else
        local rowsPerColumn = math.ceil(f.count / f.columns)
        local rowPitch = f.entryHeight + f.entryGap
        local listHeight = rowsPerColumn * rowPitch - f.entryGap
        -- The host rounds the viewport to the nearest unit. Passing a rounded-up
        -- viewport as content can create a one-unit range even when the cards fit.
        local contentHeight = listHeight > f.bodyHeight and math.ceil(listHeight) or 0
        local scrollRight = f.width - math.max(2, layout.cu(2))
        local scrollbarGutter = math.max(0,
            math.max(14, layout.cu(15)) - (scrollRight - f.right))
        local scroll = interaction.scroll({
            key = "history",
            shape = { type = "rect", x = f.left, y = f.bodyTop,
                width = scrollRight - f.left, height = f.bodyHeight },
            contentHeight = contentHeight,
        })
        local listRight = f.right - (scroll and scroll.maximum > 0 and scrollbarGutter or 0)
        local cellWidth = (listRight - f.left - f.gap * (f.columns - 1)) / f.columns
        local offset = scroll and scroll.offset or 0
        local now = time.now()
        local nowParts = time.parts(now)
        local zh = isZh()

        draw.pushClip(f.left - 2, f.bodyTop, listRight - f.left + 4,
            f.bodyHeight, EDGE_FADE and scroll
                and { scroll = scroll, fadeLength = f.controlRow * 0.5 } or nil)
        for index = 1, #f.rows do
            local column = (index - 1) % f.columns
            local rowIndex = math.floor((index - 1) / f.columns)
            local cellX = f.left + column * (cellWidth + f.gap)
            local y = f.bodyTop - offset + rowIndex * rowPitch
            if y + f.entryHeight > f.bodyTop - 1 and y < f.bodyBottom + 1 then
                drawRow(f, f.rows[index], cellX, cellWidth, y, now, zh, nowParts)
            end
        end
        draw.popClip()
    end

    drawToast(f, model)
end

local function panel(_context, model)
    local entry = model.panelEntry or model.requestedPanelEntry
    if not entry then return end
    local padding = 14
    local color = palette(widget.theme() or {})
    if entry.kind == "text" and PREVIEW_EDITOR and #entry.text <= PREVIEW_TEXT_MAX_BYTES then
        return view.box({
            key = "preview.content",
            width = "fill", height = "fill", padding = padding,
            children = {
                view.textArea({
                    key = "preview.text.editor",
                    width = "fill", height = "fill",
                    value = model.panelDraft or entry.text,
                    maxBytes = PREVIEW_TEXT_MAX_BYTES,
                    liveUpdate = true,
                    action = { id = "preview.text.change", value = entry.id },
                    accessibility = { label = l10n.tr("lua_widget.clipboard.preview_title") },
                    fontSize = 14,
                    style = { foreground = color.ink, background = color.surface, cornerRadius = 8 },
                }),
            },
        })
    end
    local width = layout.contentWidth() - padding * 2
    local height = layout.contentHeight() - padding * 2
    if width < 24 or height < 24 then return end
    if entry.kind == "image" then
        if not drawImagePreview(entry, padding, padding, width, height) then
            draw.text(padding, padding, l10n.tr("lua_widget.clipboard.toast_image_unavailable"),
                14, color.muted, width)
        end
        return
    end
    local textWidth = width - 14
    if model.panelTextEntry ~= entry or model.panelTextWidth ~= textWidth then
        model.panelTextEntry = entry
        model.panelTextWidth = textWidth
        model.panelTextHeight = math.ceil(draw.measureText(entry.text, 14, textWidth).height) + 2
    end
    local scroll = interaction.scroll({
        key = "preview.text",
        shape = { type = "rect", x = padding, y = padding, width = width, height = height },
        contentHeight = math.min(1000000, math.max(math.ceil(height), model.panelTextHeight)),
    })
    draw.pushClip(padding, padding, textWidth, height)
    draw.text(padding, padding - scroll.offset, entry.text, 14, color.ink,
        textWidth, false, false, model.panelTextHeight)
    draw.popClip()
end

-- Lifecycle ----------------------------------------------------------------

local function setup(context)
    local model = {
        history = {},
        tasks = {},
        seq = 0,
        toast = nil,
        confirmAt = 0,
        cfg = config(),
        preview = context.preview == true,
        watch = nil,
        watchError = nil,
        searchOpen = false,
        searchQuery = "",
        copiedId = nil,
        pendingRefresh = nil,
    }
    loadHistory(model)
    if not model.preview then storage.set("searchQuery", "") end
    if model.preview and #model.history == 0 then
        -- Deterministic fixture for the catalog preview; never persisted.
        local now = time.now()
        model.history = clipboard.sorted({
            { id = "preview-1", ts = now - 120000, pinned = true,
                kind = "text", text = "https://snowdesktop.com/" },
            { id = "preview-2", ts = now - 25 * 60000, pinned = false,
                kind = "text", text = "npm run pack && npm run validate" },
            { id = "preview-3", ts = now - 2 * 3600000, pinned = false,
                kind = "text", text = "周五 9:30 站会，记得带上季度数据" },
            { id = "preview-4", ts = now - 26 * 3600000, pinned = false,
                kind = "files", names = { "课程表.txt", "课程表.mtz" } },
        })
    end
    startWatch(model)
    return model
end

local function menu(_context, model, _request)
    local request = _request or {}
    if request.id == "capture.menu" then
        local items = {
            { id = "capture.refresh",
                label = l10n.tr("lua_widget.clipboard.menu_capture"),
                icon = GLYPHS.refresh, iconFont = "fluent" },
            { id = "capture.text",
                label = l10n.tr("lua_widget.clipboard.menu_capture_text"),
                icon = GLYPHS.text, iconFont = "fluent" },
            { id = "capture.image",
                label = l10n.tr("lua_widget.clipboard.menu_capture_image"),
                icon = GLYPHS.image, iconFont = "fluent" },
            { id = "capture.files",
                label = l10n.tr("lua_widget.clipboard.menu_capture_files"),
                icon = GLYPHS.files, iconFont = "fluent" },
            { type = "separator" },
        }
        local watchStatus = model.watch and "lua_widget.clipboard.watch_on"
            or "lua_widget.clipboard.watch_off"
        if model.cfg.autoWatch and model.watchError == "permissionDenied" then
            watchStatus = "lua_widget.clipboard.watch_permission"
        end
        items[#items + 1] = {
            id = "watch.toggle",
            label = l10n.tr("lua_widget.clipboard.menu_watch") .. "\t" .. l10n.tr(watchStatus),
            icon = GLYPHS.history, iconFont = "fluent",
        }
        items[#items + 1] = {
            id = "settings.open",
            label = l10n.tr("lua_widget.clipboard.menu_settings"),
            icon = GLYPHS.settings, iconFont = "fluent",
        }
        return ui.menu(items)
    end

    if request.id == "filter.menu" then
        local items = {}
        for index = 1, #MENU_FILTERS do
            local key = MENU_FILTERS[index]
            local label = l10n.tr(FILTER_KEYS[key])
            if model.cfg.filter == key then
                label = label .. "\t" .. l10n.tr("lua_widget.clipboard.menu_selected")
            end
            items[#items + 1] = {
                id = "filter.set:" .. key,
                value = key,
                label = label,
                icon = GLYPHS[key], iconFont = "fluent",
            }
        end
        return ui.menu(items)
    end

    if request.id == "entry.menu" then
        local id = tostring(request.value or "")
        local entry = findEntry(model, id)
        if not entry then return nil end
        local items = {
            {
                id = "entry.copy:" .. id,
                label = l10n.tr(entry.kind == "files" and "lua_widget.clipboard.menu_copy_path"
                    or "lua_widget.clipboard.menu_copy"),
                enabled = canCopyEntry(entry),
                icon = GLYPHS.copy, iconFont = "fluent",
            },
            {
                id = "entry.pin:" .. id,
                label = l10n.tr(entry.pinned and
                    "lua_widget.clipboard.menu_unpin" or
                    "lua_widget.clipboard.menu_pin"),
                icon = entry.pinned and GLYPHS.unpin or GLYPHS.pin,
                iconFont = "fluent",
            },
            { type = "separator" },
            {
                id = "entry.delete:" .. id,
                label = l10n.tr("lua_widget.clipboard.menu_delete"),
                icon = GLYPHS.delete, iconFont = "fluent",
            },
        }
        return ui.menu(items)
    end

    return nil
end

-- Actions ------------------------------------------------------------------

local function clearArmed(model)
    return model.confirmAt > 0 and time.monotonic() < model.confirmAt
end

local function requestClear(model)
    if #model.history == 0 then
        model.confirmAt = 0
        widget.invalidate()
        return
    end
    if clearArmed(model) then
        local changed = clearHistory(model)
        model.confirmAt = 0
        schedule.cancel("clearConfirm")
        if changed then
            local hasPinned = #model.history > 0
            toast(model, l10n.tr(hasPinned and
                "lua_widget.clipboard.toast_cleared_pinned" or
                "lua_widget.clipboard.toast_cleared"))
        else
            widget.invalidate()
        end
    else
        model.confirmAt = time.monotonic() + CONFIRM_MS
        schedule.after("clearConfirm", CONFIRM_MS)
        toast(model, l10n.tr("lua_widget.clipboard.toast_confirm"))
        widget.invalidate()
    end
end

-- Region actions carry their payload in value.value; menu items cannot repeat
-- an id, so their entry id rides in the id suffix. Both forms land here.
local function entryIdFrom(value)
    local id = tostring(value.id or "")
    local suffix = id:match("^entry%.[a-z]+:(.+)$")
    if suffix then return suffix end
    return tostring(value.value or "")
end

local function handleAction(model, value)
    local id = tostring(value.id or "")
    if id == "capture.refresh" then
        refreshClipboard(model)
    elseif id == "capture.text" then
        refreshClipboard(model, "text")
    elseif id == "capture.image" then
        refreshClipboard(model, "image")
    elseif id == "capture.files" then
        refreshClipboard(model, "file-reference")
    elseif id:sub(1, 11) == "filter.set:" then
        local filter = id:sub(12)
        if FILTER_KEYS[filter] then
            storage.set("filter", filter)
            model.cfg = config()
            widget.invalidate()
        end
    elseif id == "clear.click" then
        requestClear(model)
    elseif id == "search.toggle" then
        model.searchOpen = not model.searchOpen
        if not model.searchOpen then
            model.searchQuery = ""
            storage.set("searchQuery", "")
        end
        widget.invalidate()
    elseif id == "search.close" then
        model.searchOpen = false
        model.searchQuery = ""
        storage.set("searchQuery", "")
        widget.invalidate()
    elseif id == "watch.retry" then
        startWatch(model)
        widget.invalidate()
    elseif id == "watch.toggle" then
        storage.set("autoWatch", model.cfg.autoWatch and "false" or "true")
        model.cfg = config()
        if model.cfg.autoWatch then startWatch(model) else stopWatch(model) end
        widget.invalidate()
    elseif id == "settings.open" then
        widget.openSettings()
    elseif id == "entry.preview" then
        local entry = findEntry(model, entryIdFrom(value))
        if not entry or entry.kind == "files" or entry == model.panelEntry then return end
        model.requestedPanelEntry = entry
        widget.openPanel({
            title = l10n.tr("lua_widget.clipboard.preview_title"),
            width = entry.kind == "image" and 640 or 520,
            height = entry.kind == "image" and 480 or 360,
        })
    elseif id == "preview.text.change" then
        local entry = model.panelEntry
        if value.surface == "panel" and entry and entry.kind == "text" and
            value.value == entry.id and type(value.text) == "string" and
            #value.text <= PREVIEW_TEXT_MAX_BYTES then
            model.panelDraft = value.text
            widget.invalidate()
        end
    elseif id == "entry.copy" or id:sub(1, 11) == "entry.copy:" then
        copyEntry(model, entryIdFrom(value))
    elseif id == "entry.pin" or id:sub(1, 10) == "entry.pin:" then
        pinEntry(model, entryIdFrom(value))
    elseif id == "entry.delete" or id:sub(1, 13) == "entry.delete:" then
        deleteEntry(model, entryIdFrom(value))
    end
end

local function handleTask(model, value)
    local job = model.tasks[value.taskId]
    if not job then return end
    model.tasks[value.taskId] = nil
    local batch = model.captureBatch
    if not batch or batch.generation ~= job.generation then batch = nil end

    if not value.ok or type(value.value) ~= "table" then
        local err = tostring(value.error or "readFailed")
        if job.kind == "read" then
            -- Known host codes map to localized text; the raw code stays in the
            -- log for diagnosis.
            toast(model, err == "formatUnavailable"
                and l10n.tr("lua_widget.clipboard.toast_read_failed")
                or l10n.tr("lua_widget.clipboard.toast_read_error"))
        else
            toast(model, l10n.tr(err == "clipboardImageUnavailable"
                and "lua_widget.clipboard.toast_image_unavailable"
                or "lua_widget.clipboard.toast_write_failed"))
        end
        widget.log("warn", "clipboard " .. job.kind .. ": " .. err)
        if batch then finishCapture(model, batch)
        else widget.invalidate() end
        return
    end

    local result = value.value
    if job.kind == "write" then
        model.copiedId = job.entryId
        schedule.after("copiedMark", 2500)
        toast(model, l10n.tr("lua_widget.clipboard.toast_copied"))
        widget.invalidate()
        return
    end
    local captured = false
    local now = time.now()
    if job.format == "text" then
        local text = type(result.text) == "string" and result.text or ""
        if text == "" then
            toast(model, l10n.tr("lua_widget.clipboard.toast_read_failed"))
        elseif #text > MAX_TEXT then
            toast(model, l10n.tr("lua_widget.clipboard.toast_too_long"))
        else
            if not hasIdentity(model, text) then addTextEntry(model, text) end
            captured = true
        end
    elseif job.format == "image" then
        if result.image then
            local width = tonumber(result.width) or 0
            local height = tonumber(result.height) or 0
            captured = addSessionEntry(model, {
                id = nextId(model, now), ts = now, pinned = false,
                kind = "image", image = result.image, imageId = result.imageId,
                width = width, height = height, refreshId = job.refreshId,
            })
        end
    elseif job.format == "file-reference" then
        local references, names = {}, {}
        for index = 1, #(result.items or {}) do
            local item = result.items[index]
            if type(item) == "table" and type(item.name) == "string"
                and item.name ~= "" and item.ref then
                references[#references + 1] = item.ref
                names[#names + 1] = item.name
            end
        end
        if #references > 0 then
            captured = addSessionEntry(model, {
                id = nextId(model, now), ts = now, pinned = false,
                kind = "files", names = names, pathRefs = FILE_PATHS and references or nil,
                refreshId = job.refreshId,
            })
        end
    end
    if captured and batch then batch.captured = batch.captured + 1 end
    if captured then
        toast(model, l10n.tr("lua_widget.clipboard.toast_captured"))
    end
    if batch then finishCapture(model, batch)
    else widget.invalidate() end
end

local function onClipboardChange(model, value)
    if not model.watch or type(value) ~= "table" then return end
    model.watchKind = nil
    model.watchEntryId = nil
    if value.format == "text" then
        model.watchKind = "text"
        addTextEntry(model, value.text)
    elseif value.format == "image" and model.cfg.captureImages then
        local pixels = thumbnail.decode(value.rgb, value.width, value.height)
        if not pixels then return end
        local image = WATCH_IMAGE and value.image or nil
        local now = time.now()
        local entry = {
            id = nextId(model, now), ts = now, pinned = false,
            kind = "image", image = image, imageId = value.imageId, imageData = value.rgb,
            pixels = pixels,
            width = image and value.imageWidth or pixels.width,
            height = image and value.imageHeight or pixels.height,
        }
        model.watchEntryId = addSessionEntry(model, entry)
        model.watchKind = "image"
    elseif value.format == "file-names" and model.cfg.captureFiles then
        local names = {}
        for index, name in ipairs(value.names) do
            names[index] = clipboard.truncate(name, 256)
        end
        local now = time.now()
        local entry = {
            id = nextId(model, now), ts = now, pinned = false,
            kind = "files", names = names,
            pathRefs = FILE_PATHS and type(value.pathRefs) == "table" and #value.pathRefs == #names
                and #names > 0 and value.pathRefs or nil,
        }
        model.watchEntryId = addSessionEntry(model, entry)
        model.watchKind = "files"
    elseif value.error == "clipboardTooLarge" then
        toast(model, l10n.tr("lua_widget.clipboard.toast_too_long"))
    elseif value.error then
        toast(model, l10n.tr("lua_widget.clipboard.toast_read_failed"))
    end
end

local function event(_context, model, value)
    if type(value) ~= "table" then return end
    if value.kind == "data.change" and value.topic == "clipboard.changes" then
        onClipboardChange(model, value.clipboard)
        return
    end
    if value.kind == "action" then
        handleAction(model, value)
        return
    end
    if value.kind == "task.complete" then
        handleTask(model, value)
        return
    end
    if value.kind == "panel" then
        if value.action == "opened" then
            model.panelEntry = model.requestedPanelEntry
            model.requestedPanelEntry = nil
            model.panelDraft = nil
        elseif value.action == "closed" then
            model.panelEntry = nil
            model.panelTextEntry = nil
            model.panelDraft = nil
        end
        return
    end
    if value.kind == "schedule" then
        if value.id == "toast" then
            model.toast = nil
            widget.invalidate()
        elseif value.id == "clearConfirm" then
            model.confirmAt = 0
            widget.invalidate()
        elseif value.id == "captureNext" then
            -- Legacy pending timers are cancelled during setup/dispose.
            model.captureNextAt = nil
        elseif value.id == "copiedMark" then
            model.copiedId = nil
            widget.invalidate()
        end
        return
    end
    if value.kind == "settings.changed" then
        local previousWatch = model.cfg.autoWatch
        model.cfg = config()
        if model.cfg.autoWatch ~= previousWatch then
            if model.cfg.autoWatch then startWatch(model) else stopWatch(model) end
        end
        if model.cfg.maxCount < #model.history then
            local pruned, dropped = clipboard.upsert(model.history, nil, model.cfg.maxCount)
            model.history = pruned
            if not removeDropped({}, dropped) then
                storageError(model, "storage remove failed")
            end
        end
        if #clipboard.filtered(model.history, model.cfg.filter) == 0
            and model.cfg.filter ~= "all" then
            storage.set("filter", "all")
            model.cfg = config()
        end
        widget.invalidate()
    end
end

local function dispose(_context, model)
    schedule.cancel("toast")
    schedule.cancel("clearConfirm")
    schedule.cancel("captureNext")
    schedule.cancel("copiedMark")
    model.captureGeneration = (model.captureGeneration or 0) + 1
    model.captureActive = false
    model.captureBatch = nil
    model.pendingRefresh = nil
    for taskId in pairs(model.tasks) do
        task.cancel(taskId)
    end
    stopWatch(model)
end

return widget.define({
    name = l10n.tr("lua_widget.clipboard.name"),
    useCustomStyle = true,
    followPersonalizationDefault = true,
    bg = 0x0E0E12,
    border = 0xFFFFFF,
    alpha = 0.24,
    borderAlpha = 0.10,
    gradientEndA = 0.24,
    settings = settings,
    setup = setup,
    render = render,
    panel = panel,
    menu = menu,
    event = event,
    dispose = dispose,
})
