-- AS7263 NIR Spectral Sensor Driver (I2C 0x49)
-- Virtual Register Protocol: STATUS(0x00), WRITE(0x01), READ(0x02)
-- 6 channels: R(610nm) S(680nm) T(730nm) U(760nm) V(810nm) W(860nm)
-- Ported from SparkFun AS726X library
local M = {}

local ADDR = 0x49

-- Physical registers for virtual register protocol
local STATUS_REG = 0x00
local WRITE_REG  = 0x01
local READ_REG   = 0x02

-- Status bits
local TX_VALID = 0x02
local RX_VALID = 0x01

-- Virtual registers
local REG_CONFIG       = 0x04
local REG_INT_T        = 0x05
local REG_LED_CONFIG   = 0x07
local REG_HW_VERSION   = 0x01

-- Channel registers (16-bit, high byte first)
local CH_R = 0x08
local CH_S = 0x0A
local CH_T = 0x0C
local CH_U = 0x0E
local CH_V = 0x10
local CH_W = 0x12

-- Config bits
local CFG_SRST       = 0x80
local CFG_INT        = 0x40
local CFG_GAIN_MASK  = 0x30
local CFG_MODE_MASK  = 0x0C
local CFG_DATA_READY = 0x02

-- Gains
local GAIN_X1   = 0x00
local GAIN_X3_7 = 0x01
local GAIN_X16  = 0x02
local GAIN_X64  = 0x03

-- Modes
local MODE_6CHAN_CONTINUOUS = 0x02

function M.new(i2c_bus)
    local dev = i2c_bus:device(ADDR)
    local obj = {dev = dev}

    -- Reset sensor
    obj:_write_vreg(REG_CONFIG, CFG_SRST)
    local delay = require("delay")
    delay.delay_ms(1000)

    -- Configure: gain x64, continuous 6-channel mode
    obj:_write_vreg(REG_CONFIG, (GAIN_X64 << 4) | MODE_6CHAN_CONTINUOUS)

    -- Integration time (units of 2.78ms, 50 = ~139ms)
    obj:_write_vreg(REG_INT_T, 50)

    -- Disable bulb, set indicator current
    obj:_write_vreg(REG_LED_CONFIG, 0x00)

    return setmetatable(obj, {__index = M})
end

function M:_wait_tx_valid()
    local delay = require("delay")
    for _ = 1, 100 do
        local status = self.dev:read_byte(STATUS_REG)
        if status and (status & TX_VALID) ~= 0 then return true end
        delay.delay_ms(1)
    end
    return false
end

function M:_wait_rx_valid()
    local delay = require("delay")
    for _ = 1, 100 do
        local status = self.dev:read_byte(STATUS_REG)
        if status and (status & RX_VALID) ~= 0 then return true end
        delay.delay_ms(1)
    end
    return false
end

function M:_write_vreg(vreg, val)
    if not self:_wait_tx_valid() then return false end
    self.dev:write_byte(vreg, WRITE_REG)  -- Write virtual register address
    if not self:_wait_tx_valid() then return false end
    self.dev:write_byte(val, WRITE_REG)   -- Write value
    return true
end

function M:_read_vreg(vreg)
    if not self:_wait_tx_valid() then return nil end
    self.dev:write_byte(vreg | 0x80, WRITE_REG)  -- Set bit 7 for read
    if not self:_wait_rx_valid() then return nil end
    return self.dev:read_byte(READ_REG)
end

function M:_read_vreg16(vreg)
    local hi = self:_read_vreg(vreg)
    local lo = self:_read_vreg(vreg + 1)
    if not hi or not lo then return nil end
    return (hi << 8) | lo
end

function M:_wait_data_ready(timeout_ms)
    local delay = require("delay")
    timeout_ms = timeout_ms or 3000
    local deadline = delay.ticks_ms() + timeout_ms
    while delay.ticks_ms() < deadline do
        local cfg = self:_read_vreg(REG_CONFIG)
        if cfg and (cfg & CFG_DATA_READY) ~= 0 then return true end
        delay.delay_ms(50)
    end
    return false
end

function M:measure()
    if not self:_wait_data_ready() then return nil end
    return {
        R = self:_read_vreg16(CH_R),
        S = self:_read_vreg16(CH_S),
        T = self:_read_vreg16(CH_T),
        U = self:_read_vreg16(CH_U),
        V = self:_read_vreg16(CH_V),
        W = self:_read_vreg16(CH_W),
    }
end

function M:close()
    self.dev:close()
end

return M
