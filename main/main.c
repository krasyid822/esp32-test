#include "freertos/FreeRTOS.h" // IWYU pragma: keep
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "driver/gpio.h"
#include "esp_adc/adc_oneshot.h"
#include "ryg_lamp.h"
#include "buzzer.h"

static const char *TAG = "Main_App";

// --- KONFIGURASI PIN SENSOR ---
// 1. HC-SR04 Distance Sensor
#define TRIG_PIN    26
#define ECHO_PIN    27

// 2. Water Level Sensor (Analog ADC1 Channel 5 / GPIO 33)
#define WATER_GPIO_PIN   33
#define WATER_ADC_CHAN   ADC_CHANNEL_5

// 3. MQ Smoke Sensor (Analog ADC1 Channel 7 / GPIO 35)
#define MQ_GPIO_PIN      35
#define MQ_ADC_CHAN      ADC_CHANNEL_7

// Thresholds
#define DIST_TOUCH   4
#define DIST_CLOSE   15
#define DIST_MEDIUM  30

#define WATER_TOUCH  90.0
#define WATER_CLOSE  80.0
#define WATER_MEDIUM 50.0

#define MQ_TOUCH     85.0
#define MQ_CLOSE     60.0
#define MQ_MEDIUM    35.0

// Global variables for sensor readings
static float g_distance = 300.0;
static float g_water_percentage = 0.0;
static float g_mq_percentage = 0.0;
static adc_oneshot_unit_handle_t g_adc1_handle;

// --- SENSOR READ FUNCTIONS ---

static float get_raw_distance_cm(void)
{
    gpio_set_level(TRIG_PIN, 1);
    esp_rom_delay_us(10);
    gpio_set_level(TRIG_PIN, 0);

    int64_t start_time = esp_timer_get_time();
    int64_t timeout = start_time + 30000;
    while (gpio_get_level(ECHO_PIN) == 0) {
        if (esp_timer_get_time() > timeout) return -1.0;
    }
    
    int64_t echo_start = esp_timer_get_time();
    timeout = echo_start + 30000;
    while (gpio_get_level(ECHO_PIN) == 1) {
        if (esp_timer_get_time() > timeout) return -1.0;
    }
    
    int64_t echo_end = esp_timer_get_time();
    return ((echo_end - echo_start) * 0.0343) / 2.0;
}

static float median_of_three(float a, float b, float c)
{
    if ((a <= b && b <= c) || (c <= b && b <= a)) return b;
    if ((b <= a && a <= c) || (c <= a && a <= b)) return a;
    return c;
}

// Fungsi eksternal yang di-query oleh buzzer.c untuk pengecekan interupsi
float get_distance_cm(void)
{
    static float r1 = 300.0, r2 = 300.0, r3 = 300.0;
    static int error_count = 0;
    
    float raw = get_raw_distance_cm();
    if (raw < 0) {
        error_count++;
        if (error_count > 3) return -1.0;
        raw = r1;
    } else {
        error_count = 0;
    }
    r3 = r2; r2 = r1; r1 = raw;
    return median_of_three(r1, r2, r3);
}

// --- FREERTOS TASKS ---

// Task untuk mendeteksi jarak secara berkala
static void distance_task(void *pvParameters)
{
    gpio_reset_pin(TRIG_PIN);
    gpio_reset_pin(ECHO_PIN);
    gpio_set_direction(TRIG_PIN, GPIO_MODE_OUTPUT);
    gpio_set_direction(ECHO_PIN, GPIO_MODE_INPUT);
    gpio_set_level(TRIG_PIN, 0);

    while (1) {
        g_distance = get_distance_cm();
        vTaskDelay(pdMS_TO_TICKS(100)); // Update jarak setiap 100ms
    }
}

// Task untuk membaca sensor air dan sensor MQ asap secara berkala
static void adc_sensors_task(void *pvParameters)
{
    // Konfigurasi Saluran ADC
    adc_oneshot_chan_cfg_t config = {
        .bitwidth = ADC_BITWIDTH_DEFAULT,
        .atten = ADC_ATTEN_DB_12,
    };
    ESP_ERROR_CHECK(adc_oneshot_config_channel(g_adc1_handle, WATER_ADC_CHAN, &config));
    ESP_ERROR_CHECK(adc_oneshot_config_channel(g_adc1_handle, MQ_ADC_CHAN, &config));

    // Tunggu 1 detik stabilisasi elektrik sensor MQ
    vTaskDelay(pdMS_TO_TICKS(1000));

    while (1) {
        // 1. Baca Sensor Air
        int water_raw = 0;
        if (adc_oneshot_read(g_adc1_handle, WATER_ADC_CHAN, &water_raw) == ESP_OK) {
            g_water_percentage = (water_raw / 4095.0) * 100.0;
        }

        // 2. Baca Sensor MQ Asap
        int mq_raw = 0;
        if (adc_oneshot_read(g_adc1_handle, MQ_ADC_CHAN, &mq_raw) == ESP_OK) {
            g_mq_percentage = (mq_raw / 4095.0) * 100.0;
        }

        vTaskDelay(pdMS_TO_TICKS(200)); // Update sensor ADC setiap 200ms
    }
}

