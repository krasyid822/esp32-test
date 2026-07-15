#include "freertos/FreeRTOS.h" // IWYU pragma: keep
#include "freertos/task.h"
#include "driver/gpio.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "ryg_lamp.h" // Mengimpor library lampu RYG yang kita buat
#include "buzzer.h"   // Mengimpor library buzzer yang kita buat

static const char *TAG = "HC-SR04_Main";

// Konfigurasi PIN HC-SR04
#define TRIG_PIN    26
#define ECHO_PIN    27

// Threshold Jarak (dalam cm) (DIST thresholds are defined in buzzer.h)

static void init_sensor_gpio(void)
{
    // Konfigurasi Pin Sensor HC-SR04
    gpio_reset_pin(TRIG_PIN);
    gpio_reset_pin(ECHO_PIN);
    gpio_set_direction(TRIG_PIN, GPIO_MODE_OUTPUT);
    gpio_set_direction(ECHO_PIN, GPIO_MODE_INPUT);

    // Pastikan Trig berstatus LOW di awal
    gpio_set_level(TRIG_PIN, 0);

    ESP_LOGI(TAG, "Inisialisasi Sensor HC-SR04 Selesai.");
}

static float get_raw_distance_cm(void)
{
    // 1. Kirim trigger pulse 10 mikrodetik
    gpio_set_level(TRIG_PIN, 1);
    esp_rom_delay_us(10);
    gpio_set_level(TRIG_PIN, 0);

    // 2. Tunggu pin Echo menjadi HIGH
    int64_t start_time = esp_timer_get_time();
    int64_t timeout = start_time + 30000; // Timeout 30ms
    
    while (gpio_get_level(ECHO_PIN) == 0) {
        if (esp_timer_get_time() > timeout) {
            return -1.0;
        }
    }
    
    int64_t echo_start = esp_timer_get_time();

    // 3. Tunggu pin Echo kembali ke LOW
    timeout = echo_start + 30000;
    while (gpio_get_level(ECHO_PIN) == 1) {
        if (esp_timer_get_time() > timeout) {
            return -1.0;
        }
    }
    
    int64_t echo_end = esp_timer_get_time();
    int64_t duration = echo_end - echo_start;

    // Hitung jarak dalam cm
    float distance = (duration * 0.0343) / 2.0;
    return distance;
}

// Fungsi pencarian nilai tengah (Median Filter)
static float median_of_three(float a, float b, float c)
{
    if ((a <= b && b <= c) || (c <= b && b <= a)) return b;
    if ((b <= a && a <= c) || (c <= a && a <= b)) return a;
    return c;
}

// Fungsi publik yang dipanggil oleh main dan buzzer.c
float get_distance_cm(void)
{
    static float r1 = 300.0, r2 = 300.0, r3 = 300.0;
    static int error_count = 0;
    
    float raw = get_raw_distance_cm();
    if (raw < 0) {
        // Jika pembacaan error, tetap kembalikan nilai median sebelumnya agar tidak langsung berkedip error
        // kecuali jika error terjadi terus-menerus.
        error_count++;
        if (error_count > 3) {
            return -1.0; // Jika error lebih dari 3x berturut-turut, baru nyatakan error
        }
        raw = r1; // Gunakan data terakhir
    } else {
        error_count = 0; // Reset counter error
    }

    // Geser riwayat data
    r3 = r2;
    r2 = r1;
    r1 = raw;

    // Kembalikan nilai median (filter noise)
    return median_of_three(r1, r2, r3);
}

void hc_sr04_sensor_main(void)
{
    // Inisialisasi lampu (dari ryg_lamp.c)
    ryg_lamp_init();
    
    // Inisialisasi sensor
    init_sensor_gpio();

    // Inisialisasi buzzer
    buzzer_init();

    uint8_t red_blink_state = 0;

    while (1) {
        float distance = get_distance_cm();

        if (distance < 0) {
            ESP_LOGW(TAG, "Sensor HC-SR04 Error.");
            // Nyalakan semua lampu sebagai indikator error
            ryg_lamp_set_red(1);
            ryg_lamp_set_yellow(1);
            ryg_lamp_set_green(1);
            vTaskDelay(pdMS_TO_TICKS(1000));
            continue;
        }

        ESP_LOGI(TAG, "Jarak: %.2f cm", distance);

        if (distance < DIST_TOUCH) {
            // Kasus 1: Menempel -> Merah berkedip cepat + Buzzer bip cepat
            ryg_lamp_set_yellow(0);
            ryg_lamp_set_green(0);
            
            red_blink_state = !red_blink_state;
            ryg_lamp_set_red(red_blink_state);
            
            if (red_blink_state) {
                // Bunyikan buzzer berfrekuensi tinggi selama 150ms searah kedipan merah
                buzzer_beep(1000, 150); 
            } else {
                // Jeda mati 150ms
                vTaskDelay(pdMS_TO_TICKS(150));
            }
        } 
        else if (distance >= DIST_TOUCH && distance < DIST_CLOSE) {
            // Kasus 2: Dekat -> Merah ON + Mainkan Melodi Nada (Do Re Mi Fa Sol...)
            ryg_lamp_set_red(1);
            ryg_lamp_set_yellow(0);
            ryg_lamp_set_green(0);
            
            buzzer_play_melody();
            
            // Jeda panjang 2 detik sebelum perulangan pendeteksian, tapi bisa di-interrupt jika jarak berubah
            for (int i = 0; i < 20; i++) {
                float current_dist = get_distance_cm();
                if (current_dist < DIST_TOUCH || current_dist >= DIST_CLOSE) {
                    break;
                }
                vTaskDelay(pdMS_TO_TICKS(100));
            }
        } 
        else if (distance >= DIST_CLOSE && distance < DIST_MEDIUM) {
            // Kasus 3: Sedang -> Kuning ON + Mainkan Nada Getar Ehem
            ryg_lamp_set_red(0);
            ryg_lamp_set_yellow(1);
            ryg_lamp_set_green(0);
            
            buzzer_play_ehem();
            
            // Jeda 3 detik sebelum mengulang pembacaan, tapi bisa di-interrupt jika jarak berubah
            for (int i = 0; i < 30; i++) {
                float current_dist = get_distance_cm();
                if (current_dist < DIST_CLOSE || current_dist >= DIST_MEDIUM) {
                    break;
                }
                vTaskDelay(pdMS_TO_TICKS(100));
            }
        } 
        else {
            // Kasus 4: Jauh -> Hijau ON
            ryg_lamp_set_red(0);
            ryg_lamp_set_yellow(0);
            ryg_lamp_set_green(1);
            vTaskDelay(pdMS_TO_TICKS(300));
        }
    }
}
