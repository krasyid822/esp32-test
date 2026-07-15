#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_adc/adc_oneshot.h"
#include "ryg_lamp.h" // Mengimpor library lampu RYG

static const char *TAG = "Water_Sensor";

// Tentukan PIN sesuai angka DXX yang tertulis di board (contoh: 33 untuk D33)
#define WATER_GPIO_PIN   33

// Fungsi helper untuk menerjemahkan nomor PIN (GPIO) ke Saluran ADC1 secara otomatis
static adc_channel_t get_adc_channel(int gpio_num)
{
    switch (gpio_num) {
        case 36: return ADC_CHANNEL_0; // Pin VP
        case 39: return ADC_CHANNEL_3; // Pin VN
        case 32: return ADC_CHANNEL_4; // Pin D32
        case 33: return ADC_CHANNEL_5; // Pin D33
        case 34: return ADC_CHANNEL_6; // Pin D34
        case 35: return ADC_CHANNEL_7; // Pin D35
        default:
            ESP_LOGE(TAG, "GPIO %d tidak mendukung ADC1! Menggunakan D33 secara default.", gpio_num);
            return ADC_CHANNEL_5;
    }
}

void water_sensor_main(void)
{
    ESP_LOGI(TAG, "Memulai program deteksi air pada PIN D%d...", WATER_GPIO_PIN);
    
    // Inisialisasi Lampu RYG
    ryg_lamp_init();

    // Konversi nomor PIN ke Saluran ADC
    adc_channel_t water_channel = get_adc_channel(WATER_GPIO_PIN);

    // 1. Inisialisasi unit ADC1
    adc_oneshot_unit_handle_t adc1_handle;
    adc_oneshot_unit_init_cfg_t init_config = {
        .unit_id = ADC_UNIT_1,
    };
    ESP_ERROR_CHECK(adc_oneshot_new_unit(&init_config, &adc1_handle));

    // 2. Konfigurasi Saluran ADC
    adc_oneshot_chan_cfg_t config = {
        .bitwidth = ADC_BITWIDTH_DEFAULT, // Default 12-bit (resolusi 0 - 4095)
        .atten = ADC_ATTEN_DB_12,         // Attenuasi 12dB agar bisa membaca voltase penuh hingga ~3.1V
    };
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc1_handle, water_channel, &config));

    ESP_LOGI(TAG, "Sistem Siap.");

    uint8_t red_blink_state = 0;

    while (1) {
        int adc_raw = 0;
        
        // 3. Baca nilai analog raw
        esp_err_t err = adc_oneshot_read(adc1_handle, water_channel, &adc_raw);
        
        if (err == ESP_OK) {
            // Konversi nilai raw ke perkiraan persentase konduktivitas/ketinggian air
            float percentage = (adc_raw / 4095.0) * 100.0;
            float voltage = (adc_raw / 4095.0) * 3.3;

            ESP_LOGI(TAG, "Raw ADC: %d | Tegangan: %.2f V | Tingkat Air: %.1f%%", 
                     adc_raw, voltage, percentage);

            // LOGIKA KONTROL LAMPU BERDASARKAN PERSENTASE AIR:
            if (percentage >= 90.0) {
                // Ketinggian >= 90% -> Merah berkedip cepat (Kuning & Hijau Mati)
                ryg_lamp_set_yellow(0);
                ryg_lamp_set_green(0);
                
                red_blink_state = !red_blink_state;
                ryg_lamp_set_red(red_blink_state);
                
                vTaskDelay(pdMS_TO_TICKS(150)); // Kedip cepat 150ms
                continue; // Skip delay 500ms di bawah agar kedipan stabil cepat
            } 
            else if (percentage >= 80.0 && percentage < 90.0) {
                // Ketinggian >= 80% (tapi < 90%) -> Merah menyala konstan
                ryg_lamp_set_red(1);
                ryg_lamp_set_yellow(0);
                ryg_lamp_set_green(0);
            } 
            else if (percentage >= 50.0 && percentage < 80.0) {
                // Ketinggian >= 50% (tapi < 80%) -> Kuning menyala konstan
                ryg_lamp_set_red(0);
                ryg_lamp_set_yellow(1);
                ryg_lamp_set_green(0);
            } 
            else {
                // Ketinggian < 50% -> Hijau menyala konstan (aman)
                ryg_lamp_set_red(0);
                ryg_lamp_set_yellow(0);
                ryg_lamp_set_green(1);
            }
        } else {
            ESP_LOGE(TAG, "Gagal membaca ADC!");
            // Indikator Error: nyalakan semua lampu
            ryg_lamp_set_red(1);
            ryg_lamp_set_yellow(1);
            ryg_lamp_set_green(1);
        }

        vTaskDelay(pdMS_TO_TICKS(500)); // Pembacaan normal setiap 500ms
    }

    // Pembersihan resource ADC
    ESP_ERROR_CHECK(adc_oneshot_del_unit(adc1_handle));
}
