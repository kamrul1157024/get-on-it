package app.getonit.nudge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import app.getonit.MainActivity
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/** Settings and history in SharedPreferences, written by the Flutter side. */
object NudgeStore {
    private const val PREFS = "getonit.nudges"

    fun saveConfig(ctx: Context, json: String) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("config", json).apply()

    fun config(ctx: Context): NudgeConfig {
        val raw = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("config", null) ?: return NudgeConfig()
        return try {
            val o = JSONObject(raw)
            NudgeConfig(
                enabled = o.optBoolean("enabled"),
                unlock = o.optBoolean("unlock", true),
                apps = o.optJSONArray("apps").objects().map {
                    WatchedApp(it.getString("package"), it.optString("label", it.getString("package")), it.optInt("thresholdMin", 15))
                },
                quietStartMin = o.optInt("quietStartMin", 23 * 60),
                quietEndMin = o.optInt("quietEndMin", 7 * 60),
                strength = Strength.parse(o.optString("strength")),
                pending = o.optJSONArray("pending").objects().map {
                    PendingWork(it.getString("goalId"), it.getString("title"), it.getString("body"), it.getString("link"))
                },
                equivalents = o.optJSONArray("equivalents").objects().map {
                    Equivalent(
                        it.getDouble("unitMinutes"),
                        it.getString("singular"),
                        it.getString("plural"),
                        it.optDouble("wholeMinutes", 0.0),
                        it.optString("whole", ""),
                    )
                },
                excluded = o.optJSONArray("excluded")?.let { a -> (0 until a.length()).map { a.getString(it) }.toSet() } ?: emptySet(),
            )
        } catch (e: Exception) {
            NudgeConfig()
        }
    }

    fun history(ctx: Context): NudgeHistory {
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val steps = JSONObject(p.getString("steps", "{}") ?: "{}")
        return NudgeHistory(
            day = p.getString("day", "") ?: "",
            count = p.getInt("count", 0),
            lastAtMs = p.getLong("lastAt", 0),
            appSteps = steps.keys().asSequence().associateWith { steps.getInt(it) },
            pausedUntilMs = p.getLong("pausedUntil", 0),
        )
    }

    fun saveHistory(ctx: Context, h: NudgeHistory) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("day", h.day)
            .putInt("count", h.count)
            .putLong("lastAt", h.lastAtMs)
            .putString("steps", JSONObject(h.appSteps as Map<*, *>).toString())
            .putLong("pausedUntil", h.pausedUntilMs)
            .apply()
    }

    private fun JSONArray?.objects(): List<JSONObject> =
        if (this == null) emptyList() else (0 until length()).map { getJSONObject(it) }
}

/** Runs a trigger through the rules and posts the nudge. */
object NudgeEngine {
    const val CHANNEL = "nudges"
    const val NUDGE_ID = 7001
    const val ACTION_BREAK = "app.getonit.nudge.BREAK"

    /** The app a sticky nudge is about; cleared when the user leaves it. */
    @Volatile var stickyFor: String? = null

    fun handle(ctx: Context, trigger: Trigger): Nudge? {
        val zone = ZoneId.systemDefault()
        val now = LocalTime.now(zone)
        val (nudge, history) = NudgeRules.decide(
            NudgeStore.config(ctx),
            NudgeStore.history(ctx),
            trigger,
            LocalDate.now(zone).toString(),
            System.currentTimeMillis(),
            now.hour * 60 + now.minute,
        )
        NudgeStore.saveHistory(ctx, history)
        if (nudge != null) post(ctx, nudge)
        return nudge
    }

    private fun statsSince(ctx: Context, startMs: Long): Map<String, android.app.usage.UsageStats> {
        val usm = ctx.getSystemService(UsageStatsManager::class.java) ?: return emptyMap()
        return usm.queryAndAggregateUsageStats(startMs, System.currentTimeMillis())
    }

    private fun startOf(date: LocalDate): Long = date.atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()

    private fun statsToday(ctx: Context) = statsSince(ctx, startOf(LocalDate.now()))

    /**
     * Minutes on screen. "Visible" also counts time when the app's own dialog
     * or sheet is in front, which "foreground" misses (Android 10+).
     */
    private fun minutesOf(s: android.app.usage.UsageStats?): Int {
        s ?: return 0
        val ms = if (Build.VERSION.SDK_INT >= 29) maxOf(s.totalTimeVisible, s.totalTimeInForeground) else s.totalTimeInForeground
        return (ms / 60_000L).toInt()
    }

