-- modules/clipboard.lua - history model and text formatting.
--
-- Pure functions only: the host APIs live in main.lua, so `snowwidget test`
-- exercises every branch here. History entries are plain tables:
--   { id = "1731...-3", ts = epochMs, pinned = bool, kind = "text",
--     text = "..." }
-- Image and file entries are session-only on SnowDesktop (the host hands out
-- instance-bound image handles and opaque file refs, neither persistable), so
-- they carry `kind = "image"/"files"` and no storage line.

local clipboard = {}

local MAX_TEXT = 256 * 1024 -- session-only text; manual reads may exceed storage
local MAX_STORED_TEXT = 48 * 1024 -- below the host's 64 KiB per-value limit

-- One entry per storage key: "<ts>\t<pinned>\t<text>". Text may contain tabs,
-- newlines and anything else, so only the first two separators are structural.
local function encode(entry)
    return string.format("%d\t%s\t%s", entry.ts, entry.pinned and "1" or "0",
        entry.text or "")
end

local function decode(line)
    if type(line) ~= "string" then return nil end
    local ts, pinned, text = line:match("^(%d+)\t([01])\t(.*)$")
    if not ts then return nil end
    return {
        ts = tonumber(ts),
        pinned = pinned == "1",
        kind = "text",
        text = text,
    }
end

clipboard.encode = encode
clipboard.decode = decode
clipboard.MAX_TEXT = MAX_TEXT
clipboard.MAX_STORED_TEXT = MAX_STORED_TEXT

