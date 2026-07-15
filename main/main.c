#include "freertos/FreeRTOS.h" // IWYU pragma: keep
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "driver/gpio.h"
#include "esp_adc/adc_oneshot.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "esp_netif.h"
#include "esp_event.h"
#include "esp_http_server.h"
#include "wifi_module.h"
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

// Thresholds (DIST thresholds are defined dynamically via NVS calibration)
#define CLASS_CLOSED         0
#define CLASS_SLIGHTLY_OPEN  1
#define CLASS_WIDE_OPEN      2
#define CLASS_OBJECT_ENTER   3

static float g_calib_points[4] = {5.0f, 12.0f, 25.0f, 35.0f}; // Default calibration in cm
static const char *g_class_names[4] = {
    "Pintu Tertutup",
    "Pintu Terbuka Sedikit",
    "Pintu Terbuka Lebar",
    "Ada Objek Masuk"
};

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

// Manual Buzzer State
static volatile bool g_manual_buzzer_active = false;
static volatile int g_manual_buzzer_frequency = 2000;

// WebSocket HTTP Server Handle
static httpd_handle_t server = NULL;

static void load_calibration_data(void);
static void save_calibration_point(int class_id, float value_cm);
static int classify_distance(float dist);

static void send_sensor_data_to_all(const char *json_str)
{
    if (server == NULL) return;
    
    size_t clients = 7;
    int client_fds[7] = {0};
    if (httpd_get_client_list(server, &clients, client_fds) == ESP_OK) {
        for (size_t i = 0; i < clients; i++) {
            int fd = client_fds[i];
            if (httpd_ws_get_fd_info(server, fd) == HTTPD_WS_CLIENT_WEBSOCKET) {
                httpd_ws_frame_t ws_pkt = {
                    .payload = (uint8_t*)json_str,
                    .len = strlen(json_str),
                    .type = HTTPD_WS_TYPE_TEXT
                };
                esp_err_t ret = httpd_ws_send_frame_async(server, fd, &ws_pkt);
                if (ret != ESP_OK) {
                    ESP_LOGW(TAG, "WS send failed on fd %d (ret: %d). Triggering close...", fd, ret);
                    httpd_sess_trigger_close(server, fd);
                }
            }
        }
    }
}

static esp_err_t ws_handler(httpd_req_t *req)
{
    if (req->method == HTTP_GET) {
        ESP_LOGI(TAG, "WebSocket connection opened!");
        return ESP_OK;
    }
    
    httpd_ws_frame_t ws_pkt;
    uint8_t *buf = NULL;
    memset(&ws_pkt, 0, sizeof(httpd_ws_frame_t));
    ws_pkt.type = HTTPD_WS_TYPE_TEXT;
    
    esp_err_t ret = httpd_ws_recv_frame(req, &ws_pkt, 0);
    if (ret != ESP_OK) {
        return ret;
    }
    
    if (ws_pkt.len) {
        buf = calloc(1, ws_pkt.len + 1);
        if (buf == NULL) {
            return ESP_ERR_NO_MEM;
        }
        ws_pkt.payload = buf;
        ret = httpd_ws_recv_frame(req, &ws_pkt, ws_pkt.len);
        if (ret != ESP_OK) {
            free(buf);
            return ret;
        }
        ESP_LOGI(TAG, "Received WS packet: %s", ws_pkt.payload);
        if (strstr((char*)ws_pkt.payload, "start_buzzer") != NULL) {
            ESP_LOGI(TAG, "Manual buzzer start!");
            g_manual_buzzer_frequency = 2000;
            g_manual_buzzer_active = true;
        } else if (strstr((char*)ws_pkt.payload, "stop_buzzer") != NULL || strstr((char*)ws_pkt.payload, "stop_note") != NULL) {
            ESP_LOGI(TAG, "Manual buzzer stop!");
            g_manual_buzzer_active = false;
            gpio_set_level(BUZZER_PIN, 0); // Matikan buzzer
        } else if (strstr((char*)ws_pkt.payload, "play_note:") != NULL) {
            int freq = 2000;
            if (sscanf((char*)ws_pkt.payload, "play_note:%d", &freq) == 1) {
                ESP_LOGI(TAG, "Play note frequency: %d Hz", freq);
                g_manual_buzzer_frequency = freq;
                g_manual_buzzer_active = true;
            }
        } else if (strstr((char*)ws_pkt.payload, "train_class:") != NULL) {
            int class_id = -1;
            if (sscanf((char*)ws_pkt.payload, "train_class:%d", &class_id) == 1) {
                if (class_id >= 0 && class_id <= 3) {
                    float current_dist = g_distance;
                    if (current_dist >= 0) {
                        save_calibration_point(class_id, current_dist);
                        ESP_LOGI(TAG, "Class %d successfully calibrated to %.1f cm", class_id, current_dist);
                        
                        char feedback[128];
                        snprintf(feedback, sizeof(feedback), "{\"event\":\"calibrated\",\"class\":%d,\"value\":%.1f}", class_id, current_dist);
                        send_sensor_data_to_all(feedback);
                    } else {
                        ESP_LOGW(TAG, "Calibration failed: sensor reading invalid (%.1f)", current_dist);
                    }
                }
            }
        }
        free(buf);
    }
    return ESP_OK;
}

