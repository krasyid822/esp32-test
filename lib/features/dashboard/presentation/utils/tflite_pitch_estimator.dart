import 'dart:math' as math;
import 'package:flutter/foundation.dart';

// Conditionally import tflite_flutter to prevent compile issues on unsupported test platforms
import 'package:tflite_flutter/tflite_flutter.dart';

class TflitePitchEstimator {
  Interpreter? _interpreter;
  bool _isInitialized = false;

  Future<void> init() async {
    if (kIsWeb) return;
    try {
      _interpreter = await Interpreter.fromAsset('spice.tflite');
      _isInitialized = true;
      debugPrint('TFLite SPICE model successfully initialized.');
    } catch (e) {
      debugPrint('Error loading TFLite SPICE model: $e');
    }
  }

  bool get isReady => _isInitialized && _interpreter != null;

  /// Runs inference on a 512-sample frame @ 16kHz
  double estimatePitch(Float32List frame) {
    if (!_isInitialized || _interpreter == null) return 0.0;

    // SPICE expects exactly 512 float32 samples.
    if (frame.length != 512) {
      // pad or slice frame to 512 samples
      final Float32List paddedFrame = Float32List(512);
      for (int i = 0; i < 512 && i < frame.length; i++) {
        paddedFrame[i] = frame[i];
      }
      frame = paddedFrame;
    }

    final inputTensors = _interpreter!.getInputTensors();
    final outputTensors = _interpreter!.getOutputTensors();

    if (inputTensors.isEmpty || outputTensors.length < 2) return 0.0;

    // Format input dynamically based on shape [512] vs [1, 512]
    dynamic inputBuffer;
    if (inputTensors.first.shape.length == 2) {
      inputBuffer = [frame];
    } else {
      inputBuffer = frame;
    }

    final Float32List outputPitch = Float32List(1);
    final Float32List outputUncertainty = Float32List(1);

    dynamic outPitchBuffer = outputPitch;
    dynamic outUncertaintyBuffer = outputUncertainty;

    if (outputTensors[0].shape.length == 2) {
      outPitchBuffer = [outputPitch];
    }
    if (outputTensors[1].shape.length == 2) {
      outUncertaintyBuffer = [outputUncertainty];
    }

    final Map<int, Object> outputs = {
      0: outPitchBuffer,
      1: outUncertaintyBuffer,
    };

    try {
      _interpreter!.runForMultipleInputs([inputBuffer], outputs);

      final double pitchVal = outputPitch[0];
      final double uncertaintyVal = outputUncertainty[0];
      final double confidence = 1.0 - uncertaintyVal;

      // Only accept predictions with high confidence
      if (confidence > 0.70 && pitchVal > 0.0) {
        // Convert normalized pitch [0, 1] to Hz
        // Formula: cqt_pitch = pitch * 63.07 + 25.58; frequency = 10 * 2^(cqt_pitch/12)
        final double cqtPitch = pitchVal * 63.07 + 25.58;
        return 10.0 * math.pow(2.0, cqtPitch / 12.0);
      }
    } catch (e) {
      debugPrint('TFLite SPICE inference failed: $e');
    }

    return 0.0;
  }

  void dispose() {
    _interpreter?.close();
  }
}