// Task Utama Koordinasi Lampu RYG & Buzzer
static void coordination_task(void *pvParameters)
{
    ryg_lamp_init();
    buzzer_init();

    uint8_t blink_state = 0;

    while (1) {
        float dist = g_distance;
        float water = g_water_percentage;
        float smoke = g_mq_percentage;

        ESP_LOGI(TAG, "STATUS -> Jarak: %.1f cm | Air: %.1f%% | Asap: %.1f%%", dist, water, smoke);

        // KONDISI 1: SANGAT BAHAYA / EMERGENCY (Merah Berkedip + Buzzer Bip Cepat)
        // (Jarak < 4cm ATAU Air >= 90% ATAU Asap >= 85%)
        if (dist < DIST_TOUCH || water >= WATER_TOUCH || smoke >= MQ_TOUCH) {
            ryg_lamp_set_yellow(0);
            ryg_lamp_set_green(0);

            blink_state = !blink_state;
            ryg_lamp_set_red(blink_state);

            if (blink_state) {
                buzzer_beep(1000, 150);
            } else {
                vTaskDelay(pdMS_TO_TICKS(150));
            }
        }
        // KONDISI 2: BAHAYA (Merah ON + Melodi Lampu Merah)
        // (Jarak 4-15cm ATAU Air 80%-90% ATAU Asap 60%-85%)
        else if ((dist >= DIST_TOUCH && dist < DIST_CLOSE) || 
                 (water >= WATER_CLOSE && water < WATER_TOUCH) ||
                 (smoke >= MQ_CLOSE && smoke < MQ_TOUCH)) {
            ryg_lamp_set_red(1);
            ryg_lamp_set_yellow(0);
            ryg_lamp_set_green(0);

            buzzer_play_melody();

            // Jeda responsif pasca-melodi
            for (int i = 0; i < 20; i++) {
                if (g_distance < DIST_TOUCH || g_distance >= DIST_CLOSE || 
                    g_water_percentage < WATER_CLOSE || g_water_percentage >= WATER_TOUCH ||
                    g_mq_percentage < MQ_CLOSE || g_mq_percentage >= MQ_TOUCH) {
                    break;
                }
                vTaskDelay(pdMS_TO_TICKS(100));
            }
        }
        // KONDISI 3: SIAGA (Kuning ON + Melodi Ehem)
        // (Jarak 15-30cm ATAU Air 50%-80% ATAU Asap 35%-60%)
        else if ((dist >= DIST_CLOSE && dist < DIST_MEDIUM) || 
                 (water >= WATER_MEDIUM && water < WATER_CLOSE) ||
                 (smoke >= MQ_MEDIUM && smoke < MQ_CLOSE)) {
            ryg_lamp_set_red(0);
            ryg_lamp_set_yellow(1);
            ryg_lamp_set_green(0);

            buzzer_play_ehem();

            // Jeda responsif pasca-ehem
            for (int i = 0; i < 30; i++) {
                if (g_distance < DIST_CLOSE || g_distance >= DIST_MEDIUM || 
                    g_water_percentage < WATER_MEDIUM || g_water_percentage >= WATER_CLOSE ||
                    g_mq_percentage < MQ_MEDIUM || g_mq_percentage >= MQ_CLOSE) {
                    break;
                }
                vTaskDelay(pdMS_TO_TICKS(100));
            }
        }
        // KONDISI 4: AMAN (Hijau ON + Semua Diam)
        else {
            ryg_lamp_set_red(0);
            ryg_lamp_set_yellow(0);
            ryg_lamp_set_green(1);
            vTaskDelay(pdMS_TO_TICKS(500));
        }
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "Memulai Sistem Terpadu (Lampu, Buzzer, Air, Jarak, Asap)...");

    // Inisialisasi unit ADC1 secara global
    adc_oneshot_unit_init_cfg_t init_config = {
        .unit_id = ADC_UNIT_1,
    };
    ESP_ERROR_CHECK(adc_oneshot_new_unit(&init_config, &g_adc1_handle));

    // Membuat FreeRTOS tasks agar semua sensor berjalan paralel
    xTaskCreate(distance_task, "distance_task", 4096, NULL, 5, NULL);
    xTaskCreate(adc_sensors_task, "adc_sensors_task", 4096, NULL, 5, NULL);
    xTaskCreate(coordination_task, "coordination_task", 4096, NULL, 4, NULL);
}
