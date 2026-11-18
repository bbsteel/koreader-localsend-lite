local MAX_LOG_BYTES = 64 * 1024

local function logField(value)
    return tostring(value):gsub("%.localsend%-lite%-%x+%.part", ".localsend-lite-<temporary>.part")
        :gsub("[%c]", " "):sub(1, 320)
end

return function(path)
    return function(event, ...)
        local fields = { os.date("%Y-%m-%d %H:%M:%S"), event }
        for index = 1, select("#", ...) do
            fields[#fields + 1] = logField(select(index, ...))
        end
        local line = table.concat(fields, "\t") .. "\n"
        local file = io.open(path, "ab")
        if not file then return end
        local size = file:seek("end")
        if not size or size + #line > MAX_LOG_BYTES then
            file:close()
            if not size or not os.rename(path, path .. ".1") then return end
            file = io.open(path, "ab")
            if not file then return end
        end
        file:write(line)
        file:close()
    end
end
