idf_component_register(SRCS "main.c" "ryg_lamp.c" "buzzer.c"
                       INCLUDE_DIRS "."
                       PRIV_REQUIRES esp_adc esp_driver_gpio esp_timer)
