import 'dart:typed_data';

class MidiParser {
  static List<Map<String, int>> parseMidi(Uint8List bytes) {
    if (bytes.length < 14) throw Exception('File MIDI terlalu pendek.');

    // Read header magic: "MThd"
    if (bytes[0] != 0x4D || bytes[1] != 0x54 || bytes[2] != 0x68 || bytes[3] != 0x64) {
      throw Exception('Format MIDI tidak valid (MThd header tidak ditemukan).');
    }

    // Read Division (ticks per quarter note)
    final int division = (bytes[12] << 8) | bytes[13];
    if (division & 0x8000 != 0) {
      throw Exception('Time division SMPTE tidak didukung.');
    }

    final List<Map<String, int>> melody = [];
    int offset = 14;

    // Default Tempo: 120 BPM (500,000 microseconds per quarter note)
    int tempoUs = 500000;

    // Helper to calculate milliseconds from ticks
    double ticksToMs(int ticks) {
      return (ticks * tempoUs) / (division * 1000.0);
    }

    // Map of MIDI note number -> note starting time (in ticks)
    final Map<int, int> activeNotes = {};
    
    // List of parsed note events
    final List<_MidiNoteEvent> parsedEvents = [];

    // Parse tracks
    while (offset < bytes.length - 8) {
      // Find "MTrk" chunk
      if (bytes[offset] == 0x4D && bytes[offset + 1] == 0x54 && bytes[offset + 2] == 0x72 && bytes[offset + 3] == 0x6B) {
        final int trackLen = (bytes[offset + 4] << 24) | (bytes[offset + 5] << 16) | (bytes[offset + 6] << 8) | bytes[offset + 7];
        offset += 8;
        final int trackEnd = offset + trackLen;

        int absoluteTicks = 0;
        int runningStatus = 0;

        while (offset < trackEnd && offset < bytes.length) {
          // Parse delta time (VLQ - Variable Length Quantity)
          int delta = 0;
          while (true) {
            final int b = bytes[offset++];
            delta = (delta << 7) | (b & 0x7F);
            if (b & 0x80 == 0) break;
          }
          absoluteTicks += delta;

          // Parse event status
          int status = bytes[offset];
          if (status & 0x80 != 0) {
            runningStatus = status;
            offset++;
          } else {
            status = runningStatus;
          }

          final int eventType = status & 0xF0;

          if (eventType == 0x90) {
            // Note On
            final int note = bytes[offset++];
            final int velocity = bytes[offset++];
            if (velocity > 0) {
              activeNotes[note] = absoluteTicks;
            } else {
              // Velocity 0 is Note Off
              if (activeNotes.containsKey(note)) {
                final int startTicks = activeNotes.remove(note)!;
                parsedEvents.add(_MidiNoteEvent(
                  note: note,
                  startTimeMs: ticksToMs(startTicks).round(),
                  endTimeMs: ticksToMs(absoluteTicks).round(),
                ));
              }
            }
          } else if (eventType == 0x80) {
            // Note Off
            final int note = bytes[offset++];
            bytes[offset++]; // Skip velocity
            if (activeNotes.containsKey(note)) {
              final int startTicks = activeNotes.remove(note)!;
              parsedEvents.add(_MidiNoteEvent(
                note: note,
                startTimeMs: ticksToMs(startTicks).round(),
                endTimeMs: ticksToMs(absoluteTicks).round(),
              ));
            }
          } else if (eventType == 0xA0 || eventType == 0xB0 || eventType == 0xE0) {
            // Skip 2-byte controller / channel events
            offset += 2;
          } else if (eventType == 0xC0 || eventType == 0xD0) {
            // Skip 1-byte events
            offset += 1;
          } else if (status == 0xFF) {
            // Meta Event
            final int type = bytes[offset++];
            int len = 0;
            while (true) {
              final int b = bytes[offset++];
              len = (len << 7) | (b & 0x7F);
              if (b & 0x80 == 0) break;
            }

            if (type == 0x51 && len == 3) {
              // Tempo change (microseconds per quarter note)
              tempoUs = (bytes[offset] << 16) | (bytes[offset + 1] << 8) | bytes[offset + 2];
            }
            offset += len;
          } else if (status == 0xF0 || status == 0xF7) {
            // Sysex event
            int len = 0;
            while (true) {
              final int b = bytes[offset++];
              len = (len << 7) | (b & 0x7F);
              if (b & 0x80 == 0) break;
            }
            offset += len;
          }
        }
      } else {
        // Skip unknown chunks
        final int chunkLen = (bytes[offset + 4] << 24) | (bytes[offset + 5] << 16) | (bytes[offset + 6] << 8) | bytes[offset + 7];
        offset += 8 + chunkLen;
      }
    }

    if (parsedEvents.isEmpty) {
      throw Exception('Tidak ada nada yang didukung di file MIDI.');
    }

    // Sort notes chronologically
    parsedEvents.sort((a, b) => a.startTimeMs.compareTo(b.startTimeMs));

    // Compile melody with pauses/rests
    int currentTimeMs = 0;
    for (var event in parsedEvents) {
      final int freq = _midiNoteToFreq(event.note);
      if (freq == 0) continue; // Skip notes outside ESP32 buzzer piano range

      if (event.startTimeMs > currentTimeMs) {
        final int restDuration = event.startTimeMs - currentTimeMs;
        if (restDuration >= 20) {
          melody.add({"freq": 0, "duration": restDuration});
        }
      }

      final int duration = event.endTimeMs - event.startTimeMs;
      if (duration >= 20) {
        melody.add({"freq": freq, "duration": duration});
        currentTimeMs = event.endTimeMs;
      }
    }

    return melody;
  }

  static int _midiNoteToFreq(int midiNote) {
    // Match standard MIDI notes to our buzzer keyboard note mappings (C4-B5)
    final Map<int, int> midiToBuzzerFreq = {
      60: 262, // C4
      61: 277, // C#4
      62: 294, // D4
      63: 311, // D#4
      64: 330, // E4
      65: 349, // F4
      66: 370, // F#4
      67: 392, // G4
      68: 415, // G#4
      69: 440, // A4
      70: 466, // A#4
      71: 494, // B4
      72: 523, // C5
      73: 554, // C#5
      74: 587, // D5
      75: 622, // D#5
      76: 659, // E5
      77: 698, // F5
      78: 740, // F#5
      79: 784, // G5
      80: 831, // G#5
      81: 880, // A5
      82: 932, // A#5
      83: 988, // B5
    };
    return midiToBuzzerFreq[midiNote] ?? 0;
  }
}

class _MidiNoteEvent {
  final int note;
  final int startTimeMs;
  final int endTimeMs;
  _MidiNoteEvent({required this.note, required this.startTimeMs, required this.endTimeMs});
}
