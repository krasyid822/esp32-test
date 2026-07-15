import '../entities/sensor_reading.dart';

abstract class SensorRepository {
  /// Stream telemetry data from the ESP32.
  Stream<SensorReading> streamSensorReadings(String wsUrl);

  /// Send command to ESP32.
  void sendCommand(String command);
}
