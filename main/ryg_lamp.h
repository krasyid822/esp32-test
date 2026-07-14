#ifndef RYG_LAMP_H
#define RYG_LAMP_H

// Definisi PIN GPIO untuk Lampu RYG
#define RED_PIN     13
#define YELLOW_PIN  12
#define GREEN_PIN   14

// Fungsi inisialisasi pin lampu
void ryg_lamp_init(void);

// Fungsi mengontrol status lampu (1 = ON, 0 = OFF)
void ryg_lamp_set_red(int level);
void ryg_lamp_set_yellow(int level);
void ryg_lamp_set_green(int level);

// Mematikan semua lampu
void ryg_lamp_all_off(void);

#endif // RYG_LAMP_H
