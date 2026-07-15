#include "freertos/FreeRTOS.h" // IWYU pragma: keep
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_adc/adc_oneshot.h"
#include "ryg_lamp.h" // Mengimpor library lampu RYG

static const char *TAG = "MQ_Sensor";

// Kita gunakan pin D35 (GPIO 35) yang berada di deretan header atas
// GPIO 35 adalah ADC1 Saluran 7 (ADC1_CHANNEL_7)
#define MQ_GPIO_PIN   32

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

void mq_sensor_main(void)
{
    ESP_LOGI(TAG, "Memulai program deteksi kepekatan asap sensor MQ...");
    
    // Inisialisasi Lampu RYG
    ryg_lamp_init();

    // Konversi nomor PIN ke Saluran ADC
    adc_channel_t mq_channel = get_adc_channel(MQ_GPIO_PIN);

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
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc1_handle, mq_channel, &config));

    // Catatan: Sensor MQ memerlukan pre-heating (pemanasan) beberapa menit saat pertama dinyalakan 
    // agar pembacaannya akurat.
    ESP_LOGI(TAG, "Sistem MQ Siap. Silakan beri asap/gas untuk pengujian.");

    uint8_t red_blink_state = 0;

    // Definisikan ambang batas persentase kepekatan asap
    const float THRESHOLD_RISKY = 35.0;       // Beresiko -> Lampu Kuning
    const float THRESHOLD_DANGEROUS = 60.0;   // Berbahaya -> Lampu Merah
    const float THRESHOLD_THREATENING = 85.0; // Mengancam -> Lampu Merah Kedip

    while (1) {
        int adc_raw = 0;
        
        // 3. Baca nilai analog raw dari pin AO
        esp_err_t err = adc_oneshot_read(adc1_handle, mq_channel, &adc_raw);
        
        if (err == ESP_OK) {
            // Konversi nilai raw ke perkiraan persentase kepekatan gas/asap
            float percentage = (adc_raw / 4095.0) * 100.0;
            float voltage = (adc_raw / 4095.0) * 3.3;

            ESP_LOGI(TAG, "Raw ADC: %d | Tegangan: %.2f V | Kepekatan Asap: %.1f%%", 
                     adc_raw, voltage, percentage);

            // LOGIKA ASOSIASI LAMPU INDIKATOR:
            if (percentage >= THRESHOLD_THREATENING) {
                // MENGANCAM (>= 85%) -> Lampu Merah Berkedip Cepat (Kuning & Hijau Mati)
                ryg_lamp_set_yellow(0);
                ryg_lamp_set_green(0);
                
                red_blink_state = !red_blink_state;
                ryg_lamp_set_red(red_blink_state);
                
                vTaskDelay(pdMS_TO_TICKS(150)); // Jeda kedip cepat 150ms
                continue; // Skip delay 500ms di bawah agar kedipan cepat stabil
            } 
            else if (percentage >= THRESHOLD_DANGEROUS && percentage < THRESHOLD_THREATENING) {
                // BERBAHAYA (60% s.d 84.9%) -> Lampu Merah Menyala Konstan
                ryg_lamp_set_red(1);
                ryg_lamp_set_yellow(0);
                ryg_lamp_set_green(0);
            } 
            else if (percentage >= THRESHOLD_RISKY && percentage < THRESHOLD_DANGEROUS) {
                // BERESIKO (35% s.d 59.9%) -> Lampu Kuning Menyala Konstan
                ryg_lamp_set_red(0);
                ryg_lamp_set_yellow(1);
                ryg_lamp_set_green(0);
            } 
            else {
                // AMAN (< 35%) -> Lampu Hijau Menyala Konstan
                ryg_lamp_set_red(0);
                ryg_lamp_set_yellow(0);
                ryg_lamp_set_green(1);
            }
        } else {
            ESP_LOGE(TAG, "Gagal membaca ADC Sensor MQ!");
            // Semua lampu menyala sebagai indikator error
            ryg_lamp_set_red(1);
            ryg_lamp_set_yellow(1);
            ryg_lamp_set_green(1);
        }

        vTaskDelay(pdMS_TO_TICKS(500)); // Pembacaan normal setiap 500ms
    }

    // Pembersihan resource ADC
    ESP_ERROR_CHECK(adc_oneshot_del_unit(adc1_handle));
}
