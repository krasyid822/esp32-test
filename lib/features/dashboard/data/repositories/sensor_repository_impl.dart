import '../../domain/entities/sensor_reading.dart';
import '../../domain/repositories/sensor_repository.dart';
import '../datasources/sensor_remote_datasource.dart';

class SensorRepositoryImpl implements SensorRepository {
  final SensorRemoteDatasource remoteDatasource;

  SensorRepositoryImpl({required this.remoteDatasource});

  @override
  Stream<SensorReading> streamSensorReadings(String wsUrl) {
    return remoteDatasource.getSensorStream(wsUrl);
  }

  @override
  void sendCommand(String command) {
    remoteDatasource.sendCommand(command);
  }
}
