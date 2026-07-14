#include "buzzer.h"
#include "driver/gpio.h"
#include "freertos/FreeRTOS.h" // IWYU pragma: keep
#include "freertos/task.h"
#include "esp_log.h"

// Deklarasi fungsi pembacaan jarak dari hc_sr04_sensor.c
extern float get_distance_cm(void);

static const char *TAG = "Buzzer_Melody";

// Cek apakah kondisi jarak sudah berpindah dari wilayah lampu merah konstan (4cm s.d 15cm)
static bool should_interrupt(void)
{
    float dist = get_distance_cm();
    // Jika sensor error (dist < 0) atau jarak di luar wilayah merah konstan, segera interrupt
    if (dist < 4.0 || dist >= 15.0) {
        return true;
    }
    return false;
}

// Fungsi delay yang dapat di-interrupt di tengah jalan
static bool interruptible_delay(int ms)
{
    int steps = ms / 10; // Membagi delay menjadi langkah-langkah kecil 10ms
    for (int i = 0; i < steps; i++) {
        if (should_interrupt()) {
            return true; // Perlu di-interrupt
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    // Jika ada sisa pembagian
    int sisa = ms % 10;
    if (sisa > 0) {
        if (should_interrupt()) return true;
        vTaskDelay(pdMS_TO_TICKS(sisa));
    }
    return false;
}

// Fungsi beep yang dapat di-interrupt sebelum berbunyi
static bool interruptible_beep(int frekuensi, int durasi_ms)
{
    if (should_interrupt()) {
        return true;
    }
    
    if (frekuensi <= 0) {
        return interruptible_delay(durasi_ms);
    }
    
    int periode = 1000000 / frekuensi; // dalam mikrodetik
    int siklus = (durasi_ms * 1000) / periode;
    
    // Untuk nada yang berbunyi, kita periksa interupsi sebelum mulai
    for (int i = 0; i < siklus; i++) {
        // Cek interupsi berkala setiap 50 siklus agar tidak terlalu membebani sensor
        if (i % 50 == 0) {
            if (should_interrupt()) {
                gpio_set_level(BUZZER_PIN, 0); // Matikan buzzer
                return true;
            }
        }
        gpio_set_level(BUZZER_PIN, 1);
        esp_rom_delay_us(periode / 2);
        gpio_set_level(BUZZER_PIN, 0);
        esp_rom_delay_us(periode / 2);
    }
    return false;
}

void buzzer_init(void)
{
    gpio_reset_pin(BUZZER_PIN);
    gpio_set_direction(BUZZER_PIN, GPIO_MODE_OUTPUT);
    gpio_set_level(BUZZER_PIN, 0);
}

void buzzer_beep(int frekuensi, int durasi_ms)
{
    if (frekuensi <= 0) {
        vTaskDelay(pdMS_TO_TICKS(durasi_ms));
        return;
    }
    int periode = 1000000 / frekuensi; // dalam mikrodetik
    int siklus = (durasi_ms * 1000) / periode;
    
    for (int i = 0; i < siklus; i++) {
        gpio_set_level(BUZZER_PIN, 1);
        esp_rom_delay_us(periode / 2);
        gpio_set_level(BUZZER_PIN, 0);
        esp_rom_delay_us(periode / 2);
    }
}

void buzzer_play_melody(void)
{
    ESP_LOGI(TAG, "Mulai memainkan melodi lampu merah...");

    // Struktur nada & durasi: {Frekuensi, Durasi, Jeda Setelahnya}
    int melody[][3] = {
        // BAGIAN 1: Nada naik
        {262, 300, 100}, {294, 300, 100}, {330, 300, 100}, {349, 300, 100}, {392, 500, 100},
        // BAGIAN 2: Turun
        {392, 300, 100}, {349, 300, 100}, {330, 300, 100}, {294, 300, 100}, {262, 500, 100},
        // BAGIAN 3: Nada tinggi
        {523, 300, 100}, {494, 300, 100}, {440, 300, 100}, {392, 500, 100},
        // BAGIAN 4: Nada kembali
        {392, 300, 100}, {440, 300, 100}, {494, 300, 100}, {523, 500, 100}
    };
    
    int num_notes = sizeof(melody) / sizeof(melody[0]);

    for (int i = 0; i < num_notes; i++) {
        // Bunyikan nada
        if (interruptible_beep(melody[i][0], melody[i][1])) {
            ESP_LOGI(TAG, "Melodi di-interrupt karena objek menjauh/terlalu dekat.");
            return;
        }
        // Jeda setelah nada
        if (interruptible_delay(melody[i][2])) {
            ESP_LOGI(TAG, "Melodi di-interrupt saat jeda nada.");
            return;
        }
    }
}

// Cek apakah kondisi jarak sudah berpindah dari wilayah lampu kuning (15cm s.d 30cm)
static bool should_interrupt_yellow(void)
{
    float dist = get_distance_cm();
    if (dist < 15.0 || dist >= 30.0) {
        return true;
    }
    return false;
}

// Fungsi beep kuning yang dapat di-interrupt
static bool interruptible_beep_yellow(int frekuensi, int durasi_ms)
{
    if (should_interrupt_yellow()) {
        return true;
    }
    
    int periode = 1000000 / frekuensi; // dalam mikrodetik
    int siklus = (durasi_ms * 1000) / periode;
    
    for (int i = 0; i < siklus; i++) {
        // Cek interupsi setiap 50 siklus
        if (i % 50 == 0) {
            if (should_interrupt_yellow()) {
                gpio_set_level(BUZZER_PIN, 0); // Matikan buzzer
                return true;
            }
        }
        gpio_set_level(BUZZER_PIN, 1);
        esp_rom_delay_us(periode / 2);
        gpio_set_level(BUZZER_PIN, 0);
        esp_rom_delay_us(periode / 2);
    }
    return false;
}

void buzzer_play_ehem(void)
{
    ESP_LOGI(TAG, "Memainkan melodi kuning (ehem)...");

    // 1. Putar cepat bergantian 2 frekuensi (efek "bergetar")
    for (int i = 0; i < 80; i++) {
        if (interruptible_beep_yellow(180, 5)) return;
        if (interruptible_beep_yellow(280, 5)) return;
    }
    
    // 2. Penutupan: turun perlahan
    for (int i = 0; i < 30; i++) {
        if (interruptible_beep_yellow(200, 8)) return;
        if (interruptible_beep_yellow(150, 8)) return;
    }
    
    // 3. Jeda akhir 30ms
    int steps = 30 / 10;
    for (int i = 0; i < steps; i++) {
        if (should_interrupt_yellow()) return;
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}
