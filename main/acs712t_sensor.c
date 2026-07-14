#include <stdlib.h>
#include "freertos/FreeRTOS.h" // IWYU pragma: keep
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_adc/adc_oneshot.h"
#include "ryg_lamp.h" // Mengimpor library lampu RYG

static const char *TAG = "ACS712_Sensor";

// Kita gunakan pin D35 (GPIO 35) yang berada di deretan header atas
// GPIO 35 adalah ADC1 Saluran 7 (ADC1_CHANNEL_7)
#define ACS712_GPIO_PIN   32

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
            ESP_LOGE(TAG, "GPIO %d tidak mendukung ADC1! Menggunakan D35 secara default.", gpio_num);
            return ADC_CHANNEL_7;
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "Memulai program sensor arus ACS712...");
    
    // Inisialisasi Lampu RYG
    ryg_lamp_init();

    // Konversi nomor PIN ke Saluran ADC
    adc_channel_t acs_channel = get_adc_channel(ACS712_GPIO_PIN);

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
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc1_handle, acs_channel, &config));

    // 3. Kalibrasi Nilai Tengah (Zero Current Offset) saat startup (asumsi tanpa beban saat dinyalakan)
    ESP_LOGI(TAG, "Melakukan kalibrasi nilai tengah... Pastikan tidak ada beban aktif.");
    int sum = 0;
    const int calibration_samples = 100;
    for (int i = 0; i < calibration_samples; i++) {
        int val = 0;
        adc_oneshot_read(adc1_handle, acs_channel, &val);
        sum += val;
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    int zero_current_offset = sum / calibration_samples;
    ESP_LOGI(TAG, "Kalibrasi Selesai. Nilai Raw Tengah (0 Ampere) = %d", zero_current_offset);

    uint8_t red_blink_state = 0;

    // Batas toleransi noise (selisih nilai raw dari nilai tengah)
    // Jika selisih > NOISE_THRESHOLD, maka dianggap ada beban arus mengalir
    const int NOISE_THRESHOLD = 40; 

    while (1) {
        // Ambil sampel pembacaan arus (kita hitung simpangan rata-ratanya)
        int max_deviation = 0;
        const int samples = 50;

        for (int i = 0; i < samples; i++) {
            int raw_val = 0;
            adc_oneshot_read(adc1_handle, acs_channel, &raw_val);
            
            // Hitung simpangan absolut terhadap titik nol
            int deviation = abs(raw_val - zero_current_offset);
            if (deviation > max_deviation) {
                max_deviation = deviation;
            }
            esp_rom_delay_us(200); // Sampling cepat
        }

        ESP_LOGI(TAG, "Simpangan Arus (Max Deviation): %d", max_deviation);

        if (max_deviation > NOISE_THRESHOLD) {
            // ADA BEBAN -> Lampu Merah Berkedip Cepat (Kuning & Hijau Mati)
            ESP_LOGW(TAG, "Terdeteksi beban aktif!");
            ryg_lamp_set_yellow(0);
            ryg_lamp_set_green(0);

            red_blink_state = !red_blink_state;
            ryg_lamp_set_red(red_blink_state);

            vTaskDelay(pdMS_TO_TICKS(150)); // Kedip cepat 150ms
        } else {
            // TIDAK ADA BEBAN -> Hijau menyala konstan (Merah & Kuning Mati)
            ryg_lamp_set_red(0);
            ryg_lamp_set_yellow(0);
            ryg_lamp_set_green(1);

            vTaskDelay(pdMS_TO_TICKS(500)); // Pembacaan setiap 500ms
        }
    }

    // Pembersihan resource ADC
    ESP_ERROR_CHECK(adc_oneshot_del_unit(adc1_handle));
}
