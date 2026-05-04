-- emakefun 8-channel GPIO Expansion Board Driver (I2C 0x24)
-- 10-bit ADC (0-1023), register 0x10+pin*2, set mode to ADC (0x10) via reg 0x01+pin
local M = {}

M.MODE_ADC = 0x10
M.MODE_OUTPUT = 0x08
M.MODE_INPUT_PULLUP = 0x01
M.ADC_RESOLUTION = 1023.0
M.VREF = 3.3

function M.new(i2c_bus, addr)
    addr = addr or 0x24
    local ok, dev = pcall(function() return i2c_bus:device(addr) end)
    if not ok then return nil, "ADC expansion not found at 0x" .. string.format("%02X", addr) end
    return setmetatable({dev = dev, bus = i2c_bus}, {__index = M})
end

function M:set_pin_mode(pin, mode)
    self.dev:write_byte(mode, 0x01 + pin)
end

function M:set_pin_mode_adc(pin)
    self:set_pin_mode(pin, self.MODE_ADC)
end

function M:read_raw(pin)
    local reg = 0x10 + pin * 2
    local ok, data = pcall(function() return self.dev:read(2, reg) end)
    if not ok or not data or #data < 2 then return nil end
    return data:byte(1) | (data:byte(2) << 8)
end

function M:read_voltage(pin)
    local raw = self:read_raw(pin)
    if not raw or raw == 0xFFFF then return nil end
    return raw * (self.VREF / self.ADC_RESOLUTION)
end

function M:read_avg_voltage(pin, count)
    count = count or 10
    local total, n = 0, 0
    for _ = 1, count do
        local v = self:read_voltage(pin)
        if v then total = total + v; n = n + 1 end
    end
    if n == 0 then return nil end
    return total / n
end

function M:digital_read(pin)
    local reg = 0x40 + pin
    local ok, data = pcall(function() return self.dev:read(1, reg) end)
    if not ok or not data or #data < 1 then return nil end
    return data:byte(1)
end

function M:digital_write(pin, level)
    self.dev:write_byte(level and 1 or 0, 0x40 + pin)
end

function M:close()
    self.dev:close()
end

return M
