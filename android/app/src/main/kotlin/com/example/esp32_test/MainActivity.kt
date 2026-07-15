package com.example.esp32_test

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.esp32_test/audio_decoder"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "decodeAudio") {
                val filePath = call.argument<String>("filePath")
                val targetSampleRate = call.argument<Int>("targetSampleRate") ?: 16000
                if (filePath == null) {
                    result.error("INVALID_ARGUMENT", "filePath is null", null)
                    return@setMethodCallHandler
                }
                
                // Run in a background thread to prevent UI freezing
                Thread {
                    try {
                        val pcmData = decodeToPcm(filePath, targetSampleRate)
                        runOnUiThread {
                            result.success(pcmData)
                        }
                    } catch (e: Exception) {
                        runOnUiThread {
                            result.error("DECODE_FAILED", e.message, null)
                        }
                    }
                }.start()
            } else {
                result.notImplemented()
            }
        }
    }

    private fun decodeToPcm(filePath: String, targetSampleRate: Int): FloatArray {
        val extractor = MediaExtractor()
        extractor.setDataSource(filePath)
        
        var trackIndex = -1
        var format: MediaFormat? = null
        var mime: String? = null
        
        for (i in 0 until extractor.trackCount) {
            val trackFormat = extractor.getTrackFormat(i)
            val trackMime = trackFormat.getString(MediaFormat.KEY_MIME) ?: ""
            if (trackMime.startsWith("audio/")) {
                trackIndex = i
                format = trackFormat
                mime = trackMime
                break
            }
        }
        
        if (trackIndex == -1 || format == null || mime == null) {
            throw Exception("No audio track found in file.")
        }
        
        extractor.selectTrack(trackIndex)
        val decoder = MediaCodec.createDecoderByType(mime)
        decoder.configure(format, null, null, 0)
        decoder.start()
        
        val info = MediaCodec.BufferInfo()
        var isEOS = false
        val decodedBytes = mutableListOf<Byte>()
        
        var inputSampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var inputChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

        while (!isEOS) {
            val inIndex = decoder.dequeueInputBuffer(10000)
            if (inIndex >= 0) {
                val buffer = decoder.getInputBuffer(inIndex)
                if (buffer != null) {
                    val sampleSize = extractor.readSampleData(buffer, 0)
                    if (sampleSize < 0) {
                        decoder.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        isEOS = true
                    } else {
                        decoder.queueInputBuffer(inIndex, 0, sampleSize, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }
            
            var outIndex = decoder.dequeueOutputBuffer(info, 10000)
            while (outIndex >= 0) {
                val buffer = decoder.getOutputBuffer(outIndex)
                if (buffer != null) {
                    val chunk = ByteArray(info.size)
                    buffer.position(info.offset)
                    buffer.get(chunk)
                    decodedBytes.addAll(chunk.toList())
                }
                decoder.releaseOutputBuffer(outIndex, false)
                outIndex = decoder.dequeueOutputBuffer(info, 0)
            }

            if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val outFormat = decoder.outputFormat
                inputSampleRate = outFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                inputChannels = outFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            }
        }
        
        decoder.stop()
        decoder.release()
        extractor.release()
        
        // Convert 16-bit PCM bytes to FloatArray and downsample to Mono
        val byteBuffer = ByteBuffer.wrap(decodedBytes.toByteArray()).order(ByteOrder.LITTLE_ENDIAN)
        val numSamples = decodedBytes.size / 2
        val floatSamples = FloatArray(numSamples / inputChannels)
        
        var j = 0
        for (i in 0 until numSamples step inputChannels) {
            if (j >= floatSamples.size) break
            var sum = 0f
            for (c in 0 until inputChannels) {
                if (byteBuffer.remaining() >= 2) {
                    sum += byteBuffer.short / 32768.0f
                }
            }
            floatSamples[j++] = sum / inputChannels
        }
        
        // Resample to targetSampleRate if necessary
        if (inputSampleRate == targetSampleRate) {
            return floatSamples
        }
        
        val ratio = inputSampleRate.toDouble() / targetSampleRate
        val newLength = (floatSamples.size / ratio).toInt()
        val resampled = FloatArray(newLength)
        for (i in 0 until newLength) {
            val srcIdx = i * ratio
            val low = srcIdx.toInt()
            val high = (low + 1).coerceAtMost(floatSamples.size - 1)
            val weight = (srcIdx - low).toFloat()
            resampled[i] = (1f - weight) * floatSamples[low] + weight * floatSamples[high]
        }
        
        return resampled
    }
}
