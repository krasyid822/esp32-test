#ifndef BUZZER_H
#define BUZZER_H

#define BUZZER_PIN 25 // Pin D8 S pada carrier board

// Inisialisasi pin buzzer
void buzzer_init(void);

// Bunyi dengan frekuensi dan durasi tertentu (dalam milidetik)
void buzzer_beep(int frekuensi, int durasi_ms);

// Memainkan melodi lampu merah konstan (Do Re Mi Fa Sol...)
void buzzer_play_melody(void);

// Memainkan nada ehem untuk lampu kuning
void buzzer_play_ehem(void);

#endif // BUZZER_H
