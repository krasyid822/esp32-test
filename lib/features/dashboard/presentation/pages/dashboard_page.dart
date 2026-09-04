import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../../../core/constants/colors.dart';
import '../change_notifier/dashboard_notifier.dart';
import '../widgets/sensor_gauge.dart';
import '../utils/audio_decoder.dart';
import '../utils/tflite_pitch_estimator.dart';
import '../utils/midi_parser.dart';
import 'package:flutter/foundation.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  bool _isBuzzerPressed = false;
  int _easterEggTapCount = 0;
  bool _isPianoMode = false;
  int? _activePianoNoteFreq;

  // JSON Melody Player States
  bool _isKeyboardTab = true;
  bool _isPlayingJson = false;
  bool _isConvertingAudio = false;
  int _playbackIndex = 0;
  Timer? _playbackTimer;
  final TextEditingController _jsonMelodyController = TextEditingController();

  void _playJsonMelody(List<dynamic> melody, DashboardNotifier notifier) {
    if (!_isPlayingJson || _playbackIndex >= melody.length) {
      _stopJsonMelody(notifier);
      return;
    }

    final note = melody[_playbackIndex];
    final int freq = note['freq'] ?? 0;
    final int duration = note['duration'] ?? 100;

    setState(() {
      _activePianoNoteFreq = freq > 0 ? freq : null;
    });

    if (freq > 0) {
      notifier.playNote(freq);
    } else {
      notifier.stopNote();
    }

    _playbackIndex++;

    _playbackTimer = Timer(Duration(milliseconds: duration), () {
      _playJsonMelody(melody, notifier);
    });
  }

  void _stopJsonMelody(DashboardNotifier notifier) {
    _playbackTimer?.cancel();
    notifier.stopNote();
    setState(() {
      _isPlayingJson = false;
      _playbackIndex = 0;
      _activePianoNoteFreq = null;
    });
  }

  Future<void> _pickAndConvertAudio() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['wav', 'mp3', 'opus', 'ogg', 'm4a', 'aac', 'mid', 'midi'],
      );

      if (result.isNotEmpty) {
        final bytes = await result.first.readAsBytes();
        final String filename = result.first.name.toLowerCase();
        
        setState(() {
          _isConvertingAudio = true;
        });

        List<Map<String, int>> melody;
        if (filename.endsWith('.mid') || filename.endsWith('.midi')) {
          // Parse MIDI directly!
          melody = MidiParser.parseMidi(bytes);
        } else {
          // Run the multiplatform audio transcriber!
          melody = await AudioPitchTranscriber.transcribe(bytes);
        }

        setState(() {
          _jsonMelodyController.text = jsonEncode(melody);
          _isConvertingAudio = false;
        });

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Konversi Berhasil! ${melody.length} nada terdeteksi.'),
            backgroundColor: AppColors.safe,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isConvertingAudio = false;
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Gagal membaca audio: $e'),
          backgroundColor: AppColors.danger,
        ),
      );
    }
  }

  void _handlePianoPointer(Offset localPosition, DashboardNotifier notifier) {
    final double dx = localPosition.dx;
    final double dy = localPosition.dy;

    // Check boundary
    if (dx < 0 || dx > 320 || dy < 0 || dy > 160) {
      _handlePianoRelease(notifier);
      return;
    }

    int? detectedFreq;

    // 1. Check Black Keys (height 95)
    if (dy >= 0 && dy <= 95) {
      if (dx >= 29 && dx <= 51) {
        detectedFreq = 277; // C#4
      } else if (dx >= 69 && dx <= 91) {
        detectedFreq = 311; // D#4
      } else if (dx >= 149 && dx <= 171) {
        detectedFreq = 370; // F#4
      } else if (dx >= 189 && dx <= 211) {
        detectedFreq = 415; // G#4
      } else if (dx >= 229 && dx <= 251) {
        detectedFreq = 466; // A#4
      }
    }

    // 2. Check White Keys if no black key was hit
    if (detectedFreq == null) {
      final index = (dx / 40.0).floor().clamp(0, 7);
      const whiteFreqs = [262, 294, 330, 349, 392, 440, 494, 523];
      detectedFreq = whiteFreqs[index];
    }

    // Play if frequency changed
    if (_activePianoNoteFreq != detectedFreq) {
      setState(() {
        _activePianoNoteFreq = detectedFreq;
      });
      notifier.playNote(detectedFreq);
    }
  }

  void _handlePianoRelease(DashboardNotifier notifier) {
    if (_activePianoNoteFreq != null) {
      setState(() {
        _activePianoNoteFreq = null;
      });
      notifier.stopNote();
    }
  }

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable(); // Keep screen awake while viewing telemetry
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final notifier = Provider.of<DashboardNotifier>(context, listen: false);
      notifier.connect();
    });
  }

  @override
  void dispose() {
    WakelockPlus.disable(); // Allow screen to sleep when leaving dashboard
    _playbackTimer?.cancel();
    _jsonMelodyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Consumer<DashboardNotifier>(
        builder: (context, notifier, child) {
          final reading = notifier.currentReading;
          
          // Determine overall status
          String systemStatus = 'AMAN';
          Color statusColor = AppColors.safe;
          
          if (reading.classId == 3 || reading.waterLevel >= 90 || reading.smokeLevel >= 85) {
            systemStatus = 'SANGAT BAHAYA / DARURAT';
            statusColor = AppColors.danger;
          } else if (reading.classId == 2 || 
                     (reading.waterLevel >= 80 && reading.waterLevel < 90) ||
                     (reading.smokeLevel >= 60 && reading.smokeLevel < 85)) {
            systemStatus = 'BAHAYA';
            statusColor = AppColors.danger;
          } else if (reading.classId == 1 || 
                     (reading.waterLevel >= 50 && reading.waterLevel < 80) ||
                     (reading.smokeLevel >= 35 && reading.smokeLevel < 60)) {
            systemStatus = 'SIAGA / PERINGATAN';
            statusColor = AppColors.warning;
          }

          // Individual gauge colors
          Color distanceColor = AppColors.safe;
          if (reading.classId == 3) {
            distanceColor = AppColors.danger;
          } else if (reading.classId == 2) {
            distanceColor = AppColors.danger;
          } else if (reading.classId == 1) {
            distanceColor = AppColors.warning;
          }

          Color waterColor = AppColors.safe;
          if (reading.waterLevel >= 90) {
            waterColor = AppColors.danger;
          } else if (reading.waterLevel >= 80) {
            waterColor = AppColors.danger;
          } else if (reading.waterLevel >= 50) {
            waterColor = AppColors.warning;
          }

          Color smokeColor = AppColors.safe;
          if (reading.smokeLevel >= 85) {
            smokeColor = AppColors.danger;
          } else if (reading.smokeLevel >= 60) {
            smokeColor = AppColors.danger;
          } else if (reading.smokeLevel >= 35) {
            smokeColor = AppColors.warning;
          }

          final paddingHorizontal = MediaQuery.sizeOf(context).width > 600 ? 24.0 : 16.0;

          return SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: paddingHorizontal, vertical: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header Row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              if (notifier.status != ConnectionStatus.connected) return;
                              setState(() {
                                _easterEggTapCount++;
                                if (_easterEggTapCount >= 5) {
                                  _isPianoMode = true;
                                  _easterEggTapCount = 0;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('🎹 Mode Piano Aktif! Mainkan buzzer Anda! 🎹'),
                                      backgroundColor: AppColors.accent,
                                      duration: Duration(seconds: 2),
                                    ),
                                  );
                                }
                              });
                            },
                            child: const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Realtime dashboard',
                                  style: TextStyle(
                                    color: AppColors.accent,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 2,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                SizedBox(height: 4),
                                Text(
                                  'ESP32',
                                  style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 32,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        // Connection Indicator
                        _buildConnectionBadge(notifier.status),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Content based on connection status
                    if (notifier.status == ConnectionStatus.connected) ...[
                      // System Status Banner
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        padding: const EdgeInsets.all(16),
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: statusColor.withValues(alpha: 0.5), width: 1.5),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              systemStatus.contains('BAHAYA') ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                              color: statusColor,
                              size: 28,
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'STATUS SISTEM',
                                    style: TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    systemStatus,
                                    style: TextStyle(
                                      color: statusColor,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Unified Sensor Panel Card
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 20,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.dashboard_customize, color: AppColors.accent, size: 18),
                                SizedBox(width: 8),
                                Text(
                                  'PANEL TELEMETRI SENSOR',
                                  style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                Expanded(
                                  child: SensorGauge(
                                    title: 'Jarak Halangan',
                                    value: reading.distance,
                                    max: 300,
                                    unit: 'cm',
                                    color: distanceColor,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: SensorGauge(
                                    title: 'Level Air',
                                    value: reading.waterLevel,
                                    max: 100,
                                    unit: '%',
                                    color: waterColor,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: SensorGauge(
                                    title: 'Kadar Asap',
                                    value: reading.smokeLevel,
                                    max: 100,
                                    unit: '%',
                                    color: smokeColor,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),

                      if (_isPianoMode) ...[
                        // Piano Keyboard Panel
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              // Keyboard Header with tab selector
                              Row(
                                children: [
                                  const Icon(Icons.music_note, color: AppColors.accent, size: 18),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Row(
                                      children: [
                                        TextButton(
                                          onPressed: () {
                                            setState(() {
                                              _isKeyboardTab = true;
                                            });
                                          },
                                          style: TextButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(horizontal: 8),
                                          ),
                                          child: Text(
                                            'TUTS PIANO',
                                            style: TextStyle(
                                              color: _isKeyboardTab ? AppColors.textPrimary : AppColors.textSecondary,
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: () {
                                            setState(() {
                                              _isKeyboardTab = false;
                                            });
                                          },
                                          style: TextButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(horizontal: 8),
                                          ),
                                          child: Text(
                                            'PUTAR MP3 / WAV',
                                            style: TextStyle(
                                              color: !_isKeyboardTab ? AppColors.textPrimary : AppColors.textSecondary,
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close, color: AppColors.textSecondary, size: 18),
                                    onPressed: () {
                                      setState(() {
                                        _isPianoMode = false;
                                        _stopJsonMelody(notifier);
                                      });
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              if (_isKeyboardTab) ...[
                                // 13 Chromatic Piano Keys with Glissando (Sliding/Swiping play) support
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Listener(
                                    onPointerDown: (event) => _handlePianoPointer(event.localPosition, notifier),
                                    onPointerMove: (event) => _handlePianoPointer(event.localPosition, notifier),
                                    onPointerUp: (_) => _handlePianoRelease(notifier),
                                    onPointerCancel: (_) => _handlePianoRelease(notifier),
                                    child: SizedBox(
                                      width: 320, // Precise mathematical grid width
                                      height: 160,
                                      child: Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          // White Keys Row
                                          Positioned.fill(
                                            child: Row(
                                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                              children: [
                                                _buildPianoKey(context, 'C4', 'Do', 262),
                                                _buildPianoKey(context, 'D4', 'Re', 294),
                                                _buildPianoKey(context, 'E4', 'Mi', 330),
                                                _buildPianoKey(context, 'F4', 'Fa', 349),
                                                _buildPianoKey(context, 'G4', 'Sol', 392),
                                                _buildPianoKey(context, 'A4', 'La', 440),
                                                _buildPianoKey(context, 'B4', 'Si', 494),
                                                _buildPianoKey(context, 'C5', 'Do2', 523),
                                              ],
                                            ),
                                          ),
                                          // Black Keys (positioned at boundaries with half-width offset)
                                          _buildBlackKey(context, 'C#4', 277, 40.0 - 11.0),
                                          _buildBlackKey(context, 'D#4', 311, 80.0 - 11.0),
                                          _buildBlackKey(context, 'F#4', 370, 160.0 - 11.0),
                                          _buildBlackKey(context, 'G#4', 415, 200.0 - 11.0),
                                          _buildBlackKey(context, 'A#4', 466, 240.0 - 11.0),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ] else ...[
                                // MP3 JSON player
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    TextField(
                                      controller: _jsonMelodyController,
                                      maxLines: 3,
                                      style: const TextStyle(
                                        color: AppColors.textPrimary,
                                        fontSize: 12,
                                        fontFamily: 'monospace',
                                      ),
                                      decoration: InputDecoration(
                                        hintText: 'Tempel JSON melodi hasil konversi mp3_to_synth.py ATAU pilih file WAV di bawah...',
                                        hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
                                        fillColor: Colors.black.withValues(alpha: 0.2),
                                        filled: true,
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: const BorderSide(color: AppColors.accent),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Row(
                                        children: [
                                          ElevatedButton.icon(
                                            onPressed: () {
                                              if (_isPlayingJson) {
                                                _stopJsonMelody(notifier);
                                              } else {
                                                try {
                                                  final decoded = jsonDecode(_jsonMelodyController.text) as List<dynamic>;
                                                  setState(() {
                                                    _isPlayingJson = true;
                                                    _playbackIndex = 0;
                                                  });
                                                  _playJsonMelody(decoded, notifier);
                                                } catch (e) {
                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                    const SnackBar(
                                                      content: Text('Format JSON salah! Pastikan berupa array note.'),
                                                      backgroundColor: AppColors.danger,
                                                    ),
                                                  );
                                                }
                                              }
                                            },
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: _isPlayingJson ? AppColors.danger : AppColors.accent,
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                            ),
                                            icon: Icon(_isPlayingJson ? Icons.stop : Icons.play_arrow, color: Colors.white),
                                            label: Text(
                                              _isPlayingJson ? 'Hentikan' : 'Putar Melodi',
                                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          ElevatedButton.icon(
                                            onPressed: () => _pickAndConvertAudio(),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: const Color(0xFF0EA5E9), // Cyan/Light Blue
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                            ),
                                            icon: const Icon(Icons.audio_file_rounded, color: Colors.white),
                                            label: const Text(
                                              'Pilih Audio',
                                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          OutlinedButton(
                                            onPressed: () {
                                              _jsonMelodyController.text = jsonEncode([
                                                {"freq": 262, "duration": 300},
                                                {"freq": 294, "duration": 300},
                                                {"freq": 330, "duration": 300},
                                                {"freq": 262, "duration": 300},
                                                {"freq": 262, "duration": 300},
                                                {"freq": 294, "duration": 300},
                                                {"freq": 330, "duration": 300},
                                                {"freq": 262, "duration": 300},
                                                {"freq": 330, "duration": 300},
                                                {"freq": 349, "duration": 300},
                                                {"freq": 392, "duration": 600},
                                                {"freq": 330, "duration": 300},
                                                {"freq": 349, "duration": 300},
                                                {"freq": 392, "duration": 600}
                                              ]);
                                            },
                                            style: OutlinedButton.styleFrom(
                                              side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                            ),
                                            child: const Text('Isi Demo', style: TextStyle(color: AppColors.textPrimary)),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                          if (_isConvertingAudio)
                            Positioned.fill(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.75),
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                child: const Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      CircularProgressIndicator(
                                        valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
                                      ),
                                      SizedBox(height: 16),
                                      Text(
                                        'Menganalisis Pitch Audio...',
                                        style: TextStyle(
                                          color: AppColors.textPrimary,
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                      ] else ...[
                        // Circular Manual Buzzer Button (Hold-to-Sound)
                        Center(
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Circular text guide wrapping the top half of the button
                              CustomPaint(
                                size: const Size(180, 180),
                                painter: CircularTextPainter(
                                  text: 'TEKAN & TAHAN UNTUK BUNYI BUZZER',
                                  style: TextStyle(
                                    color: AppColors.textSecondary.withValues(alpha: 0.8),
                                    fontSize: 8.5,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.5,
                                  ),
                                  radius: 68,
                                ),
                              ),
                              // Outer concentric sound wave feedback ring
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                width: _isBuzzerPressed ? 122 : 100,
                                height: _isBuzzerPressed ? 122 : 100,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: AppColors.danger.withValues(
                                      alpha: _isBuzzerPressed ? 0.35 : 0.0,
                                    ),
                                    width: 2,
                                  ),
                                ),
                              ),
                              // Tactile scale animation container
                              GestureDetector(
                                onTapDown: (_) {
                                  setState(() {
                                    _isBuzzerPressed = true;
                                  });
                                  notifier.startBuzzer();
                                },
                                onTapUp: (_) {
                                  setState(() {
                                    _isBuzzerPressed = false;
                                  });
                                  notifier.stopBuzzer();
                                },
                                onTapCancel: () {
                                  setState(() {
                                    _isBuzzerPressed = false;
                                  });
                                  notifier.stopBuzzer();
                                },
                                child: AnimatedScale(
                                  scale: _isBuzzerPressed ? 0.92 : 1.0,
                                  duration: const Duration(milliseconds: 80),
                                  child: Container(
                                    width: 100,
                                    height: 100,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: const RadialGradient(
                                        colors: [
                                          AppColors.danger,
                                          Color(0xFF991B1B), // Red 800
                                        ],
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: AppColors.danger.withValues(
                                            alpha: _isBuzzerPressed ? 0.75 : 0.4,
                                          ),
                                          blurRadius: _isBuzzerPressed ? 32 : 20,
                                          spreadRadius: _isBuzzerPressed ? 6 : 2,
                                          offset: _isBuzzerPressed ? const Offset(0, 0) : const Offset(0, 8),
                                        ),
                                      ],
                                      border: Border.all(
                                        color: Colors.white.withValues(alpha: 0.15),
                                        width: 3,
                                      ),
                                    ),
                                    child: const Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.volume_up, color: Colors.white, size: 32),
                                        SizedBox(height: 4),
                                        Text(
                                          'HOLD',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: 1,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        // Calibration / Training Card
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.15),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.settings_suggest_rounded, color: AppColors.accent, size: 22),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      'Kalibrasi Jarak Pintu',
                                      style: TextStyle(
                                        color: AppColors.textPrimary,
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: AppColors.accent.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      reading.className,
                                      style: const TextStyle(
                                        color: AppColors.accent,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Kalibrasi Jarak Pintu (1-NN): Dekatkan/jauhkan sensor ke posisi pintu, lalu tekan tombol di bawah untuk melatih klasifikasi keadaan pintu secara real-time.',
                                style: TextStyle(
                                  color: AppColors.textSecondary.withValues(alpha: 0.8),
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 16),
                              // Current thresholds display
                              if (reading.thresholds.length >= 4) ...[
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                                    children: [
                                      _buildThresholdValue('TUTUP', reading.thresholds[0]),
                                      _buildThresholdValue('SEDIKIT', reading.thresholds[1]),
                                      _buildThresholdValue('LEBAR', reading.thresholds[2]),
                                      _buildThresholdValue('MASUK', reading.thresholds[3]),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                              ],
                              // Train buttons
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  final isWide = constraints.maxWidth > 400;
                                  return GridView.count(
                                    crossAxisCount: isWide ? 4 : 2,
                                    shrinkWrap: true,
                                    physics: const NeverScrollableScrollPhysics(),
                                    mainAxisSpacing: 10,
                                    crossAxisSpacing: 10,
                                    childAspectRatio: isWide ? 1.8 : 2.5,
                                    children: [
                                      _buildTrainButton(context, notifier, 0, 'Pintu Tertutup', AppColors.safe),
                                      _buildTrainButton(context, notifier, 1, 'Buka Sedikit', AppColors.warning),
                                      _buildTrainButton(context, notifier, 2, 'Buka Lebar', AppColors.danger),
                                      _buildTrainButton(context, notifier, 3, 'Objek Masuk', AppColors.danger),
                                    ],
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ] else ...[
                      // Offline Placeholder State
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(32),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.wifi_off_rounded, size: 48, color: AppColors.textSecondary),
                            SizedBox(height: 16),
                            Text(
                              'Telemetri Tidak Tersedia',
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 8),
                            Text(
                              'Hubungkan perangkat Anda ke Wi-Fi ESP32_Dashboard_Net untuk mensinkronisasi data sensor secara real-time.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildConnectionBadge(ConnectionStatus status) {
    Color color;
    String label;
    IconData icon;

    switch (status) {
      case ConnectionStatus.connected:
        color = AppColors.safe;
        label = 'Connected';
        icon = Icons.cloud_done;
        break;
      case ConnectionStatus.connecting:
        color = AppColors.warning;
        label = 'Connecting';
        icon = Icons.sync;
        break;
      case ConnectionStatus.error:
        color = AppColors.danger;
        label = 'Error';
        icon = Icons.error_outline;
        break;
      case ConnectionStatus.disconnected:
        color = AppColors.textSecondary;
        label = 'Disconnected';
        icon = Icons.cloud_off;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }



  Widget _buildPianoKey(BuildContext context, String noteName, String solfege, int frequency) {
    final isActive = _activePianoNoteFreq == frequency;

    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: AnimatedScale(
          scale: isActive ? 0.95 : 1.0,
          duration: const Duration(milliseconds: 60),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isActive
                    ? [
                        AppColors.accent.withValues(alpha: 0.4),
                        AppColors.accent,
                      ]
                    : [
                        Colors.white,
                        const Color(0xFFE2E8F0),
                      ],
              ),
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(8),
              ),
              boxShadow: [
                BoxShadow(
                  color: isActive 
                      ? AppColors.accent.withValues(alpha: 0.4) 
                      : Colors.black.withValues(alpha: 0.15),
                  blurRadius: isActive ? 8 : 4,
                  offset: isActive ? const Offset(0, 2) : const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  noteName,
                  style: TextStyle(
                    color: isActive ? Colors.white70 : Colors.black54,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
                Text(
                  solfege,
                  style: TextStyle(
                    color: isActive ? Colors.white : Colors.black,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBlackKey(BuildContext context, String noteName, int frequency, double leftPosition) {
    final isActive = _activePianoNoteFreq == frequency;

    return Positioned(
      left: leftPosition,
      top: 0,
      child: AnimatedScale(
        scale: isActive ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 60),
        child: Container(
          width: 22,
          height: 95,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: isActive
                  ? [
                      AppColors.accent.withValues(alpha: 0.6),
                      AppColors.accent,
                    ]
                  : [
                      const Color(0xFF1E293B), // Slate 800
                      const Color(0xFF0F172A), // Slate 900
                    ],
            ),
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(6),
            ),
            boxShadow: [
              BoxShadow(
                color: isActive
                    ? AppColors.accent.withValues(alpha: 0.5)
                    : Colors.black.withValues(alpha: 0.3),
                blurRadius: isActive ? 8 : 4,
                offset: const Offset(0, 3),
              ),
            ],
            border: Border.all(
              color: isActive ? Colors.white.withValues(alpha: 0.2) : Colors.black.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text(
                noteName,
                style: TextStyle(
                  color: isActive ? Colors.white : Colors.white60,
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThresholdValue(String label, double val) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            color: AppColors.textSecondary.withValues(alpha: 0.6),
            fontSize: 9,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${val.toStringAsFixed(1)} cm',
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  Widget _buildTrainButton(BuildContext context, DashboardNotifier notifier, int classId, String label, Color color) {
    return InkWell(
      onTap: () {
        notifier.trainClass(classId);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Mengirimkan kalibrasi untuk: $label...'),
            backgroundColor: color,
            duration: const Duration(seconds: 1),
          ),
        );
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 1.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_circle_outline_rounded, color: color, size: 16),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CircularTextPainter extends CustomPainter {
  final String text;
  final TextStyle style;
  final double radius;

  CircularTextPainter({
    required this.text,
    required this.style,
    required this.radius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    // Spread characters over the top half arc (from -150 to -30 degrees)
    const double startAngle = -5 * math.pi / 6;
    const double endAngle = -math.pi / 6;
    final double sweepAngle = endAngle - startAngle;

    final int len = text.length;
    final double angleStep = sweepAngle / (len - 1);

    for (int i = 0; i < len; i++) {
      final double angle = startAngle + i * angleStep;

      // Compute individual character placement coordinates
      final double x = center.dx + radius * math.cos(angle);
      final double y = center.dy + radius * math.sin(angle);

      canvas.save();
      canvas.translate(x, y);
      
      // Rotate tangential to circle pointing upwards
      canvas.rotate(angle + math.pi / 2);

      textPainter.text = TextSpan(
        text: text[i],
        style: style,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(-textPainter.width / 2, -textPainter.height / 2),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant CircularTextPainter oldDelegate) {
    return oldDelegate.text != text || oldDelegate.radius != radius;
  }
}

class AudioPitchTranscriber {
  static Future<List<Map<String, int>>> transcribe(Uint8List bytes, {int frameDurationMs = 100}) async {
    const int targetSampleRate = 16000;
    
    // 1. Decode audio to PCM Float32List using our multiplatform audio decoder
    final Float32List rawSamples = await decodeAudioToPcm(bytes, targetSampleRate);
    
    // 2. Pre-Filtering (Bandpass Filter: 120Hz to 800Hz) to isolate melody
    final double lpAlpha = 0.24; // Lowpass cutoff ~800Hz
    final double hpAlpha = 0.96; // Highpass cutoff ~120Hz
    
    final Float32List samples = Float32List(rawSamples.length);
    double lpPrev = 0.0;
    double hpPrevInput = 0.0;
    double hpPrevOutput = 0.0;
    
    for (int i = 0; i < rawSamples.length; i++) {
      // Lowpass Filter
      lpPrev = lpPrev + lpAlpha * (rawSamples[i] - lpPrev);
      
      // Highpass Filter
      final double hpInput = lpPrev;
      hpPrevOutput = hpAlpha * (hpPrevOutput + hpInput - hpPrevInput);
      hpPrevInput = hpInput;
      
      samples[i] = hpPrevOutput;
    }
    
    // Load and initialize TFLite SPICE AI Estimator on Mobile
    TflitePitchEstimator? aiEstimator;
    if (!kIsWeb) {
      aiEstimator = TflitePitchEstimator();
      await aiEstimator.init();
    }
    final bool useAI = aiEstimator != null && aiEstimator.isReady;
    
    // 3. Short-Time Autocorrelation or AI-inference
    final int frameSize = (targetSampleRate * (frameDurationMs / 1000.0)).toInt();
    final int hopSize = frameSize;
    
    final List<Map<String, int>> melody = [];
    int currentFreq = 0;
    int currentDuration = 0;
    
    // Low threshold for filtered RMS energy
    const double rmsThreshold = 0.015;
    
    for (int start = 0; start < samples.length - frameSize; start += hopSize) {
      // Find max amplitude in the frame
      double maxVal = 0.0;
      double sumSq = 0;
      for (int j = 0; j < frameSize; j++) {
        final double val = samples[start + j];
        sumSq += val * val;
        final double absVal = val.abs();
        if (absVal > maxVal) maxVal = absVal;
      }
      
      final double rms = math.sqrt(sumSq / frameSize);
      int noteFreq = 0;
      
      if (rms >= rmsThreshold && maxVal > 0.005) {
        if (useAI) {
          // Slice the middle 512 samples from this 100ms frame to feed to SPICE model
          final Float32List aiFrame = Float32List(512);
          final int centerStart = start + (frameSize - 512) ~/ 2;
          for (int j = 0; j < 512; j++) {
            aiFrame[j] = samples[centerStart + j];
          }
          final double detectedFreq = aiEstimator.estimatePitch(aiFrame);
          if (detectedFreq > 0) {
            noteFreq = _getClosestNoteFreq(detectedFreq);
          }
        } else {
          // Extract and Center-Clip frame (Sondhi method) - Autocorrelation Fallback
          final Float32List frame = Float32List(frameSize);
          final double clipThreshold = maxVal * 0.30;
          for (int j = 0; j < frameSize; j++) {
            final double val = samples[start + j];
            if (val.abs() < clipThreshold) {
              frame[j] = 0.0;
            } else {
              frame[j] = val > 0 ? val - clipThreshold : val + clipThreshold;
            }
          }
          
          final int minPeriod = (targetSampleRate / 800.0).toInt(); // Max pitch frequency 800Hz
          final int maxPeriod = (targetSampleRate / 130.0).toInt(); // Min pitch frequency 130Hz
          
          double maxCorrelation = -1.0;
          int bestPeriod = -1;
          
          // Compute base energy for normalization R(0)
          double r0 = 0.0;
          for (int j = 0; j < frameSize; j++) {
            r0 += frame[j] * frame[j];
          }
          
          if (r0 > 0.0) {
            for (int period = minPeriod; period <= maxPeriod; period++) {
              double correlation = 0;
              for (int j = 0; j < frameSize - period; j++) {
                correlation += frame[j] * frame[j + period];
              }
              if (correlation > maxCorrelation) {
                maxCorrelation = correlation;
                bestPeriod = period;
              }
            }
            
            // Verify correlation peak strength to filter out voice/noise friction
            if (bestPeriod > 0 && (maxCorrelation / r0) > 0.15) {
              final double detectedFreq = targetSampleRate / bestPeriod;
              noteFreq = _getClosestNoteFreq(detectedFreq);
            }
          }
        }
      }
      
      if (melody.isEmpty) {
        currentFreq = noteFreq;
        currentDuration = frameDurationMs;
        melody.add({"freq": currentFreq, "duration": currentDuration});
      } else {
        if (noteFreq == currentFreq) {
          currentDuration += frameDurationMs;
          melody.last["duration"] = currentDuration;
        } else {
          currentFreq = noteFreq;
          currentDuration = frameDurationMs;
          melody.add({"freq": currentFreq, "duration": currentDuration});
        }
      }
    }
    
    // Dispose TFLite instance
    if (aiEstimator != null) {
      aiEstimator.dispose();
    }
    
    // Simplify melody by merging short silences/noise fluctuations
    final List<Map<String, int>> cleanMelody = [];
    for (var note in melody) {
      if (cleanMelody.isEmpty) {
        cleanMelody.add(note);
      } else {
        final last = cleanMelody.last;
        // Merge identical consecutive notes
        if (last['freq'] == note['freq']) {
          last['duration'] = last['duration']! + note['duration']!;
        } else if (note['freq'] == 0 && note['duration']! < 150) {
          // Merge very short rests into the previous playing note to avoid choppy audio
          last['duration'] = last['duration']! + note['duration']!;
        } else {
          cleanMelody.add(note);
        }
      }
    }
    
    return cleanMelody;
  }
  
  static const Map<String, int> _noteFreqs = {
    "C4": 262, "C#4": 277, "D4": 294, "D#4": 311, "E4": 330, "F4": 349,
    "F#4": 370, "G4": 392, "G#4": 415, "A4": 440, "A#4": 466, "B4": 494,
    "C5": 523, "C#5": 554, "D5": 587, "D#5": 622, "E5": 659, "F5": 698,
    "F#5": 740, "G5": 784, "G#5": 831, "A5": 880, "A#5": 932, "B5": 988
  };
  
  static int _getClosestNoteFreq(double freq) {
    if (freq < 100) return 0;
    int closestFreq = 0;
    double minDiff = 999999;
    _noteFreqs.forEach((note, noteFreq) {
      final diff = (freq - noteFreq).abs();
      if (diff < minDiff) {
        minDiff = diff;
        closestFreq = noteFreq;
      }
    });
    if (minDiff > closestFreq * 0.08) return 0;
    return closestFreq;
  }
}

