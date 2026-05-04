/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "claw_cap.h"
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *broker_url;      /* "mqtt://host:1883" or "mqtts://host:8883" */
    const char *username;
    const char *password;
    const char *device_id;       /* unique device identifier for topic paths */
    const char *topic_prefix;    /* default: "esp-claw" */
} cap_im_mqtt_config_t;

esp_err_t cap_im_mqtt_register_group(void);
esp_err_t cap_im_mqtt_set_config(const cap_im_mqtt_config_t *config);
esp_err_t cap_im_mqtt_start(void);
esp_err_t cap_im_mqtt_stop(void);
esp_err_t cap_im_mqtt_send_text(const char *chat_id, const char *text);

#ifdef __cplusplus
}
#endif
