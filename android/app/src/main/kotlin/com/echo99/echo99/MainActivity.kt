package com.echo99.echo99

import android.app.PictureInPictureParams
import android.content.Intent
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /** True while the player sits at a table (set by the table service). */
    private var atTable = false

    /**
     * Leaving the app (Home / app switch) while at a table enters
     * picture-in-picture so the game, voice room and timers keep running.
     */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (!atTable || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            enterPictureInPictureMode(
                PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(9, 16))
                    .build()
            )
        } catch (_: Exception) {
            // PiP disabled by the user or unsupported: the FGS keeps us alive.
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "echo99/table_service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val title = call.argument<String>("title") ?: "Echo99"
                        val intent = Intent(this, TableVoiceService::class.java)
                            .putExtra(TableVoiceService.EXTRA_TITLE, title)
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            atTable = true
                            result.success(true)
                        } catch (e: Exception) {
                            atTable = true
                            result.success(false)
                        }
                    }
                    "stop" -> {
                        atTable = false
                        stopService(Intent(this, TableVoiceService::class.java))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
