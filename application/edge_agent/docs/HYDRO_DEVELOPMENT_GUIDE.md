# ESP32-S3 Hydroponic Controller — Development Guide

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [System Architecture](#2-system-architecture)
3. [Hardware Reference](#3-hardware-reference)
4. [Software Architecture](#4-software-architecture)
5. [Board Definition (esp32_s3_hydro)](#5-board-definition-esp32_s3_hydro)
6. [MQTT IM Integration (cap_im_mqtt)](#6-mqtt-im-integration-cap_im_mqtt)
7. [Lua Scripting Layer](#7-lua-scripting-layer)
8. [Sensor Drivers](#8-sensor-drivers)
9. [Control Drivers](#9-control-drivers)
10. [Event Router and Router Rules](#10-event-router-and-router-rules)
11. [Configuration System](#11-configuration-system)
12. [HTTP Server & Web UI](#12-http-server--web-ui)
13. [Skills System](#13-skills-system)
14. [Memory System](#14-memory-system)
15. [Build & Flash Instructions](#15-build--flash-instructions)
16. [Deployment Guide](#16-deployment-guide)
17. [MQTT External Integration](#17-mqtt-external-integration)
18. [Console Commands Reference](#18-console-commands-reference)
19. [API Reference](#19-api-reference)
20. [Troubleshooting](#20-troubleshooting)
21. [File Tree](#21-file-tree)

---

## 1. Project Overview

This project is an **AI-powered hydroponic control system** built on Espressif's **ESP-Claw** framework, running on an **ESP32-S3 N16R8** (16MB Flash, 8MB Octal PSRAM).

The system provides:

- **Multi-spectral sensor monitoring** (AS7341 VIS+NIR, AS7263 NIR, BA121 EC/Temperature, pH, pressure, leak)
- **Actuator control** (valve, peristaltic pumps, water pump, grow light)
- **AI agent** with LLM integration for intelligent decision-making
- **MQTT-based IM** for bidirectional remote control from any MQTT client
- **Lua scripting** for automation logic
- **OTA updates** via dual partition scheme
- **Web configuration UI** for WiFi, LLM, and MQTT settings

### Repository

- Fork: `https://github.com/ai-caseylai/esp-claw`
- Branch: `hydroponic-mqtt`
- Upstream: `https://github.com/espressif/esp-claw`

---

## 2. System Architecture

```
+------------------+     MQTT      +------------------+
|  External Client | <-----------> |  MQTT Broker     |
|  (Node-RED/App)  |               |  (Cloud/LAN)     |
+------------------+               +------------------+
                                         |
                                    publish/subscribe
                                         |
+---------------------------------------------------------+
|  ESP32-S3 N16R8                                          |
|                                                           |
|  cap_im_mqtt  <--->  Event Router  <--->  Agent Loop     |
|       |                  |                   |            |
|       |           Router Rules          LLM API          |
|       |                  |              (OpenAI-compat)   |
|       v                  v                               |
|  MQTT Client      cap_lua / Skills                       |
|  (esp_mqtt)           |                                  |
|                       v                                  |
|              Lua Sensor Drivers                          |
|              (hydro_*.lua)                                |
|                       |                                  |
|              Lua Control Drivers                         |
|              (hydro_controls.lua)                         |
|                       |                                  |
|                       v                                  |
|              Hardware Abstraction                        |
|              (I2C, UART, GPIO, MCPWM)                    |
|                                                           |
|  [WiFi]  [HTTP Server]  [NVS Config]  [FATFS Storage]    |
+---------------------------------------------------------+
         |            |             |            |
    WiFi STA/AP   Web UI Config   NVS Prefs   FATFS Partition
                                                   |
                                        /fatfs/memory/     (agent memory)
                                        /fatfs/skills/     (skill docs)
                                        /fatfs/scripts/    (Lua scripts)
                                        /fatfs/router_rules/ (event routing)
                                        /fatfs/scheduler/  (scheduled tasks)
                                        /fatfs/inbox/      (IM attachments)
```

### Data Flow: Inbound Message

```
MQTT Client receives message on {prefix}/{device_id}/inbox
    -> cap_im_mqtt_handle_inbound() parses JSON
    -> claw_event_router_publish_message("mqtt_gateway", "mqtt", chat_id, text, sender_id, message_id)
    -> Event Router evaluates router_rules.json
    -> Matched rule: "im_any_message_working_reply" -> send "snapping on it..." via MQTT
    -> Matched rule: "im_any_message_agent" -> run_agent
    -> Agent Loop (claw_core) processes with LLM
    -> LLM may invoke capabilities (mqtt_send_message, cap_lua, etc.)
    -> Agent output -> Event Router -> "agent_out_message_send_message" rule
    -> Outbound binding: mqtt_send_message -> cap_im_mqtt_send_text()
    -> esp_mqtt_client_publish() to {prefix}/{device_id}/outbox
```

---

## 3. Hardware Reference

### MCU: ESP32-S3 N16R8

| Parameter | Value |
|-----------|-------|
| Flash | 16MB (QIO, 120MHz) |
| PSRAM | 8MB Octal (120MHz) |
| CPU | 240 MHz dual-core |
| I2C | Port 0, SDA=GPIO8, SCL=GPIO9, 400kHz |
| UART | Port 1, TX=GPIO17, RX=GPIO18 |

### Pin Assignments

| GPIO | Function | Active Level | Notes |
|------|----------|-------------|-------|
| 1 | Leak Sensor Input | HIGH = leak | Digital read |
| 2 | Water Pump Relay | HIGH = on | |
| 3 | Grow Light Relay | HIGH = on | |
| 4 | Valve Relay | LOW = open (active-low) | |
| 6 | Pump A IN1 (MCPWM) | PWM forward | L9110S H-bridge |
| 7 | Pump A IN2 (MCPWM) | PWM reverse | L9110S H-bridge |
| 8 | I2C SDA | | 4.7K pullup |
| 9 | I2C SCL | | 4.7K pullup |
| 15 | Pump B IN1 (MCPWM) | PWM forward | L9110S H-bridge |
| 16 | Pump B IN2 (MCPWM) | PWM reverse | L9110S H-bridge |
| 17 | UART1 TX (BA121) | | 9600 baud |
| 18 | UART1 RX (BA121) | | 9600 baud |
| 38 | WS2812 LED Strip (RMT) | | 1 LED (status indicator) |

### I2C Devices

| Address | Device | Function |
|---------|--------|----------|
| 0x24 | emakefun ADC Expansion | 8-channel 10-bit ADC (pH, pressure, etc.) |
| 0x39 | AMS AS7341 | VIS+NIR 10-channel spectral sensor |
| 0x49 | ams OSRAM AS7263 | NIR 6-channel spectral sensor |

### UART Devices

| Port | Device | Baud | Protocol |
|------|--------|------|----------|
| UART1 | BA121 | 9600 | Custom binary: CMD(1B) + DATA(4B BE) + CHECKSUM(1B) |

### Voltage Divider (pH/Pressure)

- R1 = 33K, R2 = 10K
- Divider ratio = R2 / (R1 + R2) = 0.233
- ADC reads 0-3.3V, actual voltage = ADC_voltage / 0.233

### Partition Table (16MB Flash)

```
# Name,    Type, SubType, Offset,   Size
nvs,       data, nvs,     0x9000,   24KB
otadata,   data, ota,     0xF000,   8KB
phy_init,  data, phy,     0x11000,  4KB
ota_0,     app,  ota_0,         ,   4MB
ota_1,     app,  ota_1,         ,   4MB
emote,     data, spiffs,        ,   3MB
storage,   data, fat,           ,   4MB
```

- **NVS** (24KB): WiFi credentials, app config (MQTT broker, LLM keys, etc.)
- **OTA slots** (2x 4MB): Dual-bank OTA updates
- **Emote** (3MB): SPIFFS for display animations
- **Storage** (4MB): FAT filesystem, mounted at `/fatfs/`, contains all runtime data

---

## 4. Software Architecture

### ESP-Claw Framework Layers

```
Application Layer (edge_agent/main/)
    |
Framework Layer (app_claw)
    |--- Capability System (claw_cap)
    |--- Event Router (claw_event_router)
    |--- Agent Core (claw_core) -- LLM integration
    |--- Memory System (claw_memory)
    |--- Skill System (claw_skill)
    |--- Lua Engine (cap_lua)
    |
HAL Layer (ESP-IDF)
    |--- WiFi, MQTT, HTTP, I2C, UART, GPIO, MCPWM, RMT, etc.
```

### Capability System

Capabilities are self-contained modules registered via `claw_cap_register_group()`. Each group contains one or more descriptors:

| Kind | Description |
|------|-------------|
| `CLAW_CAP_KIND_EVENT_SOURCE` | Emits events (e.g., MQTT gateway, Telegram bot) |
| `CLAW_CAP_KIND_CALLABLE` | Can be invoked by LLM or other capabilities |
| `CLAW_CAP_KIND_CONSUMER` | Subscribes to events (e.g., scheduler) |

Descriptor flags:
- `CLAW_CAP_FLAG_EMITS_EVENTS` — produces events
- `CLAW_CAP_FLAG_SUPPORTS_LIFECYCLE` — has init/start/stop
- `CLAW_CAP_FLAG_CALLABLE_BY_LLM` — LLM can invoke this

### Event Router

All inter-component communication flows through the event router:

1. **Inbound**: `claw_event_router_publish_message(source_cap, channel, chat_id, text, sender_id, message_id)`
2. **Router Rules**: JSON file defines match/action rules (see Section 10)
3. **Outbound Bindings**: Registered per channel name (`"mqtt"`, `"telegram"`, etc.) to map agent output back to the correct IM channel

---

## 5. Board Definition (esp32_s3_hydro)

Board files live in `application/edge_agent/boards/espressif/esp32_s3_hydro/`.

### board_info.yaml

```yaml
board: esp32_s3_hydro
chip: esp32s3
description: "ESP32-S3 DevKitC-1 N16R8 Hydroponic Controller"
manufacturer: "CUSTOM"
```

### board_devices.yaml

```yaml
devices:
  - name: led_strip
    chip: ws2812
    type: custom
    version: default
    init_skip: true
    dependencies:
      espressif/led_strip:
        version: "^3.0"
        public: true
    config:
      max_leds: 1
    peripherals:
      - name: rmt_tx
```

### board_peripherals.yaml

```yaml
peripherals:
  - name: rmt_tx
    type: rmt
    role: tx
    config:
      gpio_num: 38
      clk_src: RMT_CLK_SRC_DEFAULT
      resolution_hz: 10000000
      mem_block_symbols: 64
      trans_queue_depth: 4
      intr_priority: 1
      flags:
        invert_out: false
        with_dma: true
```

### sdkconfig.defaults.board

```config
CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ_240=y
CONFIG_ESPTOOLPY_FLASHMODE_QIO=y
CONFIG_ESPTOOLPY_FLASHFREQ_120M=y
CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y
CONFIG_PARTITION_TABLE_CUSTOM=y
CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="partitions_16MB.csv"
CONFIG_SPIRAM=y
CONFIG_SPIRAM_MODE_OCT=y
CONFIG_SPIRAM_SPEED_120M=y
```

### setup_device.c

Custom initialization for the WS2812 LED strip using the RMT peripheral. This is generated by the board manager and calls `led_strip_rmt_new()`.

---

## 6. MQTT IM Integration (cap_im_mqtt)

### Component Structure

```
components/claw_capabilities/cap_im_mqtt/
├── CMakeLists.txt
├── idf_component.yml
├── include/
│   ├── cap_im_mqtt.h          # Public API
│   └── cmd_cap_im_mqtt.h      # CLI registration
├── src/
│   ├── cap_im_mqtt.c          # Core implementation (~430 lines)
│   └── cmd_cap_im_mqtt.c      # Console commands
└── skills/
    ├── cap_im_mqtt.md          # LLM skill description
    └── skills_list.json
```

### Public API (cap_im_mqtt.h)

```c
typedef struct {
    const char *broker_url;      // "mqtt://broker:1883" or "mqtts://broker:8883"
    const char *username;        // Optional
    const char *password;        // Optional
    const char *device_id;       // Device identifier
    const char *topic_prefix;    // Default: "esp-claw"
} cap_im_mqtt_config_t;

esp_err_t cap_im_mqtt_register_group(void);
esp_err_t cap_im_mqtt_set_config(const cap_im_mqtt_config_t *config);
esp_err_t cap_im_mqtt_start(void);
esp_err_t cap_im_mqtt_stop(void);
esp_err_t cap_im_mqtt_send_text(const char *chat_id, const char *text);
```

### Topic Design

| Topic | Direction | Purpose |
|-------|-----------|---------|
| `{prefix}/{device_id}/inbox` | ESP32 subscribes | Receive commands/messages |
| `{prefix}/{device_id}/outbox` | ESP32 publishes | Send responses/status |

Example: With `prefix="esp-claw"` and `device_id="hydro_01"`:
- Subscribe: `esp-claw/hydro_01/inbox`
- Publish: `esp-claw/hydro_01/outbox`

### Client ID

Format: `{device_id}_{MAC_last_2_bytes}` — ensures uniqueness across multiple devices.

### Capability Descriptors

1. **mqtt_gateway** (EVENT_SOURCE)
   - Family: `"im"`
   - Lifecycle: init → start → stop
   - Subscribes to inbox topic on connect
   - Publishes inbound messages to event router as `"mqtt"` channel

2. **mqtt_send_message** (CALLABLE)
   - Family: `"im"`
   - Callable by LLM
   - Input: `{"chat_id": "...", "message": "..."}`
   - Publishes JSON to outbox topic
   - Auto-chunks messages > 4096 bytes

### Inbound Message Format

The inbox accepts both JSON and plain text:

**JSON format:**
```json
{
  "chat_id": "mqtt",
  "sender_id": "user1",
  "message_id": "msg-001",
  "text": "Read all sensors"
}
```

**Plain text:** Raw payload is treated as message text with auto-generated message ID.

### Outbound Message Format

```json
{
  "chat_id": "mqtt",
  "text": "pH: 6.2, EC: 1200 uS/cm, Temp: 24.5C",
  "timestamp_ms": 1714838400000
}
```

### Registration Pattern

The MQTT capability is registered through the standard ESP-Claw pattern:

1. **Kconfig** (`components/common/app_claw/Kconfig`):
   ```
   config APP_CLAW_CAP_IM_MQTT
       bool "Enable MQTT capability"
       default y
   ```

2. **CMakeLists.txt** (`components/common/app_claw/CMakeLists.txt`):
   ```cmake
   if(CONFIG_APP_CLAW_CAP_IM_MQTT)
       list(APPEND app_claw_requires cap_im_mqtt)
   endif()
   ```

3. **idf_component.yml** — Path entries in BOTH `app_claw/idf_component.yml` AND `main/idf_component.yml`:
   ```yaml
   cap_im_mqtt:
     rules:
       - if: $CONFIG{APP_CLAW_CAP_IM_MQTT} == True
     path: ../../claw_capabilities/cap_im_mqtt
   ```

4. **app_capabilities.c** — prepare/register functions + entry in capability table

5. **app_claw.c** — outbound binding:
   ```c
   claw_event_router_register_outbound_binding("mqtt", "mqtt_send_message");
   ```

6. **app_claw_cli.c** — CLI registration

7. **app_config** — MQTT fields in config struct, NVS persistence, and mapping to `app_claw_config_t`

### CMakeLists.txt

```cmake
idf_component_register(
    SRCS
        "src/cap_im_mqtt.c"
        "src/cmd_cap_im_mqtt.c"
    INCLUDE_DIRS
        "include"
    REQUIRES
        claw_cap
        claw_event_router
        mqtt
        esp_timer
        freertos
        json
        console
)
```

**Note:** ESP-IDF's MQTT component is named `mqtt`, NOT `esp_mqtt`.

---

## 7. Lua Scripting Layer

### Runtime Environment

- Lua 5.x embedded in ESP32-S3 via `cap_lua` capability
- Scripts run in a sandboxed environment with module access
- Scripts are loaded from `/fatfs/scripts/` on the FAT partition
- Built-in demo scripts are in `/fatfs/scripts/builtin/`

### Module Loading

Scripts use `require()` with module names mapped to `.lua` files:
```lua
local i2c = require("i2c")           -- maps to i2c Lua module
local gpio = require("gpio")         -- maps to gpio Lua module
local sensors = require("hydro_sensors")  -- maps to hydro_sensors.lua
```

### Available Lua Modules

| Module | Description |
|--------|-------------|
| `i2c` | I2C bus master |
| `uart` | UART communication |
| `gpio` | Digital I/O |
| `mcpwm` | Motor PWM control |
| `adc` | Analog-to-digital conversion |
| `delay` | Timing (ms/us) |
| `system` | System info (IP, uptime, heap) |
| `display` | LCD display rendering |
| `led_strip` | WS2812 LED control |
| `camera` | Camera capture |
| `storage` | File I/O on FAT partition |
| `button` | Button/touch input |
| `knob` | Rotary encoder |
| `touch` | Capacitive touch |
| `dht` | DHT temperature/humidity |
| `ssd1306` | OLED display |
| `event_publisher` | Publish custom events to event router |
| `capability` | Call capabilities from Lua |
| `board_manager` | Access board device handles |

### Custom Hydroponic Scripts

Located at `/fatfs/scripts/`:

| Script | Purpose |
|--------|---------|
| `hydro_adc_exp.lua` | ADC expansion board driver (I2C 0x24) |
| `hydro_as7341.lua` | AS7341 VIS+NIR spectral sensor driver |
| `hydro_as7263.lua` | AS7263 NIR spectral sensor driver |
| `hydro_ba121.lua` | BA121 conductivity + temperature driver (UART) |
| `hydro_sensors.lua` | Unified sensor hub — reads all sensors |
| `hydro_controls.lua` | Actuator control (valve, pumps, relays) |
| `hydro_main.lua` | Test script — reads all sensors and prints |

---

## 8. Sensor Drivers

### hydro_adc_exp.lua — ADC Expansion Board (I2C 0x24)

8-channel GPIO expansion with 10-bit ADC (0-1023).

```lua
local adc = require("hydro_adc_exp")
local i2c = require("i2c")
local bus = i2c.new(0, 8, 9, 400000)
local board = adc.new(bus, 0x24)

-- Set pin 0 to ADC mode
board:set_pin_mode(0, adc.MODE_ADC)  -- MODE_ADC = 0x10

-- Read raw ADC value (0-1023)
local raw = board:read_raw(0)

-- Read voltage (0-3.3V)
local voltage = board:read_voltage(0)
```

Pin modes:
- `MODE_ADC` (0x10) — Analog input
- `MODE_OUTPUT` (0x08) — Digital output
- `MODE_INPUT_PULLUP` (0x01) — Digital input with pull-up

### hydro_as7341.lua — VIS+NIR Spectral Sensor (I2C 0x39)

10-channel spectral sensor: F1-F8 (415-680nm) + CLEAR + NIR.

```lua
local as7341 = require("hydro_as7341")
local i2c = require("i2c")
local bus = i2c.new(0, 8, 9, 400000)
local sensor = as7341.new(bus)
local data = sensor:read_all()
-- data.F1, data.F2, data.F3, data.F4, data.F5, data.F6, data.F7, data.F8
-- data.CLEAR, data.NIR
```

Channel wavelengths:
| Channel | Wavelength |
|---------|-----------|
| F1 | 415nm |
| F2 | 445nm |
| F3 | 480nm |
| F4 | 515nm |
| F5 | 555nm |
| F6 | 590nm |
| F7 | 630nm |
| F8 | 680nm |

### hydro_as7263.lua — NIR Spectral Sensor (I2C 0x49)

6-channel NIR sensor using virtual register protocol.

```lua
local as7263 = require("hydro_as7263")
local sensor = as7263.new(bus)
local data = sensor:measure()
-- data.R (610nm), data.S (680nm), data.T (730nm)
-- data.U (760nm), data.V (810nm), data.W (860nm)
```

### hydro_ba121.lua — Conductivity & Temperature (UART1)

```lua
local ba121 = require("hydro_ba121")
local uart = require("uart")
local u = uart.new(1, 17, 18, 9600)
local ec, temp, err = ba121.read(u)
-- ec: conductivity in uS/cm
-- temp: temperature in Celsius
```

Protocol: CMD(1B) + DATA(4B big-endian) + CHECKSUM(1B) = 6 bytes per frame.

### hydro_sensors.lua — Unified Sensor Hub

```lua
local sensors = require("hydro_sensors")
sensors.init()        -- Initialize I2C, UART, GPIO
local data = sensors.read_all()
```

Returns a table with these keys:

| Key | Type | Description |
|-----|------|-------------|
| `ph` | float | pH value (0-14) |
| `pressure_mpa` | float | Water pressure in MPa |
| `ec_us` | int | Conductivity in uS/cm |
| `ec_ms` | float | Conductivity in mS/cm |
| `water_temp` | float | Water temperature in Celsius |
| `leak` | int | Leak sensor (0=dry, 1=leak) |
| `vis_F1`..`vis_F8` | int | AS7341 visible spectral channels |
| `vis_CLEAR` | int | AS7341 clear channel |
| `vis_NIR` | int | AS7341 NIR channel |
| `nir_R`..`nir_W` | int | AS7263 NIR channels |

Hardware connections used by `hydro_sensors.lua`:
- I2C: SDA=GPIO8, SCL=GPIO9, 400kHz
- BA121 UART: TX=GPIO17, RX=GPIO18, 9600 baud
- Leak sensor: GPIO1
- Voltage divider ratio: 0.233 (R1=33K, R2=10K)

---

## 9. Control Drivers

### hydro_controls.lua

```lua
local controls = require("hydro_controls")
controls.init()
```

#### Valve (GPIO4, active-low relay)

```lua
controls.valve_open()         -- Open (set GPIO4 LOW)
controls.valve_close()        -- Close (set GPIO4 HIGH)
controls.valve_toggle()       -- Toggle state
local open = controls.valve_is_open()
```

#### Peristaltic Pumps (L9110S H-bridge + MCPWM)

Pump A: GPIO6 (IN1) + GPIO7 (IN2)
Pump B: GPIO15 (IN1) + GPIO16 (IN2)

```lua
controls.pump_a_forward(50)   -- Forward at 50% duty
controls.pump_a_reverse(75)   -- Reverse at 75% duty
controls.pump_a_stop()        -- Stop (both LOW)
```

L9110S truth table:
| IN1 | IN2 | Action |
|-----|-----|--------|
| PWM | LOW | Forward |
| LOW | PWM | Reverse |
| LOW | LOW | Stop/Brake |

#### Relays

```lua
-- Water Pump (GPIO2)
controls.water_pump_on()
controls.water_pump_off()
controls.water_pump_toggle()

-- Grow Light (GPIO3)
controls.grow_light_on()
controls.grow_light_off()
controls.grow_light_toggle()
```

#### Status

```lua
local status = controls.status()
-- status.valve_open: boolean
-- status.water_pump_on: boolean
-- status.grow_light_on: boolean
```

#### Emergency Stop

When called with `"emergency_stop"` argument, the script immediately:
1. Closes the valve
2. Stops all pumps
3. Turns off the water pump

---

## 10. Event Router and Router Rules

### Router Rules File

Located at `/fatfs/router_rules/router_rules.json`. This JSON array defines how events are processed.

### Rule Structure

```json
{
  "id": "rule_id",
  "description": "What this rule does",
  "enabled": true,
  "consume_on_match": true,
  "ack": "acknowledgment template",
  "match": {
    "event_type": "message",
    "event_key": "text",
    "content_type": "text"
  },
  "actions": [
    { "type": "action_type", "input": { ... } }
  ]
}
```

### Active Rules

| Rule ID | Trigger | Action |
|---------|---------|--------|
| `im_new_session` | Text = `/new` | Create new chat session |
| `im_any_message_working_reply` | Any text message | Send "snapping on it..." acknowledgment |
| `im_attachment_saved_reply` | Attachment saved event | Confirm file received |
| `im_any_message_agent` | Any text message | Run AI agent |
| `agent_stage_im_notify` | Agent stage progress | Forward to IM |
| `agent_out_message_send_message` | Agent output | Deliver to original IM chat |
| `hydro_leak_emergency` | Leak detected | Emergency stop + alert via IM |

### Leak Emergency Rule

```json
{
  "id": "hydro_leak_emergency",
  "match": {
    "source_cap": "cap_lua",
    "event_type": "custom",
    "event_key": "hydro_leak"
  },
  "actions": [
    { "type": "run_script", "input": { "path": "scripts/hydro_controls.lua", "args": "emergency_stop" } },
    { "type": "send_message", "input": { "channel": "telegram", "message": "ALERT: Water leak detected!" } }
  ]
}
```

### Action Types

| Type | Description |
|------|-------------|
| `send_message` | Send text via IM channel |
| `run_agent` | Invoke LLM agent |
| `run_script` | Execute Lua script |
| `call_cap` | Call a capability |

### Template Variables

Rules support `{{event.*}}` template variables:
- `{{event.source_channel}}` — IM channel (mqtt, telegram, etc.)
- `{{event.chat_id}}` — Chat identifier
- `{{event.text}}` — Message text
- `{{event.event_type}}` — Event type
- `{{event.source_cap}}` — Originating capability

---

## 11. Configuration System

### NVS-Based Persistent Configuration

Configuration is stored in NVS (Non-Volatile Storage) using the `settings_store` abstraction. All settings are key-value string pairs.

### Config Structure (app_config.h)

```c
typedef struct {
    char wifi_ssid[320];
    char wifi_password[320];
    char llm_api_key[320];
    char llm_backend_type[32];
    char llm_profile[32];
    char llm_model[64];
    char llm_base_url[320];
    char llm_auth_type[32];
    char llm_timeout_ms[16];
    char llm_max_tokens[16];
    // IM channels
    char qq_app_id[32];
    char qq_app_secret[320];
    char feishu_app_id[64];
    char feishu_app_secret[320];
    char tg_bot_token[320];
    char mqtt_broker_url[320];
    char mqtt_username[32];
    char mqtt_password[320];
    char mqtt_device_id[32];
    char mqtt_topic_prefix[32];
    char wechat_token[320];
    char wechat_base_url[320];
    char wechat_cdn_base_url[320];
    char wechat_account_id[32];
    // Search
    char search_brave_key[320];
    char search_tavily_key[320];
    // Capabilities
    char enabled_cap_groups[320];
    char llm_visible_cap_groups[320];
    char enabled_lua_modules[320];
    char time_timezone[32];
} app_config_t;
```

### MQTT NVS Keys

| NVS Key | Config Field | Default |
|---------|-------------|---------|
| `mqtt_url` | `mqtt_broker_url` | `""` |
| `mqtt_user` | `mqtt_username` | `""` |
| `mqtt_pass` | `mqtt_password` | `""` |
| `mqtt_devid` | `mqtt_device_id` | `""` |
| `mqtt_prefix` | `mqtt_topic_prefix` | `"esp-claw"` |

### Config Flow

```
NVS Storage
    -> app_config_load() reads all keys with defaults
    -> app_config_to_claw() maps to app_claw_config_t
    -> app_claw_start(s_claw_config, s_claw_paths) initializes framework
    -> Each capability prepare() receives its config fields
```

### LLM Profiles

| Profile | Description |
|---------|-------------|
| `openai` | OpenAI GPT models |
| `qwen_compatible` | Qwen (Alibaba Cloud) |
| `custom_openai_compatible` | DeepSeek or any OpenAI-compatible API |

---

## 12. HTTP Server & Web UI

The HTTP server provides a web-based configuration interface accessible via the device's IP address.

### Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/` | GET | Web UI (SPA) |
| `/api/config` | GET | Get current configuration |
| `/api/config` | POST | Save configuration |
| `/api/wifi/status` | GET | WiFi connection status |
| `/api/wifi/scan` | GET | Scan for WiFi networks |
| `/api/restart` | POST | Restart device |

### Web UI Configuration Fields

The Web UI allows setting:
- WiFi SSID and password
- LLM provider, API key, model, base URL
- MQTT broker URL, username, password, device ID, topic prefix
- Telegram bot token
- Timezone
- Enabled capability groups and Lua modules

### Captive DNS

When the device is in AP mode, a captive DNS portal automatically redirects connected clients to the web UI.

---

## 13. Skills System

Skills are Markdown files that provide domain knowledge to the LLM agent. They are stored at `/fatfs/skills/`.

### Skill Files

| File | Purpose |
|------|---------|
| `hydroponic.md` | System overview, sensor table, control table, safety rules |
| `hydro_sensors.md` | How to read sensors from Lua |
| `hydro_controls.md` | How to operate controls from Lua |
| `cap_im_mqtt.md` | MQTT messaging capability description |

### How Skills Work

1. When a new agent session starts, the skill system loads all skill Markdown files from `/fatfs/skills/`
2. These documents are injected into the LLM's system prompt
3. The LLM uses this knowledge to decide which Lua functions to call or capabilities to invoke
4. Example: User sends "read all sensors" via MQTT → LLM reads `hydro_sensors.md` → generates Lua code to call `sensors.read_all()`

### Adding New Skills

1. Create a `.md` file in `/fatfs/skills/`
2. Describe the capability, API, and usage examples
3. The skill is automatically loaded on next agent session

---

## 14. Memory System

### Session Memory

Agent conversation history is stored per-session under `/fatfs/sessions/`. Sessions persist across messages and can be reset with `/new`.

### Long-term Memory

Agent memory files are stored at `/fatfs/memory/`. The `MEMORY.md` file contains persistent system state that the agent can reference.

### Current MEMORY.md

```markdown
## System State
- Sensors: AS7341 (0x39), AS7263 (0x49), ADC Expansion (0x24), BA121 (UART1)
- Controls: Valve (GPIO4), Pump A (GPIO6+7), Pump B (GPIO15+16), Water Pump (GPIO2), Grow Light (GPIO3)
- Network: WiFi (ESP-Claw built-in)
- IM Channels: Telegram, MQTT

## Safety Thresholds
- pH safe range: 5.5 - 7.5
- EC safe range: 500 - 3000 uS/cm
- Temperature safe range: 18 - 30 C
- Pressure max: 0.8 MPa
- Leak: 0 = dry (safe), 1 = leak (emergency)
```

---

## 15. Build & Flash Instructions

### Prerequisites

- **ESP-IDF v5.5.1** installed at `~/esp/esp-idf/`
- Python 3.8+
- Git

### Environment Setup

```bash
# Source ESP-IDF
. ~/esp/esp-idf/export.sh

# Clone repository
git clone https://github.com/ai-caseylai/esp-claw.git
cd esp-claw
git checkout hydroponic-mqtt

# Navigate to edge_agent
cd application/edge_agent
```

### Build

```bash
# Full build (includes board manager generation)
idf.py -DBOARD=esp32_s3_hydro build
```

**First build note:** The board manager generates `board_manager.defaults` from board YAML files. This file is injected into SDKCONFIG_DEFAULTS, which configures flash size, PSRAM, partition table, and peripheral support.

### Flash

```bash
# Flash via USB
idf.py -DBOARD=esp32_s3_hydro -p /dev/ttyUSB0 flash

# Or specify port for macOS
idf.py -DBOARD=esp32_s3_hydro -p /dev/cu.usbmodem* flash
```

### Monitor

```bash
idf.py -DBOARD=esp32_s3_hydro -p /dev/ttyUSB0 monitor
```

### Clean Build (when adding new components)

```bash
# MUST delete both build cache and sdkconfig when adding new components
rm -rf build sdkconfig
idf.py -DBOARD=esp32_s3_hydro build
```

**Why clean build?** ESP-IDF's component manager caches resolved dependencies. New components with `idf_component.yml` path entries require a clean cmake reconfigure.

### FAT Filesystem Image

The `fatfs_image/` directory contains files that will be flashed to the FAT partition:

```bash
# Flash FAT image (first time only)
python $IDF_PATH/components/fatfs/nested_fs_example/fatfs_create.py \
    --output storage.bin \
    --size 4194304 \
    fatfs_image/

# Flash to storage partition
esptool.py --chip esp32s3 --port /dev/ttyUSB0 \
    write_flash 0x900000 storage.bin
```

**Note:** The FAT partition offset depends on your partition table. Check with `idf.py partition-table`.

---

## 16. Deployment Guide

### Initial Setup

1. **Flash firmware** via USB
2. **Flash FAT image** with Lua scripts, skills, router rules, and memory files
3. **Connect to WiFi AP** — device creates an open AP with SSID like `esp-claw-xxxxxx`
4. **Open web UI** at the AP gateway IP (usually `http://192.168.4.1/`)
5. **Configure WiFi** — enter your network SSID and password
6. **Configure LLM** — enter API key, select provider, set model
7. **Configure MQTT** — enter broker URL, device ID, credentials

### MQTT Configuration

Via Web UI or console:

```
mqtt --config mqtt://broker.example.com:1883 hydro_01
mqtt --config mqtt://broker.example.com:1883 hydro_01 user pass
mqtt --start
```

Or via NVS config:

```
# Set via console or Web UI
mqtt_url = "mqtt://broker.example.com:1883"
mqtt_devid = "hydro_01"
mqtt_prefix = "esp-claw"
mqtt_user = "username"     # optional
mqtt_pass = "password"     # optional
```

### Verifying MQTT Connection

1. Check console output for `MQTT connected, subscribing to esp-claw/hydro_01/inbox`
2. Use `mosquitto_sub` to monitor:
   ```bash
   mosquitto_sub -h broker.example.com -t "esp-claw/hydro_01/outbox"
   ```
3. Send a test message:
   ```bash
   mosquitto_pub -h broker.example.com \
       -t "esp-claw/hydro_01/inbox" \
       -m '{"text": "Read all sensors"}'
   ```

### OTA Updates

The dual-partition scheme (4MB + 4MB) supports OTA updates:

```bash
# Build OTA image
idf.py -DBOARD=esp32_s3_hydro build

# Upload via HTTP API or esp_ota_* APIs
```

---

## 17. MQTT External Integration

### Using mosquitto CLI

```bash
# Subscribe to device output
mosquitto_sub -h broker.example.com -t "esp-claw/hydro_01/outbox" -v

# Send command
mosquitto_pub -h broker.example.com \
    -t "esp-claw/hydro_01/inbox" \
    -m '{"text": "What is the current pH level?"}'

# Send with sender info
mosquitto_pub -h broker.example.com \
    -t "esp-claw/hydro_01/inbox" \
    -m '{"chat_id": "control_panel", "sender_id": "alice", "text": "Turn on grow light"}'
```

### Node-RED Integration

```
[MQTT In] → broker.example.com:1883 → topic: esp-claw/hydro_01/outbox
[Function] → Parse JSON, extract text and chat_id
[Dashboard] → Display sensor readings

[Inject] → {"text": "Read sensors"}
[MQTT Out] → broker.example.com:1883 → topic: esp-claw/hydro_01/inbox
```

### Home Assistant Integration

```yaml
# configuration.yaml
sensor:
  - platform: mqtt
    name: "Hydro Sensor Data"
    state_topic: "esp-claw/hydro_01/outbox"
    value_template: "{{ value_json.text }}"
    json_attributes_topic: "esp-claw/hydro_01/outbox"

automation:
  - alias: "Send command to hydroponic system"
    trigger:
      - platform: time
        at: "08:00:00"
    action:
      - service: mqtt.publish
        data:
          topic: "esp-claw/hydro_01/inbox"
          payload: '{"text": "Read all sensors and report status"}'
```

### TLS Configuration

Use `mqtts://` URL scheme for encrypted connections:

```
mqtt --config mqtts://broker.example.com:8883 hydro_01
```

ESP-IDF's `esp_mqtt_client` automatically handles TLS certificate verification using the ESP-TLS stack.

---

## 18. Console Commands Reference

### WiFi Commands

```
wifi --connect <ssid> <password>    # Connect to WiFi
wifi --disconnect                    # Disconnect
wifi --status                        # Show WiFi status
wifi --scan                          # Scan networks
```

### MQTT Commands

```
mqtt --config <broker_url> <device_id> [username] [password]  # Configure MQTT
mqtt --start                                                    # Start MQTT client
mqtt --stop                                                     # Stop MQTT client
mqtt --status                                                   # Show connection status
mqtt --send-text <chat_id> <text>                              # Send test message
```

### System Commands

```
restart          # Restart device
free             # Show heap memory
tasks            # Show running tasks
```

---

## 19. API Reference

### cap_im_mqtt.h

```c
/**
 * Register MQTT capability group with the framework.
 * Called during app_claw capability registration.
 */
esp_err_t cap_im_mqtt_register_group(void);

/**
 * Configure MQTT connection parameters.
 * Must be called before cap_im_mqtt_start().
 *
 * @param config  Configuration struct (all strings are copied)
 * @return ESP_OK on success
 */
esp_err_t cap_im_mqtt_set_config(const cap_im_mqtt_config_t *config);

/**
 * Start the MQTT client.
 * Connects to the broker and subscribes to inbox topic.
 *
 * @return ESP_OK on success, ESP_ERR_INVALID_STATE if not configured
 */
esp_err_t cap_im_mqtt_start(void);

/**
 * Stop the MQTT client.
 * Disconnects and destroys the client handle.
 *
 * @return ESP_OK on success
 */
esp_err_t cap_im_mqtt_stop(void);

/**
 * Send a text message via MQTT.
 * Publishes to the outbox topic as JSON.
 * Auto-chunks messages > 4096 bytes.
 *
 * @param chat_id  Target chat identifier (included in payload)
 * @param text     Message text to send
 * @return ESP_OK on success, ESP_ERR_INVALID_STATE if not connected
 */
esp_err_t cap_im_mqtt_send_text(const char *chat_id, const char *text);
```

### app_config.h

```c
/**
 * Initialize settings store (NVS backend).
 */
esp_err_t app_config_init(void);

/**
 * Load all config fields from NVS with defaults.
 */
esp_err_t app_config_load(app_config_t *config);

/**
 * Save all config fields to NVS.
 */
esp_err_t app_config_save(const app_config_t *config);

/**
 * Map app_config_t to app_claw_config_t.
 */
void app_config_to_claw(const app_config_t *config, app_claw_config_t *out);
```

---

## 20. Troubleshooting

### Build Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `cap_im_mqtt.h: No such file or directory` | Component not discoverable | Add path entry to BOTH `app_claw/idf_component.yml` AND `main/idf_component.yml`, then `rm -rf build sdkconfig` |
| `esp_mqtt component not found` | Wrong component name | Use `mqtt` in REQUIRES, not `esp_mqtt` |
| `struct broker_t has no member named uri` | Wrong ESP-IDF API | Use `mqtt_cfg.broker.address.uri` |
| `init_level field not in RMT TX flags` | ESP-IDF v5.5.1 API change | Remove `init_level` from board YAML |
| `partition table too large` | Missing flash size config | Ensure `board_manager.defaults` is in SDKCONFIG_DEFAULTS |
| `dev_custom.h: No such file` | Board defaults not loaded | Same as above — cmake must inject `board_manager.defaults` |

### Runtime Errors

| Symptom | Cause | Fix |
|---------|-------|-----|
| MQTT not connecting | Broker URL not set | Configure via console or Web UI |
| Agent not responding | LLM API key missing | Set via Web UI |
| Sensors returning nil | I2C bus not initialized | Call `sensors.init()` first |
| FATFS mount failed | Partition not formatted | First boot auto-formats; check partition table |
| WiFi not connecting | Wrong credentials | Reset via AP mode (hold BOOT on boot) |

### Clean Build Procedure

When in doubt, do a full clean:

```bash
rm -rf build sdkconfig sdkconfig.old
idf.py -DBOARD=esp32_s3_hydro build
```

### Memory Monitoring

Enable `APP_ENABLE_MEM_LOG` in main.c to get periodic heap status:

```
Memory: internal_free=123456 bytes, internal_min_free=98765 bytes, psram_free=7654321 bytes
```

---

## 21. File Tree

```
esp-claw/
├── application/
│   └── edge_agent/
│       ├── boards/
│       │   └── espressif/
│       │       └── esp32_s3_hydro/
│       │           ├── board_info.yaml
│       │           ├── board_devices.yaml
│       │           ├── board_peripherals.yaml
│       │           ├── sdkconfig.defaults.board
│       │           └── setup_device.c
│       ├── components/
│       │   ├── app_config/
│       │   │   ├── include/app_config.h
│       │   │   └── app_config.c
│       │   └── http_server/
│       │       └── (web UI + REST API)
│       ├── fatfs_image/
│       │   ├── memory/
│       │   │   ├── MEMORY.md
│       │   │   └── skills/
│       │   │       ├── hydroponic.md
│       │   │       ├── hydro_sensors.md
│       │   │       └── hydro_controls.md
│       │   ├── router_rules/
│       │   │   └── router_rules.json
│       │   ├── scripts/
│       │   │   ├── hydro_adc_exp.lua
│       │   │   ├── hydro_as7341.lua
│       │   │   ├── hydro_as7263.lua
│       │   │   ├── hydro_ba121.lua
│       │   │   ├── hydro_sensors.lua
│       │   │   ├── hydro_controls.lua
│       │   │   ├── hydro_main.lua
│       │   │   └── builtin/
│       │   │       └── (demo scripts)
│       │   ├── scheduler/
│       │   │   └── schedules.json
│       │   └── inbox/
│       ├── main/
│       │   ├── main.c
│       │   ├── CMakeLists.txt
│       │   └── idf_component.yml
│       ├── partitions_16MB.csv
│       └── tools/
│           └── cmake/
│               └── flash_partition_defaults.cmake
├── components/
│   ├── claw_capabilities/
│   │   ├── cap_im_mqtt/
│   │   │   ├── CMakeLists.txt
│   │   │   ├── idf_component.yml
│   │   │   ├── include/
│   │   │   │   ├── cap_im_mqtt.h
│   │   │   │   └── cmd_cap_im_mqtt.h
│   │   │   ├── src/
│   │   │   │   ├── cap_im_mqtt.c
│   │   │   │   └── cmd_cap_im_mqtt.c
│   │   │   └── skills/
│   │   │       ├── cap_im_mqtt.md
│   │   │       └── skills_list.json
│   │   ├── cap_im_tg/
│   │   ├── cap_lua/
│   │   ├── cap_system/
│   │   ├── cap_scheduler/
│   │   ├── cap_web_search/
│   │   └── ... (20+ capabilities)
│   ├── claw_modules/
│   │   ├── claw_cap/          # Capability framework
│   │   ├── claw_core/         # Agent loop + LLM
│   │   ├── claw_event_router/ # Event routing
│   │   ├── claw_memory/       # Session + persistent memory
│   │   └── claw_skill/        # Skill loading
│   ├── lua_modules/
│   │   ├── lua_module_i2c/
│   │   ├── lua_module_gpio/
│   │   ├── lua_module_mcpwm/
│   │   ├── lua_module_uart/
│   │   └── ... (30+ Lua modules)
│   └── common/
│       ├── app_claw/          # Application framework glue
│       ├── settings/          # NVS settings store
│       ├── wifi_manager/      # WiFi STA/AP management
│       └── captive_dns/       # Captive portal DNS
```
