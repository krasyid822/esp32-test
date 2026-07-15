import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'core/constants/colors.dart';
import 'features/dashboard/data/datasources/sensor_remote_datasource.dart';
import 'features/dashboard/data/repositories/sensor_repository_impl.dart';
import 'features/dashboard/domain/usecases/stream_sensor_readings.dart';
import 'features/dashboard/domain/usecases/send_command.dart';
import 'features/dashboard/presentation/change_notifier/dashboard_notifier.dart';
import 'features/dashboard/presentation/pages/dashboard_page.dart';

void main() {
  runApp(const TelemetryApp());
}

class TelemetryApp extends StatelessWidget {
  const TelemetryApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Dependency Injection
    final remoteDatasource = SensorRemoteDatasourceImpl();
    final repository = SensorRepositoryImpl(remoteDatasource: remoteDatasource);
    final streamSensorReadings = StreamSensorReadings(repository);
    final sendCommand = SendCommand(repository);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => DashboardNotifier(
            streamSensorReadings: streamSensorReadings,
            sendCommand: sendCommand,
          ),
        ),
      ],
      child: MaterialApp(
        title: 'ESP32 Telemetry Dashboard',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'Inter',
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppColors.accent,
            brightness: Brightness.dark,
          ),
        ),
        home: const DashboardPage(),
      ),
    );
  }
}
