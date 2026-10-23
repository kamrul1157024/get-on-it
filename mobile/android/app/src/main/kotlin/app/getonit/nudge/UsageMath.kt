package app.getonit.nudge

/** One app event, reduced to what the math needs. */
data class UsageEvent(val pkg: String, val cls: String, val timeMs: Long, val kind: Kind) {
    enum class Kind {
        /** An activity came to the front (or, before Android 10, the app did). */
        RESUMED,

        /** An activity lost focus; it may still be visible. */
        PAUSED,

        /** An activity is no longer visible (or, before Android 10, the app left the front). */
        STOPPED,

        /** The screen went off or the phone shut down: nothing is visible. */
        ALL_HIDDEN,

        /**
         * The phone started. If it lost power or was killed, no shutdown event
         * came, and apps open before still look visible.
         */
        DEVICE_STARTUP,
    }
}

/** One stored Android usage bucket: its time range and each app's time in it. */
data class UsageBucket(val startMs: Long, val endMs: Long, val msByPackage: Map<String, Long>)

/**
 * Time on screen per app, cut exactly to a time range. Pure, so it is unit
 * tested on the JVM.
 *
 * Android's queryAndAggregateUsageStats adds up whole stored buckets that
 * overlap the range, so "today" right after midnight included all of
 * yesterday. Today is therefore counted from app events, and longer periods
 * only from buckets that lie fully inside them.
 */
object UsageMath {
    /**
     * Visible time per app within [fromMs, toMs]. An app counts as visible
     * from the time one of its activities comes to the front until none of
     * them is visible any more, so its own dialog in front still counts and
     * two of its activities never count twice. Events may start before
     * [fromMs]; an app still visible at [toMs] counts until [toMs].
     */
    fun visibleMs(events: List<UsageEvent>, fromMs: Long, toMs: Long, windowStartMs: Long = fromMs): Map<String, Long> {
        val visible = mutableMapOf<String, MutableSet<String>>()
        val since = mutableMapOf<String, Long>()
        val total = mutableMapOf<String, Long>()
        val firstEventMs = mutableMapOf<String, Long>()
        var lastEventMs = windowStartMs
        val opened = mutableSetOf<String>()
        // The last screen-off or restart: nothing was visible across it.
        var lastHiddenMs = Long.MIN_VALUE

        fun add(pkg: String, start: Long, end: Long) {
            val s = maxOf(start, fromMs)
            val e = minOf(end, toMs)
            if (e > s) total[pkg] = (total[pkg] ?: 0L) + (e - s)
        }

        fun close(pkg: String, at: Long) {
            since.remove(pkg)?.let { add(pkg, it, at) }
            visible.remove(pkg)
        }

        for (ev in events.sortedBy { it.timeMs }) {
            val firstSeen = firstEventMs.getOrPut(ev.pkg) { ev.timeMs }
            when (ev.kind) {
                UsageEvent.Kind.RESUMED -> {
                    val set = visible.getOrPut(ev.pkg) { mutableSetOf() }
                    if (set.isEmpty() && ev.pkg !in since) since[ev.pkg] = ev.timeMs
                    set += ev.cls
                    opened += ev.pkg
                }
                UsageEvent.Kind.STOPPED -> {
                    val set = visible[ev.pkg]
                    if (set == null) {
                        // A stop with no start: Android does not always log
                        // the resume. Count only from this app's first event
                        // in the window, never from the window start (that
                        // read 2 minutes of YouTube as "16 h 26 min"). Older
                        // time may count low, never high.
                        if (ev.pkg !in opened) add(ev.pkg, maxOf(firstSeen, lastHiddenMs), ev.timeMs)
                    } else {
                        set -= ev.cls
                        if (set.isEmpty()) close(ev.pkg, ev.timeMs)
                    }
                }
                UsageEvent.Kind.PAUSED -> {}
                UsageEvent.Kind.ALL_HIDDEN -> {
                    for (pkg in since.keys.toList()) close(pkg, ev.timeMs)
                    lastHiddenMs = ev.timeMs
                }
                // When the phone went off is unknown: end open sessions at the
                // last event before the restart. That can count a little low,
                // never the hours the phone was off.
                UsageEvent.Kind.DEVICE_STARTUP -> {
                    for (pkg in since.keys.toList()) close(pkg, lastEventMs)
                    lastHiddenMs = ev.timeMs
                }
            }
            lastEventMs = ev.timeMs
        }
        for (pkg in since.keys.toList()) close(pkg, toMs)
        return total
    }

    /**
     * Time per app from stored buckets that lie fully inside [fromMs, toMs].
     * A bucket that starts before [fromMs] or ends after [toMs] is never
     * counted, and buckets never overlap: the longest ones are taken first,
     * then shorter ones fill the gaps. Days with no bucket fully inside are
     * left out, so the result can be lower than real use, never higher.
     */
    fun bucketMs(buckets: List<UsageBucket>, fromMs: Long, toMs: Long): Map<String, Long> {
        val chosen = mutableListOf<UsageBucket>()
        val candidates = buckets
            .filter { it.startMs >= fromMs && it.endMs <= toMs && it.endMs > it.startMs }
            .sortedWith(compareByDescending<UsageBucket> { it.endMs - it.startMs }.thenBy { it.startMs })
        for (b in candidates) {
            if (chosen.none { it.startMs < b.endMs && b.startMs < it.endMs }) chosen += b
        }
        val total = mutableMapOf<String, Long>()
        for (b in chosen) for ((pkg, ms) in b.msByPackage) total[pkg] = (total[pkg] ?: 0L) + ms
        return total
    }

    fun sum(a: Map<String, Long>, b: Map<String, Long>): Map<String, Long> =
        (a.keys + b.keys).associateWith { (a[it] ?: 0L) + (b[it] ?: 0L) }
}
