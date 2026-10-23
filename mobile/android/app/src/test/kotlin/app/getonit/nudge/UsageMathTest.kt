package app.getonit.nudge

import app.getonit.nudge.UsageEvent.Kind.ALL_HIDDEN
import app.getonit.nudge.UsageEvent.Kind.DEVICE_STARTUP
import app.getonit.nudge.UsageEvent.Kind.PAUSED
import app.getonit.nudge.UsageEvent.Kind.RESUMED
import app.getonit.nudge.UsageEvent.Kind.STOPPED
import org.junit.Assert.assertEquals
import org.junit.Test

class UsageMathTest {
    private val min = 60_000L
    private val hour = 60 * min
    private val day = 24 * hour

    // Midnight of "today"; times are minutes from it (negative: yesterday).
    private val midnight = 100 * day
    private fun at(minutes: Int) = midnight + minutes * min
    private fun ev(pkg: String, minutes: Int, kind: UsageEvent.Kind, cls: String = "Main") =
        UsageEvent(pkg, cls, at(minutes), kind)

    private val insta = "com.instagram.android"
    private val yt = "com.google.android.youtube"

    @Test fun justAfterMidnightOnlyTodaysMinutesCount() {
        // 12:15 AM. Yesterday: 2 h 35 min of Instagram in the evening, and a
        // YouTube session from 11:50 PM to 12:10 AM.
        val events = listOf(
            ev(insta, -300, RESUMED), ev(insta, -145, STOPPED),
            ev(yt, -10, RESUMED), ev(yt, 10, STOPPED),
        )
        val ms = UsageMath.visibleMs(events, fromMs = midnight, toMs = at(15), windowStartMs = at(-180))
        assertEquals(null, ms[insta])
        assertEquals(10 * min, ms[yt])
    }

    @Test fun aStopWithNoStartNeverCountsFromTheWindowStart() {
        // Android did not log YouTube's resume: only a pause at 4:24 PM and a
        // stop at 4:26 PM. That is 2 minutes, not "since 9 PM yesterday".
        val events = listOf(ev(yt, 16 * 60 + 24, PAUSED), ev(yt, 16 * 60 + 26, STOPPED))
        val ms = UsageMath.visibleMs(events, fromMs = midnight, toMs = at(16 * 60 + 29), windowStartMs = at(-180))
        assertEquals(2 * min, ms[yt])
        // A stop as the app's only event counts nothing: its start is unknown.
        val only = UsageMath.visibleMs(listOf(ev(yt, 20, STOPPED)), midnight, at(30), windowStartMs = at(-180))
        assertEquals(null, only[yt])
    }

    @Test fun twoActivitiesOfOneAppCountOnce() {
        val events = listOf(
            ev(insta, 0, RESUMED, "Feed"),
            ev(insta, 5, RESUMED, "Story"),
            ev(insta, 6, STOPPED, "Feed"),
            ev(insta, 12, STOPPED, "Story"),
        )
        assertEquals(12 * min, UsageMath.visibleMs(events, midnight, at(60))[insta])
    }

    @Test fun anAppStillOnScreenCountsUntilNow() {
        val events = listOf(ev(yt, 30, RESUMED))
        assertEquals(15 * min, UsageMath.visibleMs(events, midnight, at(45))[yt])
    }

    @Test fun screenOffClosesEverything() {
        val events = listOf(
            ev(insta, 10, RESUMED),
            UsageEvent("android", "", at(25), ALL_HIDDEN),
            // A late STOPPED after the screen went off adds nothing.
            ev(insta, 40, STOPPED),
        )
        assertEquals(15 * min, UsageMath.visibleMs(events, midnight, at(60))[insta])
    }

    @Test fun eventsOutOfOrderAreSorted() {
        val events = listOf(ev(yt, 20, STOPPED), ev(yt, 5, RESUMED))
        assertEquals(15 * min, UsageMath.visibleMs(events, midnight, at(60))[yt])
    }

    private fun bucket(startDay: Int, days: Int, vararg ms: Pair<String, Long>) =
        UsageBucket(midnight + startDay * day, midnight + (startDay + days) * day, mapOf(*ms))

    @Test fun aBucketThatStartsBeforeThePeriodIsNeverCounted() {
        // The month started 10 days ago. A weekly bucket that began 12 days
        // ago overlaps the 1st: leave it out, even though it holds time.
        val monthStart = midnight - 10 * day
        val buckets = listOf(
            bucket(-12, 7, insta to 5 * hour),
            bucket(-5, 1, insta to 1 * hour),
            bucket(-1, 1, insta to 2 * hour),
        )
        assertEquals(3 * hour, UsageMath.bucketMs(buckets, monthStart, midnight)[insta])
    }

    @Test fun aBucketThatReachesPastTheEndIsNeverCounted() {
        // Today's in-progress daily bucket and this month's bucket both reach
        // past midnight: today comes from events instead.
        val buckets = listOf(bucket(-3, 4, yt to 4 * hour), bucket(0, 1, yt to 1 * hour), bucket(-1, 1, yt to 30 * min))
        assertEquals(30 * min, UsageMath.bucketMs(buckets, midnight - 3 * day, midnight)[yt])
    }

    @Test fun dailyWeeklyAndMonthlyBucketsAreNotCountedTwice() {
        // Last month (30 days) is one monthly bucket; the same days also come
        // as weekly and daily buckets. Count the month once, then fill the
        // days after it.
        val yearStart = midnight - 200 * day
        val buckets = listOf(
            bucket(-40, 30, insta to 30 * hour),
            bucket(-40, 7, insta to 7 * hour),
            bucket(-12, 1, insta to 1 * hour), // inside the month: skipped
            bucket(-10, 7, insta to 3 * hour),
            bucket(-4, 1, insta to 1 * hour), // inside that week: skipped
            bucket(-2, 1, insta to 2 * hour),
            bucket(-1, 1, insta to 2 * hour),
            bucket(-1, 1, insta to 2 * hour), // the same day reported twice
        )
        assertEquals((30 + 3 + 2 + 2) * hour, UsageMath.bucketMs(buckets, yearStart, midnight)[insta])
    }

    @Test fun periodTotalIsBucketsPlusToday() {
        val total = UsageMath.sum(mapOf(insta to 2 * hour), mapOf(insta to 10 * min, yt to 5 * min))
        assertEquals(2 * hour + 10 * min, total[insta])
        assertEquals(5 * min, total[yt])
    }

    @Test fun aPhoneThatLostPowerDoesNotCountTheHoursItWasOff() {
        // YouTube open at 9 PM, then the battery died: no stop and no shutdown
        // event. The phone started again at 2 PM; YouTube ran 2:04-2:06 PM.
        // Seen on an emulator as "16 h 26 min" lost today.
        val startup = UsageEvent("android", "", at(14 * 60), DEVICE_STARTUP)
        val events = listOf(
            ev(yt, -180, RESUMED),
            startup,
            ev(insta, 14 * 60 + 1, STOPPED),
            ev(yt, 14 * 60 + 4, RESUMED), ev(yt, 14 * 60 + 6, STOPPED),
        )
        val ms = UsageMath.visibleMs(events, fromMs = midnight, toMs = at(16 * 60 + 26), windowStartMs = at(-180))
        assertEquals(2 * min, ms[yt])
        // A stop right after the restart is not "visible since the window began".
        assertEquals(null, ms[insta])
    }
}
