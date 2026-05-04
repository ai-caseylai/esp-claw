-- Hydroponic Controls — valve, pumps, relays
-- Uses gpio and mcpwm Lua modules
local gpio_mod = require("gpio")
local mcpwm_mod = require("mcpwm")

-- Pin definitions
local VALVE_PIN = 4       -- Active-low relay
local WATER_PUMP_PIN = 2  -- Relay
local GROW_LIGHT_PIN = 3  -- Relay

local M = {}
M.initialized = false

function M.init()
    if M.initialized then return true end

    -- Valve (active-low)
    gpio_mod.set_direction(VALVE_PIN, "output")
    gpio_mod.set_level(VALVE_PIN, 1)  -- closed

    -- Relays
    gpio_mod.set_direction(WATER_PUMP_PIN, "output")
    gpio_mod.set_level(WATER_PUMP_PIN, 0)  -- off
    gpio_mod.set_direction(GROW_LIGHT_PIN, "output")
    gpio_mod.set_level(GROW_LIGHT_PIN, 0)  -- off

    -- Pump A: L9110S on GPIO6 (IN1) + GPIO7 (IN2)
    M.pump_a = mcpwm_mod.new({
        gpio_a = 6, gpio_b = 7,
        frequency_hz = 1000, duty_percent = 0,
    })

    -- Pump B: L9110S on GPIO15 (IN1) + GPIO16 (IN2)
    M.pump_b = mcpwm_mod.new({
        gpio_a = 15, gpio_b = 16,
        frequency_hz = 1000, duty_percent = 0,
    })

    M.initialized = true
    return true
end

-- Valve
function M.valve_open()
    gpio_mod.set_level(VALVE_PIN, 0)  -- active-low
end

function M.valve_close()
    gpio_mod.set_level(VALVE_PIN, 1)
end

function M.valve_toggle()
    local current = gpio_mod.get_level(VALVE_PIN)
    gpio_mod.set_level(VALVE_PIN, current == 0 and 1 or 0)
end

function M.valve_is_open()
    return gpio_mod.get_level(VALVE_PIN) == 0
end

-- Pump control (L9110S H-bridge)
function M.pump_forward(pump, speed)
    pump:set_duty(1, speed)  -- A = PWM
    pump:set_duty(2, 0)      -- B = LOW
    pump:start()
end

function M.pump_reverse(pump, speed)
    pump:set_duty(1, 0)      -- A = LOW
    pump:set_duty(2, speed)  -- B = PWM
    pump:start()
end

function M.pump_stop(pump)
    pump:set_duty(1, 0)
    pump:set_duty(2, 0)
    pump:stop()
end

-- Pump A shortcuts
function M.pump_a_forward(speed) M.pump_forward(M.pump_a, speed or 50) end
function M.pump_a_reverse(speed) M.pump_reverse(M.pump_a, speed or 50) end
function M.pump_a_stop() M.pump_stop(M.pump_a) end

-- Pump B shortcuts
function M.pump_b_forward(speed) M.pump_forward(M.pump_b, speed or 50) end
function M.pump_b_reverse(speed) M.pump_reverse(M.pump_b, speed or 50) end
function M.pump_b_stop() M.pump_stop(M.pump_b) end

-- Relays
function M.water_pump_on()   gpio_mod.set_level(WATER_PUMP_PIN, 1) end
function M.water_pump_off()  gpio_mod.set_level(WATER_PUMP_PIN, 0) end
function M.grow_light_on()   gpio_mod.set_level(GROW_LIGHT_PIN, 1) end
function M.grow_light_off()  gpio_mod.set_level(GROW_LIGHT_PIN, 0) end

function M.water_pump_toggle()
    gpio_mod.set_level(WATER_PUMP_PIN, gpio_mod.get_level(WATER_PUMP_PIN) == 0 and 1 or 0)
end

function M.grow_light_toggle()
    gpio_mod.set_level(GROW_LIGHT_PIN, gpio_mod.get_level(GROW_LIGHT_PIN) == 0 and 1 or 0)
end

-- Status
function M.status()
    return {
        valve_open = M.valve_is_open(),
        water_pump_on = gpio_mod.get_level(WATER_PUMP_PIN) == 1,
        grow_light_on = gpio_mod.get_level(GROW_LIGHT_PIN) == 1,
    }
end

return M
