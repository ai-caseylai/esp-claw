-- Hydroponic Main Script — read all sensors and print
-- Run this script to test all sensors
local sensors = require("hydro_sensors")
local controls = require("hydro_controls")

print("=== Hydroponic System Starting ===")

-- Initialize
sensors.init()
controls.init()

print("")
print("=== Reading sensors ===")

local data = sensors.read_all()

-- Print results
for k, v in pairs(data) do
    print(string.format("  %s = %s", k, tostring(v)))
end

-- Print control status
local status = controls.status()
print(string.format("  valve = %s", status.valve_open and "OPEN" or "CLOSED"))
print(string.format("  water_pump = %s", status.water_pump_on and "ON" or "OFF"))
print(string.format("  grow_light = %s", status.grow_light_on and "ON" or "OFF"))

print("=== Done ===")
