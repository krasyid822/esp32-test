#include "ryg_lamp.h"
#include "driver/gpio.h"
#include "esp_log.h"

static const char *TAG = "RYG_Library";

void ryg_lamp_init(void)
{
    // Konfigurasi LED Lampu RYG sebagai Output
    gpio_reset_pin(RED_PIN);
    gpio_reset_pin(YELLOW_PIN);
    gpio_reset_pin(GREEN_PIN);
    
    gpio_set_direction(RED_PIN, GPIO_MODE_OUTPUT);
    gpio_set_direction(YELLOW_PIN, GPIO_MODE_OUTPUT);
    gpio_set_direction(GREEN_PIN, GPIO_MODE_OUTPUT);

    ryg_lamp_all_off();
    ESP_LOGI(TAG, "Lampu RYG berhasil diinisialisasi.");
}

void ryg_lamp_set_red(int level)
{
    gpio_set_level(RED_PIN, level);
}

void ryg_lamp_set_yellow(int level)
{
    gpio_set_level(YELLOW_PIN, level);
}

void ryg_lamp_set_green(int level)
{
    gpio_set_level(GREEN_PIN, level);
}

void ryg_lamp_all_off(void)
{
    gpio_set_level(RED_PIN, 0);
    gpio_set_level(YELLOW_PIN, 0);
    gpio_set_level(GREEN_PIN, 0);
}
