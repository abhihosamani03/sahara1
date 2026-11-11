package com.example.voice

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Real-time voice over the mesh with Codec2 at 3200 bps.
 *
 * Capture is 8 kHz mono PCM, encoded in 20 ms / 8 byte frames. Three frames are
 * batched per outbound event so the radio carries ~17 packets/s instead of 50,
 * which is what makes this usable on a BLE link.
 *
 * Playback is deliberately simple: frames are decoded and written to a streaming
 * AudioTrack from a dedicated thread. Codec2 has no inter-frame state that can
 * desynchronise, so a dropped packet costs 60 ms of audio and nothing else.
 */
class Codec2VoicePlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "Codec2Voice"
        private const val METHOD_CHANNEL = "itantra/codec2"
        private const val EVENT_CHANNEL = "itantra/codec2/events"
        private const val SAMPLE_RATE = 8000
        private const val FRAMES_PER_PACKET = 3
        private const val RX_QUEUE_LIMIT = 12
    }

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())

    private var sink: EventChannel.EventSink? = null

    private var handle: Long = 0L
    private var samplesPerFrame = 0
    private var bytesPerFrame = 0

    private var recorder: AudioRecord? = null
    private var player: AudioTrack? = null

    private var txThread: Thread? = null
    private val txRunning = AtomicBoolean(false)

    private var rxThread: Thread? = null
    private val rxQueue = LinkedBlockingQueue<ByteArray>(RX_QUEUE_LIMIT)
    private val rxRunning = AtomicBoolean(false)

    private var txSeq = 0

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    // ── Channel plumbing ────────────────────────────────────────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(event: Map<String, Any?>) {
        mainHandler.post { sink?.success(event) }
    }

    private fun emitError(message: String) {
        Log.w(TAG, message)
        emit(mapOf("type" to "error", "message" to message))
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(statusMap())
            "startTx" -> result.success(startTx())
            "stopTx" -> {
                stopTx()
                result.success(true)
            }
            "startRx" -> result.success(startRx())
            "stopRx" -> {
                stopRx()
                result.success(true)
            }
            "push" -> {
                val data = call.argument<ByteArray>("data")
                if (data == null || data.isEmpty()) {
                    result.error("bad_args", "push requires non-empty data", null)
                } else {
                    enqueueRx(data)
                    result.success(true)
                }
            }
            "stop" -> {
                stopTx()
                stopRx()
                result.success(true)
            }
            "release" -> {
                release()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun statusMap(): Map<String, Any?> = mapOf(
        "available" to (Codec2Bridge.isAvailable && ensureCodec()),
        "mode" to Codec2Bridge.MODE_3200,
        "sampleRate" to SAMPLE_RATE,
        "samplesPerFrame" to samplesPerFrame,
        "bytesPerFrame" to bytesPerFrame,
        "framesPerPacket" to FRAMES_PER_PACKET,
        "tx" to txRunning.get(),
        "rx" to rxRunning.get(),
    )

    // ── Codec lifecycle ─────────────────────────────────────────────────

    private fun ensureCodec(): Boolean {
        if (handle != 0L) return true
        if (!Codec2Bridge.isAvailable) return false
        val created = try {
            Codec2Bridge.create(Codec2Bridge.MODE_3200)
        } catch (t: Throwable) {
            Log.w(TAG, "codec2_create failed: ${t.message}")
            0L
        }
        if (created == 0L) {
            emitError("Codec2 could not be initialised")
            return false
        }
        val samples = Codec2Bridge.samplesPerFrame(created)
        val bytes = Codec2Bridge.bytesPerFrame(created)
        if (samples <= 0 || bytes <= 0) {
            Codec2Bridge.destroy(created)
            emitError("Codec2 reported an invalid frame size")
            return false
        }
        handle = created
        samplesPerFrame = samples
        bytesPerFrame = bytes
        Log.i(TAG, "codec2 ready: $samples samples / $bytes bytes per frame")
        return true
    }

    private fun hasMicPermission(): Boolean = ContextCompat.checkSelfPermission(
        context,
        Manifest.permission.RECORD_AUDIO,
    ) == PackageManager.PERMISSION_GRANTED

    // ── Transmit ────────────────────────────────────────────────────────

    private fun startTx(): Boolean {
        if (!ensureCodec()) {
            emitError("Live voice unavailable: codec not loaded")
            return false
        }
        if (txRunning.get()) return true
        if (!hasMicPermission()) {
            emitError("Microphone permission is required for live voice")
            return false
        }

        val minBytes = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBytes <= 0) {
            emitError("Microphone does not support 8 kHz mono capture")
            return false
        }

        val frameSamples = samplesPerFrame
        val bufferBytes = maxOf(minBytes, frameSamples * 2 * 4)
        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferBytes,
            )
        } catch (t: Throwable) {
            emitError("Could not open the microphone: ${t.message}")
            return false
        }

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            emitError("Microphone is busy")
            return false
        }

        recorder = record
        txRunning.set(true)
        try {
            record.startRecording()
        } catch (t: Throwable) {
            txRunning.set(false)
            recorder = null
            record.release()
            emitError("Could not start recording: ${t.message}")
            return false
        }

        val thread = Thread({ txLoop(record, frameSamples) }, "codec2-tx")
        thread.isDaemon = true
        txThread = thread
        thread.start()
        emit(mapOf("type" to "started", "dir" to "tx"))
        return true
    }

    private fun txLoop(record: AudioRecord, frameSamples: Int) {
        val frame = ShortArray(frameSamples)
        val bits = ByteArray(bytesPerFrame)
        val batch = ByteArray(bytesPerFrame * FRAMES_PER_PACKET)
        var batchFrames = 0
        var peak = 0

        try {
            while (txRunning.get()) {
                var read = 0
                while (read < frameSamples && txRunning.get()) {
                    val n = record.read(frame, read, frameSamples - read)
                    if (n <= 0) break
                    read += n
                }
                if (read < frameSamples) break

                // Track a cheap peak level so the UI can show a mic meter.
                for (s in frame) {
                    val v = if (s < 0) -s.toInt() else s.toInt()
                    if (v > peak) peak = v
                }

                val written = Codec2Bridge.encode(handle, frame, bits)
                if (written != bytesPerFrame) continue

                System.arraycopy(bits, 0, batch, batchFrames * bytesPerFrame, bytesPerFrame)
                batchFrames++
                if (batchFrames < FRAMES_PER_PACKET) continue

                val payload = batch.copyOf(bytesPerFrame * batchFrames)
                txSeq = (txSeq + 1) and 0xFFFF
                emit(
                    mapOf(
                        "type" to "tx",
                        "seq" to txSeq,
                        "frames" to batchFrames,
                        "data" to payload,
                        "level" to (peak * 100 / 32767),
                    ),
                )
                peak = 0
                batchFrames = 0
            }
        } catch (t: Throwable) {
            if (txRunning.get()) emitError("Live voice transmit stopped: ${t.message}")
        } finally {
            txRunning.set(false)
            emit(mapOf("type" to "stopped", "dir" to "tx"))
        }
    }

    private fun stopTx() {
        if (!txRunning.getAndSet(false)) {
            // Thread may already have finished on its own; still make sure the
            // recorder is released.
            recorder?.let {
                try {
                    it.stop()
                } catch (_: Throwable) {
                }
                it.release()
            }
            recorder = null
            return
        }
        txThread?.join(400)
        txThread = null
        recorder?.let {
            try {
                it.stop()
            } catch (_: Throwable) {
            }
            it.release()
        }
        recorder = null
    }

    // ── Receive ─────────────────────────────────────────────────────────

    private fun startRx(): Boolean {
        if (!ensureCodec()) {
            emitError("Live voice unavailable: codec not loaded")
            return false
        }
        if (rxRunning.get()) return true

        val minBytes = AudioTrack.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBytes <= 0) {
            emitError("Speaker does not support 8 kHz mono playback")
            return false
        }

        val track = try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setBufferSizeInBytes(maxOf(minBytes, samplesPerFrame * 2 * 6))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        } catch (t: Throwable) {
            emitError("Could not open the speaker: ${t.message}")
            return false
        }

        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release()
            emitError("Speaker is unavailable")
            return false
        }

        player = track
        rxRunning.set(true)
        rxQueue.clear()
        try {
            track.play()
        } catch (t: Throwable) {
            rxRunning.set(false)
            player = null
            track.release()
            emitError("Could not start playback: ${t.message}")
            return false
        }

        val thread = Thread({ rxLoop(track) }, "codec2-rx")
        thread.isDaemon = true
        rxThread = thread
        thread.start()
        emit(mapOf("type" to "started", "dir" to "rx"))
        return true
    }

    private fun enqueueRx(data: ByteArray) {
        if (!rxRunning.get()) return
        // Drop the oldest packet instead of the newest: in a live stream the
        // freshest audio matters, and Codec2 has no cross-packet state.
        while (!rxQueue.offer(data)) {
            rxQueue.poll() ?: break
        }
    }

    private fun rxLoop(track: AudioTrack) {
        val bits = ByteArray(bytesPerFrame)
        val pcm = ShortArray(samplesPerFrame)
        try {
            while (rxRunning.get()) {
                val data = rxQueue.poll(200, java.util.concurrent.TimeUnit.MILLISECONDS)
                    ?: continue
                var offset = 0
                while (offset + bytesPerFrame <= data.size && rxRunning.get()) {
                    System.arraycopy(data, offset, bits, 0, bytesPerFrame)
                    offset += bytesPerFrame
                    if (Codec2Bridge.decode(handle, bits, pcm) != samplesPerFrame) continue
                    track.write(pcm, 0, samplesPerFrame)
                }
            }
        } catch (t: Throwable) {
            if (rxRunning.get()) emitError("Live voice playback stopped: ${t.message}")
        } finally {
            rxRunning.set(false)
            emit(mapOf("type" to "stopped", "dir" to "rx"))
        }
    }

    private fun stopRx() {
        if (!rxRunning.getAndSet(false)) {
            player?.let {
                try {
                    it.stop()
                } catch (_: Throwable) {
                }
                it.release()
            }
            player = null
            return
        }
        rxThread?.join(500)
        rxThread = null
        player?.let {
            try {
                it.stop()
            } catch (_: Throwable) {
            }
            it.release()
        }
        player = null
        rxQueue.clear()
    }

    // ── Teardown ────────────────────────────────────────────────────────

    private fun release() {
        stopTx()
        stopRx()
        if (handle != 0L) {
            Codec2Bridge.destroy(handle)
            handle = 0L
        }
        samplesPerFrame = 0
        bytesPerFrame = 0
    }

    fun dispose() {
        release()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        sink = null
    }
}
