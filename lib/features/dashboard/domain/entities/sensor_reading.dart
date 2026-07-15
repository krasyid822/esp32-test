class SensorReading {
  final double distance;
  final double waterLevel;
  final double smokeLevel;
  final DateTime timestamp;
  final int classId;
  final String className;
  final List<double> thresholds;

  const SensorReading({
    required this.distance,
    required this.waterLevel,
    required this.smokeLevel,
    required this.timestamp,
    required this.classId,
    required this.className,
    required this.thresholds,
  });

  /// Factory constructor to return an empty/initial reading
  factory SensorReading.initial() {
    return SensorReading(
      distance: 300.0,
      waterLevel: 0.0,
      smokeLevel: 0.0,
      timestamp: DateTime.now(),
      classId: -1,
      className: 'Tidak Diketahui',
      thresholds: const [5.0, 12.0, 25.0, 35.0],
    );
  }
}
