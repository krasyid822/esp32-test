import '../entities/sensor_reading.dart';
import '../repositories/sensor_repository.dart';

class StreamSensorReadings {
  final SensorRepository repository;

  StreamSensorReadings(this.repository);

  Stream<SensorReading> call(String wsUrl) {
    return repository.streamSensorReadings(wsUrl);
  }
}
