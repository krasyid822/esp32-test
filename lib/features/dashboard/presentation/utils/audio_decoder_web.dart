// ignore_for_file: avoid_web_libraries_in_flutter, uri_does_not_exist

import 'dart:typed_data';
import 'dart:js_util' as js_util;

Future<Float32List> decodeAudioToPcm(Uint8List bytes, int targetSampleRate) async {
  // Get browser window context
  final window = js_util.globalThis;
  
  // Find AudioContext or webkitAudioContext constructor dynamically
  final audioContextClass = js_util.getProperty(window, 'AudioContext') ?? 
                            js_util.getProperty(window, 'webkitAudioContext');
  
  if (audioContextClass == null) {
    throw UnsupportedError('AudioContext tidak didukung di browser ini.');
  }

  // Instantiate: new AudioContext()
  final audioCtx = js_util.callConstructor(audioContextClass, []);
  
  // Convert Dart ByteBuffer to JS ArrayBuffer
  final jsBuffer = bytes.buffer;
  
  // Call decodeAudioData(jsBuffer) which returns a Promise
  final promise = js_util.callMethod(audioCtx, 'decodeAudioData', [jsBuffer]);
  final audioBuffer = await js_util.promiseToFuture(promise);
  
  final int sampleRate = js_util.getProperty(audioBuffer, 'sampleRate');
  final int length = js_util.getProperty(audioBuffer, 'length');
  
  // Call audioBuffer.getChannelData(0) to get raw Float32 mono samples
  final Float32List channelData = js_util.callMethod(audioBuffer, 'getChannelData', [0]);
  
  // Resample if necessary
  if (sampleRate == targetSampleRate) {
    return channelData;
  }
  
  final double ratio = sampleRate / targetSampleRate;
  final int newLength = (length / ratio).floor();
  final Float32List resampled = Float32List(newLength);
  
  for (int i = 0; i < newLength; i++) {
    final double srcIdx = i * ratio;
    final int low = srcIdx.floor();
    final int high = srcIdx.ceil().clamp(0, channelData.length - 1);
    final double weight = srcIdx - low;
    resampled[i] = (1 - weight) * channelData[low] + weight * channelData[high];
  }
  
  return resampled;
}
