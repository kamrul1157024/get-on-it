package app.getonit

import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hands shared text, opened files and getonit:// links to Dart as a string
 * (lib/features/intents/incoming.dart). Dart decides what the string is.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var initialText: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) initialText = readIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.getonit/intents").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialText" -> {
                        result.success(initialText)
                        initialText = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.getonit/system").setMethodCallHandler { call, result ->
            when (call.method) {
                "canUseFullScreenIntent" -> result.success(
                    if (Build.VERSION.SDK_INT >= 34) getSystemService(NotificationManager::class.java).canUseFullScreenIntent() else true
                )
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        readIntent(intent)?.let { channel?.invokeMethod("onText", it) }
    }

    private fun readIntent(intent: Intent?): String? {
        intent ?: return null
        return when (intent.action) {
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT) ?: streamOf(intent)?.let(::readUri)
            Intent.ACTION_VIEW -> intent.data?.let { uri ->
                if (uri.scheme == "getonit") uri.toString() else readUri(uri)
            }
            else -> null
        }
    }

    @Suppress("DEPRECATION")
    private fun streamOf(intent: Intent): Uri? = intent.getParcelableExtra(Intent.EXTRA_STREAM)

    /** Plans are small. Anything over 1 MB is refused here, as in the validator. */
    private fun readUri(uri: Uri): String? = try {
        contentResolver.openInputStream(uri)?.use { input ->
            val bytes = input.readBytes()
            if (bytes.size > 1024 * 1024) null else String(bytes, Charsets.UTF_8)
        }
    } catch (e: Exception) {
        null
    }
}