-- Count displayed Unicode code points; variation selectors add no character.
function clipboard.charCount(text)
    text = text or ""
    local offset, count = 1, 0
    while offset <= #text do
        local codepoint = utf8.codepoint(text, offset, offset)
        count = count + ((codepoint >= 0xFE00 and codepoint <= 0xFE0F) and 0 or 1)
        offset = utf8.offset(text, 2, offset) or (#text + 1)
    end
    return count
end

-- Truncate on a code point boundary, never mid-sequence.
function clipboard.truncate(text, limit)
    if limit <= 0 then return "" end
    local count, last = 0, 0
    for index = 1, #text do
        local byte = text:byte(index)
        if byte < 0x80 or byte >= 0xC0 then
            count = count + 1
            if count > limit then return text:sub(1, last) end
        end
        last = index
    end
    return text
end

-- Single-line snippet for a row: whitespace runs collapse to one space.
function clipboard.preview(text, limit)
    local flat = (text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if flat == "" then return "" end
    limit = limit or 80
    if clipboard.charCount(flat) <= limit then return flat end
    return clipboard.truncate(flat, limit) .. "\226\128\166" -- U+2026
end

function clipboard.kindOf(text)
    local trimmed = (text or ""):gsub("^%s+", "")
    trimmed = trimmed:gsub("%s+$", "")
    if not trimmed:find("%s")
        and (trimmed:sub(1, 7):lower() == "http://"
        or trimmed:sub(1, 8):lower() == "https://") then
        return "link"
    end
    if (text or ""):find("function") or (text or ""):find("const ")
        or (text or ""):find("=>") or (text or ""):find("def ")
        or (text or ""):find("local ") or (text or ""):find("#include")
        or ((text or ""):find("{") and (text or ""):find("}")) then
        return "code"
    end
    return "text"
end

-- Relative time from epoch milliseconds; local parts keep calendar dates
-- correct across local midnight and daylight-saving transitions.
function clipboard.relativeTime(ts, now, zh, parts, nowParts)
    local seconds = math.max(0, math.floor((now - ts) / 1000))
    if seconds < 60 then return zh and "刚刚" or "Just now" end
    local minutes = math.floor(seconds / 60)
    if minutes < 60 then
        return zh and (minutes .. " 分钟前") or (minutes .. "m ago")
    end
    local hours = math.floor(minutes / 60)
    local date = parts or {}
    local today = nowParts or {}
    local sameDay = date.year == today.year and date.month == today.month
        and date.day == today.day
    if hours < 24 and sameDay then
        return zh and (hours .. " 小时前") or (hours .. "h ago")
    end
    return string.format("%02d-%02d %02d:%02d",
        date.month or 1, date.day or 1, date.hour or 0, date.min or 0)
end

-- Pinned first, then newest first. Returns a new array.
function clipboard.sorted(list)
    local copy = {}
    for index = 1, #list do copy[index] = list[index] end
    table.sort(copy, function(a, b)
        if a.pinned ~= b.pinned then return a.pinned end
        return (a.ts or 0) > (b.ts or 0)
    end)
    return copy
end

-- Add or refresh an entry. Identical text moves to the top and keeps its pin;
-- ids stay stable so a menu opened before the refresh still resolves.
function clipboard.upsert(list, newEntry, maxCount)
    local result, previous, refreshed = {}, {}, nil
    if newEntry and newEntry.kind == "text" then
        for index = 1, #list do
            local item = list[index]
            if item.kind == "text" and item.text == newEntry.text then
                if not refreshed then
                    refreshed = {
                        id = item.id, ts = newEntry.ts, pinned = item.pinned,
                        kind = item.kind, text = newEntry.text,
                        sessionOnly = newEntry.sessionOnly or item.sessionOnly,
                    }
                end
            else
                previous[#previous + 1] = item
            end
        end
    else
        previous = list
    end
    for index = 1, #previous do result[index] = previous[index] end
    local inserted = refreshed or newEntry
    if inserted then result[#result + 1] = inserted end

    local sorted = clipboard.sorted(result)
    maxCount = math.max(1, maxCount or 20)
    if #sorted > maxCount then
        -- A refreshed text is no longer in `previous`, so it cannot be pruned
        -- under its old timestamp. Pins still outrank every unpinned entry.
        local dropped, drop = {}, {}
        local remaining = #sorted - maxCount
        previous = clipboard.sorted(previous)
        for index = #previous, 1, -1 do
            local item = previous[index]
            if remaining > 0 and not item.pinned then
                dropped[#dropped + 1] = item.id
                drop[item.id] = true
                remaining = remaining - 1
            end
        end
        for index = #sorted, 1, -1 do
            local item = sorted[index]
            if remaining > 0 and not item.pinned and not drop[item.id] then
                dropped[#dropped + 1] = item.id
                drop[item.id] = true
                remaining = remaining - 1
            end
        end
        local kept = {}
        for index = 1, #sorted do
            if not drop[sorted[index].id] then kept[#kept + 1] = sorted[index] end
        end
        return clipboard.sorted(kept), dropped
    end
    return sorted, {}
end

function clipboard.removeId(list, id)
    local result = {}
    for index = 1, #list do
        if list[index].id ~= id then result[#result + 1] = list[index] end
    end
    return result
end

function clipboard.copyEntry(item)
    local result = {}
    for key, value in pairs(item) do result[key] = value end
    return result
end

function clipboard.findImageEntryId(list, imageId)
    for _, entry in ipairs(list) do
        if entry.kind == "image" and entry.imageId == imageId then
            return entry.id
        end
    end
end

-- Refresh the matching content or the selected file entry, preserving its pin and id.
function clipboard.enrichSession(list, id, entry)
    local result, found = {}, false
    for index = 1, #list do
        local item = list[index]
        if item.id == id and item.kind == entry.kind then
            local merged = clipboard.copyEntry(item)
            merged.ts = entry.ts or item.ts
            if entry.kind == "image" then
                merged.image = entry.image or item.image
                merged.imageId = entry.imageId or item.imageId
                merged.imageData = entry.imageData or item.imageData
                merged.pixels = entry.pixels or item.pixels
                if entry.image or not item.image then
                    merged.width = entry.width or item.width
                    merged.height = entry.height or item.height
                end
            else
                merged.names = entry.names or item.names
                merged.items = entry.items or item.items
                merged.pathRefs = entry.pathRefs or item.pathRefs
            end
            result[#result + 1] = merged
            found = true
        else
            result[#result + 1] = item
        end
    end
    if not found then return list, false end
    return clipboard.sorted(result), true
end

function clipboard.sameIdentity(list, text)
    if not text then return false end
    for index = 1, #list do
        local item = list[index]
        if item.kind == "text" and item.text == text then return true end
    end
    return false
end

function clipboard.togglePin(list, id, now)
    local result = {}
    for index = 1, #list do
        local item = list[index]
        if item.id == id then
            local toggled = clipboard.copyEntry(item)
            toggled.pinned = not item.pinned
            toggled.pinnedAt = toggled.pinned and now or nil
            result[#result + 1] = toggled
        else
            result[#result + 1] = item
        end
    end
    return clipboard.sorted(result)
end

-- Pinned entries sort first by their original time too, so pinning does not
-- reshuffle the unpinned tail.
function clipboard.clear(list, keepPinned)
    if not keepPinned then return {}, true end
    local kept = {}
    for index = 1, #list do
        if list[index].pinned then kept[#kept + 1] = list[index] end
    end
    return kept, #kept ~= #list
end

function clipboard.counts(list)
    local counts = { all = #list, text = 0, image = 0, files = 0 }
    for index = 1, #list do
        local kind = list[index].kind
        if counts[kind] ~= nil then counts[kind] = counts[kind] + 1 end
    end
    return counts
end

-- filter: "all" | "text" | "link" | "code" | "image" | "files"
function clipboard.filtered(list, filter)
    if filter == nil or filter == "all" then return list end
    local result = {}
    for index = 1, #list do
        local item = list[index]
        local matches = item.kind == filter
        if item.kind == "text" and (filter == "link" or filter == "code") then
            matches = clipboard.kindOfEntry(item) == filter
        end
        if matches then result[#result + 1] = item end
    end
    return result
end

-- Per-entry cached classification. A text body never mutates on an existing
-- entry (upsert creates a new table), so the kindOf scan runs once per entry
-- instead of once per frame in filtered() and row tiles.
function clipboard.kindOfEntry(item)
    if item._kind == nil then item._kind = clipboard.kindOf(item.text) end
    return item._kind
end

-- Collapse duplicate text entries that share a text body but carry different
-- ids (an old build persisted one key per capture before dedupe). Pinned wins,
-- otherwise the newest. Returns the kept list and the ids to delete.
function clipboard.dedupeText(list)
    local sorted = clipboard.sorted(list)
    local seen, kept, removed = {}, {}, {}
    for index = 1, #sorted do
        local item = sorted[index]
        if item.kind == "text" then
            if seen[item.text] then
                removed[#removed + 1] = item.id
            else
                seen[item.text] = true
                kept[#kept + 1] = item
            end
        else
            kept[#kept + 1] = item
        end
    end
    return kept, removed
end

-- Legacy compact-header cycle: all is the resting state; subsequent clicks
-- advance through categories with content and then return to all.
local FILTER_ORDER = { "text", "image", "files", "all" }

function clipboard.nextFilter(list, current)
    local counts = clipboard.counts(list)
    if current == "all" then
        for index = 1, #FILTER_ORDER - 1 do
            if counts[FILTER_ORDER[index]] > 0 then return FILTER_ORDER[index] end
        end
        return "all"
    end
    local start = 0
    for index = 1, #FILTER_ORDER do
        if FILTER_ORDER[index] == current then start = index end
    end
    for step = 1, #FILTER_ORDER do
        local key = FILTER_ORDER[(start - 1 + step) % #FILTER_ORDER + 1]
        if key == "all" or counts[key] > 0 then return key end
    end
    return "all"
end

-- File entries: first name plus a "+N" tail, mirroring the reference card.
function clipboard.fileTitle(names, zh)
    if not names or #names == 0 then return zh and "文件" or "File" end
    return names[1] .. (#names > 1 and (" +" .. (#names - 1)) or "")
end

return clipboard
