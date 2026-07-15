import 'dart:async';
import 'package:flutter/material.dart';
import '../../domain/entities/sensor_reading.dart';
import '../../domain/usecases/stream_sensor_readings.dart';
import '../../domain/usecases/send_command.dart';

enum ConnectionStatus { disconnected, connecting, connected, error }

class DashboardNotifier extends ChangeNotifier {
  final StreamSensorReadings streamSensorReadings;
  final SendCommand sendCommand;

  DashboardNotifier({
    required this.streamSensorReadings,
    required this.sendCommand,
  });

  String _wsUrl = 'ws://192.168.4.1/ws'; // Default ESP32 AP WebSockets URL
  String get wsUrl => _wsUrl;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  ConnectionStatus get status => _status;

  SensorReading _currentReading = SensorReading.initial();
  SensorReading get currentReading => _currentReading;

  StreamSubscription<SensorReading>? _subscription;
  Timer? _reconnectTimer;
  bool _shouldReconnect = true;

  void updateWsUrl(String newUrl) {
    if (_wsUrl == newUrl && _status == ConnectionStatus.connected) return;
    _wsUrl = newUrl;
    _shouldReconnect = true;
    notifyListeners();
    connect();
  }

  void connect() {
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _status = ConnectionStatus.connecting;
    notifyListeners();

    try {
      final stream = streamSensorReadings(_wsUrl);
      _subscription = stream.listen(
        (reading) {
          _currentReading = reading;
          if (_status != ConnectionStatus.connected) {
            _status = ConnectionStatus.connected;
          }
          notifyListeners();
        },
        onError: (error) {
          _status = ConnectionStatus.error;
          notifyListeners();
          _scheduleReconnect();
        },
        onDone: () {
          _status = ConnectionStatus.disconnected;
          notifyListeners();
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      _status = ConnectionStatus.error;
      notifyListeners();
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!_shouldReconnect || _wsUrl.toLowerCase() == 'mock') return;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (_status != ConnectionStatus.connected) {
        connect();
      }
    });
  }

  void startBuzzer() {
    sendCommand('start_buzzer');
  }

  void stopBuzzer() {
    sendCommand('stop_buzzer');
  }

  void playNote(int frequency) {
    sendCommand('play_note:$frequency');
  }

  void stopNote() {
    sendCommand('stop_note');
  }

  void trainClass(int classId) {
    sendCommand('train_class:$classId');
  }

  void disconnect() {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _status = ConnectionStatus.disconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    super.dispose();
  }
}
