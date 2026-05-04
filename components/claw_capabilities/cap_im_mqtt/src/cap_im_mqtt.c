/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "cap_im_mqtt.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "claw_event_publisher.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "mqtt_client.h"

static const char *TAG = "cap_im_mqtt";

#define CAP_IM_MQTT_MAX_MSG_LEN    4096
#define CAP_IM_MQTT_TOPIC_BUF_LEN  160
#define CAP_IM_MQTT_URL_BUF_LEN    192
#define CAP_IM_MQTT_CRED_BUF_LEN   128
#define CAP_IM_MQTT_DEVICE_BUF_LEN 64

typedef struct {
    char broker_url[CAP_IM_MQTT_URL_BUF_LEN];
    char username[CAP_IM_MQTT_CRED_BUF_LEN];
    char password[CAP_IM_MQTT_CRED_BUF_LEN];
    char device_id[CAP_IM_MQTT_DEVICE_BUF_LEN];
    char topic_prefix[CAP_IM_MQTT_DEVICE_BUF_LEN];
    char inbox_topic[CAP_IM_MQTT_TOPIC_BUF_LEN];
    char outbox_topic[CAP_IM_MQTT_TOPIC_BUF_LEN];
    char client_id[CAP_IM_MQTT_DEVICE_BUF_LEN + 8];
    esp_mqtt_client_handle_t client;
    bool connected;
} cap_im_mqtt_state_t;

static cap_im_mqtt_state_t s_mqtt;

static int64_t cap_im_mqtt_now_ms(void)
{
    return esp_timer_get_time() / 1000LL;
}

static void cap_im_mqtt_compose_topics(void)
{
    snprintf(s_mqtt.inbox_topic, sizeof(s_mqtt.inbox_topic),
             "%s/%s/inbox", s_mqtt.topic_prefix, s_mqtt.device_id);
    snprintf(s_mqtt.outbox_topic, sizeof(s_mqtt.outbox_topic),
             "%s/%s/outbox", s_mqtt.topic_prefix, s_mqtt.device_id);
}

static void cap_im_mqtt_compose_client_id(void)
{
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(s_mqtt.client_id, sizeof(s_mqtt.client_id),
             "%s_%02x%02x", s_mqtt.device_id, mac[4], mac[5]);
}

static esp_err_t cap_im_mqtt_publish_inbound(const char *chat_id,
                                              const char *sender_id,
                                              const char *message_id,
                                              const char *text)
{
    if (!text || !text[0]) {
        return ESP_OK;
    }

    return claw_event_router_publish_message("mqtt_gateway",
                                             "mqtt",
                                             chat_id,
                                             text,
                                             sender_id,
                                             message_id);
}

static void cap_im_mqtt_handle_inbound(const char *topic, int topic_len,
                                        const char *data, int data_len)
{
    cJSON *root = NULL;
    cJSON *chat_id_json;
    cJSON *sender_id_json;
    cJSON *message_id_json;
    cJSON *text_json;
    const char *chat_id = "mqtt";
    const char *sender_id = "";
    const char *message_id = "";
    char *payload = NULL;
    char msg_id_buf[32];

    if (!data || data_len <= 0) {
        return;
    }

    payload = calloc(1, (size_t)data_len + 1);
    if (!payload) {
        return;
    }
    memcpy(payload, data, (size_t)data_len);

    root = cJSON_Parse(payload);
    if (!root) {
        /* Treat raw payload as plain text */
        snprintf(msg_id_buf, sizeof(msg_id_buf), "mqtt-%lld", (long long)cap_im_mqtt_now_ms());
        cap_im_mqtt_publish_inbound("mqtt", "", msg_id_buf, payload);
        free(payload);
        return;
    }

    chat_id_json = cJSON_GetObjectItem(root, "chat_id");
    sender_id_json = cJSON_GetObjectItem(root, "sender_id");
    message_id_json = cJSON_GetObjectItem(root, "message_id");
    text_json = cJSON_GetObjectItem(root, "text");

    if (cJSON_IsString(chat_id_json) && chat_id_json->valuestring[0]) {
        chat_id = chat_id_json->valuestring;
    }
    if (cJSON_IsString(sender_id_json) && sender_id_json->valuestring) {
        sender_id = sender_id_json->valuestring;
    }
    if (cJSON_IsString(message_id_json) && message_id_json->valuestring) {
        message_id = message_id_json->valuestring;
    } else {
        snprintf(msg_id_buf, sizeof(msg_id_buf), "mqtt-%lld", (long long)cap_im_mqtt_now_ms());
        message_id = msg_id_buf;
    }

    if (cJSON_IsString(text_json) && text_json->valuestring && text_json->valuestring[0]) {
        if (cap_im_mqtt_publish_inbound(chat_id, sender_id, message_id,
                                        text_json->valuestring) == ESP_OK) {
            ESP_LOGI(TAG, "MQTT inbound %s: %.48s%s",
                     chat_id, text_json->valuestring,
                     strlen(text_json->valuestring) > 48 ? "..." : "");
        }
    }

    cJSON_Delete(root);
    free(payload);
}

