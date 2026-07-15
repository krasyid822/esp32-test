import '../repositories/sensor_repository.dart';

class SendCommand {
  final SensorRepository repository;

  SendCommand(this.repository);

  void call(String command) {
    repository.sendCommand(command);
  }
}
