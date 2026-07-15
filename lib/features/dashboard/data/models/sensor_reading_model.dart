import '../../domain/entities/sensor_reading.dart';

class SensorReadingModel extends SensorReading {
  const SensorReadingModel({
    required super.distance,
    required super.waterLevel,
    required super.smokeLevel,
    required super.timestamp,
    required super.classId,
    required super.className,
    required super.thresholds,
  });

  /// Factory to parse from Map/JSON.
  factory SensorReadingModel.fromJson(Map<String, dynamic> json) {
    return SensorReadingModel(
      distance: (json['distance'] as num?)?.toDouble() ?? 300.0,
      waterLevel: (json['water'] as num?)?.toDouble() ?? 0.0,
      smokeLevel: (json['smoke'] as num?)?.toDouble() ?? 0.0,
      timestamp: DateTime.now(),
      classId: json['class_id'] as int? ?? -1,
      className: json['class_name'] as String? ?? 'Tidak Diketahui',
      thresholds: (json['thresholds'] as List<dynamic>?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          const [5.0, 12.0, 25.0, 35.0],
    );
  }

  /// Converts model back to JSON map if needed.
  Map<String, dynamic> toJson() {
    return {
      'distance': distance,
      'water': waterLevel,
      'smoke': smokeLevel,
    };
  }
}