static void mqtt_event_handler(void *arg, esp_event_base_t base,
                                int32_t event_id, void *event_data)
{
    esp_mqtt_event_handle_t event = (esp_mqtt_event_handle_t)event_data;

    switch ((esp_mqtt_event_id_t)event_id) {
    case MQTT_EVENT_CONNECTED:
        ESP_LOGI(TAG, "MQTT connected, subscribing to %s", s_mqtt.inbox_topic);
        esp_mqtt_client_subscribe(event->client, s_mqtt.inbox_topic, 1);
        s_mqtt.connected = true;
        break;
    case MQTT_EVENT_DISCONNECTED:
        ESP_LOGW(TAG, "MQTT disconnected");
        s_mqtt.connected = false;
        break;
    case MQTT_EVENT_DATA:
        cap_im_mqtt_handle_inbound(event->topic, event->topic_len,
                                   event->data, event->data_len);
        break;
    case MQTT_EVENT_ERROR:
        ESP_LOGW(TAG, "MQTT error event");
        break;
    default:
        break;
    }
}

/* --- Capability lifecycle --- */

static esp_err_t mqtt_gateway_init(void)
{
    if (s_mqtt.broker_url[0] == '\0') {
        ESP_LOGW(TAG, "MQTT broker URL not configured");
        return ESP_OK;
    }

    ESP_LOGI(TAG, "MQTT configured: %s device=%s", s_mqtt.broker_url, s_mqtt.device_id);
    return ESP_OK;
}

static esp_err_t mqtt_gateway_start(void)
{
    esp_mqtt_client_config_t mqtt_cfg = {0};

    if (s_mqtt.broker_url[0] == '\0') {
        ESP_LOGW(TAG, "MQTT not configured, skipping start");
        return ESP_OK;
    }
    if (s_mqtt.client) {
        return ESP_OK;
    }

    mqtt_cfg.broker.address.uri = s_mqtt.broker_url;
    mqtt_cfg.credentials.client_id = s_mqtt.client_id;
    if (s_mqtt.username[0]) {
        mqtt_cfg.credentials.username = s_mqtt.username;
    }
    if (s_mqtt.password[0]) {
        mqtt_cfg.credentials.authentication.password = s_mqtt.password;
    }

    s_mqtt.client = esp_mqtt_client_init(&mqtt_cfg);
    if (!s_mqtt.client) {
        ESP_LOGE(TAG, "Failed to initialize MQTT client");
        return ESP_FAIL;
    }

    esp_mqtt_client_register_event(s_mqtt.client, ESP_EVENT_ANY_ID, mqtt_event_handler, NULL);
    esp_mqtt_client_start(s_mqtt.client);
    return ESP_OK;
}

static esp_err_t mqtt_gateway_stop(void)
{
    if (!s_mqtt.client) {
        return ESP_OK;
    }

    esp_mqtt_client_stop(s_mqtt.client);
    esp_mqtt_client_destroy(s_mqtt.client);
    s_mqtt.client = NULL;
    s_mqtt.connected = false;
    return ESP_OK;
}

/* --- Capability execute --- */

static esp_err_t mqtt_send_message_execute(const char *input_json,
                                            const claw_cap_call_context_t *ctx,
                                            char *output,
                                            size_t output_size)
{
    cJSON *root = NULL;
    cJSON *chat_id_json;
    cJSON *message_json;
    const char *chat_id = NULL;
    const char *message = NULL;
    esp_err_t err;

    root = cJSON_Parse(input_json ? input_json : "{}");
    if (!root) {
        snprintf(output, output_size, "Error: invalid JSON");
        return ESP_ERR_INVALID_ARG;
    }

    chat_id_json = cJSON_GetObjectItem(root, "chat_id");
    message_json = cJSON_GetObjectItem(root, "message");
    if (cJSON_IsString(chat_id_json) && chat_id_json->valuestring && chat_id_json->valuestring[0]) {
        chat_id = chat_id_json->valuestring;
    } else if (ctx && ctx->chat_id && ctx->chat_id[0]) {
        chat_id = ctx->chat_id;
    }
    if (cJSON_IsString(message_json) && message_json->valuestring && message_json->valuestring[0]) {
        message = message_json->valuestring;
    }

    if (!chat_id || !message) {
        cJSON_Delete(root);
        snprintf(output, output_size,
                 "Error: chat_id and message are required");
        return ESP_ERR_INVALID_ARG;
    }

    err = cap_im_mqtt_send_text(chat_id, message);
    cJSON_Delete(root);
    if (err != ESP_OK) {
        snprintf(output, output_size, "Error: %s", esp_err_to_name(err));
        return err;
    }

    snprintf(output, output_size, "reply already sent via MQTT");
    return ESP_OK;
}

/* --- Descriptors --- */

