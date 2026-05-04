/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "cmd_cap_im_mqtt.h"

#include <stdio.h>

#include "argtable3/argtable3.h"
#include "cap_im_mqtt.h"
#include "esp_console.h"

static struct {
    struct arg_str *config;
    struct arg_lit *start;
    struct arg_lit *stop;
    struct arg_lit *status;
    struct arg_str *send_text;
    struct arg_str *text;
    struct arg_end *end;
} mqtt_args;

static int cmd_mqtt_config(int argc, const char **argv)
{
    const char *broker_url = mqtt_args.config->sval[0];
    const char *username = mqtt_args.config->count > 1 ? mqtt_args.config->sval[1] : NULL;
    const char *password = mqtt_args.config->count > 2 ? mqtt_args.config->sval[2] : NULL;
    const char *device_id = mqtt_args.config->count > 3 ? mqtt_args.config->sval[3] : "edge_agent";

    esp_err_t err = cap_im_mqtt_set_config(&(cap_im_mqtt_config_t) {
        .broker_url = broker_url,
        .username = username,
        .password = password,
        .device_id = device_id,
    });

    if (err != ESP_OK) {
        printf("mqtt config failed: %s\n", esp_err_to_name(err));
        return 1;
    }

    printf("MQTT configured: %s device=%s\n", broker_url, device_id);
    return 0;
}

static int cmd_mqtt_start(void)
{
    esp_err_t err = cap_im_mqtt_start();
    if (err != ESP_OK) {
        printf("mqtt start failed: %s\n", esp_err_to_name(err));
        return 1;
    }
    printf("MQTT gateway started\n");
    return 0;
}

static int cmd_mqtt_stop(void)
{
    esp_err_t err = cap_im_mqtt_stop();
    if (err != ESP_OK) {
        printf("mqtt stop failed: %s\n", esp_err_to_name(err));
        return 1;
    }
    printf("MQTT gateway stopped\n");
    return 0;
}

static int cmd_mqtt_status(void)
{
    /* Basic status — connected or not */
    printf("MQTT status: use 'mqtt_gateway' capability for runtime state\n");
    return 0;
}

static int cmd_mqtt_send_text(const char *chat_id, const char *text)
{
    esp_err_t err = cap_im_mqtt_send_text(chat_id, text);
    if (err != ESP_OK) {
        printf("mqtt send failed: %s\n", esp_err_to_name(err));
        return 1;
    }
    printf("MQTT text sent\n");
    return 0;
}

static int mqtt_func(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&mqtt_args);
    int operation_count;

    if (nerrors != 0) {
        arg_print_errors(stderr, mqtt_args.end, argv[0]);
        return 1;
    }

    operation_count = mqtt_args.config->count + mqtt_args.start->count +
                      mqtt_args.stop->count + mqtt_args.status->count +
                      mqtt_args.send_text->count;
    if (operation_count != 1) {
        printf("Exactly one operation must be specified\n");
        return 1;
    }

    if (mqtt_args.config->count) {
        return cmd_mqtt_config(argc, (const char **)argv);
    }

    if (mqtt_args.start->count) {
        return cmd_mqtt_start();
    }

    if (mqtt_args.stop->count) {
        return cmd_mqtt_stop();
    }

    if (mqtt_args.status->count) {
        return cmd_mqtt_status();
    }

    if (mqtt_args.send_text->count) {
        if (!mqtt_args.text->count) {
            printf("'--send-text' requires '--text'\n");
            return 1;
        }
        return cmd_mqtt_send_text(mqtt_args.send_text->sval[0], mqtt_args.text->sval[0]);
    }

    return 1;
}

void register_cap_im_mqtt(void)
{
    mqtt_args.config = arg_strn("c", "config", "<url> [user] [pass] [device_id]", 1, 4,
                                "Configure MQTT broker");
    mqtt_args.start = arg_lit0(NULL, "start", "Start the MQTT gateway");
    mqtt_args.stop = arg_lit0(NULL, "stop", "Stop the MQTT gateway");
    mqtt_args.status = arg_lit0(NULL, "status", "Show MQTT status");
    mqtt_args.send_text = arg_str0(NULL, "send-text", "<chat_id>", "Send text via MQTT");
    mqtt_args.text = arg_str0(NULL, "text", "<text>", "Text content");
    mqtt_args.end = arg_end(6);

    const esp_console_cmd_t mqtt_cmd = {
        .command = "mqtt",
        .help = "MQTT operation.\n"
        "Examples:\n"
        " mqtt --config mqtt://broker:1883\n"
        " mqtt --config mqtt://broker:1883 user pass device_01\n"
        " mqtt --start\n"
        " mqtt --stop\n"
        " mqtt --status\n"
        " mqtt --send-text mqtt --text \"hello\"\n",
        .func = mqtt_func,
        .argtable = &mqtt_args,
    };

    ESP_ERROR_CHECK(esp_console_cmd_register(&mqtt_cmd));
}