    /**
     * Today, this month and this year, in the user's time zone. Android keeps
     * older history in coarser buckets, so a month or year can include time
     * from before the app was installed.
     */
    fun periodStarts(): Map<String, Long> {
        val today = LocalDate.now(ZoneId.systemDefault())
        return mapOf(
            "today" to startOf(today),
            "month" to startOf(today.withDayOfMonth(1)),
            "year" to startOf(today.withDayOfYear(1)),
        )
    }

    /** Minutes of foreground use today for each watched app. */
    fun usageToday(ctx: Context, apps: List<WatchedApp>): Map<String, Int> {
        val stats = statsToday(ctx)
        return apps.associate { it.packageName to minutesOf(stats[it.packageName]) }
    }

    /** Android's category of [pkg] as a word; "" when it has none or is hidden. */
    fun category(ctx: Context, pkg: String): String = try {
        when (ctx.packageManager.getApplicationInfo(pkg, 0).category) {
            ApplicationInfo.CATEGORY_SOCIAL -> "social"
            ApplicationInfo.CATEGORY_VIDEO -> "video"
            ApplicationInfo.CATEGORY_GAME -> "game"
            ApplicationInfo.CATEGORY_NEWS -> "news"
            else -> ""
        }
    } catch (e: PackageManager.NameNotFoundException) {
        ""
    }

    /** A watched app with its category, for the wording. */
    fun withCategory(ctx: Context, app: WatchedApp) = app.copy(category = category(ctx, app.packageName))

    data class AppUsage(val packageName: String, val label: String, val category: String, val minutes: Int)

    /**
     * Lost time since [startMs] (today by default), most first: social, video, game and news apps and the
     * watched ones, without the ones the user took off the list. It stays on
     * the phone.
     */
    fun lostToday(ctx: Context, config: NudgeConfig): List<AppUsage> = lostSince(ctx, config, startOf(LocalDate.now()))

    fun lostSince(ctx: Context, config: NudgeConfig, startMs: Long): List<AppUsage> {
        val watched = config.apps.associateBy { it.packageName }
        val pm = ctx.packageManager
        return statsSince(ctx, startMs).values.mapNotNull { s ->
            val pkg = s.packageName
            val minutes = minutesOf(s)
            if (pkg == ctx.packageName || pkg in config.excluded || minutes < 1) return@mapNotNull null
            val cat = category(ctx, pkg)
            if (cat !in Wording.distracting && pkg !in watched) return@mapNotNull null
            val label = watched[pkg]?.label ?: try {
                pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
            } catch (e: PackageManager.NameNotFoundException) {
                pkg
            }
            AppUsage(pkg, label, cat, minutes)
        }.sortedByDescending { it.minutes }
    }

    fun ensureChannel(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Distraction nudges", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "A short reminder of your goal when you unlock the phone or spend time in other apps"
                },
            )
        }
        if (nm.getNotificationChannel(NudgeService.SERVICE_CHANNEL) == null) {
            nm.createNotificationChannel(
                NotificationChannel(NudgeService.SERVICE_CHANNEL, "Nudge service", NotificationManager.IMPORTANCE_MIN).apply {
                    description = "Shows while distraction nudges are on"
                },
            )
        }
    }

    private fun post(ctx: Context, n: Nudge) {
        ensureChannel(ctx)
        val open = PendingIntent.getActivity(
            ctx,
            0,
            Intent(Intent.ACTION_VIEW, Uri.parse(n.work.link), ctx, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        // Push me hard: the stop screen covers the app, when Android lets it.
        if (n.stopScreen && n.app != null && android.provider.Settings.canDrawOverlays(ctx)) {
            ctx.startActivity(StopActivity.intent(ctx, n))
        }
        val breakIntent = PendingIntent.getBroadcast(
            ctx,
            1,
            Intent(ACTION_BREAK, null, ctx, NudgeBreakReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        // Without the stop screen, a hard nudge stays while the user is still
        // in the app (NudgeService.checkUsage clears it).
        val sticky = n.stopScreen && n.app != null && !android.provider.Settings.canDrawOverlays(ctx)
        stickyFor = if (sticky) n.app?.packageName else null
        val notification = Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(app.getonit.R.drawable.ic_stat_getonit)
            .setContentTitle(n.title)
            .setContentText(n.body)
            .setStyle(Notification.BigTextStyle().bigText(n.body))
            .setContentIntent(open)
            .setAutoCancel(!sticky)
            .setOngoing(sticky)
            .setCategory(if (sticky) Notification.CATEGORY_ALARM else Notification.CATEGORY_REMINDER)
            .addAction(Notification.Action.Builder(null, "Get on it", open).build())
            .addAction(Notification.Action.Builder(null, "Break 1 h", breakIntent).build())
            .build()
        ctx.getSystemService(NotificationManager::class.java).notify(NUDGE_ID, notification)
    }

    /** The app in front now, from usage events; null when unknown. */
    fun foregroundApp(ctx: Context): String? {
        val usm = ctx.getSystemService(UsageStatsManager::class.java) ?: return null
        val now = System.currentTimeMillis()
        val events = usm.queryEvents(now - 10 * 60_000L, now)
        val e = android.app.usage.UsageEvents.Event()
        var last: String? = null
        while (events.hasNextEvent()) {
            events.getNextEvent(e)
            if (e.eventType == android.app.usage.UsageEvents.Event.ACTIVITY_RESUMED) last = e.packageName
        }
        return last
    }

    fun clearSticky(ctx: Context) {
        stickyFor = null
        ctx.getSystemService(NotificationManager::class.java).cancel(NUDGE_ID)
    }
}

/** "Break 1 h" on a nudge: no nudges for an hour. */
class NudgeBreakReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != NudgeEngine.ACTION_BREAK) return
        val today = LocalDate.now(ZoneId.systemDefault()).toString()
        NudgeStore.saveHistory(ctx, NudgeStore.history(ctx).breakFor(System.currentTimeMillis(), today))
        NudgeEngine.clearSticky(ctx)
    }
}

