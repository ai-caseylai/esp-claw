-- Hydroponic Sensor Hub — unified sensor reading
-- Returns all sensor data as a single table
local i2c_mod = require("i2c")
local uart_mod = require("uart")
local gpio_mod = require("gpio")
local delay = require("delay")

local adc_exp_mod = require("hydro_adc_exp")
local as7341_mod = require("hydro_as7341")
local as7263_mod = require("hydro_as7263")
local ba121_mod = require("hydro_ba121")

-- Pin definitions (ESP32-S3 DevKitC-1 N16R8)
local I2C_SDA = 8
local I2C_SCL = 9
local BA121_TX = 17
local BA121_RX = 18
local LEAK_PIN = 1
local DIVIDER_RATIO = 0.233  -- R1=33K, R2=10K

local M = {}
M.initialized = false

function M.init()
    if M.initialized then return true end

    -- I2C bus
    M.i2c_bus = i2c_mod.new(0, I2C_SDA, I2C_SCL, 400000)

    -- Scan I2C
    local addrs = M.i2c_bus:scan()
    local found = {}
    for _, a in ipairs(addrs) do
        found[a] = true
        print(string.format("  I2C: 0x%02X", a))
    end

    -- ADC Expansion (0x24)
    if found[0x24] then
        M.adc = adc_exp_mod.new(M.i2c_bus)
        if M.adc then
            M.adc:set_pin_mode_adc(0)  -- CH0 = pH
            M.adc:set_pin_mode_adc(1)  -- CH1 = Pressure
            print("ADC Expansion: found at 0x24")
        end
    else
        print("ADC Expansion: not found")
    end

    -- AS7341 (0x39)
    if found[0x39] then
        local ok, vis = pcall(as7341_mod.new, M.i2c_bus)
        if ok and vis then
            M.vis = vis
            print("AS7341: found")
        else
            print("AS7341: init failed -", vis)
        end
    else
        print("AS7341: not found")
    end

    -- AS7263 (0x49)
    if found[0x49] then
        local ok, nir = pcall(as7263_mod.new, M.i2c_bus)
        if ok and nir then
            M.nir = nir
            print("AS7263: found")
        else
            print("AS7263: init failed -", nir)
        end
    else
        print("AS7263: not found")
    end

    -- BA121 UART
    local ok, u = pcall(uart_mod.new, 1, BA121_TX, BA121_RX, 9600)
    if ok and u then
        M.ba121_uart = u
        print("BA121: UART1 initialized")
    else
        print("BA121: UART init failed")
    end

    -- GPIO inputs
    gpio_mod.set_direction(LEAK_PIN, "input")

    M.initialized = true
    return true
end

function M.read_all()
    local data = {}

    -- pH (ADC expansion CH0)
    if M.adc then
        local ph_v = M.adc:read_avg_voltage(0, 10)
        if ph_v then
            local v_actual = ph_v / DIVIDER_RATIO
            data.ph = 7.0 - (v_actual - 2.5) * (14.0 / 5.0)
            if data.ph < 0 then data.ph = 0 end
            if data.ph > 14 then data.ph = 14 end
            data.ph = math.floor(data.ph * 100 + 0.5) / 100
        end

        -- Pressure (ADC expansion CH1)
        local pr_v = M.adc:read_avg_voltage(1, 10)
        if pr_v then
            local v_actual = pr_v / DIVIDER_RATIO
            data.pressure_mpa = (v_actual - 0.5) / 4.0 * 1.2
            if data.pressure_mpa < 0 then data.pressure_mpa = 0 end
            data.pressure_mpa = math.floor(data.pressure_mpa * 1000 + 0.5) / 1000
        end
    end

    -- BA121 Conductivity + Temperature
    if M.ba121_uart then
        local ec, temp, err = ba121_mod.read(M.ba121_uart)
        if ec then
            data.ec_us = ec
            data.ec_ms = math.floor(ec / 10 + 0.5) / 100  -- uS to mS
            data.water_temp = temp or 0
        end
    end

    -- AS7341 VIS+NIR
    if M.vis then
        local ok, vis_data = pcall(function() return M.vis:read_all() end)
        if ok and vis_data then
            for k, v in pairs(vis_data) do
                data["vis_" .. k] = v
            end
        end
    end

    -- AS7263 NIR
    if M.nir then
        local ok, nir_data = pcall(function() return M.nir:measure() end)
        if ok and nir_data then
            for k, v in pairs(nir_data) do
                data["nir_" .. k] = v
            end
        end
    end

    -- Leak sensor
    data.leak = gpio_mod.get_level(LEAK_PIN)

    return data
end

return M
