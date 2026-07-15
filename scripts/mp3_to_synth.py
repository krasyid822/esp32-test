#!/usr/bin/env python3
import os
import sys
import json
import numpy as np

# Dictionary of standard piano key frequencies
NOTE_FREQS = {
    "C4": 262, "C#4": 277, "D4": 294, "D#4": 311, "E4": 330, "F4": 349,
    "F#4": 370, "G4": 392, "G#4": 415, "A4": 440, "A#4": 466, "B4": 494,
    "C5": 523, "C#5": 554, "D5": 587, "D#5": 622, "E5": 659, "F5": 698,
    "F#5": 740, "G5": 784, "G#5": 831, "A5": 880, "A#5": 932, "B5": 988
}

def get_closest_note_freq(freq):
    if freq < 100:  # Too low
        return 0
    closest_freq = 0
    min_diff = float('inf')
    for note, note_freq in NOTE_FREQS.items():
        diff = abs(freq - note_freq)
        if diff < min_diff:
            min_diff = diff
            closest_freq = note_freq
    # If the frequency is too far from any piano note, return 0 (rest)
    if min_diff > closest_freq * 0.06: # Allow ~1 semitone error tolerance
        return 0
    return closest_freq

def convert_audio_to_melody(file_path, frame_duration_ms=100):
    try:
        import librosa
    except ImportError:
        print("Error: Library 'librosa' tidak ditemukan.", file=sys.stderr)
        print("Silakan install dengan perintah: pip install librosa soundfile numpy scipy", file=sys.stderr)
        sys.exit(1)

    print(f"Membuka file audio: {file_path}...")
    # Load audio (downsampled to 16kHz for faster processing)
    y, sr = librosa.load(file_path, sr=16000, mono=True)
    
    # Calculate frame parameters
    hop_length = int(sr * (frame_duration_ms / 1000.0))
    
    print("Menganalisis pitch frekuensi dominan...")
    # Track pitch using YIN algorithm (excellent for monophonic pitch detection)
    f0 = librosa.yin(y=y, fmin=150, fmax=1000, sr=sr, hop_length=hop_length)
    
    # Track amplitude/energy to filter out silent parts (rests)
    rms = librosa.feature.rms(y=y, hop_length=hop_length)[0]
    rms_threshold = np.max(rms) * 0.15 # Filter out frames below 15% of max volume
    
    melody = []
    current_freq = 0
    current_duration = 0

    print("Mengonversi frekuensi ke nada piano...")
    for i in range(len(f0)):
        freq = f0[i]
        vol = rms[i]
        
        # Check if frame is silent
        if vol < rms_threshold or np.isnan(freq):
            note_freq = 0
        else:
            note_freq = get_closest_note_freq(freq)
            
        if i == 0:
            current_freq = note_freq
            current_duration = frame_duration_ms
        else:
            if note_freq == current_freq:
                current_duration += frame_duration_ms
            else:
                if current_freq > 0 or len(melody) > 0: # Avoid starting with rest
                    melody.append({
                        "freq": current_freq,
                        "duration": current_duration
                    })
                current_freq = note_freq
                current_duration = frame_duration_ms
                
    # Append the last note
    if current_freq > 0 or len(melody) > 0:
        melody.append({
            "freq": current_freq,
            "duration": current_duration
        })
        
    # Simplify melody (remove short noises < 150ms)
    clean_melody = []
    for note in melody:
        if note["duration"] >= 150 or note["freq"] > 0:
            clean_melody.append(note)
            
    return clean_melody

def main():
    if len(sys.argv) < 2:
        print("Penggunaan: python mp3_to_synth.py <input_audio_file> [output_json_file]")
        sys.exit(1)
        
    input_file = sys.argv[1]
    if len(sys.argv) >= 3:
        output_file = sys.argv[3]
    else:
        output_file = os.path.splitext(input_file)[0] + ".json"
        
    if not os.path.exists(input_file):
        print(f"Error: File '{input_file}' tidak ditemukan.")
        sys.exit(1)
        
    try:
        melody = convert_audio_to_melody(input_file)
        
        with open(output_file, 'w') as f:
            json.dump(melody, f, indent=2)
            
        print(f"\nSukses mengonversi! Hasil disimpan ke: {output_file}")
        print(f"Total nada dikonversi: {len(melody)}")
        print("\nContoh format data JSON:")
        print(json.dumps(melody[:5], indent=2))
        print("\nSalin isi file JSON tersebut ke dashboard Flutter untuk dimainkan.")
    except Exception as e:
        print(f"Terjadi kesalahan saat konversi: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