static const httpd_uri_t ws_uri = {
    .uri        = "/ws",
    .method     = HTTP_GET,
    .handler    = ws_handler,
    .user_ctx   = NULL,
    .is_websocket = true
};

static void start_webserver(void)
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.lru_purge_enable = true;
    
    ESP_LOGI(TAG, "Starting WebSocket Server on port %d...", config.server_port);
    if (httpd_start(&server, &config) == ESP_OK) {
        httpd_register_uri_handler(server, &ws_uri);
        ESP_LOGI(TAG, "WebSocket Server started successfully.");
    } else {
        ESP_LOGE(TAG, "Failed to start WebSocket Server!");
    }
}

#define ABS_DIFF(a, b) ((a) > (b) ? ((a) - (b)) : ((b) - (a)))

static void load_calibration_data(void)
{
    nvs_handle_t my_handle;
    esp_err_t err = nvs_open("calib", NVS_READWRITE, &my_handle);
    if (err == ESP_OK) {
        int32_t val;
        if (nvs_get_i32(my_handle, "c_closed", &val) == ESP_OK) g_calib_points[0] = val / 10.0f;
        if (nvs_get_i32(my_handle, "c_sopen", &val) == ESP_OK) g_calib_points[1] = val / 10.0f;
        if (nvs_get_i32(my_handle, "c_wopen", &val) == ESP_OK) g_calib_points[2] = val / 10.0f;
        if (nvs_get_i32(my_handle, "c_obj", &val) == ESP_OK) g_calib_points[3] = val / 10.0f;
        nvs_close(my_handle);
        ESP_LOGI(TAG, "Calibration loaded: Closed=%.1f, S_Open=%.1f, W_Open=%.1f, Object=%.1f",
                 g_calib_points[0], g_calib_points[1], g_calib_points[2], g_calib_points[3]);
    } else {
        ESP_LOGW(TAG, "NVS open failed for calibration, using defaults");
    }
}

static void save_calibration_point(int class_id, float value_cm)
{
    if (class_id < 0 || class_id > 3) return;
    g_calib_points[class_id] = value_cm;
    
    nvs_handle_t my_handle;
    esp_err_t err = nvs_open("calib", NVS_READWRITE, &my_handle);
    if (err == ESP_OK) {
        int32_t val = (int32_t)(value_cm * 10.0f);
        const char *keys[4] = {"c_closed", "c_sopen", "c_wopen", "c_obj"};
        nvs_set_i32(my_handle, keys[class_id], val);
        nvs_commit(my_handle);
        nvs_close(my_handle);
        ESP_LOGI(TAG, "Saved class %d (val=%.1f cm) to NVS", class_id, value_cm);
    } else {
        ESP_LOGE(TAG, "Failed to save calibration to NVS");
    }
}

static int classify_distance(float dist)
{
    if (dist < 0.0f) return -1; // Sensor error
    
    int closest_class = 0;
    float min_diff = ABS_DIFF(dist, g_calib_points[0]);
    
    for (int i = 1; i < 4; i++) {
        float diff = ABS_DIFF(dist, g_calib_points[i]);
        if (diff < min_diff) {
            min_diff = diff;
            closest_class = i;
        }
    }
    return closest_class;
}

int get_classified_distance_class(void)
{
    return classify_distance(g_distance);
}

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

// Fungsi eksternal yang di-query oleh buzzer.c untuk pengecekan interupsi secara cepat (non-blocking)
float get_distance_cm(void)
{
    return g_distance;
}

// Fungsi internal untuk membaca hardware sensor secara riil
static float read_sensor_distance_hardware(void)
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
        g_distance = read_sensor_distance_hardware();
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

// Task untuk generator nada manual buzzer
static void manual_buzzer_task(void *pvParameters)
{
    while (1) {
        if (g_manual_buzzer_active) {
            int freq = g_manual_buzzer_frequency;
            if (freq > 0) {
                int periode_us = 1000000 / freq;
                gpio_set_level(BUZZER_PIN, 1);
                esp_rom_delay_us(periode_us / 2);
                gpio_set_level(BUZZER_PIN, 0);
                esp_rom_delay_us(periode_us / 2);
            } else {
                vTaskDelay(pdMS_TO_TICKS(1));
            }
        } else {
            vTaskDelay(pdMS_TO_TICKS(20));
        }
    }
}

