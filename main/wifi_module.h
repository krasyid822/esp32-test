#ifndef WIFI_MODULE_H
#define WIFI_MODULE_H

/**
 * @brief Initialize ESP32 Wi-Fi in Access Point (SoftAP) mode.
 * 
 * Sets up SSID "ESP32_Dashboard_Net" and password "password123".
 * The default gateway/IP will be 192.168.4.1.
 */
void wifi_init_softap(void);

#endif // WIFI_MODULE_H
