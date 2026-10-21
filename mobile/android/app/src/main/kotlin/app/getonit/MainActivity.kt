package app.getonit

import android.app.AppOpsManager
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.provider.Settings
import app.getonit.nudge.NudgeEngine
import app.getonit.nudge.NudgeService
import app.getonit.nudge.NudgeStore
import app.getonit.nudge.Trigger
import app.getonit.nudge.WatchedApp
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
                // Distraction nudges (spec §12): the Flutter side sends the
                // settings and today's open work; the service does the rest.
                "nudgeConfigure" -> {
                    NudgeStore.saveConfig(this, call.arguments as String)
                    if (NudgeStore.config(this).enabled) NudgeService.start(this) else NudgeService.stop(this)
                    result.success(null)
                }
                "nudgeStatus" -> result.success(mapOf("running" to NudgeService.running, "usageAccess" to hasUsageAccess()))
                "openUsageAccessSettings" -> {
                    startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "listApps" -> {
                    val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                    val apps = packageManager.queryIntentActivities(launcher, 0)
                        .map { it.activityInfo.packageName to it.loadLabel(packageManager).toString() }
                        .filter { it.first != packageName }
                        .distinctBy { it.first }
                        .sortedBy { it.second.lowercase() }
                        .map { mapOf("package" to it.first, "label" to it.second) }
                    result.success(apps)
                }
                // Debug builds only: run a trigger through the real rules and
                // notification code, for the e2e tests.
                "nudgeSimulate" -> {
                    if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
                        result.error("debug-only", "Not available in release builds", null)
                    } else {
                        val args = call.arguments as Map<*, *>
                        val trigger = if (args["trigger"] == "usage") {
                            Trigger.Usage(
                                WatchedApp(args["package"] as String, args["label"] as String, (args["thresholdMin"] as Number).toInt()),
                                (args["minutes"] as Number).toInt(),
                            )
                        } else {
                            Trigger.Unlock
                        }
                        val n = NudgeEngine.handle(this, trigger)
                        result.success(n?.let { mapOf("title" to it.title, "body" to it.body, "link" to it.work.link) })
                    }
                }
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

    private fun hasUsageAccess(): Boolean {
        val ops = getSystemService(AppOpsManager::class.java)
        return ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, android.os.Process.myUid(), packageName) ==
            AppOpsManager.MODE_ALLOWED
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
