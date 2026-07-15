import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/services.dart';

const _channel = MethodChannel('com.example.esp32_test/audio_decoder');

Future<Float32List> decodeAudioToPcm(Uint8List bytes, int targetSampleRate) async {
  // If it's a WAV file, we can still parse it directly to avoid file I/O overhead.
  if (bytes.length >= 44 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46) {
    try {
      return _parseWavToPcm(bytes, targetSampleRate);
    } catch (_) {
      // Fallback to native decoder if manual parsing fails
    }
  }

  // Write audio bytes to a system temp file to let Android MediaExtractor read it
  final tempDir = Directory.systemTemp;
  final tempFile = File('${tempDir.path}/temp_decode_audio');
  await tempFile.writeAsBytes(bytes);

  try {
    final dynamic result = await _channel.invokeMethod('decodeAudio', {
      'filePath': tempFile.path,
      'targetSampleRate': targetSampleRate,
    });

    if (result is Float32List) {
      return result;
    } else if (result is List) {
      return Float32List.fromList(result.cast<double>());
    } else if (result is Float64List) {
      return Float32List.fromList(result);
    } else {
      throw Exception('Unexpected PCM result format from native channel: ${result.runtimeType}');
    }
  } finally {
    // Ensure the temp file is deleted
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
  }
}

Float32List _parseWavToPcm(Uint8List bytes, int targetSampleRate) {
  final byteData = ByteData.sublistView(bytes);
  final int sampleRate = byteData.getUint32(24, Endian.little);
  final int numChannels = byteData.getUint16(22, Endian.little);
  final int bitsPerSample = byteData.getUint16(34, Endian.little);
  
  int offset = 12;
  int dataSize = 0;
  int dataOffset = 0;
  
  while (offset < bytes.length - 8) {
    final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final int chunkSize = byteData.getUint32(offset + 4, Endian.little);
    if (chunkId == "data") {
      dataOffset = offset + 8;
      dataSize = chunkSize;
      break;
    }
    offset += 8 + chunkSize;
  }
  
  if (dataOffset == 0) {
    throw Exception("Data audio PCM tidak ditemukan.");
  }
  
  final int bytesPerSample = bitsPerSample ~/ 8;
  final int totalSamples = dataSize ~/ (bytesPerSample * numChannels);
  final samples = Float32List(totalSamples);
  
  int sampleIndex = 0;
  for (int i = dataOffset; i < dataOffset + dataSize && sampleIndex < totalSamples; i += bytesPerSample * numChannels) {
    if (bitsPerSample == 16) {
      final int val = byteData.getInt16(i, Endian.little);
      samples[sampleIndex] = val / 32768.0;
    } else if (bitsPerSample == 8) {
      final int val = bytes[i] - 128;
      samples[sampleIndex] = val / 128.0;
    }
    sampleIndex++;
  }
  
  // Resample if necessary
  if (sampleRate == targetSampleRate) {
    return samples;
  }
  
  final double ratio = sampleRate / targetSampleRate;
  final int newLength = (samples.length / ratio).floor();
  final Float32List resampled = Float32List(newLength);
  
  for (int i = 0; i < newLength; i++) {
    final double srcIdx = i * ratio;
    final int low = srcIdx.floor();
    final int high = srcIdx.ceil().clamp(0, samples.length - 1);
    final double weight = srcIdx - low;
    resampled[i] = (1 - weight) * samples[low] + weight * samples[high];
  }
  
  return resampled;
}
