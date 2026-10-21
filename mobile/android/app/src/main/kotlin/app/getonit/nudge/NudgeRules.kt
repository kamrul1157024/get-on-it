package app.getonit.nudge

/** Work that is still open today, sent by the Flutter side. */
data class PendingWork(val goalId: String, val title: String, val body: String, val link: String)

/** An app the user chose to watch, with a daily threshold in minutes. */
data class WatchedApp(val packageName: String, val label: String, val thresholdMin: Int)

/** The nudge settings and today's open work (spec §12). */
data class NudgeConfig(
    val enabled: Boolean = false,
    val unlock: Boolean = true,
    val apps: List<WatchedApp> = emptyList(),
    val quietStartMin: Int = 23 * 60,
    val quietEndMin: Int = 7 * 60,
    val maxPerDay: Int = 4,
    val minGapMin: Int = 120,
    val pending: List<PendingWork> = emptyList(),
)

/** What happened today, kept by the service. */
data class NudgeHistory(
    val day: String = "",
    val count: Int = 0,
    val lastAtMs: Long = 0,
    /** Package → the multiple of its threshold already nudged for today. */
    val appSteps: Map<String, Int> = emptyMap(),
)

sealed interface Trigger {
    data object Unlock : Trigger

    /** [minutesToday] of foreground use of [app] today. */
    data class Usage(val app: WatchedApp, val minutesToday: Int) : Trigger
}

data class Nudge(val work: PendingWork, val title: String, val body: String)

/**
 * Decides whether to nudge. Pure, so it is unit tested on the JVM.
 *
 * Rules: nudges are on; there is open work; not in quiet hours; at most
 * [NudgeConfig.maxPerDay] a day and one per [NudgeConfig.minGapMin]. An app
 * nudges once each time its use passes another multiple of its threshold.
 */
object NudgeRules {
    fun isQuiet(c: NudgeConfig, minuteOfDay: Int): Boolean =
        if (c.quietStartMin > c.quietEndMin) minuteOfDay >= c.quietStartMin || minuteOfDay < c.quietEndMin
        else minuteOfDay >= c.quietStartMin && minuteOfDay < c.quietEndMin

    fun decide(
        c: NudgeConfig,
        history: NudgeHistory,
        trigger: Trigger,
        today: String,
        nowMs: Long,
        minuteOfDay: Int,
    ): Pair<Nudge?, NudgeHistory> {
        val h = if (history.day == today) history else NudgeHistory(day = today)
        if (!c.enabled || c.pending.isEmpty() || isQuiet(c, minuteOfDay)) return null to h
        if (h.count >= c.maxPerDay) return null to h
        if (h.lastAtMs > 0 && nowMs - h.lastAtMs < c.minGapMin * 60_000L) return null to h

        val work = c.pending.first()
        return when (trigger) {
            is Trigger.Unlock -> {
                if (!c.unlock) return null to h
                Nudge(work, work.title, work.body) to h.copy(count = h.count + 1, lastAtMs = nowMs)
            }
            is Trigger.Usage -> {
                val app = trigger.app
                if (app.thresholdMin <= 0) return null to h
                val step = trigger.minutesToday / app.thresholdMin
                val done = h.appSteps[app.packageName] ?: 0
                if (step <= done) return null to h
                val nudge = Nudge(work, "${trigger.minutesToday} min on ${app.label}", work.body)
                nudge to h.copy(
                    count = h.count + 1,
                    lastAtMs = nowMs,
                    appSteps = h.appSteps + (app.packageName to step),
                )
            }
        }
    }
}
