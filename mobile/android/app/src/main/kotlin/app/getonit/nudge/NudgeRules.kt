package app.getonit.nudge

/** Work that is still open today, sent by the Flutter side. */
data class PendingWork(val goalId: String, val title: String, val body: String, val link: String)

/**
 * An app the user chose to watch, with a daily threshold in minutes.
 * [category] is Android's app category ("social", "video", "game", "news",
 * or ""), read on the phone; it picks the wording.
 */
data class WatchedApp(val packageName: String, val label: String, val thresholdMin: Int, val category: String = "")

/**
 * What one unit of an open goal takes, sent by the Flutter side: one lecture
 * of 75 min, one page of 2 min. Lost time is told in these units.
 */
data class Equivalent(val unitMinutes: Double, val singular: String, val plural: String)

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
    /** At most two, the goals most behind first. */
    val equivalents: List<Equivalent> = emptyList(),
    /** Packages the user took off the distracting list. */
    val excluded: Set<String> = emptySet(),
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
    /** [lostMinutes] today in distracting apps, when usage access is on. */
    data class Unlock(val lostMinutes: Int = 0) : Trigger

    /** [minutesToday] of foreground use of [app] today. */
    data class Usage(val app: WatchedApp, val minutesToday: Int) : Trigger
}

data class Nudge(val work: PendingWork, val title: String, val body: String)

/**
 * Words for lost time. Pure; the Flutter side has the same rules for the
 * Today card (lib/features/nudges/wasted_time.dart).
 */
object Wording {
    /** Categories whose time counts as lost. */
    val distracting = setOf("social", "video", "game", "news")

    /** The unlock nudge mentions lost time from this much on. */
    const val UNLOCK_MIN = 30

    fun duration(minutes: Int): String {
        val h = minutes / 60
        val m = minutes % 60
        return when {
            h == 0 -> "$m min"
            m == 0 -> "$h h"
            else -> "$h h $m min"
        }
    }

    /** "scrolling Instagram", "watching YouTube", "on Chrome". */
    fun doing(category: String, label: String): String = when (category) {
        "social" -> "scrolling $label"
        "video" -> "watching $label"
        "game" -> "playing $label"
        "news" -> "reading news on $label"
        else -> "on $label"
    }

    /** "2 CS229 lectures, or 40 pages of Atomic Habits"; null when no unit fits even once. */
    fun couldHave(minutes: Int, equivalents: List<Equivalent>): String? {
        val parts = equivalents.take(2).mapNotNull { e ->
            if (e.unitMinutes <= 0) return@mapNotNull null
            val n = (minutes / e.unitMinutes).toInt()
            when {
                n <= 0 -> null
                n == 1 -> "1 ${e.singular}"
                else -> "$n ${e.plural}"
            }
        }
        return if (parts.isEmpty()) null else parts.joinToString(", or ")
    }

    fun usageTitle(app: WatchedApp, minutes: Int) = "${duration(minutes)} ${doing(app.category, app.label)} today"

    fun usageBody(minutes: Int, equivalents: List<Equivalent>, fallback: String): String =
        couldHave(minutes, equivalents)?.let { "That was $it. Do the thing." } ?: fallback

    /** "45 min lost today. One CS229 lecture is 1 h 15 min." before the work. */
    fun unlockBody(lostMinutes: Int, equivalents: List<Equivalent>, workBody: String): String {
        if (lostMinutes < UNLOCK_MIN) return workBody
        val lost = "${duration(lostMinutes)} lost today."
        val compare = couldHave(lostMinutes, equivalents)?.let { "That is $it." }
            ?: equivalents.firstOrNull()?.let { "One ${it.singular} is ${duration(Math.round(it.unitMinutes).toInt())}." }
        return listOfNotNull(lost, compare, workBody).joinToString(" ")
    }
}

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
                val body = Wording.unlockBody(trigger.lostMinutes, c.equivalents, work.body)
                Nudge(work, work.title, body) to h.copy(count = h.count + 1, lastAtMs = nowMs)
            }
            is Trigger.Usage -> {
                val app = trigger.app
                if (app.thresholdMin <= 0) return null to h
                val step = trigger.minutesToday / app.thresholdMin
                val done = h.appSteps[app.packageName] ?: 0
                if (step <= done) return null to h
                val nudge = Nudge(
                    work,
                    Wording.usageTitle(app, trigger.minutesToday),
                    Wording.usageBody(trigger.minutesToday, c.equivalents, work.body),
                )
                nudge to h.copy(
                    count = h.count + 1,
                    lastAtMs = nowMs,
                    appSteps = h.appSteps + (app.packageName to step),
                )
            }
        }
    }
}
