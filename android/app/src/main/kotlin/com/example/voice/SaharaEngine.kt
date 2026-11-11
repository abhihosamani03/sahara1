package com.example.voice

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * Owns the process-wide Flutter engine.
 *
 * The engine is deliberately not tied to an Activity: emergency standby and
 * the boot receiver both need the Dart isolate (and therefore the mesh) to run
 * with no window attached. Building it in one place means the plugin and
 * channel registration order cannot drift between the two entry points.
 */
object SaharaEngine {
    private const val ENGINE_ID = "itantra_main_engine"

    @Synchronized
    fun ensure(context: Context): FlutterEngine {
        val app = context.applicationContext
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }

        val engine = FlutterEngine(app)
        GeneratedPluginRegistrant.registerWith(engine)
        SaharaChannels.register(engine, app)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
        )
        cache.put(ENGINE_ID, engine)
        return engine
    }
}
