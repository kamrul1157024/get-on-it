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
 * of 75 min, one page of 2 min. Lost time is told in these units. [whole] is
 * the whole goal ("the whole course", [wholeMinutes] long), told once the
 * time is bigger than it.
 */
data class Equivalent(
    val unitMinutes: Double,
    val singular: String,
    val plural: String,
    val wholeMinutes: Double = 0.0,
    val whole: String = "",
)

/**
 * How hard the nudges push. The limits and the tone follow it; only
 * [HARD] puts a stop screen over a watched app past its limit.
 */
enum class Strength(val maxPerDay: Int, val minGapMin: Int) {
    GENTLE(2, 180),
    FIRM(4, 120),
    HARD(12, 20);

    companion object {
        fun parse(s: String?): Strength = when (s) {
            "gentle" -> GENTLE
            "hard" -> HARD
            else -> FIRM
        }
    }
}

/** The nudge settings and today's open work (spec §12). */
data class NudgeConfig(
    val enabled: Boolean = false,
    val unlock: Boolean = true,
    val apps: List<WatchedApp> = emptyList(),
    val quietStartMin: Int = 23 * 60,
    val quietEndMin: Int = 7 * 60,
    val strength: Strength = Strength.FIRM,
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
    /** "Break 1 h": no nudges before this time. */
    val pausedUntilMs: Long = 0,
)

sealed interface Trigger {
    /** [lostMinutes] today in distracting apps, when usage access is on. */
    data class Unlock(val lostMinutes: Int = 0) : Trigger

    /** [minutesToday] of foreground use of [app] today. */
    data class Usage(val app: WatchedApp, val minutesToday: Int) : Trigger
}

/**
 * [stopScreen]: cover the app with the stop screen ([Strength.HARD], a
 * watched app past its limit); [app] is that app.
 */
data class Nudge(
    val work: PendingWork,
    val title: String,
    val body: String,
    val stopScreen: Boolean = false,
    val app: WatchedApp? = null,
    val minutes: Int = 0,
)

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
            val units = when {
                n <= 0 -> return@mapNotNull null
                n == 1 -> "1 ${e.singular}"
                else -> "$n ${e.plural}"
            }
            val times = if (e.wholeMinutes > 0 && e.whole.isNotEmpty()) (minutes / e.wholeMinutes).toInt() else 0
            when {
                times <= 0 -> units
                times == 1 -> "$units, or ${e.whole}"
                else -> "$units, or ${e.whole} $times times"
            }
        }
        return if (parts.isEmpty()) null else parts.joinToString(", or ")
    }

    fun usageTitle(app: WatchedApp, minutes: Int, strength: Strength = Strength.FIRM) = when (strength) {
        Strength.GENTLE -> "Ready for your goal?"
        Strength.FIRM -> "${duration(minutes)} ${doing(app.category, app.label)} today"
        Strength.HARD -> "${duration(minutes)} burned on ${app.label}"
    }

    fun usageBody(
        minutes: Int,
        equivalents: List<Equivalent>,
        work: PendingWork,
        app: WatchedApp? = null,
        strength: Strength = Strength.FIRM,
    ): String {
        val could = couldHave(minutes, equivalents)
        return when (strength) {
            Strength.GENTLE -> "${duration(minutes)} on ${app?.label ?: "other apps"} so far. ${work.title} is waiting."
            Strength.FIRM -> could?.let { "That was $it. Do the thing." } ?: work.body
            Strength.HARD -> (could?.let { "That was $it." } ?: "${work.title} is still open.") + " Close it. Do the thing."
        }
    }

    /** "45 min lost today. One CS229 lecture is 1 h 15 min." before the work. */
    fun unlockBody(
        lostMinutes: Int,
        equivalents: List<Equivalent>,
        workBody: String,
        strength: Strength = Strength.FIRM,
    ): String {
        if (strength == Strength.GENTLE || lostMinutes < UNLOCK_MIN) return workBody
        if (strength == Strength.HARD) {
            val that = couldHave(lostMinutes, equivalents)?.let { " That is $it." } ?: ""
            return "${duration(lostMinutes)} lost today.$that Close it and do the thing. $workBody"
        }
        val lost = "${duration(lostMinutes)} lost today."
        val compare = couldHave(lostMinutes, equivalents)?.let { "That is $it." }
            ?: equivalents.firstOrNull()?.let { "One ${it.singular} is ${duration(Math.round(it.unitMinutes).toInt())}." }
        return listOfNotNull(lost, compare, workBody).joinToString(" ")
    }
}

/**
 * Decides whether to nudge. Pure, so it is unit tested on the JVM.
 *
 * Rules: nudges are on; there is open work (done for today stops them); not
 * in quiet hours or a break; at most [Strength.maxPerDay] a day and one per
 * [Strength.minGapMin]. An app nudges once each time its use passes another
 * multiple of its threshold.
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
        if (nowMs < h.pausedUntilMs) return null to h
        if (h.count >= c.strength.maxPerDay) return null to h
        if (h.lastAtMs > 0 && nowMs - h.lastAtMs < c.strength.minGapMin * 60_000L) return null to h

        val work = c.pending.first()
        return when (trigger) {
            is Trigger.Unlock -> {
                if (!c.unlock) return null to h
                val body = Wording.unlockBody(trigger.lostMinutes, c.equivalents, work.body, c.strength)
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
                    Wording.usageTitle(app, trigger.minutesToday, c.strength),
                    Wording.usageBody(trigger.minutesToday, c.equivalents, work, app, c.strength),
                    stopScreen = c.strength == Strength.HARD,
                    app = app,
                    minutes = trigger.minutesToday,
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

/** "Break 1 h" from a nudge notification. */
fun NudgeHistory.breakFor(nowMs: Long, today: String, hours: Int = 1): NudgeHistory =
    (if (day == today) this else NudgeHistory(day = today)).copy(pausedUntilMs = nowMs + hours * 3_600_000L)
