import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/sensor_reading_model.dart';

abstract class SensorRemoteDatasource {
  Stream<SensorReadingModel> getSensorStream(String wsUrl);
  void sendCommand(String command);
}

class SensorRemoteDatasourceImpl implements SensorRemoteDatasource {
  WebSocketChannel? _activeChannel;

  @override
  Stream<SensorReadingModel> getSensorStream(String wsUrl) {
    if (wsUrl.toLowerCase() == 'mock') {
      _activeChannel = null;
      return _getMockStream();
    }

    try {
      _activeChannel = WebSocketChannel.connect(Uri.parse(wsUrl));
    } catch (e) {
      _activeChannel = null;
      return _getMockStream();
    }

    // Return the mapped stream while handling close events to release the reference
    return _activeChannel!.stream.map((event) {
      try {
        final Map<String, dynamic> data = jsonDecode(event.toString());
        return SensorReadingModel.fromJson(data);
      } catch (e) {
        return SensorReadingModel.fromJson(const {});
      }
    }).handleError((error) {
      _activeChannel = null;
    });
  }

  @override
  void sendCommand(String command) {
    if (_activeChannel != null) {
      try {
        _activeChannel!.sink.add(command);
      } catch (e) {
        // Sink error fallback
      }
    }
  }

  /// Generates a mock sensor stream for UI testing without the ESP32 hardware.
  Stream<SensorReadingModel> _getMockStream() {
    final random = Random();
    double currentDistance = 100.0;
    double currentWater = 20.0;
    double currentSmoke = 10.0;

    return Stream.periodic(const Duration(milliseconds: 300), (_) {
      // Simulate random walk
      currentDistance = (currentDistance + (random.nextDouble() * 10 - 5)).clamp(2.0, 300.0);
      currentWater = (currentWater + (random.nextDouble() * 8 - 4)).clamp(0.0, 100.0);
      currentSmoke = (currentSmoke + (random.nextDouble() * 6 - 3)).clamp(0.0, 100.0);

      return SensorReadingModel(
        distance: currentDistance,
        waterLevel: currentWater,
        smokeLevel: currentSmoke,
        timestamp: DateTime.now(),
        classId: -1,
        className: 'Simulasi',
        thresholds: const [5.0, 12.0, 25.0, 35.0],
      );
    }).asBroadcastStream();
  }
}
