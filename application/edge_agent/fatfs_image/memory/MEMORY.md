# Long-term Memory

## System State
- Sensors: AS7341 (0x39), AS7263 (0x49), ADC Expansion (0x24), BA121 (UART1)
- Controls: Valve (GPIO4), Pump A (GPIO6+7), Pump B (GPIO15+16), Water Pump (GPIO2), Grow Light (GPIO3)
- Network: WiFi (ESP-Claw built-in)
- IM Channels: Telegram, MQTT

## MQTT Integration
- Protocol: MQTT via ESP-IDF esp_mqtt_client
- Topics: {prefix}/{device_id}/inbox (subscribe), {prefix}/{device_id}/outbox (publish)
- Auth: Username/password, TLS via mqtts:// URL scheme
- Inbound: JSON payload parsed and published to event router
- Outbound: mqtt_send_message capability publishes JSON to outbox topic

## Safety Thresholds
- pH safe range: 5.5 - 7.5
- EC safe range: 500 - 3000 uS/cm
- Temperature safe range: 18 - 30 C
- Pressure max: 0.8 MPa
- Leak: 0 = dry (safe), 1 = leak (emergency)

## Skills
- hydroponic.md — System overview and safety rules
- hydro_sensors.md — How to read sensors
- hydro_controls.md — How to operate controls
- cap_im_mqtt.md — MQTT messaging
