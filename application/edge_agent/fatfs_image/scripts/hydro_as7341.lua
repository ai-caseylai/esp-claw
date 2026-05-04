-- AS7341 VIS+NIR Spectral Sensor Driver (I2C 0x39)
-- Direct register access, 10 channels: F1-F8 (415-680nm) + CLEAR + NIR
-- Ported from Adafruit AS7341 library
local M = {}

local ADDR = 0x39

-- Registers
local REG_ENABLE    = 0x80
local REG_ATIME     = 0x81
local REG_CFG0      = 0xA9
local REG_CFG1      = 0xAA
local REG_ASTEP_L   = 0xCA
local REG_ASTEP_H   = 0xCB
local REG_WHOAMI    = 0x92
local REG_STATUS    = 0x93
local REG_CH0_DATA_L = 0x95
local REG_CFG6      = 0xAF
local REG_CONTROL   = 0xFA

-- SMUX config for F1-F6 + CLEAR + NIR (low channels)
local SMUX_F1_F6_CLEAR_NIR = {
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x00, 0x05, 0x01, 0x04, 0x06, 0x00, 0x03, 0x02,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
}

-- SMUX config for F7-F8 + CLEAR + NIR (high channels)
local SMUX_F7_F8_CLEAR_NIR = {
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x00, 0x05, 0x01, 0x04, 0x06, 0x00, 0x03, 0x02,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
}

function M.new(i2c_bus)
    local dev = i2c_bus:device(ADDR)
    -- Check WHO_AM_I
    local whoami = dev:read_byte(REG_WHOAMI)
    if not whoami then return nil, "AS7341 not found" end
    local chip_id = (whoami >> 2) & 0x3F
    if chip_id ~= 0x09 then
        return nil, string.format("bad chip ID: 0x%02X", chip_id)
    end

    local obj = {
        dev = dev,
        gain = 9, -- GAIN_256X
    }
    -- Enable spectral measurement + SMUX
    obj:_write_reg(REG_ENABLE, 0x01)  -- SP_EN bit
    obj:_write_reg(REG_ATIME, 100)
    obj:_write_reg(REG_ASTEP_L, 100 & 0xFF)
    obj:_write_reg(REG_ASTEP_H, (100 >> 8) & 0xFF)
    obj:_write_reg(REG_CFG0, 0x00)
    obj:set_gain(obj.gain)

    return setmetatable(obj, {__index = M})
end

function M:_write_reg(reg, val)
    self.dev:write_byte(val, reg)
end

function M:_read_reg(reg)
    return self.dev:read_byte(reg)
end

function M:_read_reg16(reg)
    local data = self.dev:read(2, reg)
    if not data or #data < 2 then return nil end
    return data:byte(1) | (data:byte(2) << 8)
end

function M:set_gain(gain)
    self.gain = gain
    local cfg1 = self:_read_reg(REG_CFG1)
    if cfg1 then
        self:_write_reg(REG_CFG1, (cfg1 & 0xC0) | (gain & 0x3F))
    end
end

function M:_wait_data_ready(timeout_ms)
    local delay = require("delay")
    timeout_ms = timeout_ms or 3000
    local deadline = delay.ticks_ms() + timeout_ms
    while delay.ticks_ms() < deadline do
        local status = self:_read_reg(REG_STATUS2)
        if status and (status & 0x40) ~= 0 then return true end
        delay.delay_ms(5)
    end
    return false
end

function M:_load_smux(config)
    -- Write SMUX config to RAM
    self:_write_reg(REG_CFG6, 0x04)  -- SMUX_EN
    local delay = require("delay")
    delay.delay_ms(10)
    for i, val in ipairs(config) do
        self:_write_reg(0x00 + i - 1, val)
    end
    self:_write_reg(REG_CFG6, 0x00)
end

function M:_enable_measurement()
    local en = self:_read_reg(REG_ENABLE)
    self:_write_reg(REG_ENABLE, en | 0x01)
end

function M:read_f1_f6_clear_nir()
    if not self:_wait_data_ready() then return nil end
    local f1 = self:_read_reg16(REG_CH0_DATA_L)
    local f2 = self:_read_reg16(REG_CH0_DATA_L + 2)
    local f3 = self:_read_reg16(REG_CH0_DATA_L + 4)
    local f4 = self:_read_reg16(REG_CH0_DATA_L + 6)
    local f5 = self:_read_reg16(REG_CH0_DATA_L + 8)
    local f6 = self:_read_reg16(REG_CH0_DATA_L + 10)
    local clr = self:_read_reg16(REG_CH0_DATA_L + 12)
    local nir = self:_read_reg16(REG_CH0_DATA_L + 14)
    return {
        F1 = f1, F2 = f2, F3 = f3, F4 = f4,
        F5 = f5, F6 = f6, CLEAR = clr, NIR = nir
    }
end

function M:read_f7_f8_clear_nir()
    if not self:_wait_data_ready() then return nil end
    local f7 = self:_read_reg16(REG_CH0_DATA_L)
    local f8 = self:_read_reg16(REG_CH0_DATA_L + 2)
    local clr = self:_read_reg16(REG_CH0_DATA_L + 12)
    local nir = self:_read_reg16(REG_CH0_DATA_L + 14)
    return { F7 = f7, F8 = f8, CLEAR = clr, NIR = nir }
end

function M:read_all()
    -- Read F1-F6 + CLEAR + NIR
    self:_load_smux(SMUX_F1_F6_CLEAR_NIR)
    self:_enable_measurement()
    local low = self:read_f1_f6_clear_nir()
    if not low then return nil end

    -- Read F7-F8 + CLEAR + NIR
    self:_load_smux(SMUX_F7_F8_CLEAR_NIR)
    self:_enable_measurement()
    local high = self:read_f7_f8_clear_nir()
    if not high then return low end

    -- Merge
    low.F7 = high.F7
    low.F8 = high.F8
    return low
end

function M:close()
    self.dev:close()
end

return M
