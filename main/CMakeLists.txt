idf_component_register(SRCS "hc_sr04_sensor.c" "wifi_module.c" "main.c" "ryg_lamp.c" "buzzer.c"
                       INCLUDE_DIRS "."
                       PRIV_REQUIRES esp_adc esp_driver_gpio esp_timer nvs_flash esp_wifi esp_http_server)
