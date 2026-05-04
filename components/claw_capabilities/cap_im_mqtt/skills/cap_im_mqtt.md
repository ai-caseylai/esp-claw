# MQTT IM Capability

This device communicates via MQTT. You can send and receive text messages through MQTT topics.

## Topics

- **Inbox**: `{topic_prefix}/{device_id}/inbox` — messages sent TO this device
- **Outbox**: `{topic_prefix}/{device_id}/outbox` — messages sent FROM this device

## Inbound Message Format

JSON payload on the inbox topic:
```json
{
  "chat_id": "conversation-id",
  "sender_id": "sender-name",
  "message_id": "unique-id",
  "text": "Hello"
}
```

Plain text payloads are also accepted.

## Outbound

Use the `mqtt_send_message` capability to reply:
```json
{
  "chat_id": "conversation-id",
  "message": "Response text"
}
```

If `chat_id` is omitted, it defaults to the current conversation's chat_id.