// Task Utama Koordinasi Lampu RYG & Buzzer
static void coordination_task(void *pvParameters)
{
    ryg_lamp_init();
    buzzer_init();

    uint8_t blink_state = 0;

    while (1) {
        if (g_manual_buzzer_active) {
            vTaskDelay(pdMS_TO_TICKS(50));
            continue;
        }
        float dist = g_distance;
        float water = g_water_percentage;
        float smoke = g_mq_percentage;
        int dist_class = classify_distance(dist);

        ESP_LOGI(TAG, "STATUS -> Jarak: %.1f cm (Class: %d, %s) | Air: %.1f%% | Asap: %.1f%%",
                 dist, dist_class, 
                 (dist_class >= 0 && dist_class <= 3) ? g_class_names[dist_class] : "Error",
                 water, smoke);

        char json_buf[256];
        snprintf(json_buf, sizeof(json_buf), 
                 "{\"distance\":%.1f,\"water\":%.1f,\"smoke\":%.1f,\"class_id\":%d,\"class_name\":\"%s\","
                 "\"thresholds\":[%.1f,%.1f,%.1f,%.1f]}",
                 dist, water, smoke, dist_class, 
                 (dist_class >= 0 && dist_class <= 3) ? g_class_names[dist_class] : "Error",
                 g_calib_points[0], g_calib_points[1], g_calib_points[2], g_calib_points[3]);
        send_sensor_data_to_all(json_buf);

        // KONDISI 1: SANGAT BAHAYA / EMERGENCY (Merah Berkedip + Buzzer Bip Cepat)
        // (Ada Objek Masuk ATAU Air >= 90% ATAU Asap >= 85%)
        if (dist_class == CLASS_OBJECT_ENTER || water >= WATER_TOUCH || smoke >= MQ_TOUCH) {
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
        // (Pintu Terbuka Lebar ATAU Air 80%-90% ATAU Asap 60%-85%)
        else if (dist_class == CLASS_WIDE_OPEN || 
                 (water >= WATER_CLOSE && water < WATER_TOUCH) ||
                 (smoke >= MQ_CLOSE && smoke < MQ_TOUCH)) {
            ryg_lamp_set_red(1);
            ryg_lamp_set_yellow(0);
            ryg_lamp_set_green(0);

            buzzer_play_melody();

            // Jeda responsif pasca-melodi
            for (int i = 0; i < 20; i++) {
                if (classify_distance(g_distance) != CLASS_WIDE_OPEN || 
                    g_water_percentage < WATER_CLOSE || g_water_percentage >= WATER_TOUCH ||
                    g_mq_percentage < MQ_CLOSE || g_mq_percentage >= MQ_TOUCH) {
                    break;
                }
                vTaskDelay(pdMS_TO_TICKS(100));
            }
        }
        // KONDISI 3: SIAGA (Kuning ON + Melodi Ehem)
        // (Pintu Terbuka Sedikit ATAU Air 50%-80% ATAU Asap 35%-60%)
        else if (dist_class == CLASS_SLIGHTLY_OPEN || 
                 (water >= WATER_MEDIUM && water < WATER_CLOSE) ||
                 (smoke >= MQ_MEDIUM && smoke < MQ_CLOSE)) {
            ryg_lamp_set_red(0);
            ryg_lamp_set_yellow(1);
            ryg_lamp_set_green(0);

            buzzer_play_ehem();

            // Jeda responsif pasca-ehem
            for (int i = 0; i < 30; i++) {
                if (classify_distance(g_distance) != CLASS_SLIGHTLY_OPEN || 
                    g_water_percentage < WATER_MEDIUM || g_water_percentage >= WATER_CLOSE ||
                    g_mq_percentage < MQ_MEDIUM || g_mq_percentage >= MQ_CLOSE) {
                    break;
                }
                vTaskDelay(pdMS_TO_TICKS(100));
            }
        }
        // KONDISI 4: AMAN (Hijau ON + Semua Diam) (Pintu Tertutup / Kelas Lain)
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

    // Initialize NVS
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    // Load dynamic classification calibration points from NVS
    load_calibration_data();

    // Initialize TCP/IP and Event Loop
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    // Initialize Wi-Fi Access Point
    wifi_init_softap();

    // Start WebSocket Web Server
    start_webserver();

    // Inisialisasi unit ADC1 secara global
    adc_oneshot_unit_init_cfg_t init_config = {
        .unit_id = ADC_UNIT_1,
    };
    ESP_ERROR_CHECK(adc_oneshot_new_unit(&init_config, &g_adc1_handle));

    // Membuat FreeRTOS tasks agar semua sensor berjalan paralel
    xTaskCreate(distance_task, "distance_task", 4096, NULL, 5, NULL);
    xTaskCreate(adc_sensors_task, "adc_sensors_task", 4096, NULL, 5, NULL);
    xTaskCreate(coordination_task, "coordination_task", 4096, NULL, 4, NULL);
    xTaskCreate(manual_buzzer_task, "manual_buzzer_task", 2048, NULL, 5, NULL);
}
