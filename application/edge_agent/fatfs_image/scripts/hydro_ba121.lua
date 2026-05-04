-- BA121 Conductivity & Temperature Sensor Driver
-- UART 9600bps, 8N1
-- Frame: CMD(1B) + DATA(4B, big-endian) + CHECKSUM(1B) = 6 bytes
local M = {}

local CMD_READ = 0xA0
local HEADER_DATA = 0xAA
local HEADER_STATUS = 0xAC

function M.read(uart)
    -- Send read command
    local frame = string.char(CMD_READ, 0, 0, 0, 0)
    local sum = 0
    for i = 1, #frame do sum = sum + frame:byte(i) end
    uart:write(frame .. string.char(sum & 0xFF))

    local delay = require("delay")
    delay.delay_ms(800)

    -- Read response
    local data = uart:read(6, 1000)
    if not data or #data < 6 then return nil, nil, "timeout" end

    local header = data:byte(1)

    if header == HEADER_STATUS then
        local status = data:byte(5)
        return nil, nil, "status:" .. status
    end

    if header ~= HEADER_DATA then
        return nil, nil, "bad header:" .. string.format("0x%02X", header)
    end

    -- Verify checksum
    local sum = 0
    for i = 1, 5 do sum = sum + data:byte(i) end
    if (sum & 0xFF) ~= data:byte(6) then
        return nil, nil, "checksum error"
    end

    -- Parse: conductivity (4B big-endian) + temperature (signed 16-bit)
    local ec_raw = (data:byte(2) << 24) | (data:byte(3) << 16) |
                   (data:byte(4) << 8) | data:byte(5)

    -- Wait for temperature frame
    delay.delay_ms(100)
    local data2 = uart:read(6, 500)
    local temp = nil
    if data2 and #data2 >= 5 and data2:byte(1) == HEADER_DATA then
        -- Temperature is in the second data frame
        local temp_raw = (data2:byte(2) << 8) | data2:byte(3)
        if temp_raw > 32767 then temp_raw = temp_raw - 65536 end
        temp = temp_raw / 100.0
    end

    return ec_raw, temp, nil
end

return M
