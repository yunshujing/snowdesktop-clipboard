-- Convert the subscription's RGB thumbnail into horizontal drawing runs.

local preview = {}

-- Decode exactly width*height RGB triples. Invalid or incomplete payloads never
-- produce a partial thumbnail or throw during an event/render callback.
function preview.decode(rgb, width, height)
    if type(rgb) ~= "string" or type(width) ~= "number"
        or type(height) ~= "number" or width < 1 or height < 1
        or width > 32 or height > 32 or width % 1 ~= 0 or height % 1 ~= 0
        or #rgb ~= width * height * 3 then
        return nil
    end

    -- Coalesce adjacent equal pixels so flat screenshots cost only a few draw
    -- commands. Each run is {x, y, width, color}, in 0-based source cells.
    local rows, offset = {}, 1
    for y = 0, height - 1 do
        local runs = {}
        local x = 0
        while x < width do
            local r, g, b = rgb:byte(offset, offset + 2)
            local color = r * 65536 + g * 256 + b
            local finish = x + 1
            while finish < width do
                local nextOffset = offset + (finish - x) * 3
                local nextR, nextG, nextB = rgb:byte(nextOffset, nextOffset + 2)
                if nextR ~= r or nextG ~= g or nextB ~= b then break end
                finish = finish + 1
            end
            runs[#runs + 1] = { x = x, y = y, width = finish - x, color = color }
            offset = offset + (finish - x) * 3
            x = finish
        end
        rows[#rows + 1] = runs
    end
    return { width = width, height = height, rows = rows }
end

return preview