/**
 * Listens for unlocks and checks app usage every 2 minutes while the screen
 * is on (spec §12.3). A foreground service, because Android stops plain
 * background work.
 */
class NudgeService : Service() {
    companion object {
        const val SERVICE_CHANNEL = "nudge-service"
        private const val SERVICE_ID = 7000
        private const val POLL_MS = 2 * 60_000L

        @Volatile var running = false
            private set

        fun start(ctx: Context) {
            ctx.startForegroundService(Intent(ctx, NudgeService::class.java))
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, NudgeService::class.java))
        }
    }

    private val handler = Handler(Looper.getMainLooper())

    private val poll = object : Runnable {
        override fun run() {
            checkUsage()
            handler.postDelayed(this, pollMs())
        }
    }

    private val screen = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_USER_PRESENT -> {
                    val lost = NudgeEngine.lostToday(ctx, NudgeStore.config(ctx)).sumOf { it.minutes }
                    NudgeEngine.handle(ctx, Trigger.Unlock(lost))
                }
                Intent.ACTION_SCREEN_ON -> {
                    handler.removeCallbacks(poll)
                    handler.postDelayed(poll, pollMs())
                }
                Intent.ACTION_SCREEN_OFF -> handler.removeCallbacks(poll)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        NudgeEngine.ensureChannel(this)
        val notification = Notification.Builder(this, SERVICE_CHANNEL)
            .setSmallIcon(app.getonit.R.drawable.ic_stat_getonit)
            .setContentTitle("Distraction nudges are on")
            .setContentText("Get On It reminds you of your goal when you unlock the phone.")
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(SERVICE_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(SERVICE_ID, notification)
        }
        registerReceiver(
            screen,
            IntentFilter().apply {
                addAction(Intent.ACTION_USER_PRESENT)
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_SCREEN_OFF)
            },
        )
        if (getSystemService(PowerManager::class.java).isInteractive) handler.postDelayed(poll, pollMs())
        running = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!NudgeStore.config(this).enabled) stopSelf()
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        handler.removeCallbacks(poll)
        unregisterReceiver(screen)
        super.onDestroy()
    }

    /** Push me hard checks every minute, so the stop screen is on time. */
    private fun pollMs() = if (NudgeStore.config(this).strength == Strength.HARD) 60_000L else POLL_MS

    private fun checkUsage() {
        val config = NudgeStore.config(this)
        NudgeEngine.stickyFor?.let { if (NudgeEngine.foregroundApp(this) != it) NudgeEngine.clearSticky(this) }
        if (!config.enabled || config.apps.isEmpty()) return
        val minutes = NudgeEngine.usageToday(this, config.apps)
        for (app in config.apps) {
            val usage = Trigger.Usage(NudgeEngine.withCategory(this, app), minutes[app.packageName] ?: 0)
            if (NudgeEngine.handle(this, usage) != null) return
        }
    }
}

/** Starts the service again after a restart, if nudges are on. */
class NudgeBootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED && NudgeStore.config(ctx).enabled) NudgeService.start(ctx)
    }
}
