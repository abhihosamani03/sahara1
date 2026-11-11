package com.example.voice

import android.util.Log

/**
 * Thin JNI surface over the vendored Codec2 1.2.0 library.
 *
 * The codec object is a native pointer; callers must own exactly one handle and
 * call [destroy] when done. All methods are cheap except create/destroy.
 */
object Codec2Bridge {
    private const val TAG = "Codec2Bridge"

    /** Codec2 mode constant from codec2.h: 3200 bps, 20 ms / 8 byte frames. */
    const val MODE_3200 = 0

    private val loaded: Boolean = try {
        System.loadLibrary("sahara_codec2")
        Log.i(TAG, "codec2 native library loaded")
        true
    } catch (t: Throwable) {
        // A missing .so must degrade to "live voice unavailable", never crash
        // the app: the rest of the mesh works without it.
        Log.w(TAG, "codec2 native library unavailable: ${t.message}")
        false
    }

    val isAvailable: Boolean get() = loaded

    external fun modeSupported(mode: Int): Int
    external fun create(mode: Int): Long
    external fun destroy(handle: Long)
    external fun samplesPerFrame(handle: Long): Int
    external fun bytesPerFrame(handle: Long): Int
    external fun encode(handle: Long, pcm: ShortArray, bits: ByteArray): Int
    external fun decode(handle: Long, bits: ByteArray, pcm: ShortArray): Int
}