static const claw_cap_descriptor_t s_mqtt_descriptors[] = {
    {
        .id = "mqtt_gateway",
        .name = "mqtt_gateway",
        .family = "im",
        .description = "MQTT client gateway. Subscribes to inbox topic for inbound messages.",
        .kind = CLAW_CAP_KIND_EVENT_SOURCE,
        .cap_flags = CLAW_CAP_FLAG_EMITS_EVENTS | CLAW_CAP_FLAG_SUPPORTS_LIFECYCLE,
        .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
        .init = mqtt_gateway_init,
        .start = mqtt_gateway_start,
        .stop = mqtt_gateway_stop,
    },
    {
        .id = "mqtt_send_message",
        .name = "mqtt_send_message",
        .family = "im",
        .description = "Send a text message via MQTT to the outbox topic.",
        .kind = CLAW_CAP_KIND_CALLABLE,
        .cap_flags = CLAW_CAP_FLAG_CALLABLE_BY_LLM,
        .input_schema_json =
        "{\"type\":\"object\",\"properties\":{\"chat_id\":{\"type\":\"string\"},\"message\":{\"type\":\"string\"}},\"required\":[\"chat_id\",\"message\"]}",
        .execute = mqtt_send_message_execute,
    },
};

static const claw_cap_group_t s_mqtt_group = {
    .group_id = "cap_im_mqtt",
    .descriptors = s_mqtt_descriptors,
    .descriptor_count = sizeof(s_mqtt_descriptors) / sizeof(s_mqtt_descriptors[0]),
};

esp_err_t cap_im_mqtt_register_group(void)
{
    if (claw_cap_group_exists(s_mqtt_group.group_id)) {
        return ESP_OK;
    }
    return claw_cap_register_group(&s_mqtt_group);
}

esp_err_t cap_im_mqtt_set_config(const cap_im_mqtt_config_t *config)
{
    if (!config) {
        return ESP_ERR_INVALID_ARG;
    }

    if (config->broker_url) {
        strlcpy(s_mqtt.broker_url, config->broker_url, sizeof(s_mqtt.broker_url));
    }
    if (config->username) {
        strlcpy(s_mqtt.username, config->username, sizeof(s_mqtt.username));
    }
    if (config->password) {
        strlcpy(s_mqtt.password, config->password, sizeof(s_mqtt.password));
    }
    if (config->device_id) {
        strlcpy(s_mqtt.device_id, config->device_id, sizeof(s_mqtt.device_id));
    }
    if (config->topic_prefix) {
        strlcpy(s_mqtt.topic_prefix, config->topic_prefix, sizeof(s_mqtt.topic_prefix));
    } else if (s_mqtt.topic_prefix[0] == '\0') {
        strlcpy(s_mqtt.topic_prefix, "esp-claw", sizeof(s_mqtt.topic_prefix));
    }

    cap_im_mqtt_compose_topics();
    cap_im_mqtt_compose_client_id();
    return ESP_OK;
}

esp_err_t cap_im_mqtt_start(void)
{
    if (s_mqtt.broker_url[0] == '\0') {
        ESP_LOGE(TAG, "MQTT broker URL is not configured");
        return ESP_ERR_INVALID_STATE;
    }
    return mqtt_gateway_start();
}

esp_err_t cap_im_mqtt_stop(void)
{
    return mqtt_gateway_stop();
}

esp_err_t cap_im_mqtt_send_text(const char *chat_id, const char *text)
{
    cJSON *root = NULL;
    char *json_str = NULL;
    size_t text_len;
    size_t offset = 0;
    esp_err_t last_err = ESP_OK;

    if (!text || text[0] == '\0') {
        return ESP_ERR_INVALID_ARG;
    }
    if (!s_mqtt.client || !s_mqtt.connected) {
        return ESP_ERR_INVALID_STATE;
    }

    text_len = strlen(text);
    while (offset < text_len) {
        size_t chunk_len = text_len - offset;
        char *chunk = NULL;
        int ret;

        if (chunk_len > CAP_IM_MQTT_MAX_MSG_LEN) {
            chunk_len = CAP_IM_MQTT_MAX_MSG_LEN;
        }

        chunk = calloc(1, chunk_len + 1);
        if (!chunk) {
            return ESP_ERR_NO_MEM;
        }
        memcpy(chunk, text + offset, chunk_len);

        root = cJSON_CreateObject();
        if (!root) {
            free(chunk);
            return ESP_ERR_NO_MEM;
        }

        if (chat_id && chat_id[0]) {
            cJSON_AddStringToObject(root, "chat_id", chat_id);
        }
        cJSON_AddStringToObject(root, "text", chunk);
        cJSON_AddNumberToObject(root, "timestamp_ms", (double)cap_im_mqtt_now_ms());

        json_str = cJSON_PrintUnformatted(root);
        cJSON_Delete(root);
        free(chunk);

        if (!json_str) {
            return ESP_ERR_NO_MEM;
        }

        ret = esp_mqtt_client_publish(s_mqtt.client, s_mqtt.outbox_topic,
                                      json_str, 0, 1, 0);
        free(json_str);

        if (ret < 0) {
            ESP_LOGW(TAG, "MQTT publish failed (offset %zu)", offset);
            last_err = ESP_FAIL;
        } else {
            ESP_LOGI(TAG, "MQTT published to %s: %zu bytes", s_mqtt.outbox_topic, chunk_len);
        }

        offset += chunk_len;
    }

    return last_err;
}
