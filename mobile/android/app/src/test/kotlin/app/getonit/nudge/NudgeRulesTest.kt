package app.getonit.nudge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class NudgeRulesTest {
    private val work = PendingWork("atomic-habits", "Read Atomic Habits", "Read p. 45–46 · ≈ 4 min", "getonit://start/atomic-habits")
    private val insta = WatchedApp("com.instagram.android", "Instagram", 15)
    private val base = NudgeConfig(enabled = true, apps = listOf(insta), pending = listOf(work))
    private val noon = 12 * 60
    private val t0 = 1_800_000_000_000L

    private fun decide(c: NudgeConfig = base, h: NudgeHistory = NudgeHistory(), trigger: Trigger = Trigger.Unlock, nowMs: Long = t0, minute: Int = noon) =
        NudgeRules.decide(c, h, trigger, "2026-10-21", nowMs, minute)

    @Test fun unlockNudgesWithTheFirstOpenWork() {
        val (nudge, h) = decide()
        assertNotNull(nudge)
        assertEquals("Read Atomic Habits", nudge!!.title)
        assertEquals("getonit://start/atomic-habits", nudge.work.link)
        assertEquals(1, h.count)
    }

    @Test fun nothingWhenOffDoneOrQuiet() {
        assertNull(decide(c = base.copy(enabled = false)).first)
        assertNull(decide(c = base.copy(pending = emptyList())).first)
        assertNull(decide(minute = 23 * 60 + 30).first)
        assertNull(decide(minute = 6 * 60).first)
        assertNull(decide(c = base.copy(unlock = false)).first)
    }

    @Test fun twoHoursBetweenNudgesAndFourADay() {
        val (_, h1) = decide()
        assertNull(decide(h = h1, nowMs = t0 + 60 * 60_000L).first)
        val (second, h2) = decide(h = h1, nowMs = t0 + 121 * 60_000L)
        assertNotNull(second)
        val full = h2.copy(count = 4)
        assertNull(decide(h = full, nowMs = t0 + 600 * 60_000L).first)
    }

    @Test fun aNewDayStartsAFreshCount() {
        val old = NudgeHistory(day = "2026-10-20", count = 4, lastAtMs = t0)
        val (nudge, h) = decide(h = old, nowMs = t0 + 1)
        assertNotNull(nudge)
        assertEquals("2026-10-21", h.day)
        assertEquals(1, h.count)
    }

    @Test fun usageNudgesOncePerThresholdStep() {
        assertNull(decide(trigger = Trigger.Usage(insta, 14)).first)
        val (nudge, h) = decide(trigger = Trigger.Usage(insta, 16))
        assertEquals("16 min on Instagram", nudge!!.title)
        assertEquals("Read p. 45–46 · ≈ 4 min", nudge.body)
        val later = t0 + 130 * 60_000L
        assertNull(decide(h = h, trigger = Trigger.Usage(insta, 25), nowMs = later).first)
        assertNotNull(decide(h = h, trigger = Trigger.Usage(insta, 31), nowMs = later).first)
    }

    @Test fun quietHoursCanBeAnInsideRange() {
        val c = base.copy(quietStartMin = 12 * 60, quietEndMin = 14 * 60)
        assertNull(decide(c = c, minute = 13 * 60).first)
        assertNotNull(decide(c = c, minute = 15 * 60).first)
    }
}
