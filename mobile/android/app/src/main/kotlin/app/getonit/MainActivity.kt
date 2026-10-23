package app.getonit

import android.app.AppOpsManager
import android.app.NotificationManager
import android.content.Intent
import android.content.ActivityNotFoundException
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
                    NudgeEngine.dropStale(this)
                    if (NudgeStore.config(this).enabled) NudgeService.start(this) else NudgeService.stop(this)
                    result.success(null)
                }
                // Lost time today, this month and this year for the Today card;
                // it stays on the phone.
                "lostTime" -> {
                    if (!hasUsageAccess()) {
                        result.success(emptyMap<String, Any>())
                    } else {
                        // The exclusions come with the call: the stored copy can lag a
                        // just-made change.
                        val excluded = (call.arguments as? List<*>)?.filterIsInstance<String>()?.toSet()
                        val config = NudgeStore.config(this).let { c -> excluded?.let { c.copy(excluded = it) } ?: c }
                        result.success(
                            NudgeEngine.periodStarts().mapValues { (_, start) ->
                                NudgeEngine.lostSince(this, config, start).map {
                                    mapOf("package" to it.packageName, "label" to it.label, "category" to it.category, "minutes" to it.minutes)
                                }
                            },
                        )
                    }
                }
                // Push me hard: the stop screen needs "Display over other apps".
                "canDrawOverlays" -> result.success(Settings.canDrawOverlays(this))
                "openOverlaySettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }
                "nudgeStatus" -> result.success(mapOf("running" to NudgeService.running, "usageAccess" to hasUsageAccess()))
                // The phone's backup page (Google account backup). Names vary by
                // maker, so the first one that the phone has wins.
                "openBackupSettings" -> {
                    val candidates = listOf(
                        Intent("com.android.settings.BACKUP_SETTINGS"),
                        Intent(Settings.ACTION_PRIVACY_SETTINGS),
                        Intent(Settings.ACTION_SETTINGS),
                    )
                    val intent = candidates.first { it.resolveActivity(packageManager) != null }
                    startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "openUsageAccessSettings" -> {
                    // Straight to this app's switch where the phone supports it.
                    val direct = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS, Uri.parse("package:$packageName"))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    try {
                        startActivity(direct)
                    } catch (e: ActivityNotFoundException) {
                        startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }
                    result.success(null)
                }
                // App info: where "Allow restricted settings" is, for an app
                // installed from a downloaded APK (Android 13+).
                "openAppDetails" -> {
                    startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
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
                            val pkg = args["package"] as String
                            Trigger.Usage(
                                WatchedApp(
                                    pkg,
                                    args["label"] as String,
                                    (args["thresholdMin"] as Number).toInt(),
                                    args["category"] as String? ?: NudgeEngine.category(this, pkg),
                                ),
                                (args["minutes"] as Number).toInt(),
                            )
                        } else {
                            Trigger.Unlock((args["lostMinutes"] as Number?)?.toInt() ?: 0)
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
